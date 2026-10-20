"""Integration tests for scripts/rotate-api-keys.sh.

These tests execute the rotation script against the live stack, verify the new
key propagated to every consumer, then restore the original key so the suite
remains idempotent. They are marked `rotation` and are excluded from the
default `make test` run because they modify running service state.

App ports are not published to the host, so all API calls run curl inside the
target container (see conftest.container_http), matching how the rotation
scripts themselves talk to the apps.

Run explicitly with:
    pytest -m rotation tests/test_rotate_api_keys.py
"""

import json
import subprocess
import time
import xml.etree.ElementTree as ET

import pytest
import yaml

from conftest import (
    ENV,
    REPO_ROOT,
    container_http,
    homepage_widget_failures,
    is_enabled,
    live_db,
    read_secret,
    restart_container,
    skip_if_not_running,
    wait_for_healthy,
    wait_for_homepage_ready,
)

pytestmark = pytest.mark.rotation

TIMEOUT = 30
SCRIPTS = REPO_ROOT / "scripts"

BAZARR_CONFIG = REPO_ROOT / "configs/bazarr/config/config/config.yaml"
RECYCLARR_SECRETS = REPO_ROOT / "configs/recyclarr/config/secrets.yml"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _run_script(script: str, target: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(SCRIPTS / script), target],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=600,
    )


def _read_xml_key(rel_path: str) -> str:
    path = REPO_ROOT / rel_path
    tree = ET.parse(path)
    elem = tree.find("ApiKey")
    assert elem is not None and elem.text, f"ApiKey not found in {rel_path}"
    return elem.text


def _health_status(
    app: str, scheme: str, port: int, url_base: str, api_ver: str, key: str
) -> int:
    status, _ = container_http(
        app,
        f"{scheme}://127.0.0.1:{port}/{url_base}/api/{api_ver}/health",
        headers={"X-Api-Key": key},
        timeout=TIMEOUT,
    )
    return status


def _restore_arr_key(app: str, xml_path: str, old_key: str):
    """Write old_key back to config.xml and restart the app to load it.

    The arr apps ignore apiKey changes sent over their API, so restore uses
    the same mechanism as the rotation script: edit config.xml and restart.
    """
    subprocess.run(  # nosec B607 - xmlstarlet is a trusted, fixed CLI in this stack
        [
            "xmlstarlet",
            "--quiet",
            "ed",
            "--inplace",
            "--update",
            "/Config/ApiKey",
            "--value",
            old_key,
            str(REPO_ROOT / xml_path),
        ],
        check=True,
    )
    subprocess.run(  # nosec B607 - podman is a trusted, fixed CLI in this stack
        ["podman", "restart", app], check=True, capture_output=True
    )
    assert wait_for_healthy(app), f"{app} did not become healthy after key restore"


def _arr_prowlarr_indexer_apikeys(db_rel: str) -> dict[str, str]:
    """Map indexer name -> stored apiKey, for indexers pointing at Prowlarr.

    The arr apps' own API redacts apiKey in every response, so the only way
    to verify the stored value is to read the Indexers table directly.
    """
    db_path = REPO_ROOT / db_rel
    if not db_path.exists():
        return {}
    result = {}
    with live_db(db_path) as conn:
        for name, settings in conn.execute("SELECT Name, Settings FROM Indexers"):
            data = json.loads(settings)
            if "prowlarr" in str(data.get("baseUrl", "")).lower():
                result[name] = data.get("apiKey")
    return result


def _restore_arr_indexer_apikeys(
    app: str, scheme: str, port: int, api_ver: str, app_api_key: str, old_key: str
):
    """PUT old_key back into every Prowlarr-sourced Indexer on a live arr app.

    Mirrors scripts/rotate-api-keys.sh's propagate_prowlarr_key(): the arr
    apps never refresh an Indexer's apiKey field on their own, so restoring
    Prowlarr's own key needs this same explicit PUT, not just a resync.
    """
    # A few retries: an arr app can 500 with "unable to open database file"
    # for a few seconds right after its own restart (SQLite still opening),
    # confirmed live when this raced against test_rinse_and_repeat.py's
    # stack-wide restart cycle running immediately before this test.
    status, body = 0, ""
    for _attempt in range(6):
        status, body = container_http(
            app,
            f"{scheme}://127.0.0.1:{port}/{app}/api/{api_ver}/indexer",
            headers={"X-Api-Key": app_api_key},
            timeout=TIMEOUT,
        )
        if status == 200:
            break
        time.sleep(5)
    assert status == 200, f"[{app}] GET indexer failed while restoring: {status} {body}"
    for rec in json.loads(body):
        base_url = next(
            (f["value"] for f in rec["fields"] if f["name"] == "baseUrl"), ""
        )
        if "prowlarr" not in str(base_url).lower():
            continue
        for field in rec["fields"]:
            if field["name"] == "apiKey":
                field["value"] = old_key
        status, body = container_http(
            app,
            f"{scheme}://127.0.0.1:{port}/{app}/api/{api_ver}/indexer/{rec['id']}"
            "?forceSave=true",
            method="PUT",
            headers={"X-Api-Key": app_api_key, "Content-Type": "application/json"},
            data=json.dumps(rec),
            timeout=TIMEOUT,
        )
        assert status in (200, 202), (
            f"[{app}] could not restore indexer '{rec['name']}' apiKey: {status} {body}"
        )


def _read_ini_torznab_prowlarr_key(rel_path: str) -> str | None:
    """Return the `api` value of the Torznab section pointing at Prowlarr."""
    import configparser

    parser = configparser.ConfigParser(strict=False)
    parser.read(REPO_ROOT / rel_path)
    for section in parser.sections():
        if not section.startswith("Torznab_"):
            continue
        if "prowlarr" in parser.get(section, "host", fallback="").lower():
            return parser.get(section, "api", fallback=None)
    return None


def _prowlarr_application(prowlarr_api_key: str, app_name: str) -> dict | None:
    """Return the Prowlarr Applications entry for app_name, or None if absent."""
    port = int(ENV.get("PROWLARR_HTTPS_PORT", "6969"))
    status, body = container_http(
        "prowlarr",
        f"https://127.0.0.1:{port}/prowlarr/api/v1/applications",
        headers={"X-Api-Key": prowlarr_api_key},
        timeout=TIMEOUT,
    )
    if status != 200:
        return None
    for app in json.loads(body):
        if app.get("name") == app_name:
            return app
    return None


def _prowlarr_stored_key(app_name: str) -> str | None:
    """Return the apiKey Prowlarr stores for an app, read from prowlarr.db.

    The Prowlarr API redacts apiKey values in GET responses, so the only way
    to verify the stored value is to read the Applications table directly.
    """
    with live_db(REPO_ROOT / "configs/prowlarr/config/prowlarr.db") as conn:
        row = conn.execute(
            "SELECT Settings FROM Applications WHERE Name = ?", (app_name,)
        ).fetchone()
    if row is None:
        return None
    return json.loads(row[0]).get("apiKey")


def _set_prowlarr_key_for_app(
    prowlarr_api_key: str, app_name: str, key: str, timeout: int = 60
):
    """Write an app's API key back into Prowlarr's Applications table.

    This is a read-modify-write against a record other workers also touch.
    rotation_isolated runs several arr-app cases in parallel and each rewrites
    its own Prowlarr application, so the record can change between the read and
    the write, and Prowlarr rejects the stale copy with a 400. Prowlarr is also
    restarted during these rotations, which fails the write outright.

    Re-read and retry rather than asserting on a single attempt. Observed live
    in CI as "Could not restore Prowlarr application 'Sonarr': 400".
    """
    port = int(ENV.get("PROWLARR_HTTPS_PORT", "6969"))
    deadline = time.time() + timeout
    status = None
    while time.time() < deadline:
        app_json = _prowlarr_application(prowlarr_api_key, app_name)
        if app_json is not None:
            for field in app_json.get("fields", []):
                if field.get("name") == "apiKey":
                    field["value"] = key
            status, _ = container_http(
                "prowlarr",
                f"https://127.0.0.1:{port}/prowlarr/api/v1/applications/{app_json['id']}",
                method="PUT",
                headers={
                    "X-Api-Key": prowlarr_api_key,
                    "Content-Type": "application/json",
                },
                data=json.dumps(app_json),
                timeout=TIMEOUT,
            )
            if status in (200, 202):
                return
        time.sleep(3)
    assert status in (200, 202), (
        f"Could not restore Prowlarr application '{app_name}': {status}"
    )


def _bazarr_running() -> bool:
    result = subprocess.run(  # nosec B607 - podman is a trusted, fixed CLI in this stack
        ["podman", "inspect", "bazarr", "--format", "{{.State.Running}}"],
        capture_output=True,
        text=True,
    )
    return result.stdout.strip() == "true"


def _restore_yaml_consumers(app: str, old_key: str):
    """Restore Bazarr and Recyclarr entries for sonarr/radarr.

    A running Bazarr is stopped around the edit, the way rotate-api-keys.sh
    edits it: it writes config.yaml back from memory, so an edit made while
    it runs can be lost, and it rewrites the file as it starts.
    """
    running = _bazarr_running()
    if running:
        subprocess.run(  # nosec B607 - podman is a trusted, fixed CLI in this stack
            ["podman", "stop", "bazarr"], check=True, capture_output=True
        )
    try:
        with open(BAZARR_CONFIG) as fh:
            bazarr_cfg = yaml.safe_load(fh)
        bazarr_cfg[app]["apikey"] = old_key
        with open(BAZARR_CONFIG, "w") as fh:
            yaml.dump(bazarr_cfg, fh, default_flow_style=False, allow_unicode=True)
    finally:
        if running:
            subprocess.run(  # nosec B607 - podman is a trusted, fixed CLI in this stack
                ["podman", "start", "bazarr"], check=True, capture_output=True
            )
    if running:
        assert wait_for_healthy("bazarr"), "bazarr did not become healthy after restore"

    # RECYCLARR_PROFILE is disabled by default, and rotate-api-keys.sh
    # itself already skips this file cleanly when it doesn't exist yet
    # (update_prowlarr_application's own convention); match that here.
    if RECYCLARR_SECRETS.exists():
        with open(RECYCLARR_SECRETS) as fh:
            recyclarr_cfg = yaml.safe_load(fh)
        recyclarr_cfg[f"{app}_apikey"] = old_key
        with open(RECYCLARR_SECRETS, "w") as fh:
            yaml.dump(recyclarr_cfg, fh, default_flow_style=False)


def _restore_api_key_secret(app: str, old_key: str):
    # No trailing newline: consumers (homepage) read the file verbatim
    path = REPO_ROOT / f"configs/{app}/secrets/api_key.txt"
    path.write_text(old_key)
    path.chmod(0o644)


def _assert_homepage_widget_ok(app: str, action: str, timeout: int = 90):
    # rotation_isolated runs several of these arr-app cases in parallel
    # (pytest -n 4), and every one of them restarts the shared homepage
    # container as part of its own rotate/restore cycle. wait_for_homepage_
    # ready() only proves homepage answered at that instant; a sibling
    # worker's restart landing microseconds later can still make the
    # following widget check see "HTTP 0" even though nothing is actually
    # broken. Confirmed live: two concurrent workers (lidarr, sonarr) both
    # hit this on the same run. Retry the whole ready+widget check instead
    # of asserting on a single sample.
    #
    # 30s was not enough on a loaded runner: CI still failed here with
    # "Radarr (queue/status): HTTP 0", homepage simply not answering yet.
    # Four workers each restarting the same container serialises those
    # restarts, so the window has to cover all of them, not just one.
    deadline = time.time() + timeout
    failures: list[str] = []
    while time.time() < deadline:
        if wait_for_homepage_ready(timeout=15):
            failures = homepage_widget_failures(only_services={app})
            if not failures:
                return
        time.sleep(3)
    assert not failures, f"Homepage widget broken after {action} {app}:\n" + "\n".join(
        failures
    )


# app, xml_path, scheme, port_var, url_base, api_ver
ARR_APP_TARGETS = [
    (
        "sonarr",
        "configs/sonarr/config/config.xml",
        "http",
        "SONARR_HTTP_PORT",
        "sonarr",
        "v3",
    ),
    (
        "radarr",
        "configs/radarr/config/config.xml",
        "https",
        "RADARR_HTTPS_PORT",
        "radarr",
        "v3",
    ),
    (
        "lidarr",
        "configs/lidarr/config/config.xml",
        "https",
        "LIDARR_HTTPS_PORT",
        "lidarr",
        "v1",
    ),
    (
        "readarr",
        "configs/readarr/config/config.xml",
        "https",
        "READARR_HTTPS_PORT",
        "readarr",
        "v1",
    ),
    (
        "whisparr",
        "configs/whisparr/config/config.xml",
        "https",
        "WHISPARR_HTTPS_PORT",
        "whisparr",
        "v3",
    ),
]

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.rotation_isolated
@pytest.mark.parametrize(
    "app,xml_path,scheme,port_var,url_base,api_ver", ARR_APP_TARGETS
)
def test_rotate_api_key_propagates(
    app,
    xml_path,
    scheme,
    port_var,
    url_base,
    api_ver,
    running_containers,
):
    """Rotating an arr app's API key updates all consumers and the new key works."""
    if not is_enabled(app):
        pytest.skip(f"{app} profile is disabled")
    skip_if_not_running(app, running_containers)
    skip_if_not_running("prowlarr", running_containers)

    old_key = _read_xml_key(xml_path)
    port = int(ENV.get(port_var, "0"))

    result = _run_script("rotate-api-keys.sh", app)
    assert result.returncode == 0, (
        f"rotate-api-keys.sh {app} exited {result.returncode}:\n{result.stderr}"
    )

    new_key = _read_xml_key(xml_path)
    assert new_key != old_key, f"{app}: key was not changed"

    # The script recreates the app container; wait for it to come back.
    assert wait_for_healthy(app), f"{app} did not become healthy after rotation"

    # New key is accepted
    status = _health_status(app, scheme, port, url_base, api_ver, new_key)
    assert status == 200, (
        f"{app}: new key not accepted by health endpoint (HTTP {status})"
    )

    # Old key is rejected
    status = _health_status(app, scheme, port, url_base, api_ver, old_key)
    assert status == 401, (
        f"{app}: old key still accepted after rotation (HTTP {status})"
    )

    # Prowlarr Applications table was updated (skipped for apps that have no
    # application entry in Prowlarr, e.g. Whisparr)
    prowlarr_key = _read_xml_key("configs/prowlarr/config/config.xml")
    prowlarr_entry = _prowlarr_application(prowlarr_key, app.capitalize())
    if prowlarr_entry is not None:
        stored = _prowlarr_stored_key(app.capitalize())
        assert stored == new_key, (
            f"Prowlarr application '{app}' has a stale key, expected the rotated one"
        )

    # Sonarr and Radarr also propagate to Bazarr and recyclarr
    if app in ("sonarr", "radarr"):
        # The script restarted Bazarr, which rewrites config.yaml as it
        # starts; healthy means that write is done.
        if _bazarr_running():
            assert wait_for_healthy("bazarr"), (
                "bazarr did not become healthy after rotation"
            )
        with open(BAZARR_CONFIG) as fh:
            bazarr_cfg = yaml.safe_load(fh)
        assert bazarr_cfg[app]["apikey"] == new_key, (
            f"Bazarr config.yaml {app}.apikey not updated"
        )

        if RECYCLARR_SECRETS.exists():
            with open(RECYCLARR_SECRETS) as fh:
                recyclarr_cfg = yaml.safe_load(fh)
            assert recyclarr_cfg[f"{app}_apikey"] == new_key, (
                f"recyclarr secrets.yml {app}_apikey not updated"
            )

    # The shared secret file (read by homepage) holds the new key, without a
    # trailing newline, at mode 644
    secret_path = REPO_ROOT / f"configs/{app}/secrets/api_key.txt"
    assert secret_path.read_text() == new_key, (
        f"configs/{app}/secrets/api_key.txt was not updated with the new key"
    )
    assert oct(secret_path.stat().st_mode)[-3:] == "644", (
        f"configs/{app}/secrets/api_key.txt has the wrong mode for rootless podman"
    )

    # Homepage was restarted by the script and must work with the new key
    if "homepage" in running_containers:
        _assert_homepage_widget_ok(app, "rotating")

    # ------------------------------------------------------------------
    # Restore the original key everywhere so the suite stays idempotent
    # ------------------------------------------------------------------
    _restore_arr_key(app, xml_path, old_key)

    status = _health_status(app, scheme, port, url_base, api_ver, old_key)
    assert status == 200, f"{app}: could not restore old key (HTTP {status})"

    if prowlarr_entry is not None:
        _set_prowlarr_key_for_app(prowlarr_key, app.capitalize(), old_key)

    if app in ("sonarr", "radarr"):
        _restore_yaml_consumers(app, old_key)
    _restore_api_key_secret(app, old_key)

    # Homepage reads the key from a bind-mounted secret file, so a plain
    # restart (not a recreate) is enough to pick up the restored value.
    if "homepage" in running_containers:
        restart_container("homepage")
        _assert_homepage_widget_ok(app, "restoring")


def test_rotate_prowlarr_api_key(running_containers):
    """Rotating Prowlarr's own key updates every place that key is stored.

    Prowlarr's own API key isn't just local to Prowlarr: it also gets
    embedded, at indexer-push time, into every downstream app's *Indexer*
    record (as the credential that app uses to call back through Prowlarr's
    indexer proxy) and into LazyLibrarian's matching Torznab entry. This test
    exists because that propagation was previously missing entirely: the old
    key kept working there until a manual `make wire_connections`, which
    surfaced as "invalid credentials" / 401 errors testing an indexer in
    Sonarr, Radarr, etc., and a failing indexer test in LazyLibrarian.
    """
    from test_rotate_passwords import ARR_DB_PATHS

    if not is_enabled("prowlarr"):
        pytest.skip("prowlarr profile is disabled")
    skip_if_not_running("prowlarr", running_containers)

    xml_path = "configs/prowlarr/config/config.xml"
    old_key = _read_xml_key(xml_path)
    port = int(ENV.get("PROWLARR_HTTPS_PORT", "6969"))

    result = _run_script("rotate-api-keys.sh", "prowlarr")
    assert result.returncode == 0, (
        f"rotate-api-keys.sh prowlarr exited {result.returncode}:\n{result.stderr}"
    )

    new_key = _read_xml_key(xml_path)
    assert new_key != old_key, "prowlarr: key was not changed"
    assert wait_for_healthy("prowlarr"), (
        "prowlarr did not become healthy after rotation"
    )

    status = _health_status("prowlarr", "https", port, "prowlarr", "v1", new_key)
    assert status == 200, f"prowlarr: new key not accepted (HTTP {status})"
    status = _health_status("prowlarr", "https", port, "prowlarr", "v1", old_key)
    assert status == 401, f"prowlarr: old key still accepted (HTTP {status})"

    secret_path = REPO_ROOT / "configs/prowlarr/secrets/api_key.txt"
    assert secret_path.read_text() == new_key, (
        "configs/prowlarr/secrets/api_key.txt was not updated with the new key"
    )

    # Every arr app's Prowlarr-sourced Indexer entry carries the new key...
    for app, _xml, _scheme, _port_var, _url_base, _api_ver in ARR_APP_TARGETS:
        if not is_enabled(app) or app not in running_containers:
            continue
        apikeys = _arr_prowlarr_indexer_apikeys(ARR_DB_PATHS[app])
        for name, apikey in apikeys.items():
            assert apikey == new_key, (
                f"[{app}] indexer '{name}' still holds Prowlarr's old key"
            )

    # ...and so does LazyLibrarian's matching Torznab entry.
    if "lazylibrarian" in running_containers:
        ll_key = _read_ini_torznab_prowlarr_key(LAZYLIBRARIAN_INI)
        if ll_key is not None:
            assert ll_key == new_key, (
                "LazyLibrarian's Prowlarr Torznab entry still holds the old key"
            )

    if "homepage" in running_containers:
        assert wait_for_homepage_ready(), "homepage API did not respond after rotation"
        failures = homepage_widget_failures(only_services={"prowlarr"})
        assert not failures, (
            "Homepage widget broken after rotating prowlarr:\n" + "\n".join(failures)
        )

    # ------------------------------------------------------------------
    # Restore the original key everywhere so the suite stays idempotent
    # ------------------------------------------------------------------
    _restore_arr_key("prowlarr", xml_path, old_key)
    status = _health_status("prowlarr", "https", port, "prowlarr", "v1", old_key)
    assert status == 200, f"prowlarr: could not restore old key (HTTP {status})"
    _restore_api_key_secret("prowlarr", old_key)

    for app, _xml, scheme, port_var, _url_base, api_ver in ARR_APP_TARGETS:
        if not is_enabled(app) or app not in running_containers:
            continue
        app_key = _read_xml_key(f"configs/{app}/config/config.xml")
        _restore_arr_indexer_apikeys(
            app, scheme, int(ENV.get(port_var, "0")), api_ver, app_key, old_key
        )

    if "lazylibrarian" in running_containers:
        status, _ = container_http(
            "prowlarr",
            f"https://127.0.0.1:{port}/prowlarr/api/v1/command",
            method="POST",
            headers={"X-Api-Key": old_key, "Content-Type": "application/json"},
            data=json.dumps({"name": "ApplicationIndexerSync"}),
            timeout=TIMEOUT,
        )
        assert status in (200, 201, 202), (
            f"Could not trigger ApplicationIndexerSync to restore "
            f"LazyLibrarian's key: {status}"
        )

    if "homepage" in running_containers:
        restart_container("homepage")
        assert wait_for_homepage_ready(), "homepage API did not respond after restore"
        failures = homepage_widget_failures(only_services={"prowlarr"})
        assert not failures, (
            "Homepage widget broken after restoring prowlarr:\n" + "\n".join(failures)
        )


def test_rotate_bazarr_api_key(running_containers):
    """Rotating Bazarr's own key updates config.yaml, the secret file, and Homepage.

    Nothing consumes Bazarr's own key (Bazarr consumes Sonarr/Radarr's keys,
    not the other way around), so restoring only needs config.yaml and the
    secret file.
    """
    if not is_enabled("bazarr"):
        pytest.skip("bazarr profile is disabled")
    skip_if_not_running("bazarr", running_containers)

    with open(BAZARR_CONFIG) as fh:
        old_key = yaml.safe_load(fh)["auth"]["apikey"]
    port = int(ENV.get("BAZARR_HTTP_PORT", "6767"))

    result = _run_script("rotate-api-keys.sh", "bazarr")
    assert result.returncode == 0, (
        f"rotate-api-keys.sh bazarr exited {result.returncode}:\n{result.stderr}"
    )

    with open(BAZARR_CONFIG) as fh:
        new_key = yaml.safe_load(fh)["auth"]["apikey"]
    assert new_key != old_key, "bazarr: key was not changed"
    assert wait_for_healthy("bazarr"), "bazarr did not become healthy after rotation"

    status, _ = container_http(
        "bazarr",
        f"http://127.0.0.1:{port}/bazarr/api/system/health",
        headers={"X-API-KEY": new_key},
        timeout=TIMEOUT,
    )
    assert status == 200, f"bazarr: new key not accepted (HTTP {status})"
    status, _ = container_http(
        "bazarr",
        f"http://127.0.0.1:{port}/bazarr/api/system/health",
        headers={"X-API-KEY": old_key},
        timeout=TIMEOUT,
    )
    assert status == 401, f"bazarr: old key still accepted (HTTP {status})"

    secret_path = REPO_ROOT / "configs/bazarr/secrets/api_key.txt"
    assert secret_path.read_text() == new_key, (
        "configs/bazarr/secrets/api_key.txt was not updated with the new key"
    )

    if "homepage" in running_containers:
        assert wait_for_homepage_ready(), "homepage API did not respond after rotation"
        failures = homepage_widget_failures(only_services={"bazarr"})
        assert not failures, (
            "Homepage widget broken after rotating bazarr:\n" + "\n".join(failures)
        )

    with open(BAZARR_CONFIG) as fh:
        cfg = yaml.safe_load(fh)
    cfg["auth"]["apikey"] = old_key
    subprocess.run(  # nosec B607 - podman is a trusted, fixed CLI in this stack
        ["podman", "stop", "bazarr"], check=True, capture_output=True
    )
    with open(BAZARR_CONFIG, "w") as fh:
        yaml.dump(cfg, fh, default_flow_style=False)
    subprocess.run(  # nosec B607 - podman is a trusted, fixed CLI in this stack
        ["podman", "start", "bazarr"], check=True, capture_output=True
    )
    assert wait_for_healthy("bazarr"), "bazarr did not become healthy after restore"
    _restore_api_key_secret("bazarr", old_key)

    if "homepage" in running_containers:
        restart_container("homepage")
        assert wait_for_homepage_ready(), "homepage API did not respond after restore"
        failures = homepage_widget_failures(only_services={"bazarr"})
        assert not failures, (
            "Homepage widget broken after restoring bazarr:\n" + "\n".join(failures)
        )


# ---------------------------------------------------------------------------
# INI-configured apps (LazyLibrarian, Mylar), NZBHydra2, and Jellyfin.
# These rotations are forward-only: every consumer is updated by the script,
# so there is no state to restore.
# ---------------------------------------------------------------------------


def _read_ini_api_key(rel_path: str) -> str:
    for line in (REPO_ROOT / rel_path).read_text().splitlines():
        if line.startswith("api_key = "):
            return line.split("= ", 1)[1]
    return ""


LAZYLIBRARIAN_INI = "configs/lazylibrarian/config/config.ini"
MYLAR_INI = "configs/mylar/config/mylar/config.ini"


def test_rotate_lazylibrarian_api_key(running_containers):
    """Rotating LazyLibrarian's API key updates config.ini and Prowlarr."""
    skip_if_not_running("lazylibrarian", running_containers)
    skip_if_not_running("prowlarr", running_containers)

    old_key = _read_ini_api_key(LAZYLIBRARIAN_INI)
    result = _run_script("rotate-api-keys.sh", "lazylibrarian")
    assert result.returncode == 0, (
        f"rotate-api-keys.sh lazylibrarian exited {result.returncode}:\n{result.stderr}"
    )

    new_key = _read_ini_api_key(LAZYLIBRARIAN_INI)
    assert new_key and new_key != old_key, "LazyLibrarian api_key was not changed"
    assert _prowlarr_stored_key("LazyLibrarian") == new_key, (
        "Prowlarr's LazyLibrarian entry was not updated"
    )
    assert wait_for_healthy("lazylibrarian"), "lazylibrarian unhealthy after rotation"


def test_rotate_mylar_api_key(running_containers):
    """Rotating Mylar's API key updates config.ini, Prowlarr, and Homepage."""
    skip_if_not_running("mylar", running_containers)
    skip_if_not_running("prowlarr", running_containers)

    old_key = _read_ini_api_key(MYLAR_INI)
    result = _run_script("rotate-api-keys.sh", "mylar")
    assert result.returncode == 0, (
        f"rotate-api-keys.sh mylar exited {result.returncode}:\n{result.stderr}"
    )

    new_key = _read_ini_api_key(MYLAR_INI)
    assert new_key and new_key != old_key, "Mylar api_key was not changed"
    assert _prowlarr_stored_key("Mylar") == new_key, (
        "Prowlarr's Mylar entry was not updated"
    )
    assert wait_for_healthy("mylar"), "mylar unhealthy after rotation"

    secret_path = REPO_ROOT / "configs/mylar/secrets/api_key.txt"
    assert secret_path.read_text() == new_key, (
        "configs/mylar/secrets/api_key.txt was not updated with the new key"
    )

    if "homepage" in running_containers:
        assert wait_for_homepage_ready(), "homepage API did not respond"
        failures = homepage_widget_failures(only_services={"mylar"})
        assert not failures, (
            "Homepage Mylar widget broken after rotation:\n" + "\n".join(failures)
        )


def test_rotate_nzbhydra2_api_key(running_containers):
    """Rotating NZBHydra2's key updates the yml and every consumer."""
    skip_if_not_running("nzbhydra2", running_containers)

    def ll_hydra_key() -> str:
        # Section-aware, matching rotate-api-keys.sh's own lookup exactly:
        # a naive "first api = line in the whole file" scan (the previous
        # version of this helper) actually reads Torznab_0's key instead,
        # Prowlarr's own entry, unrelated to NZBHydra2, confirmed live by
        # that value staying constant across a rotation that never touches
        # it. Two passes: first find which section's host mentions
        # nzbhydra, then read that section's own api = line.
        lines = (REPO_ROOT / LAZYLIBRARIAN_INI).read_text().splitlines()
        section_hosts: dict[str, str] = {}
        current = None
        for line in lines:
            if line.startswith("["):
                current = line
            elif line.startswith("host = ") and current:
                section_hosts[current] = line
        current = None
        for line in lines:
            if line.startswith("["):
                current = line
            elif (
                line.startswith("api = ")
                and "nzbhydra" in section_hosts.get(current, "").lower()
            ):
                return line.split("= ", 1)[1]
        return ""

    old_key = ll_hydra_key()
    if not old_key:
        pytest.skip(
            "LazyLibrarian has no NZBHydra2 Newznab provider configured. "
            "Nothing in this stack wires that connection yet (unlike "
            "Prowlarr's Applications/DownloadClients, which "
            "scripts/wire-connections.sh does handle): a real, separate "
            "feature gap, not something this rotation can propagate to."
        )
    result = _run_script("rotate-api-keys.sh", "nzbhydra2")
    assert result.returncode == 0, (
        f"rotate-api-keys.sh nzbhydra2 exited {result.returncode}:\n{result.stderr}"
    )

    new_key = ll_hydra_key()
    assert new_key and new_key != old_key, "NZBHydra2 key was not changed"

    # All arr Indexers entries point at the new key
    from test_rotate_passwords import ARR_DB_PATHS

    for svc, db_rel in ARR_DB_PATHS.items():
        db_path = REPO_ROOT / db_rel
        if not db_path.exists():
            continue
        with live_db(db_path) as conn:
            rows = conn.execute("SELECT Name, Settings FROM Indexers").fetchall()
        for name, settings in rows:
            data = json.loads(settings)
            if "nzbhydra" in str(data.get("baseUrl", "")).lower():
                assert data.get("apiKey") == new_key, (
                    f"{svc} indexer '{name}' still holds the old NZBHydra2 key"
                )

    # Mylar's extra_newznabs/extra_torznabs entries carry the new key
    assert new_key in (REPO_ROOT / MYLAR_INI).read_text(), (
        "Mylar config does not carry the new NZBHydra2 key"
    )

    # NZBHydra2 accepts the new key and rejects a wrong one (both are HTTP
    # 200; the body distinguishes results from the error envelope)
    assert wait_for_healthy("nzbhydra2"), "nzbhydra2 unhealthy after rotation"
    port = int(ENV.get("NZBHYDRA2_HTTPS_PORT", "5077"))
    _, body = container_http(
        "nzbhydra2",
        f"https://127.0.0.1:{port}/nzbhydra2/api?t=caps&apikey={new_key}",
        timeout=TIMEOUT,
    )
    assert "<error" not in body, f"NZBHydra2 rejected the new key: {body[:120]}"
    _, body = container_http(
        "nzbhydra2",
        f"https://127.0.0.1:{port}/nzbhydra2/api?t=caps&apikey={old_key}",
        timeout=TIMEOUT,
    )
    assert "<error" in body, "NZBHydra2 still accepts the old key"


def test_rotate_jellyfin_api_key(running_containers):
    """Rotating Jellyfin's key creates a new one, adopts it, revokes the old."""
    skip_if_not_running("jellyfin", running_containers)

    key_path = REPO_ROOT / "configs/jellyfin/secrets/api_key.txt"
    if not key_path.exists():
        pytest.skip("configs/jellyfin/secrets/api_key.txt not present")

    old_key = read_secret("jellyfin", "api_key.txt")
    result = _run_script("rotate-api-keys.sh", "jellyfin")
    assert result.returncode == 0, (
        f"rotate-api-keys.sh jellyfin exited {result.returncode}:\n{result.stderr}"
    )

    new_key = read_secret("jellyfin", "api_key.txt")
    assert new_key and new_key != old_key, "Jellyfin key was not changed"
    assert oct(key_path.stat().st_mode)[-3:] == "644", (
        "configs/jellyfin/secrets/api_key.txt has the wrong mode for rootless podman"
    )

    port = int(ENV.get("JELLYFIN_HTTP_PORT", "8096"))
    status, _ = container_http(
        "jellyfin",
        f"http://127.0.0.1:{port}/jellyfin/Auth/Keys",
        headers={"Authorization": f'MediaBrowser Token="{new_key}"'},
        timeout=TIMEOUT,
    )
    assert status == 200, f"Jellyfin does not accept the new key (HTTP {status})"

    status, _ = container_http(
        "jellyfin",
        f"http://127.0.0.1:{port}/jellyfin/Auth/Keys",
        headers={"Authorization": f'MediaBrowser Token="{old_key}"'},
        timeout=TIMEOUT,
    )
    assert status == 401, f"Jellyfin still accepts the revoked key (HTTP {status})"

    # Every arr app's Jellyfin connection holds the new key, read from its
    # database since the API masks it. Left on the revoked one, Sonarr's own
    # connection test failed after every bootstrap (#324).
    from test_rotate_passwords import ARR_DB_PATHS

    for svc, db_rel in ARR_DB_PATHS.items():
        db_path = REPO_ROOT / db_rel
        if svc not in running_containers or not db_path.exists():
            continue
        with live_db(db_path) as conn:
            rows = conn.execute(
                "SELECT Settings FROM Notifications WHERE Implementation = 'MediaBrowser'"
            ).fetchall()
        for (settings,) in rows:
            assert json.loads(settings).get("apiKey") == new_key, (
                f"{svc}'s Jellyfin connection still holds the old key"
            )

    if "homepage" in running_containers:
        assert wait_for_homepage_ready(), "homepage API did not respond"
        failures = homepage_widget_failures(only_services={"jellyfin"})
        assert not failures, (
            "Homepage Jellyfin widget broken after rotation:\n" + "\n".join(failures)
        )
