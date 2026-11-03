"""`make calibre_library` seeds or moves the Calibre database before `make start`.

The recipe runs scripts/seed-calibre-library.sh, which keeps metadata.db off
data/ (#402), whenever calibre or calibre-web is enabled, and skips it when
both are disabled, since neither container then mounts the database folder.

The unit tier runs in a container without make, so these tests read the
recipe from the Makefile, expand the make variables it uses, and run it with
sh in a temporary directory, where scripts/seed-calibre-library.sh is a stand
in that only records that it ran.
"""

from __future__ import annotations

import stat
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

REPO_ROOT = Path(__file__).resolve().parents[2]
MAKEFILE = REPO_ROOT / "Makefile"


def _recipe(target: str) -> str:
    """The recipe of `target` as make hands it to the shell."""
    lines = MAKEFILE.read_text().splitlines()
    start = lines.index(f"{target}:")
    recipe = []
    for line in lines[start + 1 :]:
        if not line.startswith("\t"):
            break
        recipe.append(line[1:].removeprefix("@"))
    return "\n".join(recipe)


def _run(tmp_path: Path, calibre: str, calibre_web: str) -> str | None:
    """Runs the recipe; the RUNTIME the seed script saw, or None if it did not run."""
    script = tmp_path / "scripts" / "seed-calibre-library.sh"
    script.parent.mkdir()
    script.write_text(f'#!/bin/sh\nprintf %s "$RUNTIME" >"{tmp_path}/ran"\n')
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    recipe = (
        _recipe("calibre_library")
        .replace("$(CALIBRE_PROFILE)", calibre)
        .replace("$(CALIBREWEB_PROFILE)", calibre_web)
        .replace("$(RUNTIME)", "docker")
    )
    subprocess.run(["sh", "-c", recipe], cwd=tmp_path, check=True)  # nosec B603 B607
    ran = tmp_path / "ran"
    return ran.read_text() if ran.exists() else None


@pytest.mark.parametrize(
    ("calibre", "calibre_web", "runs"),
    [
        ("enabled", "enabled", True),
        ("enabled", "disabled", True),
        ("disabled", "enabled", True),
        ("disabled", "disabled", False),
    ],
)
def test_runs_when_either_app_is_enabled(tmp_path, calibre, calibre_web, runs):
    # With the Makefile's runtime, so a Docker host runs it with docker.
    assert _run(tmp_path, calibre, calibre_web) == ("docker" if runs else None)


def test_start_runs_it_before_the_permissions_repair():
    # The repair hands a moved database to the calibre user, so it has to
    # come after the move.
    start = next(
        line for line in MAKEFILE.read_text().splitlines() if line.startswith("start:")
    ).split()
    assert start.index("calibre_library") < start.index("permissions_repair")
