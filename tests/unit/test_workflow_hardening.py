"""Keep the workflow fixes zizmor asked for in place (#116).

The zizmor pre-commit hook fails a change that brings one of these back, but
only for the findings it reports with its default settings, and a later
`# zizmor: ignore[...]` would silence it. These read the workflows directly,
so the two properties below hold whatever zizmor is told.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

pytestmark = pytest.mark.unit

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = REPO_ROOT / ".github/workflows"
LOGIN_OUTPUT = "${{ steps.login.outputs.secret }}"


def _workflow(name: str) -> dict:
    return yaml.safe_load((WORKFLOWS / name).read_text())


def _steps(workflow: dict) -> list[tuple[str, dict]]:
    return [
        (job_name, step)
        for job_name, job in workflow["jobs"].items()
        for step in job.get("steps", [])
    ]


def test_validation_checkouts_do_not_persist_credentials():
    """No PR Validation job pushes, so none keeps the token in .git/config."""
    checkouts = [
        (job, step)
        for job, step in _steps(_workflow("pull-request-validation.yml"))
        if str(step.get("uses", "")).startswith("actions/checkout@")
    ]
    assert checkouts, "no checkout found, so nothing is guarded"
    for job, step in checkouts:
        assert step.get("with", {}).get("persist-credentials") is False, job


@pytest.mark.parametrize(
    ("name", "jobs"),
    [
        ("integration-tests.yml", {"suite", "tiers"}),
        ("nightly-tests.yml", {"nightly"}),
    ],
)
def test_registry_secret_reaches_the_suite_as_a_step_output(name, jobs):
    """The Docker Hub login hands its secret's name on as `secret`, not GITHUB_ENV.

    If the output or the reference to it drifts, the value comes through
    empty, the Makefile leaves out the secret, and the nested pulls run
    anonymously with nothing failing.
    """
    workflow = _workflow(name)
    for job in jobs:
        steps = workflow["jobs"][job]["steps"]
        logins = [step for step in steps if step.get("id") == "login"]
        assert len(logins) == 1, f"{name} {job}: one step with id login"
        assert 'echo "secret=$name" >> "$GITHUB_OUTPUT"' in logins[0]["run"]
        readers = [
            step
            for step in steps
            if step.get("env", {}).get("NESTED_REGISTRY_SECRET") == LOGIN_OUTPUT
        ]
        assert len(readers) == 1, f"{name} {job}: one step reads the login output"
    assert "NESTED_REGISTRY_SECRET=" not in (WORKFLOWS / name).read_text()
