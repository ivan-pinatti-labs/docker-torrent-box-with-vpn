#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
"""Turn kcov's Cobertura report into SonarQube's generic coverage format.

kcov measures which lines of a shell script ran, and writes Cobertura XML.
SonarQube Cloud has no importer of its own for shell coverage, but it does
accept its generic coverage format for any file it analyzes, so this
rewrites one into the other.

It also holds the shell to 100%: every script named on the command line has
to appear in the report with every line covered. kcov has no threshold of
its own, and it leaves a script that never ran out of its report entirely,
so a script nobody tested would otherwise read as nothing to cover.

Usage: convert-kcov-coverage.py <root> <cobertura.xml> <output.xml> <script> [<script> ...]

<root> is where the repository was when kcov ran. Each script is a path
relative to it, the path SonarQube knows the file by.
"""

from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import PurePosixPath

USAGE = "Usage: convert-kcov-coverage.py <root> <cobertura.xml> <output.xml> <script> [<script> ...]"


def read_cobertura(path: str, root: str) -> dict[str, dict[int, bool]]:
    """Map each file in a Cobertura report to {line number: covered}.

    kcov names a file either absolutely or relative to one of the report's
    <source> directories, depending on how it was traced. Either way the
    name kept here is the file's path relative to `root`, which is the path
    SonarQube resolves; a file outside `root` keeps its absolute path, so it
    can never be mistaken for one of the repository's own.
    """
    # S314: the report is kcov's own output from the same `make coverage`
    # run, inside the same container, never a file from outside it.
    report = ET.parse(path).getroot()  # noqa: S314
    sources = [PurePosixPath(s.text or "/") for s in report.iter("source")] or [PurePosixPath("/")]
    base = PurePosixPath(root)
    files: dict[str, dict[int, bool]] = {}
    for cls in report.iter("class"):
        name = PurePosixPath(cls.get("filename", ""))
        if not name.is_absolute():
            name = sources[0] / name
        if name.is_relative_to(base):
            name = name.relative_to(base)
        lines = files.setdefault(str(name), {})
        for line in cls.iter("line"):
            number = int(line.get("number", "0"))
            lines[number] = lines.get(number, False) or int(line.get("hits", "0")) > 0
    return files


def to_generic(files: dict[str, dict[int, bool]]) -> ET.ElementTree:
    """Build SonarQube's generic coverage document from `read_cobertura`'s map."""
    coverage = ET.Element("coverage", version="1")
    for name in sorted(files):
        file = ET.SubElement(coverage, "file", path=name)
        for number, covered in sorted(files[name].items()):
            ET.SubElement(
                file,
                "lineToCover",
                lineNumber=str(number),
                covered="true" if covered else "false",
            )
    return ET.ElementTree(coverage)


def shortfalls(files: dict[str, dict[int, bool]], scripts: list[str]) -> list[str]:
    """Every reason the named scripts are not 100% covered, one per script."""
    problems = []
    for script in scripts:
        lines = files.get(script)
        if lines is None:
            problems.append(f"{script}: not in the report, so no test ran it")
            continue
        missed = [str(number) for number, covered in sorted(lines.items()) if not covered]
        if missed:
            problems.append(f"{script}: lines not covered: {', '.join(missed)}")
    return problems


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        print(USAGE, file=sys.stderr)
        return 2
    root, report, output, *scripts = argv
    files = read_cobertura(report, root)
    to_generic(files).write(output, encoding="utf-8", xml_declaration=True)
    problems = shortfalls(files, scripts)
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        return 1
    print(f"Shell coverage 100%: {', '.join(scripts)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
