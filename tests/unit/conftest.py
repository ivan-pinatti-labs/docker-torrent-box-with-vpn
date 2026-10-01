"""Shared fixtures for the unit tier.

The unit tier tests the Python under scripts/ as code rather than as a
program run against a live stack: no container, no network, no podman or
docker, nothing outside the test's own temporary directory. Every external a
script drives (podman, the Podman socket, HTTP, the filesystem it manages) is
replaced with a stand in. `make coverage` runs it under coverage.py and holds
scripts/ to 100% of its lines and branches; see .coveragerc.

The integration suite in tests/ never collects this directory (pytest.ini's
norecursedirs), and this tier never loads tests/conftest.py, which imports
the Docker SDK and reads .env: it runs with `--confcutdir=tests/unit`. See
docs/TESTING.md, "The unit tier".
"""

import importlib.util
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = REPO_ROOT / "scripts"


def _load(filename: str):
    """Execute scripts/<filename> as a fresh module and return it.

    The scripts are named with hyphens and are not a package, so they cannot be
    imported by name. Loading by path, once per test, also gives every test its
    own copy of module level state such as a cache or a patched constant.
    """
    path = SCRIPTS / filename
    spec = importlib.util.spec_from_file_location(
        path.stem.replace("-", "_") + "_under_test", path
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def load_script():
    """The loader above, as a fixture so test modules need no import of it."""
    return _load
