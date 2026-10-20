"""`make configure_jdownloader2_api` waits for jDownloader2's own config.

The unit tier runs in a container without make, so these tests read the
recipe from the Makefile, expand the few make variables it uses, and run it
with sh in a temporary directory. podman, the compose command, jq and sleep
are stand ins on PATH that log their calls, so nothing is started and no time
passes: the 180 second wait runs to its end at once.
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
TARGET = "configs/jdownloader2/config/cfg/org.jdownloader.api.RemoteAPIConfig.json"

# What a stand in does once it has logged its call. podman runs what follows
# `unshare`, as the real one does inside its user namespace, and answers
# inspect and logs the way a crash looping jDownloader2 would, or fails both
# when STUB_NO_CONTAINER is set, as for a container that was never created.
STUBS = {
    "podman": """case "$1" in
    unshare) shift; exec "$@" ;;
    inspect | logs) [ -z "$STUB_NO_CONTAINER" ] || exit 125 ;;
esac
case "$1" in
    inspect) echo "status=exited restarts=3 exitcode=1" ;;
    logs) echo "JDownloader exited" ;;
esac""",
    "compose": "",
    "jq": """echo '{"edited": true}'""",
    "sleep": "",
}


def _recipe(target: str) -> str:
    """The recipe of `target` as make hands it to the shell."""
    lines = MAKEFILE.read_text().splitlines()
    start = lines.index(f"{target}:")
    recipe = []
    for line in lines[start + 1 :]:
        if not line.startswith("\t"):
            break
        recipe.append(line[1:])
    return "\n".join(recipe).removeprefix("@")


def _run(
    tmp_path: Path, profile: str = "enabled", no_container: bool = False
) -> tuple[subprocess.CompletedProcess, list[str]]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    log = tmp_path / "log"
    for name, body in STUBS.items():
        stub = bin_dir / name
        stub.write_text(f'#!/bin/sh\necho "{name} $*" >>"{log}"\n{body}\n')
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
    variables = {
        "JDOWNLOADER2_PROFILE": profile,
        "COMPOSE": "compose",
        "COMPOSE_FILES": "--file docker-compose.yml",
        "RUNTIME": "podman",
        "CONTAINER_PREFIX": "dev-",
    }
    script = re.sub(
        r"\$\((\w+)\)",
        lambda m: variables[m.group(1)],
        _recipe("configure_jdownloader2_api"),
    )
    script = script.replace("$$", "$")
    result = subprocess.run(  # nosec B603 B607 - sh runs the Makefile's own recipe against stubs
        ["sh", "-c", script],
        cwd=tmp_path,
        env={
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "STUB_NO_CONTAINER": "1" if no_container else "",
        },
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    calls = log.read_text().splitlines() if log.exists() else []
    return result, calls


def test_a_disabled_profile_is_skipped(tmp_path: Path) -> None:
    result, calls = _run(tmp_path, profile="disabled")
    assert result.returncode == 0
    assert "jDownloader2 is disabled in .env" in result.stdout
    assert calls == []


def test_the_config_is_opened_once_it_exists(tmp_path: Path) -> None:
    config = tmp_path / TARGET
    config.parent.mkdir(parents=True)
    config.write_text("{}")
    result, calls = _run(tmp_path)
    assert result.returncode == 0, result.stderr
    assert (
        calls[0]
        == "compose --file docker-compose.yml --profile enabled stop jdownloader2"
    )
    assert calls[1].startswith(
        "podman unshare sh -c jq -c '.externinterfaceenabled = true"
    )
    assert calls[2].startswith("jq -c .externinterfaceenabled = true")
    assert (
        calls[-1]
        == "compose --file docker-compose.yml --profile enabled start jdownloader2"
    )
    assert config.read_text().strip() == '{"edited": true}'
    assert not any(call.startswith("sleep") for call in calls)


def test_a_config_that_never_appears_fails_with_diagnostics(tmp_path: Path) -> None:
    result, calls = _run(tmp_path)
    assert result.returncode == 1
    assert f"ERROR: {TARGET} was not created after 180s" in result.stdout
    assert "status=exited restarts=3 exitcode=1" in result.stdout
    assert "JDownloader exited" in result.stdout
    # The whole 180s although the container reads as exited: it runs with
    # restart: unless-stopped, so exited between two restarts is not dead.
    assert calls.count("sleep 2") == 90
    assert calls[-2].startswith("podman inspect dev-jdownloader2 --format status=")
    assert calls[-1] == "podman logs --tail 40 dev-jdownloader2"
    assert not any(call.startswith("compose") for call in calls)


def test_diagnostics_that_fail_say_so(tmp_path: Path) -> None:
    result, _ = _run(tmp_path, no_container=True)
    assert result.returncode == 1
    assert "(jdownloader2 could not be inspected" in result.stdout
    assert "(no logs available)" in result.stdout
