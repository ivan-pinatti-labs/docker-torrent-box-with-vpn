"""Tests for scripts/coderabbit-review-verdict.py.

This is the fix for #114: a green `CodeRabbit` status does not mean a review
happened, and the cases below are the ones that would otherwise merge on the
strength of a colour rather than a review. No containers and no stack state,
so these run anywhere:

    pytest -m scripts tests/test_coderabbit_review_verdict.py
"""

import json
import subprocess

import pytest

from conftest import REPO_ROOT

pytestmark = pytest.mark.scripts

SCRIPT = REPO_ROOT / "scripts" / "coderabbit-review-verdict.py"


def _run(data: dict) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["python3", str(SCRIPT)],
        input=json.dumps(data),
        capture_output=True,
        text=True,
        timeout=60,
    )


def _outputs(result: subprocess.CompletedProcess) -> dict:
    values = {}
    for line in result.stdout.splitlines():
        key, _, value = line.partition("=")
        values[key] = value
    return values


# ---------------------------------------------------------------------------
# Lane 1: drafts are pending, never failure
# ---------------------------------------------------------------------------


def test_draft_is_pending_regardless_of_everything_else():
    result = _run(
        {
            "is_draft": True,
            "author": "someone",
            "is_fork": False,
            "coderabbit_description": "Review rate limited",
        }
    )
    assert result.returncode == 0
    outputs = _outputs(result)
    assert outputs["state"] == "pending"


def test_a_draft_bot_pull_request_is_still_pending():
    result = _run(
        {
            "is_draft": True,
            "author": "renovate[bot]",
            "is_fork": False,
            "pin_only_state": "success",
        }
    )
    assert _outputs(result)["state"] == "pending"


# ---------------------------------------------------------------------------
# Lane 2: bot pull requests are graded on the pin-only verdict
# ---------------------------------------------------------------------------


def test_bot_pull_request_with_a_pin_only_diff_passes_unattended():
    result = _run(
        {
            "is_draft": False,
            "author": "renovate[bot]",
            "is_fork": False,
            "pin_only_state": "success",
        }
    )
    outputs = _outputs(result)
    assert outputs["state"] == "success"
    assert "pin-only" in outputs["description"]


def test_dependabot_is_no_longer_a_recognized_bot():
    # Dependabot's version updates were retired; see
    # docs/DEPENDENCY_UPDATES.md, "Retiring Dependabot". A pull request from
    # this login is graded as a human's now, not waved through on a pin-only
    # verdict it should never reach: a `pin_only_state` reading "success" here
    # would be Renovate's own Pin Only bot lane leaking to a login that no
    # longer has one, exactly the sort of stale-assumption bug #114 was about.
    result = _run(
        {
            "is_draft": False,
            "author": "dependabot[bot]",
            "is_fork": False,
            "pin_only_state": "success",
        }
    )
    assert _outputs(result)["state"] == "pending"


def test_bot_pull_request_whose_pin_only_verdict_is_not_yet_published_waits():
    # Absent, not "assume clean". The bot lane cannot be graded yet, and that
    # reads as pending rather than a pass.
    result = _run(
        {
            "is_draft": False,
            "author": "renovate[bot]",
            "is_fork": False,
        }
    )
    assert _outputs(result)["state"] == "pending"


def test_bot_pull_request_with_an_unrecognized_pin_only_state_waits():
    result = _run(
        {
            "is_draft": False,
            "author": "renovate[bot]",
            "is_fork": False,
            "pin_only_state": "pending",
        }
    )
    assert _outputs(result)["state"] == "pending"


def test_bot_pull_request_whose_diff_is_not_pin_only_is_graded_like_a_human():
    # This is the injection case #114 named directly: a bot pull request that
    # reaches outside its lane already gets no automatic approval, so a
    # person is already involved, and requiring a real review here cannot
    # stall the unattended path since there was never an unattended path for
    # this diff.
    result = _run(
        {
            "is_draft": False,
            "author": "renovate[bot]",
            "is_fork": False,
            "pin_only_state": "failure",
            "coderabbit_description": "",
        }
    )
    assert _outputs(result)["state"] == "pending"

    result = _run(
        {
            "is_draft": False,
            "author": "renovate[bot]",
            "is_fork": False,
            "pin_only_state": "failure",
            "coderabbit_description": "Review completed",
        }
    )
    assert _outputs(result)["state"] == "success"


def test_a_forked_bot_login_does_not_reach_the_unattended_lane():
    # renovate[bot] cannot open a pull request from a fork in practice, since
    # it runs with write access, but the check is repeated here rather than
    # trusted from the caller: an upstream filter being wrong is exactly how
    # #114 happened.
    result = _run(
        {
            "is_draft": False,
            "author": "renovate[bot]",
            "is_fork": True,
            "pin_only_state": "success",
            "coderabbit_description": "",
        }
    )
    assert _outputs(result)["state"] == "pending"


# ---------------------------------------------------------------------------
# Lane 3: everything else is graded on the actual CodeRabbit description
# ---------------------------------------------------------------------------


def test_review_completed_is_the_only_success():
    result = _run(
        {
            "is_draft": False,
            "author": "a-human",
            "is_fork": False,
            "coderabbit_description": "Review completed",
        }
    )
    assert _outputs(result)["state"] == "success"


def test_no_status_yet_is_pending_not_a_pass():
    result = _run(
        {
            "is_draft": False,
            "author": "a-human",
            "is_fork": False,
            "coderabbit_description": "",
        }
    )
    assert _outputs(result)["state"] == "pending"


def test_review_queued_is_pending_not_failure():
    # CodeRabbit's own in-flight state. Found live on #133, the first pull
    # request the required gate ever ran against: a review that has not
    # returned an answer yet has not declined one either.
    result = _run(
        {
            "is_draft": False,
            "author": "a-human",
            "is_fork": False,
            "coderabbit_description": "Review queued",
        }
    )
    assert _outputs(result)["state"] == "pending"


def test_review_in_progress_is_pending_not_failure():
    result = _run(
        {
            "is_draft": False,
            "author": "a-human",
            "is_fork": False,
            "coderabbit_description": "Review in progress",
        }
    )
    assert _outputs(result)["state"] == "pending"


def test_rate_limited_fails_instead_of_passing():
    # This is the actual bug: #86, #87 and #88 all merged on this exact
    # description reading as success.
    result = _run(
        {
            "is_draft": False,
            "author": "a-human",
            "is_fork": False,
            "coderabbit_description": "Review rate limited",
        }
    )
    assert _outputs(result)["state"] == "failure"


def test_a_skipped_draft_description_reaching_this_lane_fails():
    # Should not happen in practice, since lane 1 already caught an actual
    # draft, but a description this script has never seen before must not
    # read as a pass either way.
    result = _run(
        {
            "is_draft": False,
            "author": "a-human",
            "is_fork": False,
            "coderabbit_description": "Review skipped: draft pull request",
        }
    )
    assert _outputs(result)["state"] == "failure"


def test_an_unrecognized_description_fails_closed():
    result = _run(
        {
            "is_draft": False,
            "author": "a-human",
            "is_fork": False,
            "coderabbit_description": "Something CodeRabbit has never said before",
        }
    )
    assert _outputs(result)["state"] == "failure"


def test_a_fork_pull_request_is_graded_like_a_human():
    result = _run(
        {
            "is_draft": False,
            "author": "a-contributor",
            "is_fork": True,
            "coderabbit_description": "Review rate limited",
        }
    )
    assert _outputs(result)["state"] == "failure"


# ---------------------------------------------------------------------------
# Fails closed on unreadable input
# ---------------------------------------------------------------------------


def test_refuses_malformed_json():
    result = subprocess.run(
        ["python3", str(SCRIPT)],
        input="not json",
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert result.returncode == 1
    assert "not valid JSON" in result.stderr


def test_refuses_a_json_value_that_is_not_an_object():
    result = subprocess.run(
        ["python3", str(SCRIPT)],
        input="[1, 2, 3]",
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert result.returncode == 1
    assert "not an object" in result.stderr


def test_missing_keys_fail_closed_to_pending_not_success():
    result = _run({})
    assert _outputs(result)["state"] == "pending"
