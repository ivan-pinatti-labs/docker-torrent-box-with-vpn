"""`make seed_flaresolverr_chromedriver` keeps the seeded binary in step with the image.

FlareSolverr runs the chromedriver bind-mounted from
configs/flaresolverr/config/chromedriver, which has to match the Chromium in
the image; one left over from an older image crash-loops the container
(#383). The recipe records the image reference beside the binary and
re-extracts on a different FLARESOLVERR_VERSION.

The unit tier runs in a container without make, so these tests read the
recipe from the Makefile, expand the make variables it uses, and run it with
sh in a temporary directory. podman is a stand in on PATH that logs its call
and prints a fake binary for the image it was asked for, or fails, or prints
nothing, as STUB_EXTRACT says.
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
BINARY = "configs/flaresolverr/config/chromedriver"
OLD = "v3.4.6@sha256:aaaa"
NEW = "v3.5.2@sha256:bbbb"

PODMAN = """case "$STUB_EXTRACT" in
    fail) exit 125 ;;
    empty) exit 0 ;;
esac
image="$5"
printf 'chromedriver from %s\\n' "${image#*:}"
"""


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
    *,
    version: str = NEW,
    profile: str = "enabled",
    binary: str | None = None,
    stamp: str | None = None,
    extract: str = "",
) -> tuple[subprocess.CompletedProcess, list[str]]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    log = tmp_path / "log"
    stub = bin_dir / "podman"
    stub.write_text(f'#!/bin/sh\necho "podman $*" >>"{log}"\n{PODMAN}')
    stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
    (tmp_path / BINARY).parent.mkdir(parents=True)
    if binary is not None:
        (tmp_path / BINARY).write_text(binary)
    if stamp is not None:
        (tmp_path / f"{BINARY}.image").write_text(f"{stamp}\n")
    variables = {
        "RUNTIME": "podman",
        "FLARESOLVERR_CHROMEDRIVER": BINARY,
        "FLARESOLVERR_PROFILE": profile,
        "FLARESOLVERR_VERSION": version,
    }
    script = re.sub(
        r"\$\((\w+)\)",
        lambda m: variables[m[1]],
        _recipe("seed_flaresolverr_chromedriver"),
    ).replace("$$", "$")
    result = subprocess.run(  # nosec B603 B607 - sh runs the Makefile's own recipe against a stub
        ["sh", "-c", script],
        cwd=tmp_path,
        env={
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "STUB_EXTRACT": extract,
        },
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    calls = log.read_text().splitlines() if log.exists() else []
    return result, calls


def _binary(tmp_path: Path) -> str:
    return (tmp_path / BINARY).read_text()


def _stamp(tmp_path: Path) -> str:
    return (tmp_path / f"{BINARY}.image").read_text().strip()


def test_a_missing_binary_is_seeded_and_stamped(tmp_path: Path) -> None:
    result, calls = _run(tmp_path)
    assert result.returncode == 0, result.stdout + result.stderr
    assert calls == [
        f"podman run --rm --entrypoint cat docker.io/flaresolverr/flaresolverr:{NEW} /app/chromedriver"
    ]
    assert _binary(tmp_path) == f"chromedriver from {NEW}\n"
    assert _stamp(tmp_path) == NEW
    assert (tmp_path / BINARY).stat().st_mode & 0o777 == 0o755


def test_a_binary_from_the_current_image_is_left_alone(tmp_path: Path) -> None:
    result, calls = _run(
        tmp_path, binary="patched by undetected_chromedriver", stamp=NEW
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert calls == []
    assert _binary(tmp_path) == "patched by undetected_chromedriver"


def test_a_binary_from_an_older_image_is_re_extracted(tmp_path: Path) -> None:
    result, calls = _run(tmp_path, binary="chromedriver 142", stamp=OLD)
    assert result.returncode == 0, result.stdout + result.stderr
    assert len(calls) == 1
    assert _binary(tmp_path) == f"chromedriver from {NEW}\n"
    assert _stamp(tmp_path) == NEW


def test_a_binary_with_no_record_of_its_image_is_re_extracted_once(
    tmp_path: Path,
) -> None:
    # Every install seeded before the stamp existed: refreshed on the next start.
    result, calls = _run(tmp_path, binary="seeded before #383")
    assert result.returncode == 0, result.stdout + result.stderr
    assert len(calls) == 1
    assert _stamp(tmp_path) == NEW
    (tmp_path / "again").mkdir()
    again, calls = _run(tmp_path / "again", binary=_binary(tmp_path), stamp=NEW)
    assert again.returncode == 0
    assert calls == []


def test_a_disabled_profile_keeps_the_binary_it_has(tmp_path: Path) -> None:
    result, calls = _run(
        tmp_path, profile="disabled", binary="chromedriver 142", stamp=OLD
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert calls == []
    assert _binary(tmp_path) == "chromedriver 142"


def test_a_disabled_profile_still_seeds_a_missing_binary(tmp_path: Path) -> None:
    # podman would vivify a directory at the bind mount otherwise.
    result, calls = _run(tmp_path, profile="disabled")
    assert result.returncode == 0, result.stdout + result.stderr
    assert len(calls) == 1
    assert _stamp(tmp_path) == NEW


@pytest.mark.parametrize("extract", ["fail", "empty"])
def test_a_failed_extraction_keeps_the_old_binary(tmp_path: Path, extract: str) -> None:
    result, calls = _run(
        tmp_path, binary="chromedriver 142", stamp=OLD, extract=extract
    )
    assert result.returncode == 1
    assert (
        f"ERROR: could not extract /app/chromedriver from flaresolverr:{NEW}"
        in result.stdout
    )
    assert _binary(tmp_path) == "chromedriver 142"
    assert _stamp(tmp_path) == OLD
    assert not (tmp_path / f"{BINARY}.new").exists()


def test_make_start_seeds_ahead_of_permissions_repair() -> None:
    # permissions_repair then hands the new file to the FlareSolverr user.
    start = next(
        line for line in MAKEFILE.read_text().splitlines() if line.startswith("start:")
    )
    prerequisites = start.split(":", 1)[1].split()
    assert prerequisites.index("seed_flaresolverr_chromedriver") < prerequisites.index(
        "permissions_repair"
    )
