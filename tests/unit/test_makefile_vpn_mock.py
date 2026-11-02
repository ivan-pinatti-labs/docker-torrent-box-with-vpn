"""`make start`'s handling of vpn_mock's tunnel (#370).

On GitHub's ubuntu-26.04 runners the wireguard image's own `wg-quick up`
fails and leaves the tunnel down, and vpn_mock gets no default route. The
Makefile's start_vpn_mock, ensure_vpn_mock_tunnel and vpn_mock_diagnostics
defines (and wait_for_gluetun's timeout branch, which calls the last one)
work around and report that.

The unit tier runs in a container without make, so these tests read each
define from the Makefile, expand the make references in it, and run it with
sh in a temporary directory. podman, the compose command, sleep and timeout
are stand ins on PATH that log their calls and answer from a small state
directory, so nothing is started and no time passes.
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
VPN_MOCK_IP = "172.28.0.11"

# podman answers from files in $STATE: wg_up (wg0 exists), image_down (the
# image's log says it gave the tunnel up), has_default (a default route),
# vpn_mock (that container exists) and gluetun_running. `wg-quick up` brings
# the tunnel up on attempt number $UP_AFTER, and a route add creates the
# default route.
STUBS = {
    "podman": r"""state="$STATE"
case "$*" in
    "exec dev-vpn_mock wg show wg0") [ -e "$state/wg_up" ] ;;
    "exec dev-vpn_mock bash /usr/bin/wg-quick up "*)
        n=$(( $(cat "$state/attempts" 2>/dev/null || echo 0) + 1 ))
        echo "$n" >"$state/attempts"
        if [ "$n" -ge "${UP_AFTER:-1}" ]; then : >"$state/wg_up"; fi ;;
    "exec dev-vpn_mock ip -4 route show default")
        [ ! -e "$state/has_default" ] || echo "default via 10.89.0.1 dev eth0" ;;
    "exec dev-vpn_mock ip -4 route add default via "*) : >"$state/has_default" ;;
    "network inspect proj_wan "*) echo "10.89.0.1" ;;
    "logs dev-vpn_mock") [ ! -e "$state/image_down" ] || echo "**** All tunnels are now down. ****" ;;
    "inspect dev-vpn_mock"*) [ -e "$state/vpn_mock" ] ;;
    "inspect dev-gluetun --format {{.State.Running}}")
        if [ -e "$state/gluetun_running" ]; then echo true; else echo false; fi ;;
    *) echo "($*)" ;;
esac""",
    "compose": "",
    "sleep": "",
    # wait_for_gluetun's bounded wait, always running out.
    "timeout": "exit 124",
}


def _defines() -> dict[str, str]:
    """Every `define NAME ... endef` body in the Makefile, by name."""
    defines: dict[str, str] = {}
    name = None
    body: list[str] = []
    for line in MAKEFILE.read_text().splitlines():
        if name is None:
            match = re.match(r"define (\w+)$", line)
            if match:
                name, body = match[1], []
        elif line == "endef":
            defines[name] = "\n".join(body)
            name = None
        else:
            body.append(line)
    return defines


def _expand(text: str, defines: dict[str, str], variables: dict[str, str]) -> str:
    """The make references in `text` expanded the way make would.

    `$$` stands in as NUL until the very end, so the shell's own `$(...)`
    that it becomes is never read as a make reference.
    """

    def expand(text: str) -> str:
        previous = None
        text = text.replace("$$", "\0")
        while previous != text:
            previous = text
            text = re.sub(r"\$\(([^()]*(?:\([^()]*\))?[^()]*)\)", reference, text)
        return text

    def reference(match: re.Match) -> str:
        inner = match[1]
        if inner.startswith("call "):
            return expand(defines[inner.removeprefix("call ")])
        if inner.startswith("subst .,\\.,"):
            return expand(inner.removeprefix("subst .,\\.,")).replace(".", "\\.")
        return variables[inner]

    return expand(text).replace("\0", "$")


def _script(define: str, variables: dict[str, str]) -> str:
    """A define as sh runs it: recipe lines without their tab and @."""
    lines = _expand(_defines()[define], _defines(), variables).splitlines()
    return "\n".join(line.lstrip("\t").removeprefix("@") for line in lines)


def _run(
    tmp_path: Path,
    define: str,
    *,
    state: tuple[str, ...] = (),
    up_after: int = 1,
    profile: str = "enabled",
    gluetun_env: str | None = f"WIREGUARD_ENDPOINT_IP={VPN_MOCK_IP}\n",
) -> tuple[subprocess.CompletedProcess, list[str]]:
    bin_dir = tmp_path / "bin"
    state_dir = tmp_path / "state"
    bin_dir.mkdir()
    state_dir.mkdir()
    for flag in state:
        (state_dir / flag).touch()
    log = tmp_path / "log"
    for name, body in STUBS.items():
        stub = bin_dir / name
        stub.write_text(f'#!/bin/sh\necho "{name} $*" >>"{log}"\n{body}\n')
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
    if gluetun_env is not None:
        (tmp_path / "configs/gluetun").mkdir(parents=True)
        (tmp_path / "configs/gluetun/.env").write_text(gluetun_env)
    variables = {
        "RUNTIME": "podman",
        "CONTAINER_PREFIX": "dev-",
        "COMPOSE": "compose",
        "COMPOSE_FILES": "--file docker-compose.yml",
        "COMPOSE_PROJECT_NAME": "proj",
        "CONFIG_FOLDER": "./configs",
        "VPN_MOCK_PROFILE": profile,
        "VPN_MOCK_IP": VPN_MOCK_IP,
        "VPN_MOCK_WG_CONF": "/config/wg_confs/wg0.conf",
    }
    result = subprocess.run(  # nosec B603 B607 - sh runs the Makefile's own defines against stubs
        ["sh", "-c", _script(define, variables)],
        cwd=tmp_path,
        env={
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "STATE": str(state_dir),
            "UP_AFTER": str(up_after),
        },
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    calls = log.read_text().splitlines() if log.exists() else []
    return result, calls


WG_QUICK_UP = (
    "podman exec dev-vpn_mock bash /usr/bin/wg-quick up /config/wg_confs/wg0.conf"
)


def test_a_tunnel_already_up_is_left_alone(tmp_path: Path) -> None:
    result, calls = _run(
        tmp_path, "ensure_vpn_mock_tunnel", state=("wg_up", "has_default")
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert WG_QUICK_UP not in calls
    assert not any("route add" in call for call in calls)


def test_a_tunnel_the_image_left_down_is_brought_up_through_bash(
    tmp_path: Path,
) -> None:
    result, calls = _run(
        tmp_path, "ensure_vpn_mock_tunnel", state=("image_down", "has_default")
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "vpn_mock left its tunnel down; bringing it up by hand..." in result.stdout
    # Through bash, never through wg-quick's own shebang, which is what fails.
    assert calls.count(WG_QUICK_UP) == 1


def test_a_tunnel_up_only_after_the_last_attempt_still_passes(tmp_path: Path) -> None:
    result, calls = _run(
        tmp_path,
        "ensure_vpn_mock_tunnel",
        state=("image_down", "has_default"),
        up_after=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert calls.count(WG_QUICK_UP) == 30
    assert "did not come up" not in result.stdout


def test_a_tunnel_that_never_comes_up_fails_with_diagnostics(tmp_path: Path) -> None:
    result, calls = _run(
        tmp_path, "ensure_vpn_mock_tunnel", state=("image_down",), up_after=99
    )
    assert result.returncode == 1
    assert "ERROR: vpn_mock's tunnel did not come up in 60s" in result.stdout
    assert calls.count(WG_QUICK_UP) == 30
    for heading in (
        "vpn_mock log",
        "vpn_mock wg show",
        "vpn_mock addresses, routes and firewall",
    ):
        assert f"--- {heading}" in result.stdout
    # gluetun is not started yet at this point, so there is nothing to ask it.
    assert "--- gluetun addresses and routes ---" not in result.stdout
    assert not any(call.startswith("podman exec dev-gluetun") for call in calls)


def test_a_missing_default_route_gets_the_wan_gateway(tmp_path: Path) -> None:
    result, calls = _run(tmp_path, "ensure_vpn_mock_tunnel", state=("wg_up",))
    assert result.returncode == 0, result.stdout + result.stderr
    assert (
        "vpn_mock has no default route; adding one via the wan gateway 10.89.0.1..."
        in result.stdout
    )
    assert "podman exec dev-vpn_mock ip -4 route add default via 10.89.0.1" in calls


@pytest.mark.parametrize(
    "line",
    [
        f"WIREGUARD_ENDPOINT_IP={VPN_MOCK_IP}",
        f'WIREGUARD_ENDPOINT_IP="{VPN_MOCK_IP}"',
        f"  WIREGUARD_ENDPOINT_IP = '{VPN_MOCK_IP}'  ",
    ],
)
def test_start_waits_on_the_tunnel_when_gluetun_dials_vpn_mock(
    tmp_path: Path, line: str
) -> None:
    result, calls = _run(
        tmp_path,
        "start_vpn_mock",
        state=("wg_up", "has_default"),
        gluetun_env=f"VPN_TYPE=wireguard\n{line}\n",
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert (
        "compose --file docker-compose.yml --profile enabled up --detach --no-recreate vpn_mock"
        in calls
    )
    assert "Waiting for the mock VPN tunnel (up to 60s)..." in result.stdout
    assert "podman exec dev-vpn_mock wg show wg0" in calls


@pytest.mark.parametrize(
    "gluetun_env",
    [
        "WIREGUARD_ENDPOINT_IP=203.0.113.5\n",
        # The mock's IP as a prefix of another address is not the mock.
        f"WIREGUARD_ENDPOINT_IP={VPN_MOCK_IP}0\n",
        "VPN_SERVICE_PROVIDER=protonvpn\n",
        None,
    ],
)
def test_start_skips_the_tunnel_when_gluetun_dials_elsewhere(
    tmp_path: Path, gluetun_env: str | None
) -> None:
    result, calls = _run(tmp_path, "start_vpn_mock", gluetun_env=gluetun_env)
    assert result.returncode == 0, result.stdout + result.stderr
    assert (
        "gluetun does not dial vpn_mock (a real VPN key is in place); not waiting on its tunnel."
        in result.stdout
    )
    assert not any(call.startswith("podman exec dev-vpn_mock") for call in calls)


def test_start_without_the_mock_profile_starts_nothing(tmp_path: Path) -> None:
    result, calls = _run(tmp_path, "start_vpn_mock", profile="disabled")
    assert result.returncode == 0, result.stdout + result.stderr
    assert calls == []


def test_a_gluetun_timeout_also_reports_vpn_mock_when_it_exists(tmp_path: Path) -> None:
    result, calls = _run(
        tmp_path, "wait_for_gluetun", state=("vpn_mock", "wg_up", "gluetun_running")
    )
    assert result.returncode == 1
    assert "ERROR: gluetun did not become healthy in time" in result.stdout
    assert "--- vpn_mock wg show ---" in result.stdout
    assert "--- gluetun addresses and routes ---" in result.stdout
    assert "podman exec dev-vpn_mock wg show" in calls


def test_a_gluetun_timeout_without_vpn_mock_reports_gluetun_only(
    tmp_path: Path,
) -> None:
    result, calls = _run(tmp_path, "wait_for_gluetun")
    assert result.returncode == 1
    assert "ERROR: gluetun did not become healthy in time" in result.stdout
    assert "--- vpn_mock" not in result.stdout
    assert not any(call.startswith("podman exec dev-vpn_mock") for call in calls)


def test_a_stopped_gluetun_is_not_exec_ed_into(tmp_path: Path) -> None:
    result, calls = _run(tmp_path, "vpn_mock_diagnostics", state=("vpn_mock",))
    assert result.returncode == 0, result.stdout + result.stderr
    assert "--- gluetun addresses and routes ---" not in result.stdout
    assert not any(call.startswith("podman exec dev-gluetun") for call in calls)
