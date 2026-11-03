"""`make podman_userns_guard` refuses a podman that cannot run the exporters in a pod.

podman_exporter and podman_limits_exporter set userns_mode, and podman-compose
runs every service in a pod. podman before 5.8.0 refuses that at create time
("--userns and --pod cannot be set together"); 5.8.0 replaced the CLI check
(podman#26848) with one that only refuses a pod with an infra container, which
podman-compose's pod does not have (#399). `make start` and
`make start_observability` run the guard first, so the refusal comes before
anything starts and names the ways out.

The unit tier runs in a container without make, so these tests read the
recipe from the Makefile, expand the make variables it uses, and run it with
sh against a stand in podman that prints the version it is given.
"""

from __future__ import annotations

import os
import re
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


def _run(
    tmp_path: Path,
    version: str | None,
    *,
    runtime: str = "podman",
    exporter: str = "enabled",
    limits_exporter: str = "enabled",
    compose: str = "podman-compose",
) -> subprocess.CompletedProcess:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    stub = bin_dir / "podman"
    if version is None:
        stub.write_text("#!/bin/sh\nexit 127\n")
    else:
        stub.write_text(f"#!/bin/sh\necho {version}\n")
    stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
    variables = {
        "RUNTIME": runtime,
        "PODMAN_EXPORTER_PROFILE": exporter,
        "PODMAN_LIMITS_EXPORTER_PROFILE": limits_exporter,
        "COMPOSE": compose,
    }
    script = re.sub(
        r"\$\((\w+)\)",
        lambda m: variables[m[1]],
        _recipe("podman_userns_guard"),
    ).replace("$$", "$")
    return subprocess.run(  # nosec B603 B607 - sh runs the Makefile's own recipe against a stub
        ["sh", "-c", script],
        cwd=tmp_path,
        env={**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}"},
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )


@pytest.mark.parametrize("version", ["4.9.3", "5.0.0", "5.7.0", "5.7.1"])
def test_podman_before_5_8_is_refused_with_the_ways_out(
    tmp_path: Path, version: str
) -> None:
    result = _run(tmp_path, version)
    assert result.returncode == 1, result.stdout + result.stderr
    assert f"ERROR: podman {version} cannot create podman_exporter" in result.stdout
    assert "--userns and --pod cannot be set together" in result.stdout
    assert "upgrade podman to 5.8.0 or later" in result.stdout
    assert 'make start "COMPOSE=podman-compose --in-pod false"' in result.stdout
    assert (
        "PODMAN_EXPORTER_PROFILE=disabled and PODMAN_LIMITS_EXPORTER_PROFILE=disabled"
        in result.stdout
    )


@pytest.mark.parametrize("version", ["5.8.0", "5.8.9", "6.0.0", "6.2.0-rc1", "10.0.0"])
def test_podman_from_5_8_passes(tmp_path: Path, version: str) -> None:
    result = _run(tmp_path, version)
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout == ""


@pytest.mark.parametrize(
    ("exporter", "limits_exporter", "refused"),
    [
        ("enabled", "disabled", True),
        ("disabled", "enabled", True),
        ("disabled", "disabled", False),
    ],
)
def test_only_an_enabled_exporter_is_guarded(
    tmp_path: Path, exporter: str, limits_exporter: str, refused: bool
) -> None:
    result = _run(tmp_path, "5.7.0", exporter=exporter, limits_exporter=limits_exporter)
    assert result.returncode == (1 if refused else 0), result.stdout + result.stderr


@pytest.mark.parametrize(
    "compose", ["podman-compose --in-pod false", "podman-compose --in-pod=false"]
)
def test_running_without_a_pod_passes(tmp_path: Path, compose: str) -> None:
    result = _run(tmp_path, "5.7.0", compose=compose)
    assert result.returncode == 0, result.stdout + result.stderr


def test_the_podman_compose_fallback_is_not_guarded(tmp_path: Path) -> None:
    """Without podman-compose, COMPOSE is `podman compose`: docker-compose, no pod."""
    result = _run(tmp_path, "5.7.0", compose="podman compose")
    assert result.returncode == 0, result.stdout + result.stderr


def test_docker_is_not_guarded(tmp_path: Path) -> None:
    result = _run(tmp_path, "5.7.0", runtime="docker", compose="docker compose")
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize("version", [None, "", "unknown"])
def test_an_unreadable_version_is_left_to_compose(
    tmp_path: Path, version: str | None
) -> None:
    result = _run(tmp_path, version)
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize("target", ["start", "start_observability"])
def test_the_start_targets_run_the_guard(target: str) -> None:
    line = next(
        line
        for line in MAKEFILE.read_text().splitlines()
        if line.startswith(f"{target}:")
    )
    assert "podman_userns_guard" in line.split(":", 1)[1].split()
