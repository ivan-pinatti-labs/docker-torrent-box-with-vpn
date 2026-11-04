"""Every start target writes nginx's list of disabled apps and reloads nginx.

`up --no-recreate` leaves a running nginx alone, so without the reload a
profile flipped since nginx started would keep its old page (#415). The step
is `make nginx_disabled_apps`, a prerequisite of each target that starts apps
from .env's profiles. The unit tier runs in a container without make, so these
tests read its recipe, expand the make variables it uses, and run it with sh,
where the generator and the container runtime are stand ins that record their
calls.
"""

from __future__ import annotations

import stat
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

REPO_ROOT = Path(__file__).resolve().parents[2]
MAKEFILE = REPO_ROOT / "Makefile"
GENERATOR = "./scripts/generate-nginx-disabled-apps.py"


def _rule(target: str) -> str:
    """The rule line of `target`: its name and prerequisites."""
    return next(
        line
        for line in MAKEFILE.read_text().splitlines()
        if line.startswith(f"{target}:")
    )


def _step() -> str:
    """The recipe of nginx_disabled_apps, as make hands it to sh."""
    lines = MAKEFILE.read_text().splitlines()
    start = lines.index(_rule("nginx_disabled_apps"))
    recipe = []
    for line in lines[start + 1 :]:
        if not line.startswith("\t"):
            break
        recipe.append(line[1:].removeprefix("@"))
    assert recipe[0] == GENERATOR
    return "\n".join(recipe).replace("$$", "$")


def _stub(path: Path, body: str) -> None:
    path.write_text(f"#!/bin/sh\n{body}\n")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def _run(tmp_path: Path, running: str, reload_status: int) -> tuple[list[str], str]:
    """Runs the step; the calls the stand ins saw, and what it printed."""
    log = tmp_path / "log"
    (tmp_path / "scripts").mkdir()
    _stub(
        tmp_path / "scripts/generate-nginx-disabled-apps.py", f'echo generate >>"{log}"'
    )
    _stub(
        tmp_path / "runtime",
        f'echo "$*" >>"{log}"\n'
        f'case "$1" in container) echo "{running}" ;; exec) exit {reload_status} ;; esac',
    )
    script = (
        _step()
        .replace("$(RUNTIME)", str(tmp_path / "runtime"))
        .replace("$(CONTAINER_PREFIX)", "dev-")
    )
    result = subprocess.run(  # noqa: S603 - sh with the recipe, in tmp_path
        ["sh", "-c", script],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        check=True,
    )
    return log.read_text().splitlines(), result.stdout


@pytest.mark.parametrize("target", ["start", "start_library", "start_observability"])
def test_every_start_target_writes_the_list_first(target: str) -> None:
    """A prerequisite, so it runs before the recipe starts anything."""
    assert "nginx_disabled_apps" in _rule(target).split(":", 1)[1].split()


def test_the_step_is_phony() -> None:
    """It writes no file named after itself, so make must always run it."""
    assert any(
        "nginx_disabled_apps" in line.split()[1:]
        for line in MAKEFILE.read_text().splitlines()
        if line.startswith(".PHONY:")
    )


def test_a_running_nginx_is_reloaded(tmp_path: Path) -> None:
    calls, output = _run(tmp_path, "true", 0)
    assert calls == [
        "generate",
        "container inspect -f {{.State.Running}} dev-nginx",
        "exec dev-nginx nginx -s reload",
    ]
    assert output == ""


def test_a_refused_reload_says_so(tmp_path: Path) -> None:
    _, output = _run(tmp_path, "true", 1)
    assert "WARNING: nginx refused to reload" in output


@pytest.mark.parametrize("running", ["false", ""])
def test_a_stopped_or_missing_nginx_is_left_to_read_it_at_start(
    tmp_path: Path, running: str
) -> None:
    calls, _ = _run(tmp_path, running, 0)
    assert calls == ["generate", "container inspect -f {{.State.Running}} dev-nginx"]
