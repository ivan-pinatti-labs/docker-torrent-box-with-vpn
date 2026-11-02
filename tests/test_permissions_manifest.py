from pathlib import Path

import pytest
import yaml
from dotenv import dotenv_values

REPO_ROOT = Path(__file__).parent.parent
PERMISSIONS = yaml.safe_load((REPO_ROOT / "permissions.yml").read_text())
ENV = dotenv_values(REPO_ROOT / ".env")


def _compose_file(name: str) -> dict:
    return yaml.safe_load((REPO_ROOT / name).read_text())


def _identity(name: str) -> dict:
    return PERMISSIONS["identities"][name]


def _env_prefix(identity: str) -> str:
    aliases = {"calibre_web": "CALIBREWEB"}
    return aliases.get(identity, identity.upper())


def test_permissions_paths_are_repo_relative():
    for entry in PERMISSIONS["paths"]:
        path = (REPO_ROOT / entry["path"]).resolve()
        assert path.is_relative_to(REPO_ROOT), entry["path"]
        assert ".." not in Path(entry["path"]).parts


def test_permissions_references_known_identities():
    identities = set(PERMISSIONS["identities"])
    host_access_identity = (PERMISSIONS.get("host_access") or {}).get("identity")
    if host_access_identity not in (None, "root"):
        assert host_access_identity in identities
    for entry in PERMISSIONS["paths"]:
        owner = entry.get("owner")
        if owner not in (None, "root"):
            assert owner in identities
        for acl_key in ("acl", "default_acl"):
            for acl in entry.get(acl_key, []):
                assert acl["identity"] == "root" or acl["identity"] in identities


def test_identity_env_vars_match_manifest():
    for name, ident in PERMISSIONS["identities"].items():
        env_prefix = _env_prefix(name)
        assert ENV[f"{env_prefix}_UID"] == str(ident["uid"])
        assert ENV[f"{env_prefix}_GID"] == str(ident["gid"])


def test_host_access_is_enabled_for_rootless_operator():
    assert PERMISSIONS["runtime"]["rootless_user_namespace"] is True
    assert PERMISSIONS["host_access"] == {
        "enabled": True,
        "identity": "root",
        "perms": "rwx",
        "default_perms": "rwx",
    }


@pytest.mark.parametrize(
    ("compose_name", "service", "identity"),
    [
        ("docker-compose-torrent.yml", "qbittorrent", "qbittorrent"),
        ("docker-compose-nzb.yml", "sabnzbd", "sabnzbd"),
        ("docker-compose-nzb.yml", "nzbhydra2", "nzbhydra2"),
        ("docker-compose-servarr.yml", "sonarr", "sonarr"),
        ("docker-compose-servarr.yml", "radarr", "radarr"),
        ("docker-compose-servarr.yml", "lidarr", "lidarr"),
        ("docker-compose-servarr.yml", "readarr", "readarr"),
        ("docker-compose-servarr.yml", "whisparr", "whisparr"),
        ("docker-compose-servarr.yml", "bazarr", "bazarr"),
        ("docker-compose-servarr.yml", "prowlarr", "prowlarr"),
        ("docker-compose-servarr.yml", "lazylibrarian", "lazylibrarian"),
        ("docker-compose-servarr.yml", "mylar", "mylar"),
        ("docker-compose-media-library.yml", "jellyfin", "jellyfin"),
        ("docker-compose-media-library.yml", "calibre", "calibre"),
        ("docker-compose-media-library.yml", "calibre-web", "calibre_web"),
    ],
)
def test_puid_pgid_services_use_manifest_identity(compose_name, service, identity):
    service_def = _compose_file(compose_name)["services"][service]
    environment = service_def["environment"]
    if isinstance(environment, list):
        env_map = dict(item.split("=", 1) for item in environment)
    else:
        env_map = environment

    prefix = _env_prefix(identity)
    assert env_map["PUID"] == f"${{{prefix}_UID}}"
    assert env_map["PGID"] == f"${{{prefix}_GID}}"


def test_jdownloader2_uses_manifest_identity():
    service_def = _compose_file("docker-compose-torrent.yml")["services"][
        "jdownloader2"
    ]
    env_map = dict(item.split("=", 1) for item in service_def["environment"])

    assert env_map["USER_ID"] == "${JDOWNLOADER2_UID}"
    assert env_map["GROUP_ID"] == "${JDOWNLOADER2_GID}"


@pytest.mark.parametrize(
    ("compose_name", "service", "identity"),
    [
        ("docker-compose-servarr.yml", "recyclarr", "recyclarr"),
        ("docker-compose-servarr.yml", "flaresolverr", "flaresolverr"),
        ("docker-compose-media-library.yml", "audiobookshelf", "audiobookshelf"),
        ("docker-compose-proxy.yml", "homepage", "homepage"),
        ("docker-compose-observability.yml", "alloy", "alloy"),
        ("docker-compose-observability.yml", "log_rotator", "log_rotator"),
        ("docker-compose-observability.yml", "prometheus", "prometheus"),
        ("docker-compose-observability.yml", "loki", "loki"),
        ("docker-compose-observability.yml", "grafana", "grafana"),
    ],
)
def test_user_field_services_use_manifest_identity(compose_name, service, identity):
    service_def = _compose_file(compose_name)["services"][service]
    prefix = _env_prefix(identity)
    assert service_def["user"] == f"${{{prefix}_UID}}:${{{prefix}_GID}}"


def test_log_rotator_can_rotate_nginx_logs():
    # nginx creates its log files as root, so owning logs/nginx gives the
    # rotator nothing on them. Without a named entry in both ACLs it cannot
    # read or truncate a single log, and the rotation script stops at the
    # first file with "Permission denied".
    entry = next(e for e in PERMISSIONS["paths"] if e["path"] == "logs/nginx")
    for key in ("acl", "default_acl"):
        perms = {item["identity"]: item["perms"] for item in entry[key]}
        assert "r" in perms.get("log_rotator", ""), key
        assert "w" in perms.get("log_rotator", ""), key


def test_no_rootless_start_chown_to_container_root_regression():
    makefile = (REPO_ROOT / "Makefile").read_text()
    assert "podman unshare sh -c" not in makefile
    assert (
        "./scripts/permissions.py repair --runtime $(RUNTIME) --recursive" in makefile
    )


def test_hardlink_smoke_tests_reference_declared_paths():
    declared = {entry["path"] for entry in PERMISSIONS["paths"]}
    for test in PERMISSIONS["smoke_tests"]["hardlinks"]:
        assert test["source_dir"] in declared
        assert test["target_dir"] in declared
        assert test["user"] in PERMISSIONS["identities"]
