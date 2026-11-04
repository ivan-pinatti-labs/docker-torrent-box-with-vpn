"""`make start` writes nginx's list of disabled apps and reloads a running nginx.

`up --no-recreate` leaves a running nginx alone, so without the reload a
profile flipped since nginx started would keep its old page (#415). The unit
tier runs in a container without make, so these tests take the step from the
`start` recipe, expand the make variables it uses, and run it with sh, where
the generator and the container runtime are stand ins that record their calls.
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


def _step() -> str:
    """The generator call and the reload after it, as make hands them to sh."""
    lines = MAKEFILE.read_text().splitlines()
    start = lines.index(next(line for line in lines if line.startswith("start:")))
    recipe = []
    for line in lines[start + 1 :]:
        if not line.startswith("\t"):
            break
        recipe.append(line[1:].removeprefix("@"))
    first = recipe.index(GENERATOR)
    end = next(i for i in range(first, len(recipe)) if recipe[i].strip() == "fi")
    return "\n".join(recipe[first : end + 1]).replace("$$", "$")


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


def test_the_list_is_written_before_compose_starts_anything() -> None:
    recipe = MAKEFILE.read_text().split("\nstart:", 1)[1]
    assert recipe.index(GENERATOR) < recipe.index("up --detach")


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
