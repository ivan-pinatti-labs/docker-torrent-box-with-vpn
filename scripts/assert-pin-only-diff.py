#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
"""Refuse a unified diff that changes anything but a dependency pin.

Read a diff on stdin (`gh pr diff <n> | scripts/assert-pin-only-diff.py`) and
exit non-zero unless every changed file is one of the pin files below and every
changed line differs from its counterpart in nothing but a version or digest.

This is the check that stands between "renovate[bot] opened a pull request" and
an unattended merge. Without it, approving a bot's pull request on the strength
of its author means the bot identity holds write access to main: a compromised
Renovate, or a Renovate whose configuration has been edited to widen what it
manages, could rewrite a workflow and be approved for it. Two of the five
allowed paths are executable surfaces on their own, since the pip pins live in
workflow `run:` steps and the scanner image tags live inside pre-commit hook
`entry:` commands, so a path allowlist alone would not be much of a fence. The
line comparison is what makes it one.

The comparison normalizes both sides and requires them to match line for line
per file, duplicates counted. A line whose structure changed has no counterpart
and the diff is refused, which covers `uses: actions/checkout@v7` becoming
`uses: evil/checkout@v7` as much as it covers an added `curl | sh`. Anything
this refuses is not broken, it just waits for a person: the approval is skipped
and the pull request sits there, which is the direction to fail in.

Only a number in a pin position is treated as substitutable, which is narrower
than "any number on the line" and deliberately so. `PUID=1000` becoming
`PUID=0`, or a `timeout-minutes:` moving, are numeric edits with real effects
that a looser rule would wave through, so they are refused like any other
structural change. The residue is a number that sits in a pin position and is
not a pin, which in these five files means an image tag's port-like suffix and
little else.

What it deliberately does not catch: a bump to a version that exists but is
malicious. `checkov==3.3.2` becoming `checkov==3.3.11` is the change this file
exists to permit, and no amount of diff reading can tell a good release from a
backdoored one. That is what the cooling window in .github/renovate.json5, the
integration suite, and the scanners are for. See docs/HARDENING.md.
"""

import re
import sys
from collections import Counter

# The files Renovate, the only dependency bot here, is allowed to touch:
# .env.example for image pins, the workflow directory for the pip pins and
# GitHub Actions versions it maintains there, .pre-commit-config.yaml for hook
# revs, additional_dependencies and the scanner image tags, tests/requirements.txt
# for the pip pins the test suite runs on, and .tool-versions for the asdf
# managed tools. Dependabot managed the pre-commit, github-actions and pip
# ecosystems from a separate set of pin positions across the same files until
# its version updates were retired; see docs/DEPENDENCY_UPDATES.md,
# "Retiring Dependabot". Nothing here shrank when it left, since Renovate's
# native managers for those three ecosystems write into the same files.
ALLOWED_PATHS = (
    ".env.example",
    ".pre-commit-config.yaml",
    ".github/workflows/",
    "tests/requirements.txt",
    ".tool-versions",
)

# `.tool-versions` writes `<tool> <version>`, one per line, with nothing to
# anchor on but the space. That cannot go in the prefix set below, because a
# lookbehind of variable width is not allowed and "the word after a space" would
# match most of a workflow file. It is matched whole-line instead, and only for
# that file, which is why normalize takes the path.
TOOL_VERSION_LINE = re.compile(r"^(?P<prefix>[A-Za-z0-9_.-]+[ \t]+)\S+[ \t]*$")

# A released version, always starting with a digit (an optional single leading
# `v` aside): `v7`, `v7.0.1`, `3.1.0`. Anchors the trailing comment on a GitHub
# Actions pin below, and is deliberately narrower than "any tag-shaped token":
# a floating ref like `main` is made entirely of characters that shape would
# otherwise accept.
RELEASE = r"v?[0-9][0-9A-Za-z.+_-]*"

# Removed outright rather than replaced with a placeholder: Renovate's
# pinDigests adds a digest to a line that had none, so a placeholder would make
# the before and after differ by its presence and refuse a legitimate first pin.
# This is a Docker image digest (`.env.example` only); a GitHub Actions SHA pin
# is handled separately below, because it can carry a trailing release comment
# that has to normalize together with the SHA.
DIGEST = re.compile(r"@sha256:[0-9a-f]{7,}")

# A GitHub Actions pin: a full 40 character commit SHA, optionally followed by
# a trailing release comment (`# v7`, `# v7.0.1`) that the dependency bot
# rewrites on the same bump whenever the tag the SHA resolves from changes.
# Both have to normalize together: an earlier version of this script
# normalized only the SHA and left the comment as ordinary text, so an
# ordinary bump that also moved `# v7` to `# v7.0.1` read as a structural
# change and `Pin Only` refused a diff that was actually pin-only. Every
# grouped Actions update makes this a near-certainty rather than an edge
# case, since one bump is enough to trip it.
#
# The comment is folded into the normalization only when it is actually a
# release token running to the end of the line; anything else after the SHA,
# including a comment with extra text trailing a valid version token, is left
# alone, so it is still read as a structural change if it differs between the
# two sides. The negative lookahead after the hex run stops a 40 character
# prefix of a longer hex run (a sha256 digest, in particular) from matching
# and silently swallowing the character that would have made the shapes
# differ.
ACTION_SHA = re.compile(
    r"@[0-9a-f]{40}(?![0-9a-fA-F])(?P<comment>[ \t]+#[ \t]*" + RELEASE + r")?$"
)


def _normalize_action_sha(match: re.Match[str]) -> str:
    """Strip a `@<sha>` action pin, normalizing its trailing release comment."""
    if match.group("comment"):
        return " # <version>"
    return ""


# A version-shaped token that sits where a pin sits, and nowhere else. The
# prefix is what makes this narrow: matching any number on the line would accept
# `PUID=1000` becoming `PUID=0`, or a `fetch-depth` moving, since both sides
# would normalize alike.
#
# The six prefixes are the shapes a pin takes everywhere except .tool-versions,
# which is handled whole-line above:
#
#   ==1.2.3              pip, in a workflow run step or additional_dependencies
#   >=1.2.3              pip, in tests/requirements.txt, which pins floors
#                        rather than exact versions
#   @v1.2.3              an action ref, and what is left after a digest is cut
#   FOO_VERSION=1.2.3    .env.example, where a bare `=` is not enough: PUID and
#                        the port variables use one too
#   rev: v1.2.3          a pre-commit hook revision
#   image:1.2.3          a tag, the colon pressed against a non-space so that a
#                        YAML `key: 25` cannot pass for one
#
# `>=` was missing until it was noticed on PR #94, a Dependabot bump of
# tests/requirements.txt, which that pull request has been failing `Pin Only`
# on ever since: every line in that file is a `>=` floor, so no bump of it
# could ever grade pin-only and every one of them waited for a person for a
# reason nobody could see from the status. Only `>=` is added, not the rest of
# pip's operator vocabulary: `==` and `>=` are the only two that appear
# anywhere in ALLOWED_PATHS, and inventing shapes this repository does not use
# would widen what a bot may push for no benefit. The prefix is still captured
# and put back, so `docker>=7.2.0` becoming `docker==7.2.0` is a change of pin
# shape and still reads as a difference.
# The prefix is captured and put back, so that a pin changing shape rather than
# value, `foo==1.2.3` becoming `foo@1.2.3`, still reads as a difference.
# The token is any tag-shaped run of characters, and the narrowing lives entirely
# in the prefix rather than in the shape. Two rounds of guessing at the shape
# were both wrong: `\d+(\.\d+)*` matched only the `40` of lazylibrarian's
# `40a389ea-ls310` and refused PR #62, and requiring a leading digit still
# refused `KORSYNC_VERSION=sha-7bcefd34...`, which is what korsync was pinned to
# at the time. It has since moved to a plain `0.2.3`, but the shape has to stay
# accepted: nothing stops the next pin being a commit tag again, and this file
# is the wrong place to find that out. `stable-alpine` and `latest` are in
# .env.example too.
#
# Being this permissive about the value costs nothing, because whatever is being
# pinned is always named to the *left* of the prefix and stays literal:
# `actions/checkout@v7` becoming `attacker/checkout@v7` still fails, as does
# `checkov==3.3.2` becoming `evil==3.3.2`. What a bump is allowed to change is
# the value in a pin position, and only there, which is why `PUID=1000` is
# untouched by this and a change to it is refused.
VERSION = re.compile(
    r"(?P<prefix>==|>=|@|(?<=VERSION)=|\brev:[ \t]+|(?<=\S):)"
    r"[0-9A-Za-z][0-9A-Za-z.+_-]*"
)

FILE_HEADER = re.compile(r"^diff --git a/(?P<old>.+) b/(?P<new>.+)$")


def normalize(line: str, path: str = "") -> str:
    """Reduce a line to everything about it that a version bump may not change."""
    stripped = DIGEST.sub("", line)
    stripped = ACTION_SHA.sub(_normalize_action_sha, stripped)
    if path.endswith(".tool-versions"):
        return TOOL_VERSION_LINE.sub(r"\g<prefix><version>", stripped)
    return VERSION.sub(r"\g<prefix><version>", stripped)


def parse(diff: str) -> tuple[dict[str, tuple[Counter, Counter]], list[str]]:
    """Group removed and added lines by file, and collect structural changes."""
    changes: dict[str, tuple[Counter, Counter]] = {}
    structural: list[str] = []
    path = None
    in_hunk = False

    for line in diff.splitlines():
        header = FILE_HEADER.match(line)
        if header:
            old, new = header.group("old"), header.group("new")
            path = new
            in_hunk = False
            changes.setdefault(path, (Counter(), Counter()))
            if old != new:
                structural.append(f"{old} renamed to {new}")
            continue

        if line.startswith("@@"):
            in_hunk = True
            continue

        # Everything between a file header and its first hunk is preamble: the
        # index line, the ---/+++ pair, and any mode line. Recognizing those
        # only here is what stops a content line impersonating one. Inside a
        # hunk, `+++foo` is an added line reading `++foo`, and skipping it as a
        # file header would drop it from the comparison, which fails open.
        if not in_hunk:
            if line.startswith(
                ("new file ", "deleted file ", "old mode ", "new mode ")
            ):
                structural.append(f"{path}: {line.strip()}")
            continue

        if path is None:
            continue

        if line.startswith("-"):
            changes[path][0][normalize(line[1:], path)] += 1
        elif line.startswith("+"):
            changes[path][1][normalize(line[1:], path)] += 1

    return changes, structural


def main() -> int:
    diff = sys.stdin.read()
    if not diff.strip():
        print("REFUSED: the diff is empty, so there is nothing to approve.")
        return 1

    changes, problems = parse(diff)

    # Output that parsed into nothing is not a clean bill of health. Truncated
    # output, a binary diff, or anything that arrives without a `diff --git`
    # header would otherwise leave the change set empty and read as "no problems
    # found", approving a diff nobody managed to read.
    if not changes:
        print("REFUSED: no file headers in the diff, so nothing could be checked.")
        return 1

    for path in changes:
        if not path.startswith(ALLOWED_PATHS):
            problems.append(f"{path}: not a dependency pin file")

    for path, (removed, added) in changes.items():
        if not removed and not added:
            problems.append(f"{path}: no readable changed lines, so nothing was checked")

    for path, (removed, added) in changes.items():
        # Counter subtraction drops non-positive counts, so each direction has
        # to be asked separately to see both halves of a mismatch.
        for line in removed - added:
            problems.append(f"{path}: removed a line that was not re-added: -{line}")
        for line in added - removed:
            problems.append(f"{path}: added a line that was not a version bump: +{line}")

    if problems:
        print("REFUSED: this diff changes more than dependency pins.")
        for problem in problems:
            print(f"  {problem}")
        print(
            "\nNothing is broken. The automated approval is skipped and the pull "
            "request waits for a person, which is what should happen when a "
            "dependency bot reaches outside its lane."
        )
        return 1

    files = ", ".join(sorted(changes)) or "nothing"
    print(f"Pin-only diff confirmed: {files}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
