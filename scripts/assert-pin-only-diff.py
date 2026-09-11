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

A first pin counts as a version moving too, not only a bump between two
existing pins: `uses: actions/checkout@v7` becoming
`uses: actions/checkout@<sha> # v7` is Renovate's `pinDigests` update type
adding a SHA and a release comment where there was previously only a bare
tag, which is exactly as safe to wave through as any other version moving in
a pin position, for the same reason a first Docker image digest already is
(see DIGEST below). #178 was refused before this normalized, despite being
nothing else.
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
#
# Case-insensitive (`[0-9a-fA-F]`, not `[0-9a-f]`): GitHub resolves a
# `uses:` SHA the same way regardless of case, so an uppercase or
# mixed-case SHA is just as real a pin as a lowercase one, and matching
# only lowercase left a gap a CodeRabbit review of BARE_ACTION_VERSION
# below found: an uppercase SHA on a first-time pin's new side fell
# through ACTION_SHA entirely and was accepted by BARE_ACTION_VERSION's
# generic RELEASE grammar instead, which does not check that a
# first-time pin's target is SHA-shaped at all.
#
# Anchored to a genuine `uses:` field at the start of the line, the same
# anchor BARE_ACTION_VERSION uses, rather than a bare `@<sha>` matched
# anywhere: a follow-up CodeRabbit finding pointed out the original,
# unanchored ACTION_SHA matched a 40 character hex run on ANY changed
# workflow line, `run:` step content included, so a `run:` command could
# change while its normalized form stayed equal, as long as the line
# still ended in something SHA-shaped.
ACTION_SHA = re.compile(
    r"(?P<uses_prefix>^(?:[ \t]*-[ \t]+)?[ \t]*uses:[ \t]+[\w.-]+/[\w./-]+)"
    r"@[0-9a-fA-F]{40}(?![0-9a-fA-F])(?P<comment>[ \t]+#[ \t]*" + RELEASE + r")?$"
)


def _normalize_action_sha(match: re.Match[str]) -> str:
    """Strip a `@<sha>` action pin, normalizing its trailing release comment."""
    prefix = match.group("uses_prefix")
    if match.group("comment"):
        return f"{prefix} # <version>"
    return prefix


# A first-time `pinDigests` bump on a GitHub Action changes
# `uses: actions/checkout@v7` to `uses: actions/checkout@<sha> # v7` in one
# step: there is no prior SHA to compare against, and the trailing release
# comment appears for the first time alongside it. #178 proved this live,
# refused by `Pin Only` despite being nothing but the pin Renovate's own
# `pinDigests` update type exists to add.
#
# ACTION_SHA above normalizes the pinned side to " # <version>" whenever a
# release comment trails the SHA, exactly what a first-time pin always
# carries (Renovate never adds a bare SHA with no comment). This pattern
# gives the unpinned side the identical placeholder, so the two sides of a
# first-time pin compare equal the same way an ordinary SHA-to-SHA bump does.
# It has to run before the generic VERSION fallback below, which would
# otherwise normalize the bare form to `@<version>` instead, a shape the
# pinned side can never produce and so could never match; ACTION_SHA already
# ran first and would have consumed any line that has a SHA, so by the time
# this pattern is tried, `@RELEASE$` can only mean a bare, unpinned ref.
#
# Anchored to end of line for the same reason ACTION_SHA is: a version token
# followed by anything else is not this shape and is left alone, so it is
# still read as a structural change if it differs between the two sides. The
# dependency name stays literal to the left of the `@` exactly as with every
# other pin type here, which is what still refuses
# `actions/checkout@v7` becoming `attacker/checkout@v7`: normalizing the
# common suffix both sides share does not touch the text that has to match
# for the lines to be counted as the same pin.
#
# Requires a `uses:` field and an owner/repo-shaped coordinate immediately
# before the `@`, unlike ACTION_SHA above, which does not check for `uses:`
# at all. A CodeRabbit review of this pull request found the gap an
# unscoped version left: a `run:` step's `tool@v7` would normalize the same
# way, so that line could grow an unrelated-looking SHA and comment and
# still read as a first-time pin, on a file where a `run:` step is already
# called out above as one of the two executable surfaces a path allowlist
# alone would not fence. ACTION_SHA is left as it was rather than narrowed
# to match: its shape (a 40 character hex run) is not one `run:` step
# content plausibly produces by coincidence the way a short version tag is,
# and narrowing an already-relied-on pattern belongs in its own change, not
# folded into this one.
#
# `uses:` alone was not narrow enough either, as a follow-up CodeRabbit
# finding on this exact pattern (ported to other repositories in this
# family) went on to show: `\buses:` is a word-boundary check, not a
# position check, so it matched the substring "uses:" anywhere a line
# contains it, including inside a `run:` step's own text
# (`run: uses: actions/checkout@v7` normalized the same way a real `uses:`
# line did, and was confirmed to slip past this check before this fix).
# Anchored to the start of the line instead, with only an optional YAML
# list marker (`- `) and indentation in front of `uses:`, which is the only
# place a real `uses:` field can sit.
#
# The version is its own capture group, `bare_version`, rather than folded
# unnamed into the match, because a third CodeRabbit-class finding (found by
# extending their own test, not reported directly) showed RELEASE alone is
# still too permissive here: `_normalize_bare_action_version` below refuses
# a 40 character match outright, real hex or not, because 40 characters is
# the shape ACTION_SHA exists to own exclusively. Without that check, a
# non-hex 40 character token, `0` followed by 39 `z`s for instance, never
# matches ACTION_SHA (not hex) and was accepted here instead, since nothing
# about this pattern's own grammar checked that the "version" replacing a
# first-time pin's bare tag was ever a real SHA at all, only that it was
# RELEASE-shaped. A real first-time pin's target is always exactly a 40
# character SHA, ACTION_SHA's exclusive domain, so anything that length
# reaching this pattern instead is already suspect, and refusing it outright
# costs nothing: a length that long never occurs in a genuine bare release
# tag either.
BARE_ACTION_VERSION = re.compile(
    r"(?P<action_prefix>^(?:[ \t]*-[ \t]+)?[ \t]*uses:[ \t]+[\w.-]+/[\w./-]+)@"
    r"(?P<bare_version>" + RELEASE + r")$"
)


def _normalize_bare_action_version(match: re.Match[str]) -> str:
    if len(match.group("bare_version")) == 40:
        return match.group(0)
    return f"{match.group('action_prefix')} # <version>"


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
#
# `@` is deliberately not one of the prefixes here, unlike the five that
# are: it is a separate pattern below, ACTION_REF_VERSION, gated by block
# scalar status the same way ACTION_SHA and BARE_ACTION_VERSION are. This
# regex used to carry `@` directly, and a block scalar review found the
# gap that left: skipping ACTION_SHA and BARE_ACTION_VERSION for a line
# inside a run: | block did not stop that line being treated as a pin at
# all, since this regex's own unscoped `@` still matched it independently.
# Confirmed exploitable: `uses: fake/action@v7` becoming
# `uses: fake/action@v8` inside a run: | block still read as Pin-only
# before this split, even with the block scalar check already in place.
VERSION = re.compile(
    r"(?P<prefix>==|>=|(?<=VERSION)=|\brev:[ \t]+|(?<=\S):)"
    r"[0-9A-Za-z][0-9A-Za-z.+_-]*"
)

# The `@` case VERSION used to carry directly: an action ref that is not a
# SHA pin at all, either a first-time pin's bare, unpinned side (`@v7`,
# handled together with the pinned side by BARE_ACTION_VERSION when it is
# not inside a block scalar) or a floating tag moving to another floating
# tag (`@v7` becoming `@v7.1.0`, an action that has never been SHA-pinned
# at all). `.env.example`'s own `@` usage is a Docker image digest, and
# DIGEST above already removes that entirely before this pattern ever
# runs, so nothing here needs an `.env.example` case to stay working.
#
# Anchored to a genuine `uses:` field at the start of the line, the same
# anchor ACTION_SHA and BARE_ACTION_VERSION use, rather than a bare `@`
# matched anywhere: a CodeRabbit review found the block scalar gating
# above was not enough on its own, because this pattern's own unscoped
# `@` still matched a plain, single-line `run:` step's own text once
# outside a block scalar, `run: echo fake/action@v7` becoming
# `run: echo fake/action@v8` in particular, with no `uses:` field
# involved at all. Confirmed exploitable before this anchor was added.
ACTION_REF_VERSION = re.compile(
    r"(?P<prefix>^(?:[ \t]*-[ \t]+)?[ \t]*uses:[ \t]+[\w.-]+/[\w./-]+)"
    r"@[0-9A-Za-z][0-9A-Za-z.+_-]*$"
)

FILE_HEADER = re.compile(r"^diff --git a/(?P<old>.+) b/(?P<new>.+)$")

# A YAML block scalar opener: `key: |`, `key: >`, with the optional
# chomping (`-`/`+`) and explicit indentation (a digit) modifiers the spec
# allows, in either order (`|2-` and `|-2` are both valid YAML), and an
# optional trailing comment after them. Everything indented more than a
# line matching this, until a line at or below its own indentation
# appears, is that block scalar's literal content, not further YAML
# structure: a `run: |` step body is the shape that matters here, since
# its content can coincidentally read exactly like a `uses:` field. A
# CodeRabbit review found and confirmed this: an indented `uses:
# owner/action@<sha> # v7` inside a run: | block matched ACTION_SHA and
# BARE_ACTION_VERSION alike, treating shell text as if it were a real
# GitHub Actions step, which a required check reading `Pin Only` then
# approves. A later review round found the first regex here only matched
# one modifier order and no trailing comment, so `run: |2-  # step body`
# or `run: |-2` opened a block scalar this check could not recognize as
# one. Deliberately not applied to VERSION below: its own `@` prefix
# already covers a pip pin's `pkg==1.2.3` living inside a `run:` step by
# design (see VERSION's own comment), a legitimate shape in this
# repository's workflows that a block scalar check must not cost its
# normalization.
BLOCK_SCALAR_OPENER = re.compile(
    r":\s*[|>](?:[+-][1-9]?|[1-9][+-]?)?(?:[ \t]+#.*)?\s*$"
)


def _line_indent(line: str) -> int:
    return len(line) - len(line.lstrip(" \t"))


def _in_block_scalar(context: list[str], indent: int) -> bool:
    """Judge, from the lines already seen in this file's diff, whether
    `indent` sits inside an open YAML block scalar.

    Scans backward for the nearest line indented less than `indent`,
    skipping blank lines (a block scalar can itself contain one, and its
    zero indentation must not be mistaken for the boundary that closes the
    scalar). Inside a block scalar if that nearer line opens one.
    Conservatively also inside one if no such line is visible at all: the
    diff is all this script ever sees of the file around a change, so a
    block scalar whose own opening line sits outside the diff's context
    cannot be told apart from one that was never open, and refusing the
    line as a candidate pin either way is the fail closed direction, the
    same one every other shape in this file takes when it cannot be sure.

    A CodeRabbit review named the residual gap in this precisely: the
    first shallower line found is trusted as the boundary even when it is
    itself ordinary scalar content one level further out, rather than the
    real opener sitting deeper in the scan, so a `uses:` line nested under
    something like an `if` inside a `run: |` block, both indented past the
    block's own floor, is not caught. Scanning past a shallower non-opener
    line to keep looking, rather than trusting it as decisive, would close
    that gap, but was tried and reverted: it also requires reaching the
    file's own top level (indentation zero) before a real diff's limited
    context ever earns a confident "not inside one", and no ordinary `gh
    pr diff` output carries that much. Verified against #178's own real
    diff, which never contains the change's enclosing indentation chain
    down to indentation zero: the deeper version refused it outright, the
    same result a compromised bot's diff should get, not a clean one.
    This narrower version is the one actually deployed; the nested case
    above is an accepted, documented gap rather than a silently unfixed
    one.
    """
    for seen in reversed(context):
        if not seen.strip():
            continue
        if _line_indent(seen) < indent:
            return bool(BLOCK_SCALAR_OPENER.search(seen))
    return True


def normalize(line: str, path: str = "", in_block_scalar: bool = False) -> str:
    """Reduce a line to everything about it that a version bump may not change."""
    stripped = DIGEST.sub("", line)
    # Scoped to .github/workflows/: nothing else here (.env.example,
    # .tool-versions) has a YAML block scalar to be inside. Every `@`
    # pattern is gated together, since ACTION_REF_VERSION is the same
    # unpinned-action-ref shape BARE_ACTION_VERSION and ACTION_SHA cover,
    # just without a first-time pin's SHA on the other side.
    if not (in_block_scalar and path.startswith(".github/workflows/")):
        stripped = ACTION_SHA.sub(_normalize_action_sha, stripped)
        stripped = BARE_ACTION_VERSION.sub(_normalize_bare_action_version, stripped)
        stripped = ACTION_REF_VERSION.sub(r"\g<prefix>@<version>", stripped)
    if path.endswith(".tool-versions"):
        return TOOL_VERSION_LINE.sub(r"\g<prefix><version>", stripped)
    return VERSION.sub(r"\g<prefix><version>", stripped)


def parse(diff: str) -> tuple[dict[str, tuple[Counter, Counter]], list[str]]:
    """Group removed and added lines by file, and collect structural changes."""
    changes: dict[str, tuple[Counter, Counter]] = {}
    structural: list[str] = []
    path = None
    in_hunk = False
    # The lines of each side of this file seen so far in the current hunk,
    # in file order: what a block scalar check has to work with, since the
    # diff never carries the whole file. Kept separate because a hunk can
    # add or remove a block scalar's own opening line, which changes
    # whether a later line on just one side is inside one. Reset on every
    # hunk header, not only every file header: a hunk boundary means the
    # diff skips lines in between, and a line just past the gap could
    # otherwise be judged against context from before it, a shallower line
    # left over from the previous hunk that is not actually the nearest
    # one to the real file. Kept context from the file's earlier hunks
    # cannot be trusted to still be the true boundary once the diff has
    # jumped past lines neither side of this comparison ever saw; starting
    # each hunk with nothing visible falls back to the same fail closed
    # default `_in_block_scalar` already takes when a file's first hunk
    # opens with no context at all.
    old_context: list[str] = []
    new_context: list[str] = []

    for line in diff.splitlines():
        header = FILE_HEADER.match(line)
        if header:
            old, new = header.group("old"), header.group("new")
            path = new
            in_hunk = False
            old_context = []
            new_context = []
            changes.setdefault(path, (Counter(), Counter()))
            if old != new:
                structural.append(f"{old} renamed to {new}")
            continue

        if line.startswith("@@"):
            in_hunk = True
            old_context = []
            new_context = []
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
            content = line[1:]
            in_scalar = _in_block_scalar(old_context, _line_indent(content))
            changes[path][0][normalize(content, path, in_scalar)] += 1
            old_context.append(content)
        elif line.startswith("+"):
            content = line[1:]
            in_scalar = _in_block_scalar(new_context, _line_indent(content))
            changes[path][1][normalize(content, path, in_scalar)] += 1
            new_context.append(content)
        elif line.startswith(" ") or line == "":
            # An unchanged context line: not compared itself, but part of
            # the surrounding structure a block scalar check on a later
            # line in this file needs to see.
            content = line[1:] if line else line
            old_context.append(content)
            new_context.append(content)

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
