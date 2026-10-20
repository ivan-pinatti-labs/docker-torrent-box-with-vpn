"""tests/xdist_groups.py keeps one app's rotation cases on one xdist worker.

The integration suite's conftest cannot load here (it imports the Docker SDK
and reads .env), so the hook lives in a module of its own, and these tests run
it as a plugin in a pytest of their own under `-n 2 --dist loadgroup`, the way
the Makefile's suite_ci runs the rotation_isolated tier. xdist appends the
group it saw to each node id (`...[sonarr]@sonarr-radarr`), so the reported
ids say which group xdist actually applied. A mark added too late, the bug
fixed in #328, leaves the ids bare.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

TESTS_DIR = Path(__file__).resolve().parents[1]

CASES = """
import pytest


@pytest.mark.rotation_isolated
@pytest.mark.parametrize("app", ["sonarr", "radarr", "lidarr", "whisparr"])
def test_rotation(app):
    pass


@pytest.mark.parametrize("app", ["sonarr"])
def test_not_isolated(app):
    pass


@pytest.mark.rotation_isolated
def test_without_an_app():
    pass
"""


@pytest.fixture(scope="module")
def groups(tmp_path_factory) -> dict[str, str]:
    """Each case's node id, mapped to the group xdist reported for it."""
    work = tmp_path_factory.mktemp("xdist")
    (work / "pytest.ini").write_text(
        "[pytest]\nmarkers =\n    rotation_isolated: as in the suite\n"
    )
    (work / "test_cases.py").write_text(CASES)
    result = subprocess.run(  # nosec B603 - the unit tier's own pytest, against a scratch file
        [
            sys.executable,
            "-m",
            "pytest",
            "-p",
            "no:cacheprovider",
            "-p",
            "xdist_groups",
            "-n",
            "2",
            "--dist",
            "loadgroup",
            "-v",
            "test_cases.py",
        ],
        cwd=work,
        env={**os.environ, "PYTHONPATH": str(TESTS_DIR)},
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    found = {}
    for node in re.findall(r"PASSED (test_cases\.py::\S+)", result.stdout):
        name, _, group = node.partition("@")
        found[name] = group
    assert len(found) == 6, result.stdout
    return found


def test_sonarr_and_radarr_share_a_group(groups: dict[str, str]) -> None:
    assert groups["test_cases.py::test_rotation[sonarr]"] == "sonarr-radarr"
    assert groups["test_cases.py::test_rotation[radarr]"] == "sonarr-radarr"


def test_every_other_app_is_a_group_of_its_own(groups: dict[str, str]) -> None:
    assert groups["test_cases.py::test_rotation[lidarr]"] == "lidarr"
    assert groups["test_cases.py::test_rotation[whisparr]"] == "whisparr"


def test_only_isolated_cases_with_an_app_are_grouped(groups: dict[str, str]) -> None:
    assert groups["test_cases.py::test_not_isolated[sonarr]"] == ""
    assert groups["test_cases.py::test_without_an_app"] == ""
