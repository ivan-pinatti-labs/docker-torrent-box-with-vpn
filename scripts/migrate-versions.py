#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
"""Clear the image pins an older .env still carries, so versions.env applies.

Image versions used to live in .env, a gitignored copy of .env.example made
once at setup. Renovate bumped .env.example, so every update stopped there and
a deployment pulling main kept running the images its .env named on the day it
was seeded. The pins now live in the committed versions.env, which the
Makefile reads before .env. Any pin left in .env still wins over it, which is
what makes a deliberate hold possible and also what keeps a stale copy alive.

This tells the two apart. A pin in .env with a comment line starting `# hold`
directly above it is a hold and stays. Every other line in .env that sets a
variable versions.env pins is a stale copy and goes, together with the
`# renovate:` annotation directly above it, which only ever meant something in
.env.example. .env is copied to .env.backup.<timestamp> first.

Usage: scripts/migrate-versions.py [--check]

--check reports what would change and changes nothing. `make start` runs it
that way, so a deployment that pulled without migrating is told why its images
did not move. `make migrate_versions` and `make update` run it for real.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
import tempfile
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ENV_FILE = REPO_ROOT / ".env"
VERSIONS_FILE = REPO_ROOT / "versions.env"

PIN_LINE = re.compile(r"^(?P<name>[A-Z0-9_]+_VERSION)=(?P<value>.*)$")
HOLD_LINE = re.compile(r"^#\s*hold\b", re.IGNORECASE)
ANNOTATION_LINE = re.compile(r"^#\s*renovate:")


def read_pins(path: Path) -> dict[str, str]:
    """Every `<NAME>_VERSION=<value>` in path, by name."""
    pins = {}
    for line in path.read_text().splitlines():
        match = PIN_LINE.match(line)
        if match:
            pins[match["name"]] = match["value"]
    return pins


def plan(env_lines: list[str], pins: dict[str, str]) -> tuple[list[str], list[tuple[str, str, str]]]:
    """The .env lines to keep, and one (name, value, verdict) per pin found.

    The verdict is "held", "stale" (differs from versions.env) or "same".
    """
    drop: set[int] = set()
    found = []
    for index, line in enumerate(env_lines):
        match = PIN_LINE.match(line)
        if not match or match["name"] not in pins:
            continue
        above = env_lines[index - 1] if index else ""
        if HOLD_LINE.match(above):
            found.append((match["name"], match["value"], "held"))
            continue
        verdict = "same" if match["value"] == pins[match["name"]] else "stale"
        found.append((match["name"], match["value"], verdict))
        drop.add(index)
        if ANNOTATION_LINE.match(above):
            drop.add(index - 1)
    kept = [line for index, line in enumerate(env_lines) if index not in drop]
    return kept, found


def short(value: str) -> str:
    """A pin without its digest, which is too long for a report line."""
    return value.split("@", 1)[0] or "(empty)"


def report(found: list[tuple[str, str, str]], pins: dict[str, str], check: bool) -> None:
    removing = "would remove" if check else "removed"
    for name, value, verdict in found:
        if verdict == "held":
            print(f"  {name}: {short(value)}, held (versions.env has {short(pins[name])})")
        elif verdict == "same":
            print(f"  {name}: {short(value)}, {removing}, same as versions.env")
        elif short(value) == short(pins[name]):
            print(f"  {name}: {short(value)}, {removing}, versions.env pins that tag to another digest")
        else:
            print(f"  {name}: {short(value)}, {removing}, versions.env has {short(pins[name])}")


def write_atomically(path: Path, text: str) -> None:
    """Replace path with text, keeping its mode, never leaving it half written."""
    mode = path.stat().st_mode & 0o7777
    handle, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(handle, "w") as stream:
            stream.write(text)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    except BaseException:
        os.unlink(temporary)
        raise


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="report only, change nothing")
    args = parser.parse_args(argv)

    if not VERSIONS_FILE.is_file():
        print(f"ERROR: {VERSIONS_FILE.name} not found; it is committed, so the checkout is incomplete.", file=sys.stderr)
        return 1
    if not ENV_FILE.is_file():
        print(f"No {ENV_FILE.name} yet, nothing to migrate.")
        return 0

    pins = read_pins(VERSIONS_FILE)
    text = ENV_FILE.read_text()
    kept, found = plan(text.splitlines(), pins)
    removed = [entry for entry in found if entry[2] != "held"]

    if not removed:
        if found:
            print(f"{ENV_FILE.name} holds {len(found)} image pin(s) back on purpose:")
            report(found, pins, args.check)
        elif not args.check:
            print(f"{ENV_FILE.name} carries no image pins; versions.env applies as committed.")
        return 0

    if args.check:
        print(f"NOTICE: {ENV_FILE.name} still pins {len(removed)} image(s), which override versions.env:")
        report(found, pins, args.check)
        print("Run 'make migrate_versions' to clear them (it backs .env up first), or")
        print("mark one you mean to keep with a '# hold' comment line directly above it.")
        return 0

    backup = ENV_FILE.with_name(f"{ENV_FILE.name}.backup.{time.strftime('%Y-%m-%d-%H%M%S')}")
    shutil.copy2(ENV_FILE, backup)
    new_text = "\n".join(kept)
    if kept and text.endswith("\n"):
        new_text += "\n"
    write_atomically(ENV_FILE, new_text)
    print(f"Cleared {len(removed)} image pin(s) from {ENV_FILE.name}; versions.env applies to them now:")
    report(found, pins, args.check)
    print(f"The previous {ENV_FILE.name} is at {backup.name}.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
