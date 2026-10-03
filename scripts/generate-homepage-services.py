#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
"""Generate configs/homepage/config/services.yaml from services.yaml.template,
dropping any app whose compose profile is disabled in .env, and dropping any
section left empty as a result. Run on every `make start`, not just bootstrap,
so flipping a profile and restarting is enough to update Homepage; see the
comment at the top of services.yaml.template.

Also expands `${VAR}` from .env, which is what lets a widget point at an address
the deployment actually uses instead of a literal. The template used to hard code
gluetun's services address, so any checkout whose .env moved that subnet
regenerated a Homepage that pointed at the previous deployment's address on every
`make start`, and the widget answered with a timeout. Homepage's own
`{{HOMEPAGE_FILE_*}}` placeholders use different delimiters and are left alone.
"""

import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print(
        "ERROR: PyYAML is required (pip install --user pyyaml or your distro's "
        "python3-yaml/python3-pyyaml package) to generate Homepage's services.yaml.",
        file=sys.stderr,
    )
    sys.exit(1)

REPO_ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = REPO_ROOT / ".env"
TEMPLATE_FILE = REPO_ROOT / "configs/homepage/config/services.yaml.template"
OUTPUT_FILE = REPO_ROOT / "configs/homepage/config/services.yaml"

# Maps each entry's display name (the single key of its list item) to the
# .env *_PROFILE variable that gates it. Entries with no mapping here (there
# are none today) are always kept, since there's nothing to gate them on.
SERVICE_PROFILE = {
    "Sonarr": "SONARR_PROFILE",
    "Radarr": "RADARR_PROFILE",
    "Lidarr": "LIDARR_PROFILE",
    "Readarr": "READARR_PROFILE",
    "Mylar": "MYLAR_PROFILE",
    "Whisparr": "WHISPARR_PROFILE",
    "Bazarr": "BAZARR_PROFILE",
    "qBittorrent": "QBITTORRENT_PROFILE",
    "SABnzbd": "SABNZBD_PROFILE",
    "Prowlarr": "PROWLARR_PROFILE",
    "NZBHydra2": "NZBHYDRA2_PROFILE",
    "JDownloader2": "JDOWNLOADER2_PROFILE",
    "Jellyfin": "JELLYFIN_PROFILE",
    "Audiobookshelf": "AUDIOBOOKSHELF_PROFILE",
    "Calibre Web": "CALIBREWEB_PROFILE",
    "Calibre": "CALIBRE_PROFILE",
    "LazyLibrarian": "LAZYLIBRARIAN_PROFILE",
    "KOReader Sync": "KORSYNC_PROFILE",
    "Grafana": "GRAFANA_PROFILE",
    "Prometheus": "PROMETHEUS_PROFILE",
    "cAdvisor": "CADVISOR_PROFILE",
    # The Overview section's only entry embeds a Grafana dashboard, so it
    # rides on Grafana's own profile rather than having one of its own.
    "Metrics": "GRAFANA_PROFILE",
}


def read_env(env_file: Path) -> dict[str, str]:
    """Every KEY=value in .env, for `${VAR}` expansion in the template.

    Trailing comments and either quote style are stripped. read_profiles below
    parses the same file more loosely and can afford to, because it only compares
    a value against the literal "enabled"; a value that reaches this function is
    going into a URL, where an unnoticed ` # note` or a kept quote produces an
    address Homepage cannot parse and reports as the same timeout it reports for
    an address that is merely dead.
    """
    values = {}
    for line in env_file.read_text().splitlines():
        m = re.match(r"^([A-Z0-9_]+)=(.*)$", line)
        if not m:
            continue
        value = m.group(2).strip()
        if value[:1] in ("'", '"') and value[-1:] == value[:1] and len(value) > 1:
            value = value[1:-1]
        else:
            # Only an unquoted value can carry a trailing comment, and only when
            # the # is preceded by whitespace: a bare # is legal inside a value.
            # One whitespace character, not a run of them: the comment starts at
            # the same #, strip() drops the rest of the run, and `\s+#` had to
            # try every space of a long run from every position before failing.
            value = re.split(r"\s#", value, maxsplit=1)[0].strip()
        values[m.group(1)] = value
    return values


def expand(text: str, values: dict[str, str]) -> str:
    """Substitute `${VAR}` from .env, refusing anything .env does not define.

    Refusing rather than leaving the placeholder in place on purpose: a typo
    would otherwise reach Homepage as a literal `${FOO}` inside a URL, and a
    widget that cannot parse its own address reports the same timeout as one
    pointing somewhere dead, which is a considerably worse thing to debug.
    """
    missing = sorted(
        {
            name
            for name in re.findall(r"\$\{([A-Z0-9_]+)\}", text)
            if name not in values
        }
    )
    if missing:
        raise SystemExit(
            f"ERROR: {TEMPLATE_FILE.name} references {', '.join(missing)}, "
            f"which {ENV_FILE.name} does not define."
        )
    return re.sub(r"\$\{([A-Z0-9_]+)\}", lambda m: values[m.group(1)], text)


def read_profiles(env_file: Path) -> dict[str, bool]:
    profiles = {}
    for line in env_file.read_text().splitlines():
        m = re.match(r"^([A-Z0-9_]+_PROFILE)=(\S*)$", line)
        if m:
            profiles[m.group(1)] = m.group(2) == "enabled"
    return profiles


def is_enabled(name: str, profiles: dict[str, bool]) -> bool:
    var = SERVICE_PROFILE.get(name)
    if var is None:
        return True
    # Missing from .env entirely is not expected once bootstrapped, but
    # fails open (keeps the entry) rather than silently hiding an app over
    # a parsing mismatch.
    return profiles.get(var, True)


def main() -> None:
    """Write OUTPUT_FILE. A failure raises SystemExit; reaching the end is success."""
    if not ENV_FILE.is_file():
        print(f"{ENV_FILE} does not exist yet, skipping.", file=sys.stderr)
        return

    profiles = read_profiles(ENV_FILE)
    sections = yaml.safe_load(expand(TEMPLATE_FILE.read_text(), read_env(ENV_FILE)))

    filtered_sections = []
    for section in sections:
        (section_name, entries), = section.items()
        filtered_entries = [
            entry
            for entry in entries
            if is_enabled(next(iter(entry)), profiles)
        ]
        if filtered_entries:
            filtered_sections.append({section_name: filtered_entries})

    with OUTPUT_FILE.open("w") as f:
        f.write(
            "# Generated by scripts/generate-homepage-services.py from\n"
            "# services.yaml.template on every `make start`. Edit the template,\n"
            "# not this file: it gets overwritten.\n"
        )
        yaml.dump(filtered_sections, f, default_flow_style=False, sort_keys=False)

    # `make start` runs permissions_repair (scripts/permissions.py) before
    # this script, and permissions.yml's configs/homepage/config entry
    # (chown_files: true) already recursively chowns this file to
    # Homepage's own mapped UID/GID, which is what actually lets the
    # container read it regardless of the file's mode bits. That leaves the
    # host user access to write this file at all through the manifest's own
    # ACL grant, not ownership, so chmod (owner/root only, unlike a plain
    # write) fails here on any run after the very first: confirmed live,
    # PermissionError every time on a file already chowned by a prior
    # permissions_repair. Best-effort only; the container's own access does
    # not depend on it succeeding.
    try:
        OUTPUT_FILE.chmod(0o644)
    except PermissionError:
        pass


if __name__ == "__main__":
    main()
