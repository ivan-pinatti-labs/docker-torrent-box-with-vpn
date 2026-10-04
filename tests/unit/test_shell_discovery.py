"""The shell scripts `make coverage` measures are found, never listed.

The Makefile's COVERAGE_SHELL_SCRIPTS is every file git would commit that ends
in .sh or .bash or starts with a sh, bash or dash shebang, minus tests/ and the
vendored paths in SHELL_EXCLUDE, plus SHELL_EXTRA. These tests hold that in
place where the unit tier runs, which is a container with neither git nor a
.git directory: they apply the same rule to the tree in Python, check the
result against the scripts this repository is known to have, and check that
the Makefile still carries the rule rather than a hand list that could fall
behind.

The awk shebang pattern is read out of the Makefile and translated, not copied,
so this file and the Makefile cannot drift onto two different rules.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml

pytestmark = pytest.mark.unit

REPO_ROOT = Path(__file__).resolve().parents[2]
MAKEFILE = REPO_ROOT / "Makefile"
PRE_COMMIT = REPO_ROOT / ".pre-commit-config.yaml"

# Shell scripts this repository writes and measures. Every one has to be
# found; a missing one means the rule shrank coverage.
KNOWN_SCRIPTS = {
    ".claude/hooks/git-guard.sh",
    "configs/calibre/custom-cont-init.d/10-fix-library.sh",
    "scripts/assert-stack-started.sh",
    "scripts/auto-start.sh",
    "scripts/check-network-subnets.sh",
    "scripts/detect-system-values.sh",
    "scripts/disk-status.sh",
    "scripts/enable-test-profiles.sh",
    "scripts/korsync-users.sh",
    "scripts/prune-nginx-cache.sh",
    "scripts/rotate-all.sh",
    "scripts/rotate-api-keys.sh",
    "scripts/rotate-certificate.sh",
    "scripts/rotate-nginx-logs.sh",
    "scripts/rotate-passwords.sh",
    "scripts/schedule-backup.sh",
    "scripts/seed-calibre-library.sh",
    "scripts/seed-configs.sh",
    "scripts/seed-gluetun-secret.sh",
    "scripts/seed-nginx-ports.sh",
    "scripts/seed-secrets.sh",
    "scripts/seed-vpn-mock.sh",
    "scripts/storage-mount.sh",
    "scripts/wire-connections.sh",
}


def _variable(name: str) -> str:
    """The right hand side of `name :=` in the Makefile, continuations joined."""
    lines = MAKEFILE.read_text().splitlines()
    for index, line in enumerate(lines):
        if line.startswith(f"{name} :="):
            value = [line.split(":=", 1)[1]]
            while value[-1].endswith("\\"):
                index += 1
                value.append(lines[index])
            return " ".join(part.rstrip("\\").strip() for part in value).strip()
    raise AssertionError(f"{name} is not defined with := in the Makefile")


def _awk_shebang() -> str:
    """The awk shebang pattern as the Makefile writes it, with make's $$ undone."""
    match = re.search(r"\$\$0 ~ /(.+?[^\\])/\)", _variable("COVERAGE_SHELL_SCRIPTS"))
    assert match, "the Makefile's discovery rule has no `$$0 ~ /.../` shebang test"
    return match.group(1).replace("$$", "$")


def _shebang_regex() -> re.Pattern[str]:
    """The same pattern for Python's re: POSIX classes and escaped slashes."""
    pattern = (
        _awk_shebang()
        .replace("[^[:space:]]", r"\S")
        .replace("[[:space:]]", r"\s")
        .replace(r"\/", "/")
    )
    return re.compile(pattern)


def _candidates() -> list[str]:
    """The files git would commit, or every file when there is no git.

    The unit tier's container holds exactly the files git would commit, so a
    plain walk sees the same set there; outside it, ask git so ignored runtime
    state (configs/, data/, tests/.venv) is not read.
    """
    if (REPO_ROOT / ".git").exists() and shutil.which("git"):
        out = subprocess.run(
            ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            cwd=REPO_ROOT,
            check=True,
            capture_output=True,
        ).stdout.decode()
        return [path for path in out.split("\0") if path]
    found = []
    for directory, subdirectories, files in os.walk(REPO_ROOT):
        subdirectories[:] = [d for d in subdirectories if d != ".git"]
        for name in files:
            found.append((Path(directory) / name).relative_to(REPO_ROOT).as_posix())
    return found


def _is_shell(path: str, shebang: re.Pattern[str]) -> bool:
    if re.search(r"\.(sh|bash)$", path):
        return True
    with (REPO_ROOT / path).open("rb") as handle:
        first = handle.readline().decode("utf-8", "replace").rstrip("\n")
    return bool(shebang.search(first))


def discovered() -> set[str]:
    """COVERAGE_SHELL_SCRIPTS, computed the Makefile's way over this tree."""
    shebang = _shebang_regex()
    exclude = set(_variable("SHELL_EXCLUDE").split())
    extra = set(_variable("SHELL_EXTRA").split())
    shell = {
        path
        for path in _candidates()
        if (REPO_ROOT / path).is_file()
        and not path.startswith("tests/")
        and _is_shell(path, shebang)
    }
    return (shell - exclude) | extra


def test_the_makefile_finds_the_scripts_rather_than_listing_them():
    rule = _variable("COVERAGE_SHELL_SCRIPTS")
    assert "$(shell" in rule
    assert "git ls-files -z --cached --others --exclude-standard" in rule
    assert r"FILENAME ~ /\.(sh|bash)$$/" in rule
    assert "grep -v '^tests/'" in rule
    assert "$(filter-out $(SHELL_EXCLUDE)," in rule
    assert "$(SHELL_EXTRA)" in rule
    assert not re.search(r"(^|\s)[\w./-]+\.(sh|bash)(\s|$)", rule), (
        "COVERAGE_SHELL_SCRIPTS names a script by hand; add it to SHELL_EXTRA "
        "only if neither its name nor its shebang identifies it"
    )


@pytest.mark.parametrize(
    "line",
    [
        "#!/bin/sh",
        "#!/bin/bash",
        "#!/usr/bin/dash",
        "#!/usr/bin/env bash",
        "#!/usr/bin/env -S bash -e",
        "#! /bin/bash -eu",
        "#!bash",
    ],
)
def test_the_shebang_rule_finds_shell(line):
    assert _shebang_regex().search(line)


@pytest.mark.parametrize(
    "line",
    [
        "#!/usr/bin/env python3",
        "#!/usr/bin/zsh",
        "#!/usr/bin/fish",
        "#!/usr/bin/with-contenv bash",
        "#!/bin/bashful",
        "# !/bin/sh",
        "echo '#!/bin/sh'",
    ],
)
def test_the_shebang_rule_leaves_other_interpreters_alone(line):
    assert not _shebang_regex().search(line)


def test_every_known_script_is_found():
    missing = KNOWN_SCRIPTS - discovered()
    assert not missing, f"no longer found, so no longer measured: {sorted(missing)}"


def test_nothing_under_tests_is_measured():
    assert not [path for path in discovered() if path.startswith("tests/")]


def test_vendored_shell_stays_out():
    found = discovered()
    for path in _variable("SHELL_EXCLUDE").split():
        assert path not in found
    assert "configs/lidarr/custom-cont-init.d/scripts_init.bash" in _variable(
        "SHELL_EXCLUDE"
    )


def test_every_found_script_has_a_unit_test():
    untested = [
        path
        for path in sorted(discovered())
        if not (
            REPO_ROOT / "tests/unit" / f"{Path(path).name.removesuffix('.sh')}.test.sh"
        ).is_file()
    ]
    assert not untested, f"no tests/unit/<name>.test.sh for {untested}"


def test_the_coverage_hook_runs_for_every_found_script():
    config = yaml.safe_load(PRE_COMMIT.read_text())
    hooks = [hook for repo in config["repos"] for hook in repo.get("hooks", [])]
    (coverage,) = [hook for hook in hooks if hook["id"] == "coverage"]
    files = re.compile(coverage["files"])
    unmatched = [path for path in sorted(discovered()) if not files.search(path)]
    assert not unmatched, f"the coverage hook's `files` misses {unmatched}"


def test_discovery_refuses_unsafe_script_names():
    """A script name reaches make's recipes as shell text, so discovery has to
    refuse any name outside [A-Za-z0-9._/+-] (a committed `x;id;#.sh` would
    otherwise run `id`)."""
    here = Path(__file__).resolve().parent
    while not (here / "Makefile").is_file():
        here = here.parent
    text = (here / "Makefile").read_text()
    assert "_shell_safe = $(if $(filter UNSAFE:," in text
    assert "$(call _shell_safe," in text
    assert '? substr(FILENAME, 3) : "UNSAFE:")' in text
    # awk reads an operand like `shell=tool.sh` as a variable assignment, so
    # every path reaches it as `./path` and is printed without that prefix.
    assert 'printf "./%s\\0"' in text
