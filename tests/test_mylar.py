"""Mylar to qBittorrent over HTTPS with the stack's self-signed certificate.

Until #106 five patched files mounted over the image added this; Mylar v0.11.0
ships it as `qbittorrent_ignore_ssl`. This runs Mylar's own client inside the
mylar container, the code its downloads go through, rather than curl, so it
fails if Mylar stops honouring the setting, and checks the opposite too: with
certificate verification on, the same login has to fail, or the setting is
not what is letting it through.
"""

import os
import subprocess  # nosec B404 - podman CLI with fixed arguments

import pytest

from conftest import REPO_ROOT, container_name, env, read_secret, skip_if_not_running

pytestmark = pytest.mark.connectivity

CONFIG_INI = REPO_ROOT / "configs" / "mylar" / "config" / "mylar" / "config.ini"

# Mylar's TorrentClient, imported the way the app imports it. The credentials
# arrive through the environment, so they never appear in a process list.
CONNECT = """
import os, sys
sys.path[:0] = ["/app/mylar3", "/app/mylar3/lib"]
from mylar.torrent.clients.qbittorrent import TorrentClient
try:
    result = TorrentClient().connect(
        os.environ["QBT_HOST"], os.environ["QBT_USER"], os.environ["QBT_PASS"],
        ignore_ssl=os.environ["QBT_IGNORE_SSL"] == "True", test=True,
    )
except Exception as error:
    result = {"status": False, "error": error}
print("STATUS", result["status"])
print("DETAIL", result.get("version") or result.get("error"))
"""


def _config_value(key: str) -> str | None:
    """A plain `key = value` line out of Mylar's live config.ini."""
    if not CONFIG_INI.exists():
        return None
    for line in CONFIG_INI.read_text().splitlines():
        if line.strip().startswith(f"{key} ="):
            return line.split("=", 1)[1].strip()
    return None


def _connect(host: str, ignore_ssl: str) -> str:
    environment = {
        **os.environ,
        "QBT_HOST": host,
        "QBT_USER": read_secret("qbittorrent", "username.txt") or "",
        "QBT_PASS": read_secret("qbittorrent", "password.txt") or "",
        "QBT_IGNORE_SSL": ignore_ssl,
    }
    result = subprocess.run(  # nosec B603 B607 - fixed arguments
        [
            "podman",
            "exec",
            "-w",
            "/app/mylar3",
            "-e",
            "QBT_HOST",
            "-e",
            "QBT_USER",
            "-e",
            "QBT_PASS",
            "-e",
            "QBT_IGNORE_SSL",
            container_name("mylar"),
            "/lsiopy/bin/python3",
            "-c",
            CONNECT,
        ],
        env=environment,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    return result.stdout + result.stderr


def test_mylar_logs_in_to_qbittorrent_over_its_self_signed_https(running_containers):
    if env("MYLAR_PROFILE", "disabled").lower() != "enabled":
        pytest.skip("mylar profile is disabled")
    skip_if_not_running("mylar", running_containers)
    skip_if_not_running("qbittorrent", running_containers)

    host = _config_value("qbittorrent_host")
    ignore_ssl = _config_value("qbittorrent_ignore_ssl")
    assert host and host.startswith("https://"), f"qbittorrent_host is {host!r}"
    assert ignore_ssl == "True", f"qbittorrent_ignore_ssl is {ignore_ssl!r}"

    output = _connect(host, ignore_ssl)
    assert "STATUS True" in output, output

    # Verification on fails at the TLS handshake, before any login is sent,
    # so it costs nothing against qBittorrent's failed login ban.
    output = _connect(host, "False")
    assert "STATUS False" in output, output
    assert "CERTIFICATE_VERIFY_FAILED" in output, output
