"""The link check covers changed documents only, with a read only token (#319).

Code Check runs the lychee hook in a step of its own over the documents a
pull request changes, never in the merge queue, and hands it the job's token
as LYCHEE_GITHUB_TOKEN. The hook forwards that one variable to the container
as GITHUB_TOKEN, and nothing else. These tests read the workflow and the
pre-commit configuration, and run the hook's own entry against a stub docker
that records what it was given, so no container starts and no link is
fetched.
"""

from __future__ import annotations

import os
import re
import shlex
import subprocess
import tomllib
from pathlib import Path

import pytest
import yaml

pytestmark = pytest.mark.unit

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = REPO_ROOT / ".github/workflows/pull-request-validation.yml"
PRE_COMMIT = REPO_ROOT / ".pre-commit-config.yaml"
LYCHEE_TOML = REPO_ROOT / "lychee.toml"


def _steps() -> dict[str, dict]:
    """Code Check's steps, by name."""
    workflow = yaml.safe_load(WORKFLOW.read_text())
    return {
        step["name"]: step
        for step in workflow["jobs"]["pr_check"]["steps"]
        if "name" in step
    }


def _hook() -> dict:
    config = yaml.safe_load(PRE_COMMIT.read_text())
    hooks = [
        hook
        for repo in config["repos"]
        for hook in repo["hooks"]
        if hook["id"] == "lychee"
    ]
    assert len(hooks) == 1
    return hooks[0]


def test_the_all_files_run_skips_the_link_check() -> None:
    skipped = _steps()["Pre-commit Run"]["env"]["SKIP"].split(",")
    assert "lychee" in skipped


def test_the_link_check_runs_on_changed_documents_only() -> None:
    step = _steps()["Check links in changed documents"]
    assert 'base="$(git merge-base origin/main HEAD)"' in step["run"]
    assert (
        'pre-commit run lychee --hook-stage pre-push --from-ref "$base" --to-ref HEAD'
        in step["run"]
    )
    assert "--all-files" not in step["run"]


@pytest.mark.parametrize(
    ("event", "runs"),
    [("pull_request", True), ("workflow_dispatch", True), ("merge_group", False)],
)
def test_the_link_check_skips_only_the_merge_queue(event: str, runs: bool) -> None:
    condition = _steps()["Check links in changed documents"]["if"]
    match = re.fullmatch(r"github\.event_name != '(\w+)'", condition)
    assert match, f"unexpected condition {condition!r}"
    assert (event != match.group(1)) is runs


def test_the_link_check_gets_the_jobs_read_only_token() -> None:
    workflow = yaml.safe_load(WORKFLOW.read_text())
    job = workflow["jobs"]["pr_check"]
    assert job["permissions"] == {"contents": "read"}
    env = _steps()["Check links in changed documents"]["env"]
    assert env == {"LYCHEE_GITHUB_TOKEN": "${{ github.token }}"}


def _run_hook(tmp_path: Path, env: dict[str, str]) -> tuple[list[str], str]:
    """Run the hook's entry on one file with a stub docker; its argv and token."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    record = tmp_path / "record"
    stub = bin_dir / "docker"
    stub.write_text(
        "#!/usr/bin/env bash\n"
        f'printf "%s\\n" "$@" >"{record}"\n'
        f'echo "token=${{GITHUB_TOKEN-unset}}" >>"{record}"\n'
    )
    stub.chmod(0o755)
    command = [*shlex.split(_hook()["entry"]), "docs/README.md"]
    base = {
        key: value for key, value in os.environ.items() if "GITHUB_TOKEN" not in key
    }
    base["PATH"] = f"{bin_dir}:{os.environ['PATH']}"
    subprocess.run(command, cwd=tmp_path, env={**base, **env}, check=True)  # noqa: S603
    *argv, token = record.read_text().splitlines()
    return argv, token


def test_the_hook_forwards_the_lychee_token(tmp_path: Path) -> None:
    argv, token = _run_hook(tmp_path, {"LYCHEE_GITHUB_TOKEN": "t0ken"})
    assert argv[:4] == ["run", "--rm", "-e", "GITHUB_TOKEN"]
    assert token == "token=t0ken"
    assert "t0ken" not in argv
    assert argv[-1] == "docs/README.md"


def test_the_hook_forwards_no_token_without_one(tmp_path: Path) -> None:
    argv, _ = _run_hook(tmp_path, {})
    assert "-e" not in argv
    assert argv[-1] == "docs/README.md"


def test_the_hook_never_forwards_an_exported_github_token(tmp_path: Path) -> None:
    argv, _ = _run_hook(tmp_path, {"GITHUB_TOKEN": "personal"})
    assert "-e" not in argv
    assert not any("personal" in arg for arg in argv)


def _excluded(url: str) -> bool:
    patterns = tomllib.loads(LYCHEE_TOML.read_text())["exclude"]
    return any(re.search(pattern, url) for pattern in patterns)


@pytest.mark.parametrize(
    "url",
    [
        "https://github.com/ivan-pinatti-labs/docker-torrent-box-with-vpn/issues/new",
        "https://github.com/ivan-pinatti-labs/docker-torrent-box-with-vpn/security/advisories/new",
    ],
)
def test_login_page_buttons_are_excluded(url: str) -> None:
    assert _excluded(url)


@pytest.mark.parametrize(
    "url",
    [
        "https://github.com/ivan-pinatti-labs/docker-torrent-box-with-vpn/issues/319",
        "https://github.com/ivan-pinatti-labs/docker-torrent-box-with-vpn/security/advisories",
        "https://github.com/ivan-pinatti-labs/docker-torrent-box-with-vpn/blob/main/LICENSE.md",
    ],
)
def test_other_github_links_are_still_checked(url: str) -> None:
    assert not _excluded(url)
