"""Container security: hardening config, non-root processes, and config file access."""

import shutil
import sqlite3
import subprocess

import pytest

from conftest import (
    REPO_ROOT,
    SERVICES,
    env,
    fresh_container,
    is_enabled,
    skip_if_disabled,
    skip_if_not_running,
)

pytestmark = pytest.mark.security

# Services that received security_opt + cap_drop hardening.
# Excludes: cadvisor (privileged:true), podman_exporter and
# podman_limits_exporter (userns_mode plus label=disable, both run 0:0 with no
# dropped capabilities), gluetun (VPN caps).
HARDENED_SERVICES = [
    s
    for s in [
        "sonarr",
        "radarr",
        "bazarr",
        "lidarr",
        "prowlarr",
        "readarr",
        "whisparr",
        "recyclarr",
        "flaresolverr",
        "qbittorrent",
        "sabnzbd",
        "jellyfin",
        "prometheus",
        "grafana",
        "node_exporter",
        "nginx_exporter",
        "qbittorrent_exporter",
        "sabnzbd_exporter",
    ]
    if s in SERVICES
]

# Services using PUID/PGID env vars (linuxserver/hotio images).
# s6-overlay starts as root, then drops to PUID:PGID before exec'ing the app.
PUID_PGID_SERVICES = [
    s
    for s in [
        "sonarr",
        "radarr",
        "bazarr",
        "lidarr",
        "prowlarr",
        "readarr",
        "whisparr",
        "qbittorrent",
        "sabnzbd",
    ]
    if s in SERVICES
]

# Services whose entrypoint starts as root and drops to PUID/PGID via
# s6-overlay (same set as PUID_PGID_SERVICES, plus jellyfin which uses the
# same pattern but isn't covered by the PUID/PGID-specific tests below).
# Confirmed empirically that cap_drop: ALL breaks these: s6-applyuidgid's
# setgroups() call fails with "unable to set supplementary group list" once
# CAP_SETGID is removed, so they need the engine's default capability floor
# and cap_drop: ALL was never added to their compose blocks.
ROOT_INIT_SERVICES = set(PUID_PGID_SERVICES) | (
    {"jellyfin"} if "jellyfin" in SERVICES else set()
)

# Services that mount /config and whose app process must be able to read and write it.
SERVICES_WITH_CONFIG = [
    s
    for s in [
        "sonarr",
        "radarr",
        "bazarr",
        "lidarr",
        "prowlarr",
        "readarr",
        "whisparr",
        "recyclarr",
        "qbittorrent",
        "sabnzbd",
    ]
    if s in SERVICES
]

IPV6_DISABLED_SERVICES = [
    s
    for s in [
        "sabnzbd_exporter",
    ]
    if s in SERVICES
]

SABNZBD_COMPLETED_CATEGORIES = {
    "tv": ("0", "tv"),
    "movies": ("1", "movies"),
    "music": ("2", "music"),
    "ebooks": ("3", "ebooks"),
    "audiobooks": ("4", "audiobooks"),
    "comics": ("5", "comics"),
    "mature": ("6", "mature"),
}

# cspell:disable
TRASH_UNWANTED_EXTENSIONS = {
    "ade",
    "adp",
    "app",
    "application",
    "appref-ms",
    "asp",
    "aspx",
    "asx",
    "bas",
    "bat",
    "bgi",
    "cab",
    "cer",
    "chm",
    "cmd",
    "cnt",
    "com",
    "cpl",
    "crt",
    "csh",
    "der",
    "diagcab",
    "exe",
    "fxp",
    "gadget",
    "grp",
    "hlp",
    "hpj",
    "hta",
    "htc",
    "inf",
    "ins",
    "iso",
    "isp",
    "its",
    "jar",
    "jnlp",
    "js",
    "jse",
    "ksh",
    "lnk",
    "mad",
    "maf",
    "mag",
    "mam",
    "maq",
    "mar",
    "mas",
    "mat",
    "mau",
    "mav",
    "maw",
    "mcf",
    "mda",
    "mdb",
    "mde",
    "mdt",
    "mdw",
    "mdz",
    "msc",
    "msh",
    "msh1",
    "msh2",
    "mshxml",
    "msh1xml",
    "msh2xml",
    "msi",
    "msp",
    "mst",
    "msu",
    "ops",
    "osd",
    "pcd",
    "pif",
    "pl",
    "plg",
    "prf",
    "prg",
    "printerexport",
    "ps1",
    "ps1xml",
    "ps2",
    "ps2xml",
    "psc1",
    "psc2",
    "psd1",
    "psdm1",
    "pst",
    "py",
    "pyc",
    "pyo",
    "pyw",
    "pyz",
    "pyzw",
    "reg",
    "scf",
    "scr",
    "sct",
    "shb",
    "shs",
    "sln",
    "theme",
    "tmp",
    "url",
    "vb",
    "vbe",
    "vbp",
    "vbs",
    "vcxproj",
    "vhd",
    "vhdx",
    "vsmacros",
    "vsw",
    "webpnp",
    "website",
    "ws",
    "wsc",
    "wsf",
    "wsh",
    "xbap",
    "xll",
    "xnk",
}
# cspell:enable


def _sabnzbd_config_lines() -> list[str]:
    path = REPO_ROOT / "configs/sabnzbd/config/sabnzbd.ini"
    try:
        return path.read_text().splitlines()
    except PermissionError:
        result = subprocess.run(  # nosec B607 - podman is a trusted, fixed CLI in this stack
            ["podman", "unshare", "cat", str(path.relative_to(REPO_ROOT))],
            cwd=REPO_ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.splitlines()


def _sabnzbd_misc() -> dict[str, str]:
    values = {}
    in_misc = False
    for line in _sabnzbd_config_lines():
        stripped = line.strip()
        if stripped == "[misc]":
            in_misc = True
            continue
        if in_misc and stripped.startswith("[") and stripped.endswith("]"):
            break
        if in_misc and "=" in stripped:
            key, value = stripped.split("=", 1)
            values[key.strip()] = value.strip()
    return values


def _sabnzbd_categories() -> dict[str, dict[str, str]]:
    categories = {}
    current = None
    in_categories = False
    for line in _sabnzbd_config_lines():
        stripped = line.strip()
        if stripped == "[categories]":
            in_categories = True
            continue
        if in_categories and stripped.startswith("[[") and stripped.endswith("]]"):
            current = stripped.removeprefix("[[").removesuffix("]]")
            categories[current] = {}
            continue
        if in_categories and stripped.startswith("[") and not stripped.startswith("[["):
            break
        if in_categories and current and "=" in stripped:
            key, value = stripped.split("=", 1)
            categories[current][key.strip()] = value.strip()
    return categories


def _repo_file_exists(path) -> bool:
    if path.is_file():
        return True
    if not shutil.which("podman"):
        return False
    rel = path.relative_to(REPO_ROOT)
    result = subprocess.run(  # nosec B607 - podman is a trusted, fixed CLI in this stack
        ["podman", "unshare", "test", "-f", str(rel)],
        cwd=REPO_ROOT,
        check=False,
    )
    return result.returncode == 0


def _container_env(container) -> dict:
    """Return the container's environment variables as a flat dict."""
    return dict(
        kv.split("=", 1)
        for kv in (container.attrs.get("Config", {}).get("Env") or [])
        if "=" in kv
    )


def _app_uid(container) -> str:
    """Return the UID the app process runs as.

    Prefers PUID env var (linuxserver/hotio images via s6-overlay); falls back
    to the container's user: field; then falls back to the host UID from .env.
    """
    env_dict = _container_env(container)
    puid = env_dict.get("PUID")
    if puid and puid != "0":
        return puid
    user_field = container.attrs.get("Config", {}).get("User", "")
    if user_field:
        return user_field.split(":")[0]
    return env("UID", "1000")


@pytest.mark.parametrize("service_name", IPV6_DISABLED_SERVICES)
def test_ipv6_sysctls_disabled(service_name, running_containers, docker_client):
    """Standalone hardened services that can disable IPv6 must do so."""
    skip_if_disabled(service_name)
    skip_if_not_running(service_name, running_containers)
    container = fresh_container(docker_client, service_name)
    for path in (
        "/proc/sys/net/ipv6/conf/all/disable_ipv6",
        "/proc/sys/net/ipv6/conf/default/disable_ipv6",
        "/proc/sys/net/ipv6/conf/lo/disable_ipv6",
    ):
        exit_code, output = container.exec_run(["cat", path])
        assert exit_code == 0
        assert output.decode(errors="replace").strip() == "1"


def test_vpn_namespace_has_no_global_ipv6_address(running_containers, docker_client):
    """Nothing in gluetun's namespace may hold a routable IPv6 address.

    This is the control docker-compose-vpn.yml names: IPv6 is deliberately left
    enabled there, because gluetun's DNS server binds `[::]:53`, and leaks are
    prevented by no interface holding an IPv6 address plus gluetun's ip6tables
    rules. Until now nothing asserted the first half of that.

    It is the property the SABnzbd bind address was standing in for, and a
    better one to test. The bind address belongs to linuxserver's start script
    rather than to us, so asserting it proved only what upstream felt like doing
    that week, and a listener on `::` reaches nothing while this holds. Should a
    provider ever hand out an IPv6 address inside the tunnel, this fails and the
    bind address becomes worth arguing about again.
    """
    service_name = env("VPN_PROVIDER", "gluetun")
    # Not skip_if_disabled(): the VPN container is not a SERVICES entry, so that
    # helper finds no profile_var and always skipped. Read the profile the way
    # test_containers.py's test_vpn_container_running does.
    vpn_profile = f"{service_name.upper()}_PROFILE"
    if env(vpn_profile, "disabled").lower() != "enabled":
        pytest.skip(f"{vpn_profile} is not enabled")
    skip_if_not_running(service_name, running_containers)
    container = fresh_container(docker_client, service_name)

    # /proc/net/if_inet6 rather than `ip -6 addr`, which the image may not carry.
    # Columns are address, index, prefix length, scope, flags, device. Scope 10
    # is link-local and scope 20 is host, neither of which is routable; scope 00
    # is global, which is the one that must not appear.
    exit_code, output = container.exec_run(["cat", "/proc/net/if_inet6"])
    assert exit_code == 0, output.decode(errors="replace")

    global_addresses = [
        line
        for line in output.decode(errors="replace").splitlines()
        if len(line.split()) >= 4 and line.split()[3] == "00"
    ]
    assert not global_addresses, (
        "gluetun's namespace holds a routable IPv6 address, so the download "
        f"clients sharing it are reachable over IPv6: {global_addresses}"
    )


def test_sabnzbd_config_disables_ipv6():
    """SABnzbd should not select Usenet servers over IPv6, nor open [::1]."""
    misc = _sabnzbd_misc()
    # Either value is acceptable, because the bind address is the container's to
    # choose and not ours. linuxserver's start script passes `--server ::`
    # whenever /proc/net/if_inet6 exists, which it does here since gluetun keeps
    # IPv6 sysctls enabled for its own DNS listener, and `--server` overrides the
    # config file and is persisted back into it. So `host = 0.0.0.0` in the seeded
    # ini cannot survive a start, which is what turned the 5.0.4 bump red.
    #
    # Reported upstream twice, linuxserver/docker-sabnzbd#116 and #240, and closed
    # as intended behavior: forcing it stops a user binding 127.0.0.1 and locking
    # themselves out of the web UI.
    #
    # Nothing is lost by accepting it. The listener sits in gluetun's network
    # namespace, which has no IPv6 address and is firewalled, so `::` reaches
    # nothing `0.0.0.0` would not. See docs/HARDENING.md.
    assert misc["host"] in ("0.0.0.0", "::")  # nosec B104 - asserting a config value, not binding a socket
    # These two are ours. `--server` does not touch them, and they are what
    # actually governs IPv6 behavior rather than the bind address.
    assert misc["ipv6_hosting"] == "0"
    assert misc["ipv6_servers"] == "0"


def test_sabnzbd_config_has_bandwidth_schedule():
    """SABnzbd shares bandwidth with qBittorrent: 100 Mbps day, 500 Mbps night."""
    misc = _sabnzbd_misc()
    assert misc["bandwidth_max"] == "62500K"
    assert misc["schedlines"] == (
        "1 0 0 1234567 speedlimit 62500K, 1 0 8 1234567 speedlimit 12500K"
    )


def test_sabnzbd_categories_match_media_layout():
    """SABnzbd categories should map to the expected completed-download folders."""
    categories = _sabnzbd_categories()
    for name, (order, directory) in SABNZBD_COMPLETED_CATEGORIES.items():
        assert categories[name]["name"] == name
        assert categories[name]["order"] == order
        assert categories[name]["pp"] == "3"
        assert categories[name]["dir"] == directory


def test_usenet_completed_category_folders_exist_in_repo():
    """SABnzbd category folders must exist under complete_dir."""
    usenet_root = REPO_ROOT / "data/usenet"
    assert _repo_file_exists(usenet_root / "incomplete/.gitkeep")
    assert _repo_file_exists(usenet_root / "complete/.gitkeep")
    for _, directory in SABNZBD_COMPLETED_CATEGORIES.values():
        assert _repo_file_exists(usenet_root / f"complete/{directory}/.gitkeep")


@pytest.mark.parametrize(
    "service_name",
    ["sabnzbd", "sonarr", "radarr", "lidarr", "readarr", "whisparr"],
)
def test_usenet_completed_category_folders_visible_to_apps(
    service_name, running_containers, docker_client
):
    """All apps sharing /data must see the same SABnzbd completed paths."""
    skip_if_disabled(service_name)
    skip_if_not_running(service_name, running_containers)
    container = fresh_container(docker_client, service_name)
    paths = ["/data/usenet/incomplete", "/data/usenet/complete"]
    paths.extend(
        f"/data/usenet/complete/{directory}"
        for _, directory in SABNZBD_COMPLETED_CATEGORIES.values()
    )
    command = " && ".join(f"test -d {path}" for path in paths)
    exit_code, output = container.exec_run(["sh", "-c", command])
    assert exit_code == 0, output.decode(errors="replace")


def test_servarr_remote_path_mappings_not_needed_for_shared_data_mount():
    """Servarr apps should not need remote mappings when all containers mount /data."""
    dbs = {
        "sonarr": "configs/sonarr/config/sonarr.db",
        "radarr": "configs/radarr/config/radarr.db",
        "lidarr": "configs/lidarr/config/lidarr.db",
        "readarr": "configs/readarr/config/readarr.db",
        "whisparr": "configs/whisparr/config/whisparr3.db",
    }
    for app, db in dbs.items():
        if not is_enabled(app):
            continue
        conn = sqlite3.connect(REPO_ROOT / db)
        try:
            count = conn.execute("SELECT COUNT(*) FROM RemotePathMappings").fetchone()[
                0
            ]
        finally:
            conn.close()
        assert count == 0, f"{db} contains RemotePathMappings"


def test_sabnzbd_trash_guide_alignment():
    """SABnzbd media defaults should follow the applicable TRaSH guidance."""
    misc = _sabnzbd_misc()
    unwanted_extensions = {
        item.strip() for item in misc["unwanted_extensions"].split(",") if item.strip()
    }

    assert misc["propagation_delay"] == "5"
    assert unwanted_extensions == TRASH_UNWANTED_EXTENSIONS
    assert misc["unwanted_extensions_mode"] == "0"
    assert misc["action_on_unwanted_extensions"] == "2"
    assert misc["direct_unpack"] == "1"
    assert misc["direct_unpack_threads"] == "2"
    assert misc["enable_unrar"] == "1"
    assert misc["enable_7zip"] == "1"
    assert misc["enable_filejoin"] == "1"
    assert misc["enable_tsjoin"] == "1"
    assert misc["safe_postproc"] == "1"
    assert misc["sfv_check"] == "1"
    assert misc["enable_recursive"] == "1"
    assert misc["ignore_samples"] == "1"
    assert misc["nzb_backup_dir"] == "history"
    assert misc["enable_tv_sorting"] == "0"
    assert misc["enable_movie_sorting"] == "0"
    assert misc["enable_date_sorting"] == "0"


@pytest.mark.parametrize("service_name", HARDENED_SERVICES)
def test_no_new_privileges(service_name, running_containers):
    """no-new-privileges must be in SecurityOpt for all hardened services."""
    skip_if_disabled(service_name)
    skip_if_not_running(service_name, running_containers)
    container = running_containers[service_name]
    security_opts = container.attrs.get("HostConfig", {}).get("SecurityOpt") or []
    assert any("no-new-privileges" in opt for opt in security_opts), (
        f"Container '{service_name}' is missing 'no-new-privileges' in SecurityOpt: {security_opts}"
    )


# podman's Docker-compatible API expands `cap_drop: [ALL]` into the engine's
# actual default capability set instead of reporting the literal "ALL" token
# real Docker returns, so check that every default capability was dropped
# rather than looking for that literal string.
DEFAULT_CAPABILITIES = {
    "CHOWN",
    "DAC_OVERRIDE",
    "FOWNER",
    "FSETID",
    "KILL",
    "NET_BIND_SERVICE",
    "SETFCAP",
    "SETGID",
    "SETPCAP",
    "SETUID",
    "SYS_CHROOT",
}


@pytest.mark.parametrize("service_name", HARDENED_SERVICES)
def test_capabilities_dropped(service_name, running_containers):
    """Hardened services must drop every capability they don't structurally need.

    Most hardened services can and do drop every capability (cap_drop: ALL).
    ROOT_INIT_SERVICES structurally can't: their entrypoint starts as root
    and needs the engine's default capability floor to drop privileges via
    s6-overlay, so for those this only checks that nothing extra was added
    on top of that floor.
    """
    skip_if_disabled(service_name)
    skip_if_not_running(service_name, running_containers)
    container = running_containers[service_name]
    host_config = container.attrs.get("HostConfig", {})
    cap_add = {cap.upper() for cap in (host_config.get("CapAdd") or [])}

    if service_name in ROOT_INIT_SERVICES:
        assert not cap_add, (
            f"Container '{service_name}' has capabilities added beyond the "
            f"default floor it needs for its own privilege drop: {sorted(cap_add)}"
        )
        return

    cap_drop = {cap.upper() for cap in (host_config.get("CapDrop") or [])}
    if "ALL" in cap_drop:
        return
    missing = DEFAULT_CAPABILITIES - cap_drop
    assert not missing, (
        f"Container '{service_name}' retains capabilities beyond the default "
        f"floor (CapDrop={sorted(cap_drop)}): missing {sorted(missing)}"
    )


@pytest.mark.parametrize("service_name", PUID_PGID_SERVICES)
def test_puid_pgid_non_root(service_name, running_containers):
    """PUID and PGID env vars must not be '0' for linuxserver/hotio services."""
    skip_if_disabled(service_name)
    skip_if_not_running(service_name, running_containers)
    container = running_containers[service_name]
    env_dict = _container_env(container)
    puid = env_dict.get("PUID", "0")
    pgid = env_dict.get("PGID", "0")
    assert puid != "0", (
        f"Container '{service_name}' has PUID=0: app process runs as root"
    )
    assert pgid != "0", (
        f"Container '{service_name}' has PGID=0: app process runs as root group"
    )


@pytest.mark.parametrize("service_name", PUID_PGID_SERVICES)
def test_app_process_non_root(service_name, running_containers, docker_client):
    """At least one process inside the container must run as a non-root UID.

    s6-overlay PID 1 legitimately runs as uid=0; the app process it spawns must
    run as PUID (non-zero). We inspect /proc to confirm.
    """
    skip_if_disabled(service_name)
    skip_if_not_running(service_name, running_containers)
    container = fresh_container(docker_client, service_name)
    exit_code, output = container.exec_run(
        [
            "sh",
            "-c",
            "cat /proc/[0-9]*/status 2>/dev/null | awk '/^Uid:/{print $2}' | grep -v '^0$' | head -1",
        ]
    )
    non_root_uid = output.decode(errors="replace").strip()
    assert exit_code == 0 and non_root_uid != "", (
        f"Container '{service_name}' has no non-root processes: "
        "PUID/PGID may not have been applied by s6-overlay"
    )
    expected_puid = _container_env(container).get("PUID", "")
    if expected_puid:
        assert non_root_uid == expected_puid, (
            f"Container '{service_name}' has a non-root process running as uid={non_root_uid}, "
            f"expected PUID={expected_puid}"
        )


@pytest.mark.parametrize("service_name", SERVICES_WITH_CONFIG)
def test_config_readable_as_app_user(service_name, running_containers, docker_client):
    """The app user must be able to list and read the /config directory."""
    skip_if_disabled(service_name)
    skip_if_not_running(service_name, running_containers)
    container = fresh_container(docker_client, service_name)
    uid = _app_uid(container)
    exit_code, output = container.exec_run(
        [
            "sh",
            "-c",
            "test -d /config && test -r /config && ls /config > /dev/null && echo ok",
        ],
        user=uid,
    )
    assert exit_code == 0 and output.decode(errors="replace").strip() == "ok", (
        f"Container '{service_name}' uid={uid} cannot read /config: "
        f"{output.decode(errors='replace').strip()}"
    )


@pytest.mark.parametrize("service_name", SERVICES_WITH_CONFIG)
def test_config_writable_as_app_user(service_name, running_containers, docker_client):
    """The app user must be able to create and remove a file inside /config."""
    skip_if_disabled(service_name)
    skip_if_not_running(service_name, running_containers)
    container = fresh_container(docker_client, service_name)
    uid = _app_uid(container)
    exit_code, output = container.exec_run(
        [
            "sh",
            "-c",
            "touch /config/.security_write_test && rm -f /config/.security_write_test && echo ok",
        ],
        user=uid,
    )
    assert exit_code == 0 and output.decode(errors="replace").strip() == "ok", (
        f"Container '{service_name}' uid={uid} cannot write to /config: "
        f"{output.decode(errors='replace').strip()}"
    )
