"""`make check_requirements` refuses a yq that is not mikefarah/yq v4 (#373).

Debian's and Ubuntu's yq package is kislyuk/yq, a jq wrapper that prints
JSON unless told otherwise, so the scripts' in-place edits could rewrite a
YAML config as JSON. The version strings below are what each tool printed
for `yq --version` (mikefarah/yq 4.44.3 and 3.4.1 from their images,
kislyuk/yq 3.4.3 from PyPI, the version Ubuntu 26.04 packages).

The unit tier runs in a container without make, so these tests take the yq
check out of the recipe and run it with sh against a stand in yq.
"""

from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

REPO_ROOT = Path(__file__).resolve().parents[2]
MAKEFILE = REPO_ROOT / "Makefile"


def _yq_check() -> str:
    """The recipe line of check_requirements that judges yq, as sh gets it."""
    lines = MAKEFILE.read_text().splitlines()
    start = lines.index("check_requirements:")
    recipe = []
    for line in lines[start + 1 :]:
        if not line.startswith("\t"):
            break
        recipe.append(line[1:])
    first = next(i for i, line in enumerate(recipe) if "mikefarah/yq/?" in line)
    check = []
    for line in recipe[first:]:
        check.append(line)
        if not line.endswith("\\"):
            break
    return "\n".join(check).removeprefix("@").replace("$$", "$")


def _run(tmp_path: Path, version: str) -> subprocess.CompletedProcess:
    stub = tmp_path / "yq"
    stub.write_text(f"#!/bin/sh\necho '{version}'\n")
    stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
    return subprocess.run(  # nosec B603 B607 - sh runs the Makefile's own check against a stub
        ["sh", "-c", _yq_check()],
        env={**os.environ, "PATH": f"{tmp_path}:{os.environ['PATH']}"},
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )


def test_mikefarah_yq_v4_passes(tmp_path: Path) -> None:
    result = _run(tmp_path, "yq (https://github.com/mikefarah/yq/) version v4.44.3")
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize(
    "version",
    [
        "yq 3.4.3",  # kislyuk/yq, the Debian/Ubuntu package
        "yq version 3.4.1",  # mikefarah/yq v3
        "yq (https://github.com/mikefarah/yq/) version v5.0.0",
    ],
)
def test_any_other_yq_fails_and_says_which_one_to_install(
    tmp_path: Path, version: str
) -> None:
    result = _run(tmp_path, version)
    assert result.returncode == 1
    assert (
        "ERROR: yq must be mikefarah/yq v4 (https://github.com/mikefarah/yq#install)."
        in result.stdout
    )
    assert "kislyuk/yq" in result.stdout


def test_a_missing_yq_fails(tmp_path: Path) -> None:
    result = subprocess.run(  # nosec B603 B607 - sh runs the Makefile's own check
        ["/bin/sh", "-c", _yq_check()],
        env={**os.environ, "PATH": str(tmp_path)},
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    assert result.returncode == 1
