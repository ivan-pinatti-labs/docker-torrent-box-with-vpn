"""Keep every copy of "the Python this repository runs on" equal.

CI's interpreter is PYTHON_VERSION in .env.example, which each workflow copies
to .env and hands to actions/setup-python. The same fact is written down in
four more places, none of them derived from it. ruff's `target-version` in
pyproject.toml decides which idioms `UP` rewrites to and which version
dependent rules fire. `sonar.python.version` in sonar-project.properties is
what SonarQube Cloud's Python rules judge the code against. The python image
`make coverage` runs the unit tier in (Makefile) moves its tag by hand only,
since Renovate moves just its digest. The `--python-version` in the header of
every hash lock is what the lock was resolved for, and Renovate replays it
when it bumps a pin.

Any of them can be left behind by a bump, and the failure is quiet: ruff or
Sonar grading against an older interpreter keeps passing, and a lock resolved
for another version installs until a wheel is missing. This test is what
makes a Python bump touch all of them together.

The python image PODMAN_LIMITS_EXPORTER_VERSION in .env.example is not one of
them: it runs scripts/podman-limits-exporter.py inside the stack and moves with
the observability group on its own schedule (docs/DEPENDENCY_UPDATES.md).
"""

from __future__ import annotations

import os
import re
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

REPO_ROOT = Path(__file__).resolve().parents[2]
ENV_EXAMPLE = REPO_ROOT / ".env.example"
WORKFLOWS = REPO_ROOT / ".github/workflows"
PYPROJECT = REPO_ROOT / "pyproject.toml"
SONAR = REPO_ROOT / "sonar-project.properties"
MAKEFILE = REPO_ROOT / "Makefile"
LOCKS = [
    REPO_ROOT / "scripts/requirements.txt",
    REPO_ROOT / "tests/unit/requirements.txt",
]

# Every way a workflow may give setup-python its version: the PYTHON_VERSION it
# read from .env, or a quoted literal. A bare literal is a bug worth failing
# on, since YAML reads 3.10 as the float 3.1.
PYTHON_VERSION_INPUT = re.compile(r"^\s*python-version:\s*(?P<value>.*?)\s*$", re.M)
FROM_ENV = "${{ env.PYTHON_VERSION }}"
READS_ENV = "grep -m1 '^PYTHON_VERSION=' .env >> \"$GITHUB_ENV\""
QUOTED = re.compile(r'^"(?P<major>\d+)\.(?P<minor>\d+)"$')


def ci_python() -> tuple[str, str]:
    match = re.search(
        r"^PYTHON_VERSION=(?P<major>\d+)\.(?P<minor>\d+)$",
        ENV_EXAMPLE.read_text(),
        re.M,
    )
    assert match, f"no PYTHON_VERSION=<major>.<minor> in {ENV_EXAMPLE.name}"
    return match.group("major"), match.group("minor")


def _workflows() -> list[Path]:
    return sorted(WORKFLOWS.glob("*.y*ml"))


def test_every_setup_python_runs_ci_python():
    expected = ci_python()
    seen = 0
    for workflow in _workflows():
        text = workflow.read_text()
        for match in PYTHON_VERSION_INPUT.finditer(text):
            seen += 1
            value = match.group("value")
            where = f"{workflow.name}: python-version: {value}"
            if value == FROM_ENV:
                assert READS_ENV in text, (
                    f"{where}, but the workflow never reads PYTHON_VERSION from .env"
                )
                continue
            quoted = QUOTED.match(value)
            assert quoted, f"{where} is neither {FROM_ENV} nor a quoted X.Y"
            assert (quoted.group("major"), quoted.group("minor")) == expected, (
                f"{where}, but .env.example says Python {'.'.join(expected)}"
            )
    assert seen, "no workflow sets python-version, so nothing is guarded"


def test_ruff_targets_ci_python():
    major, minor = ci_python()
    targets = re.findall(
        r'^target-version\s*=\s*"(py\d+)"\s*$', PYPROJECT.read_text(), re.M
    )
    assert targets == [f"py{major}{minor}"], (
        f"{PYPROJECT.name} ruff target-version is {targets}, but CI runs "
        f"Python {major}.{minor}"
    )


def test_sonar_analyzes_ci_python():
    major, minor = ci_python()
    versions = re.findall(r"^sonar\.python\.version=(\S+)\s*$", SONAR.read_text(), re.M)
    assert versions == [f"{major}.{minor}"], (
        f"{SONAR.name} sonar.python.version is {versions}, but CI runs "
        f"Python {major}.{minor}"
    )


def test_every_python_image_in_the_makefile_runs_ci_python():
    major, minor = ci_python()
    images = re.findall(
        r"/python:(\d+\.\d+)-[^@\s]*@sha256:[0-9a-f]{64}", MAKEFILE.read_text()
    )
    assert images, f"no digest pinned python image in {MAKEFILE.name}"
    assert set(images) == {f"{major}.{minor}"}, (
        f"{MAKEFILE.name} pins python images {images}, but CI runs "
        f"Python {major}.{minor}"
    )


@pytest.mark.parametrize(
    "lock", LOCKS, ids=lambda path: path.relative_to(REPO_ROOT).as_posix()
)
def test_every_hash_lock_is_resolved_for_ci_python(lock):
    major, minor = ci_python()
    header = [
        line for line in lock.read_text().splitlines()[:5] if "uv pip compile" in line
    ]
    assert header, f"{lock.name} has no `uv pip compile` header"
    versions = re.findall(r"--python-version[= ](\S+)", header[0])
    assert versions == [f"{major}.{minor}"], (
        f"{lock} was compiled for Python {versions}, but CI runs Python {major}.{minor}"
    )


# Runtime state outside the unit tier's container, never a place for a lock.
NOT_SOURCE = {".git", ".venv", "node_modules", "configs", "data", "storage", "backup"}


def test_every_hash_lock_is_guarded():
    locks = set()
    for directory, subdirectories, files in os.walk(REPO_ROOT):
        subdirectories[:] = [d for d in subdirectories if d not in NOT_SOURCE]
        if "requirements.txt" in files:
            path = Path(directory) / "requirements.txt"
            if "uv pip compile" in "".join(path.read_text().splitlines(True)[:3]):
                locks.add(path)
    assert locks == set(LOCKS), (
        f"hash locks {sorted(str(p) for p in locks - set(LOCKS))} are not in LOCKS"
    )
