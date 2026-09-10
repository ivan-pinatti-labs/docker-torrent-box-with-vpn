"""Static checks that every pinned container image is actually watched.

A pin and a watched pin look identical in `.env.example`. Twelve pins sat in
the `### VERSIONS` block with no `# renovate:` annotation above them, so
nothing bumped them and they froze, several for more than a year, while the
file still read as fully pinned. Nothing in the repository said so, which is
the only reason it lasted. These tests make that state fail on the pull
request that introduces it.

Three ways a pin goes quiet without looking wrong, one test each. No
annotation at all, so Renovate never sees the variable. An annotation the
customManager's regex cannot parse, which reads as watched to a person and is
invisible to the bot. A `packageRules` entry naming a package no annotation
declares: one rule listed five observability images by bare repository name
while the annotations are registry-qualified, so it matched zero of its five
members, and another named `ghcr.io/tprasadtp/protonwire`, which this
repository has never pulled.

Marked `prerequisites` rather than carrying a marker of its own, so
`make test_prerequisites` picks it up. That target is what the `Prerequisite
Checks` job in .github/workflows/pull-request-validation.yml runs, so these
gate every pull request without waiting on the integration suite, which is the
point: an unwatched pin is a review-time mistake, not a runtime failure.

No containers and no stack state, so these run anywhere:
    pytest -m prerequisites tests/test_renovate_pins.py
"""

import re
from pathlib import Path

import json5
import pytest
import yaml

from conftest import REPO_ROOT

pytestmark = pytest.mark.prerequisites

ENV_EXAMPLE = REPO_ROOT / ".env.example"
RENOVATE_CONFIG = REPO_ROOT / ".github" / "renovate.json5"
PRE_COMMIT_CONFIG = REPO_ROOT / ".pre-commit-config.yaml"
WORKFLOWS = REPO_ROOT / ".github" / "workflows"

# The block heading in .env.example that holds the image pins. Scoping to it
# matters: PYTHON_VERSION and STORAGE_CIFS_VERSION are named exactly like image
# pins and are not images (one feeds actions/setup-python, the other is an SMB
# protocol level), and both live outside this block.
VERSIONS_HEADING = "### VERSIONS"

# Tags deliberately left on a channel rather than a version. There is no
# version here for Renovate to bump, so an annotation would only produce
# lookup failures on the dashboard. Every entry has to keep earning its place:
# test_exemption_still_covers_something fails when one names a variable
# .env.example no longer defines.
FLOATING = {
    "NGINX_VERSION": "stable-alpine is a channel tag, not a version",
    "PLEX_VERSION": (
        "not in the default stack (PLEX_PROFILE=disabled); latest is also a "
        "channel tag with no digest to pin anyway"
    ),
}

# Annotated pins that must not carry a digest. Both are consumed twice, as the
# tag of a locally built wrapper image (`image: lazylibrarian-calibre:${...}`
# and `image: mylar-pyopenssl:${...}` in docker-compose-servarr.yml) and as the
# BASE_VERSION build arg the wrapper's Dockerfile pulls its base with. A
# reference carrying both a tag and a digest cannot name a locally built image:
# `podman build -t probe:1.0@sha256:0000...` exits 125 with "Docker references
# with both a tag and digest are currently not supported", and `podman tag`
# refuses the same reference with "tag by digest not supported". A digest in
# either value would therefore break the build rather than pin anything, which
# is why pinDigests has to be allowed to leave these two alone.
NO_DIGEST = {
    # LAZYLIBRARIAN_VERSION was here until 2026-09-03 for exactly this reason,
    # and came off by splitting the two uses: the wrapper's own image is now
    # tagged `local` in docker-compose-servarr.yml, leaving the variable to
    # name only the base, which can then carry a digest. MYLAR_VERSION has the
    # identical shape and the same fix applies to it, once its patch clears
    # and there is a reason to touch the file; see issue #106.
    "MYLAR_VERSION": (
        "also the BASE_VERSION build arg and the local wrapper image's own tag, "
        "and a container runtime rejects a reference with both a tag and a digest"
    ),
}

# Pins with no service in any compose file, so there is no image reference to
# check an annotation's depName against. Kept as an explicit exemption rather
# than skipped silently, so the day a service appears the omission surfaces.
NO_SERVICE = {
    "JACKETT_VERSION": (
        "legacy app, kept for existing setups; no service block in any compose "
        "file, only a commented port mapping in docker-compose-vpn.yml"
    ),
}

# Volumes mounted from here mark a service as running patched code.
PATCH_MOUNT_PREFIX = "./patches/"

# The two locally built wrappers. Their compose `image:` names a tag this
# repository builds, not something a registry serves, so the image an
# annotation has to describe is the wrapper's base instead.
LOCAL_BUILD_DOCKERFILES = {
    "LAZYLIBRARIAN_VERSION": "build/lazylibrarian/Dockerfile",
    "MYLAR_VERSION": "build/mylar/Dockerfile",
}

# `#?` on both patterns is load-bearing. The notifiarr service in
# docker-compose-servarr.yml is commented out in full, and NOTIFIARR_VERSION
# still rots exactly like a live pin: a commented service is one uncomment away
# from running, and the pin it comes back with is whatever was frozen here.
IMAGE_LINE = re.compile(r"^\s*#?\s*image:\s*(?P<ref>\S+):\$\{(?P<var>[A-Z0-9_]+)\}\s*$")
BUILD_ARG_LINE = re.compile(r"^\s*#?\s*BASE_VERSION:\s*\$\{(?P<var>[A-Z0-9_]+)\}\s*$")

# The FROM that consumes BASE_VERSION, not the first FROM in the file.
# build/lazylibrarian/Dockerfile is multi stage and its first stage pulls
# ghcr.io/linuxserver/mods, so taking the first FROM would compare an
# annotation against the wrong image entirely.
FROM_BASE_VERSION = re.compile(r"^FROM\s+(?P<ref>\S+):\$\{BASE_VERSION\}", re.MULTILINE)

# Any `# renovate:` comment declaring a depName, wherever it sits and whatever
# else it carries. Deliberately looser than the customManager regexes: this is
# what a reader would call an annotation, and comparing it against what the
# config can actually parse is the whole of
# test_renovate_regex_matches_every_annotation.
ANNOTATION = re.compile(r"#\s*renovate:.*?\bdepName=(\S+)")

DIGEST_SUFFIX = re.compile(r"@sha256:[0-9a-f]{64}$")


def _versions_block() -> list[str]:
    """The lines under `### VERSIONS`, up to the next `###` heading."""
    lines = ENV_EXAMPLE.read_text().splitlines()
    starts = [i for i, line in enumerate(lines) if line.strip() == VERSIONS_HEADING]
    assert starts, f"no `{VERSIONS_HEADING}` heading in {ENV_EXAMPLE.name}"
    block = []
    for line in lines[starts[0] + 1 :]:
        if line.startswith("###"):
            break
        block.append(line)
    return block


def _pins() -> dict[str, str]:
    """Every `<NAME>_VERSION=<value>` in the versions block, by variable name.

    The `_VERSION` suffix rather than every assignment in the block, so a
    variable dropped in here that is not a version does not start demanding an
    annotation it has no use for.
    """
    pins = {}
    for line in _versions_block():
        match = re.match(r"^(?P<var>[A-Z0-9_]+_VERSION)=(?P<value>.*)$", line)
        if match:
            pins[match["var"]] = match["value"].strip()
    return pins


def _annotations() -> dict[str, str]:
    """depName declared on the line directly above each pin, by variable name.

    Directly above, not anywhere nearby: the customManager's regex requires the
    annotation and the assignment to be adjacent lines, so an annotation with a
    blank line or a stray comment between them is one Renovate cannot use.
    """
    annotations = {}
    block = _versions_block()
    for index, line in enumerate(block):
        match = re.match(r"^(?P<var>[A-Z0-9_]+_VERSION)=", line)
        if not match or index == 0:
            continue
        declared = ANNOTATION.search(block[index - 1])
        if declared:
            annotations[match["var"]] = declared.group(1)
    return annotations


def _compose_files() -> list[Path]:
    """Every compose file, including the per-service VPN route overrides.

    The route files carry no `image:` today. They are read anyway because they
    are compose files that could grow one, and a pin is only unwatched once.
    """
    return sorted(REPO_ROOT.glob("docker-compose*.yml")) + sorted(
        (REPO_ROOT / "docker-compose.routes").glob("*.yml")
    )


def _compose_image_refs() -> dict[str, str]:
    """Variable name to the image repository a compose file interpolates it into."""
    refs = {}
    for path in _compose_files():
        for line in path.read_text().splitlines():
            match = IMAGE_LINE.match(line)
            if match:
                refs[match["var"]] = match["ref"]
    return refs


def _compose_build_args() -> set[str]:
    """Variables passed to a build as BASE_VERSION."""
    found = set()
    for path in _compose_files():
        for line in path.read_text().splitlines():
            match = BUILD_ARG_LINE.match(line)
            if match:
                found.add(match["var"])
    return found


def _watched_candidates() -> list[str]:
    """Every variable that names a container image version.

    The union of what the compose files interpolate and what the versions block
    pins, not either one alone. A compose file is the authority on what the
    stack pulls, but JACKETT_VERSION shows why that is not enough: no compose
    file carries a service for it, the pin ships to every clone regardless, and
    a compose-only sweep would call it watched by never looking at it at all.
    """
    return sorted(
        _compose_image_refs() | dict.fromkeys(_compose_build_args()) | _pins()
    )


def _canonical_image(image: str) -> str:
    """Collapse the two spellings of a Docker Hub official image into one.

    `docker.io/alpine` and `docker.io/library/alpine` are the same repository
    and both spellings are in use here (`docker.io/nginx` in the proxy compose
    file, `docker.io/library/python` in the observability one), so comparing
    them literally would fail on a difference that does not exist.
    """
    parts = image.split("/")
    if len(parts) == 2 and parts[0] == "docker.io":
        return f"docker.io/library/{parts[1]}"
    return image


def _dockerfile_base(variable: str) -> str:
    """The repository a locally built wrapper's Dockerfile pulls its base from."""
    path = REPO_ROOT / LOCAL_BUILD_DOCKERFILES[variable]
    match = FROM_BASE_VERSION.search(path.read_text())
    assert match, f"no `FROM <image>:${{BASE_VERSION}}` line in {path}"
    return match["ref"]


def _renovate_config() -> dict:
    """The parsed .github/renovate.json5.

    json5 rather than stripping comments by hand: the config carries `//`
    inside a string value (the $schema URL), so a naive stripper eats the rest
    of that line and corrupts the document it is trying to read.
    """
    return json5.loads(RENOVATE_CONFIG.read_text())


def _manager_matches(pattern: str, filename: str) -> bool:
    """Whether one managerFilePatterns entry selects a file.

    Renovate accepts both a `/regex/` and a bare glob here. Only the regex form
    is used in this repository, so the glob case falls back to a literal
    comparison rather than pulling in a glob engine to translate a form nothing
    writes.
    """
    if pattern.startswith("/") and pattern.endswith("/"):
        return re.search(pattern[1:-1], filename) is not None
    return pattern == filename


def _env_manager() -> dict:
    """The customManagers entry that reads .env.example."""
    managers = [
        manager
        for manager in _renovate_config()["customManagers"]
        if any(
            _manager_matches(pattern, ENV_EXAMPLE.name)
            for pattern in manager["managerFilePatterns"]
        )
    ]
    assert len(managers) == 1, (
        f"expected exactly one customManager reading {ENV_EXAMPLE.name}, "
        f"found {len(managers)}"
    )
    return managers[0]


def _to_python_regex(pattern: str) -> str:
    """Rewrite a RE2 named group into Python's spelling of the same thing.

    Renovate's patterns are RE2 flavoured, where a named group is
    `(?<name>...)`; Python's `re` spells it `(?P<name>...)` and rejects the
    other form outright. That rename is the only edit this pattern needs, so
    what the test runs is the config's own regex character for character apart
    from three group names. It is also safe against the one thing that could
    make the rename wrong: a lookbehind is `(?<=` or `(?<!`, and renaming
    either produces an invalid pattern that raises rather than quietly meaning
    something else.
    """
    return pattern.replace("(?<", "(?P<")


def _package_rule_names() -> list[str]:
    """Every literal package name any packageRules entry matches on.

    Renovate also accepts patterns here (`/regex/`, a `*` glob, a leading `!`
    for a negation), which name nothing on their own and are skipped: only a
    literal claims a specific dependency exists.
    """
    names = set()
    for rule in _renovate_config().get("packageRules", []):
        for name in rule.get("matchPackageNames", []):
            if name.startswith(("/", "!")) or "*" in name:
                continue
            names.add(name)
    return sorted(names)


def _annotated_dependency_names() -> set[str]:
    """Every depName any `# renovate:` annotation in the repository declares."""
    sources = [ENV_EXAMPLE, PRE_COMMIT_CONFIG, *sorted(WORKFLOWS.glob("*.yml"))]
    declared = set()
    for path in sources:
        declared.update(ANNOTATION.findall(path.read_text()))
    return declared


def test_versions_block_holds_pins():
    """Guard the parametrized lists below against silently collecting nothing."""
    assert len(_pins()) > 20, f"only {len(_pins())} pins found in {ENV_EXAMPLE.name}"
    assert len(_annotations()) > 10, "almost nothing in .env.example is annotated"
    assert len(_compose_image_refs()) > 20, "almost no compose image lines matched"


@pytest.mark.parametrize("variable", _watched_candidates())
def test_image_pin_is_watched(variable):
    """Every image version variable needs a `# renovate:` annotation above it."""
    if variable in FLOATING:
        pytest.skip(f"deliberately floating: {FLOATING[variable]}")
    pins = _pins()
    assert variable in pins, (
        f"{variable} is interpolated by a compose file but no pin defines it "
        f"under {VERSIONS_HEADING} in {ENV_EXAMPLE.name}"
    )
    assert variable in _annotations(), (
        f"{variable} carries no `# renovate: depName=<image>` comment on the "
        f"line directly above it in {ENV_EXAMPLE.name}, so Renovate cannot see "
        f"it and the pin stays frozen at {pins[variable]} forever. Add the "
        f"annotation naming the registry-qualified image the compose file "
        f"pulls, or add {variable} to FLOATING in this file if the tag is meant "
        f"to track a channel."
    )


@pytest.mark.parametrize("variable", sorted(_annotations()))
def test_watched_pin_carries_digest(variable):
    """A watched pin needs a digest, or a republished tag changes what runs."""
    if variable in NO_DIGEST:
        pytest.skip(f"digest exempt: {NO_DIGEST[variable]}")
    value = _pins()[variable]
    assert DIGEST_SUFFIX.search(value), (
        f"{variable}={value} has no `@sha256:<digest>` suffix, so the tag alone "
        f"decides what runs and a republished tag changes it with no pull "
        f"request saying so. Renovate's pinDigests adds one on the next bump; "
        f"add {variable} to NO_DIGEST with a reason if it genuinely cannot "
        f"carry a digest."
    )


@pytest.mark.parametrize(
    ("collection", "variable"),
    [("FLOATING", name) for name in sorted(FLOATING)]
    + [("NO_DIGEST", name) for name in sorted(NO_DIGEST)]
    + [("NO_SERVICE", name) for name in sorted(NO_SERVICE)],
)
def test_exemption_still_covers_something(collection, variable):
    """An exemption naming a pin that no longer exists has to fail, not pass.

    A stale entry is worse than no entry: it reads as a considered decision
    while covering nothing, and it would go on covering nothing if the variable
    came back under a different name.
    """
    assert variable in _pins(), (
        f"{collection} names {variable}, which {ENV_EXAMPLE.name} no longer "
        f"defines under {VERSIONS_HEADING}. Drop the entry from {collection} in "
        f"this file."
    )


def test_renovate_regex_matches_every_annotation():
    """Renovate's own regex has to capture every annotation a reader can see.

    This is the check for an annotation that looks right and parses to nothing.
    The regex demands `# renovate: depName=` with nothing in between, so an
    annotation that leads with `datasource=` is read by a person as watched and
    by Renovate as a comment, with no error anywhere to say so.
    """
    text = ENV_EXAMPLE.read_text()
    captured = set()
    for pattern in _env_manager()["matchStrings"]:
        captured.update(
            match.group("depName")
            for match in re.finditer(_to_python_regex(pattern), text)
        )
    declared = set(ANNOTATION.findall(text))
    assert captured == declared, (
        f"the customManager regex in {RENOVATE_CONFIG.name} does not capture "
        f"every annotation in {ENV_EXAMPLE.name}. Annotated but not captured, "
        f"so watched by nobody: {sorted(declared - captured)}. Captured but not "
        f"annotated, so the regex is reading something else: "
        f"{sorted(captured - declared)}."
    )


@pytest.mark.parametrize("package", _package_rule_names())
def test_package_rule_names_a_real_dependency(package):
    """A packageRules entry has to name a package some annotation declares.

    A name that matches nothing costs nothing to write and silently disables
    whatever the rule was for. The observability group listed five images by
    bare repository name while the annotations are registry-qualified, so it
    matched 0 of its 5 members and quietly stopped grouping anything; another
    rule named ghcr.io/tprasadtp/protonwire, which this repository has never
    pulled.
    """
    assert package in _annotated_dependency_names(), (
        f"packageRules in {RENOVATE_CONFIG.name} matches on {package!r}, which "
        f"no `# renovate:` annotation declares in {ENV_EXAMPLE.name}, "
        f"{PRE_COMMIT_CONFIG.name} or .github/workflows/. The rule therefore "
        f"applies to nothing. depName is the authority: match on the exact "
        f"string the pin's own annotation carries, registry and all."
    )


@pytest.mark.parametrize("variable", sorted(_annotations()))
def test_annotation_names_the_image_the_stack_pulls(variable):
    """An annotation has to describe the image the compose file actually pulls.

    A depName that resolves in a registry but is not what runs here produces
    pull requests bumping a version this stack never uses, and they look
    entirely ordinary.
    """
    declared_name = _annotations()[variable]
    refs = _compose_image_refs()
    if variable in NO_SERVICE:
        assert variable not in refs, (
            f"NO_SERVICE claims {variable} has no service, but a compose file "
            f"pulls {refs.get(variable)} with it. Drop the NO_SERVICE entry so "
            f"the annotation is checked against that image."
        )
        pytest.skip(f"no compose service: {NO_SERVICE[variable]}")
    if variable in LOCAL_BUILD_DOCKERFILES:
        expected = _dockerfile_base(variable)
        source = LOCAL_BUILD_DOCKERFILES[variable]
    else:
        assert variable in refs, (
            f"{variable} is annotated but no compose file interpolates it into "
            f"an `image:` line. Add the service, or record it in NO_SERVICE "
            f"with the reason."
        )
        expected = refs[variable]
        source = "the compose `image:` line"
    assert _canonical_image(declared_name) == _canonical_image(expected), (
        f"{variable} is annotated `depName={declared_name}` but {source} names "
        f"{expected}, so Renovate is watching the wrong image. Point the "
        f"annotation at {expected}."
    )


class _ComposeLoader(yaml.SafeLoader):
    """SafeLoader that tolerates Compose's own YAML tags.

    The per service override files under docker-compose.routes/ write
    `networks: !reset []`, and `!reset` and `!override` are Compose's, not
    YAML's, so SafeLoader refuses the document outright. Reading them as None is
    enough here, because this module only asks which service mounts a patch and
    a tagged value never answers that. tests/test_compose_config.py never hit
    this: it reads only the top level compose files.
    """


_ComposeLoader.add_multi_constructor("!", lambda loader, suffix, node: None)


def _load_compose(path: Path):
    """Parse one compose file with the loader above.

    The loader is driven directly rather than through `yaml.load(...,
    Loader=_ComposeLoader)`, which is the same thing: bandit's B506 fires on any
    `yaml.load` call whatever loader it is handed, and a suppression would read
    as "we know this is unsafe" when the loader is a SafeLoader subclass.
    """
    loader = _ComposeLoader(path.read_text())
    try:
        return loader.get_single_data()
    finally:
        loader.dispose()


def _patched_service_variables() -> dict[str, str]:
    """Image version variable to service name, for services running a patch.

    Parsed as YAML rather than scanned line by line, unlike the helpers above,
    because a patch mount only matters together with the `image:` line in the
    same service block and a line scan cannot tell which service a volume
    belongs to. The compose files lean on anchors and `<<` merge keys, which
    the loader resolves the same way safe_load would.
    """
    patched = {}
    for path in _compose_files():
        document = _load_compose(path) or {}
        for name, service in (document.get("services") or {}).items():
            if not isinstance(service, dict):
                continue
            volumes = service.get("volumes") or []
            mounts = [volume for volume in volumes if isinstance(volume, str)]
            if not any(mount.startswith(PATCH_MOUNT_PREFIX) for mount in mounts):
                continue
            match = re.search(r"\$\{([A-Z0-9_]+)\}", str(service.get("image", "")))
            assert match, f"service {name} mounts a patch but pins no image variable"
            patched[match.group(1)] = name
    return patched


def _held_dependency_names() -> set[str]:
    """Packages some packageRules entry switches off with `enabled: false`."""
    held = set()
    for rule in _renovate_config().get("packageRules", []):
        if rule.get("enabled") is False:
            held.update(rule.get("matchPackageNames", []))
    return held


def _digest_exempt_dependency_names() -> set[str]:
    """Packages some packageRules entry holds out of pinDigests."""
    exempt = set()
    for rule in _renovate_config().get("packageRules", []):
        if rule.get("pinDigests") is False:
            exempt.update(rule.get("matchPackageNames", []))
    return exempt


def test_patched_services_were_found():
    """Guard the parametrize below: an empty sweep would pass every case."""
    assert len(_patched_service_variables()) >= 2, (
        f"only {len(_patched_service_variables())} services mount a patch, and "
        f"two do: sabnzbd and mylar. lazylibrarian and jdownloader2 dropped "
        f"theirs on 2026-09-02 once the fixes reached their images (#109, #107); "
        f"if this count falls further, check that was deliberate rather than a "
        f"mount going missing"
    )


@pytest.mark.parametrize("variable", sorted(_patched_service_variables()))
def test_patched_image_is_held_at_a_fixed_version(variable):
    """A service running patched code needs its image held, not bumped.

    A patch shadows one file inside the image and nothing here can tell whether
    the shadowing copy still matches the file it replaces, so an unattended bump
    pairs patched old source with new upstream code and the result starts,
    reports healthy and passes the suite while being subtly wrong. Holding the
    pin is the decision; the alternative is re-deriving every patch against
    every release, forever. Dropping the patch is what unfreezes the pin, and
    An issue labelled `upstream-blocked` tracks each patch for exactly that.
    """
    service = _patched_service_variables()[variable]
    declared = _annotations().get(variable)
    assert declared, (
        f"{service} mounts a file from {PATCH_MOUNT_PREFIX}, and {variable} "
        f"carries no `# renovate:` annotation, so there is no depName to hold. "
        f"Annotate the pin first."
    )
    assert declared in _held_dependency_names(), (
        f"{service} runs a file bind mounted from {PATCH_MOUNT_PREFIX}, but "
        f"{declared} is not held in {RENOVATE_CONFIG.name}, so Renovate will "
        f"bump the image out from under the patch. Add it to the "
        f"`enabled: false` rule there, or drop the patch."
    )


@pytest.mark.parametrize("variable", sorted(NO_DIGEST))
def test_digest_exemption_is_backed_by_the_config(variable):
    """A pin this file excuses from a digest needs pinDigests off in the config.

    The two halves have to agree or the exemption is worse than useless. This
    file skipping the digest check only records that the pin is allowed to have
    none; `pinDigests` is on globally, so without a rule turning it off for the
    same package Renovate opens a pinDigest pull request adding one anyway, and
    that pull request is what breaks the wrapper build. Exactly that update was
    already pending for lazylibrarian before the rule existed.
    """
    declared = _annotations().get(variable)
    assert declared, (
        f"NO_DIGEST names {variable}, which carries no `# renovate:` annotation, "
        f"so there is no depName to hold pinDigests off for."
    )
    assert declared in _digest_exempt_dependency_names(), (
        f"{variable} is in NO_DIGEST, but {declared} has no `pinDigests: false` "
        f"rule in {RENOVATE_CONFIG.name}, so Renovate will add the digest this "
        f"file excuses it from. Add the package to that rule, or drop the "
        f"exemption."
    )
