"""Integration tests for scripts/wire-connections.sh.

These run the wiring script against the live stack, then verify via each
app's own live API that the expected DownloadClients/Applications entries
exist with the right host/port/category. Marked `wiring` and excluded from
the default `make test` run because they create real, persistent state.

Unlike the rotation tests, there is no restore-after-test: a wired connection
is meant to stay, not act as a temporary probe value.

The Jellyfin cases at the bottom are additionally marked `wiring_readonly`:
they only read the wiring back, so they skip the script run and CI does run
them. See pytest.ini and the Makefile's comment on test_ci.

App ports are not published to the host, so all API calls run curl inside the
target container (see conftest.container_http), matching how the wiring
script itself talks to the apps.

Run explicitly with:
    pytest -m wiring tests/test_wire_connections.py
"""

import json
import subprocess
import time
from datetime import UTC

import pytest

from conftest import (
    ENV,
    REPO_ROOT,
    container_http,
    container_name,
    is_enabled,
    skip_if_not_running,
)

pytestmark = pytest.mark.wiring

TIMEOUT = 30
SCRIPT = REPO_ROOT / "scripts" / "wire-connections.sh"

# app: (scheme, port_var, api_version, sabnzbd_category)
ARR_APPS = {
    "lidarr": ("https", "LIDARR_HTTPS_PORT", "v1", "music"),
    "radarr": ("https", "RADARR_HTTPS_PORT", "v3", "movies"),
    "readarr": ("https", "READARR_HTTPS_PORT", "v1", "ebooks"),
    "sonarr": ("http", "SONARR_HTTP_PORT", "v3", "tv"),
    "whisparr": ("https", "WHISPARR_HTTPS_PORT", "v3", "mature"),
}

PROWLARR_APPLICATIONS = [
    "LazyLibrarian",
    "Lidarr",
    "Mylar",
    "Radarr",
    "Readarr",
    "Sonarr",
    "Whisparr",
]


def _env(key: str) -> str:
    val = ENV.get(key)
    assert val, f"{key} not set in .env"
    return val


def _api_key(app: str) -> str:
    import xml.etree.ElementTree as ET

    path = REPO_ROOT / f"configs/{app}/config/config.xml"
    tree = ET.parse(path)
    elem = tree.find("ApiKey")
    assert elem is not None and elem.text
    return elem.text


def _download_clients(app: str, running_containers: dict) -> list[dict]:
    skip_if_not_running(app, running_containers)
    scheme, port_var, api_ver, _ = ARR_APPS[app]
    port = _env(port_var)
    status, body = container_http(
        container_name(app),
        f"{scheme}://127.0.0.1:{port}/{app}/api/{api_ver}/downloadclient",
        headers={"X-Api-Key": _api_key(app)},
        timeout=TIMEOUT,
    )
    assert status == 200, f"[{app}] GET downloadclient failed: {status} {body[:200]}"
    import json

    return json.loads(body)


def _field(client: dict, name: str) -> object:
    for f in client["fields"]:
        if f["name"] == name:
            return f["value"]
    raise KeyError(name)


@pytest.fixture(scope="module", autouse=True)
def run_wire_connections(request):
    """Run the wiring script once for the whole module (it's idempotent).

    Skipped when every selected test in this module is wiring_readonly. Those
    only read back wiring that already exists, so running the script buys them
    nothing and would cost minutes of real writes against live apps. That is
    what lets CI run the read-only subset in its fast tier, off the back of its
    own `make wire_connections` step, without pulling in the serial tier this
    module otherwise belongs to (see the Makefile's own comment on test_ci).
    """
    selected = [item for item in request.session.items if item.path == request.path]
    if selected and all(
        item.get_closest_marker("wiring_readonly") for item in selected
    ):
        return None

    result = subprocess.run(  # nosec B603 - fixed path, no user input
        [str(SCRIPT)],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=900,
    )
    assert result.returncode == 0, (
        f"wire-connections.sh failed:\nSTDOUT:\n{result.stdout}\n"
        f"STDERR:\n{result.stderr}"
    )
    return result


@pytest.mark.parametrize("app", sorted(ARR_APPS))
def test_qbittorrent_client_wired(app, running_containers):
    if not is_enabled(app):
        pytest.skip(f"service '{app}' profile is disabled")
    clients = _download_clients(app, running_containers)
    matches = [c for c in clients if c["implementation"] == "QBittorrent"]
    assert len(matches) == 1, (
        f"[{app}] expected exactly one QBittorrent client, found {len(matches)}"
    )
    client = matches[0]
    assert client["enable"] is True
    assert _field(client, "host") == _env("GLUETUN_SERVICES_IP")
    assert _field(client, "port") == int(_env("QBITTORRENT_HTTPS_PORT"))
    # qBittorrent's own categories.json uses each app's bare name.
    category_field = next(
        f["name"]
        for f in client["fields"]
        if f["name"].endswith("Category") and "Imported" not in f["name"]
    )
    assert _field(client, category_field) == app


@pytest.mark.parametrize("app", sorted(ARR_APPS))
def test_sabnzbd_client_wired(app, running_containers):
    if not is_enabled(app):
        pytest.skip(f"service '{app}' profile is disabled")
    _, _, _, expected_category = ARR_APPS[app]
    clients = _download_clients(app, running_containers)
    matches = [c for c in clients if c["implementation"] == "Sabnzbd"]
    assert len(matches) == 1, (
        f"[{app}] expected exactly one Sabnzbd client, found {len(matches)}"
    )
    client = matches[0]
    assert client["enable"] is True
    assert _field(client, "host") == _env("GLUETUN_SERVICES_IP")
    assert _field(client, "port") == int(_env("SABNZBD_HTTP_PORT"))
    category_field = next(
        f["name"]
        for f in client["fields"]
        if f["name"].endswith("Category") and "Imported" not in f["name"]
    )
    assert _field(client, category_field) == expected_category


def _prowlarr_download_clients(running_containers) -> list[dict]:
    skip_if_not_running("prowlarr", running_containers)
    port = _env("PROWLARR_HTTPS_PORT")
    status, body = container_http(
        container_name("prowlarr"),
        f"https://127.0.0.1:{port}/prowlarr/api/v1/downloadclient",
        headers={"X-Api-Key": _api_key("prowlarr")},
        timeout=TIMEOUT,
    )
    assert status == 200, f"[prowlarr] GET downloadclient failed: {status} {body[:200]}"
    import json

    return json.loads(body)


def test_prowlarr_qbittorrent_client_wired(running_containers):
    """Prowlarr's own Interactive Search grab button needs a download client.

    Independent of the arr apps' own qBittorrent clients (test_wire_
    connections.py wires those separately): this is what Prowlarr itself
    uses.
    """
    if not is_enabled("prowlarr"):
        pytest.skip("service 'prowlarr' profile is disabled")
    clients = _prowlarr_download_clients(running_containers)
    matches = [c for c in clients if c["implementation"] == "QBittorrent"]
    assert len(matches) == 1, (
        f"[prowlarr] expected exactly one QBittorrent client, found {len(matches)}"
    )
    client = matches[0]
    assert client["enable"] is True
    assert _field(client, "host") == _env("GLUETUN_SERVICES_IP")
    assert _field(client, "port") == int(_env("QBITTORRENT_HTTPS_PORT"))


def test_prowlarr_sabnzbd_client_wired(running_containers):
    if not is_enabled("prowlarr"):
        pytest.skip("service 'prowlarr' profile is disabled")
    clients = _prowlarr_download_clients(running_containers)
    matches = [c for c in clients if c["implementation"] == "Sabnzbd"]
    assert len(matches) == 1, (
        f"[prowlarr] expected exactly one Sabnzbd client, found {len(matches)}"
    )
    client = matches[0]
    assert client["enable"] is True
    assert _field(client, "host") == _env("GLUETUN_SERVICES_IP")
    assert _field(client, "port") == int(_env("SABNZBD_HTTP_PORT"))


def test_prowlarr_flaresolverr_indexer_proxy_wired(running_containers):
    """FlareSolverr is available to select as an Indexer Proxy.

    This only asserts the proxy exists to choose from; Prowlarr never
    assigns it to an indexer automatically (see docs/CONNECTIONS.md), so
    there's nothing further to assert here.
    """
    if not is_enabled("prowlarr"):
        pytest.skip("service 'prowlarr' profile is disabled")
    if not is_enabled("flaresolverr"):
        pytest.skip("service 'flaresolverr' profile is disabled")
    skip_if_not_running("prowlarr", running_containers)
    port = _env("PROWLARR_HTTPS_PORT")
    status, body = container_http(
        container_name("prowlarr"),
        f"https://127.0.0.1:{port}/prowlarr/api/v1/indexerproxy",
        headers={"X-Api-Key": _api_key("prowlarr")},
        timeout=TIMEOUT,
    )
    assert status == 200, f"GET indexerproxy failed: {status} {body[:200]}"
    import json

    proxies = json.loads(body)
    matches = [p for p in proxies if p["implementation"] == "FlareSolverr"]
    assert len(matches) == 1, (
        f"expected exactly one FlareSolverr indexer proxy, found {len(matches)}"
    )
    assert (
        _field(matches[0], "host")
        == f"http://flaresolverr:{_env('FLARESOLVERR_HTTP_PORT')}"
    )

    status, body = container_http(
        container_name("prowlarr"),
        f"https://127.0.0.1:{port}/prowlarr/api/v1/tag",
        headers={"X-Api-Key": _api_key("prowlarr")},
        timeout=TIMEOUT,
    )
    assert status == 200, f"GET tag failed: {status} {body[:200]}"
    tags = json.loads(body)
    flaresolverr_tag = next((t for t in tags if t["label"] == "flaresolverr"), None)
    assert flaresolverr_tag is not None, "no 'flaresolverr' tag exists in Prowlarr"
    assert flaresolverr_tag["id"] in matches[0]["tags"], (
        "FlareSolverr indexer proxy is not tagged 'flaresolverr'"
    )


@pytest.mark.parametrize("app", sorted(ARR_APPS))
def test_arr_host_prereqs_wired(app, running_containers):
    """CertificateValidation relaxed and an initial WebUI login exists."""
    if not is_enabled(app):
        pytest.skip(f"service '{app}' profile is disabled")
    skip_if_not_running(app, running_containers)
    scheme, port_var, api_ver, _ = ARR_APPS[app]
    port = _env(port_var)
    status, body = container_http(
        container_name(app),
        f"{scheme}://127.0.0.1:{port}/{app}/api/{api_ver}/config/host",
        headers={"X-Api-Key": _api_key(app)},
        timeout=TIMEOUT,
    )
    assert status == 200, f"[{app}] GET config/host failed: {status} {body[:200]}"
    import json

    host_config = json.loads(body)
    assert host_config["username"] == app
    assert host_config["certificateValidation"] == "disabledForLocalAddresses"


def test_prowlarr_applications_wired(running_containers):
    if not is_enabled("prowlarr"):
        pytest.skip("service 'prowlarr' profile is disabled")
    skip_if_not_running("prowlarr", running_containers)
    port = _env("PROWLARR_HTTPS_PORT")
    status, body = container_http(
        container_name("prowlarr"),
        f"https://127.0.0.1:{port}/prowlarr/api/v1/applications",
        headers={"X-Api-Key": _api_key("prowlarr")},
        timeout=TIMEOUT,
    )
    assert status == 200, f"GET applications failed: {status} {body[:200]}"
    import json

    applications = json.loads(body)
    names = {a["name"] for a in applications}
    # LazyLibrarian/Mylar aren't Servarr apps and have no profile_var in
    # conftest's SERVICES, so their enabled check goes straight to .env.
    expected = {
        name
        for name in PROWLARR_APPLICATIONS
        if ENV.get(f"{name.upper()}_PROFILE", "disabled").lower() == "enabled"
    }
    missing = expected - names
    assert not missing, f"Prowlarr missing applications: {missing}"


def test_prowlarr_indexer_wired(running_containers):
    """Prowlarr ends up with at least one indexer.

    A real bootstrap left Prowlarr with zero indexers because
    wire_prowlarr_apps died on the first application registration under
    `set -e`, taking the indexer (registered after them) down with it.
    """
    if not is_enabled("prowlarr"):
        pytest.skip("service 'prowlarr' profile is disabled")
    skip_if_not_running("prowlarr", running_containers)
    port = _env("PROWLARR_HTTPS_PORT")
    status, body = container_http(
        container_name("prowlarr"),
        f"https://127.0.0.1:{port}/prowlarr/api/v1/indexer",
        headers={"X-Api-Key": _api_key("prowlarr")},
        timeout=TIMEOUT,
    )
    assert status == 200, f"GET indexer failed: {status} {body[:200]}"
    import json

    indexers = json.loads(body)
    assert indexers, "Prowlarr has no indexers at all"


@pytest.mark.parametrize("app", sorted(ARR_APPS))
def test_prowlarr_indexers_propagated_to_arr_app(app, running_containers):
    """Prowlarr's indexer actually reached each arr app.

    Registering the Applications in Prowlarr is only half the chain; the
    indexer still has to be pushed into each app. That push silently failed
    in a real bootstrap: Prowlarr had put the indexer into a failure backoff
    (Internet Archive's advancedsearch API intermittently times out), so it
    answered each arr app's capability probe with 429, the app rejected the
    indexer with 400, and nothing retried. The user-visible symptom was "no
    indexers in the arr apps" while Prowlarr itself looked fine, which is
    exactly what this asserts against.
    """
    if not is_enabled(app) or not is_enabled("prowlarr"):
        pytest.skip("service profile is disabled")
    if app == "whisparr":
        pytest.skip(
            "Whisparr's Application entry only syncs indexers matching its "
            "syncCategories (6000-series, adult content only). The seeded "
            "default indexer, Internet Archive, doesn't serve that category "
            "(confirmed live via its own capabilities.categories), so zero "
            "synced indexers is structurally correct here, not a wiring "
            "failure. See wire-connections.sh's sync_prowlarr_indexers()."
        )
    skip_if_not_running(app, running_containers)
    scheme, port_var, api_ver, _ = ARR_APPS[app]
    port = _env(port_var)
    import json
    from datetime import datetime

    prowlarr_port = _env("PROWLARR_HTTPS_PORT")

    # A single point-in-time check raced Internet Archive's own backoff
    # cycling on and off, confirmed live: the same app had indexers on one
    # run and not on the next, and indexerstatus showed a backoff that had
    # only just cleared (or not yet been recorded) at the exact moment of
    # a failing check. wire-connections.sh's own sync_prowlarr_indexers()
    # already budgets ~345s (a backoff-clear wait plus 3 sync attempts)
    # for this same reason; this retries across a comparable window,
    # re-fetching both the indexer list and the backoff state fresh each
    # time rather than trusting either snapshot alone.
    indexers: list = []
    backoff_status = ""
    for attempt in range(4):
        status, body = container_http(
            container_name(app),
            f"{scheme}://127.0.0.1:{port}/{app}/api/{api_ver}/indexer",
            headers={"X-Api-Key": _api_key(app)},
            timeout=TIMEOUT,
        )
        assert status == 200, f"[{app}] GET indexer failed: {status} {body[:200]}"
        indexers = json.loads(body)
        if indexers:
            break

        status, body = container_http(
            container_name("prowlarr"),
            f"https://127.0.0.1:{prowlarr_port}/prowlarr/api/v1/indexerstatus",
            headers={"X-Api-Key": _api_key("prowlarr")},
            timeout=TIMEOUT,
        )
        backoff_status = ""
        if status == 200:
            for entry in json.loads(body):
                disabled_till = entry.get("disabledTill")
                most_recent_failure = entry.get("mostRecentFailure")
                if disabled_till:
                    until = datetime.fromisoformat(disabled_till.replace("Z", "+00:00"))
                    if until > datetime.now(UTC):
                        backoff_status = (
                            f"an active failure backoff until {disabled_till}"
                        )
                        break
                if most_recent_failure:
                    since = datetime.fromisoformat(
                        most_recent_failure.replace("Z", "+00:00")
                    )
                    if (datetime.now(UTC) - since).total_seconds() < 1800:
                        backoff_status = (
                            f"a failure as recently as {most_recent_failure}"
                        )
                        break
        if attempt < 3:
            time.sleep(90)

    if not indexers and backoff_status:
        pytest.skip(
            f"[{app}] has no indexers, but Prowlarr's own indexerstatus "
            f"shows {backoff_status}: Internet Archive's own API, not "
            "this stack's wiring. Re-run once that clears."
        )
    assert indexers, (
        f"[{app}] has no indexers: Prowlarr's Application sync never landed. "
        "Check Prowlarr's log for 429/backoff and the app's log for "
        "'Invalid Request' on POST .../indexer"
    )


def test_wiring_is_idempotent(running_containers):
    """Re-running the script must not create duplicate entries."""
    result = subprocess.run(  # nosec B603 - fixed path, no user input
        [str(SCRIPT)],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=900,
    )
    assert result.returncode == 0, (
        f"second wire-connections.sh run failed:\nSTDOUT:\n{result.stdout}\n"
        f"STDERR:\n{result.stderr}"
    )
    for app in ARR_APPS:
        if not is_enabled(app):
            continue
        clients = _download_clients(app, running_containers)
        for implementation in ("QBittorrent", "Sabnzbd"):
            matches = [c for c in clients if c["implementation"] == implementation]
            assert len(matches) == 1, (
                f"[{app}] expected exactly one {implementation} client after "
                f"re-running, found {len(matches)}"
            )


# ---------------------------------------------------------------------------
# Jellyfin connections
#
# Without these nothing tells Jellyfin to rescan after an import, so a
# finished download stays invisible until Jellyfin's own scheduled scan. The
# connection is an *arr "Connection" of type MediaBrowser, which is their name
# for Emby/Jellyfin.
#
# All of these are wiring_readonly: they read the connection back and exercise
# the app's own Test action, which reports reachability without writing
# anything. Nothing here restarts a container or creates persistent state, so
# unlike the rest of this module they are cheap and stable enough for CI.
# ---------------------------------------------------------------------------


def _notifications(app: str, running_containers: dict) -> list[dict]:
    skip_if_not_running(app, running_containers)
    scheme, port_var, api_ver, _ = ARR_APPS[app]
    status, body = container_http(
        container_name(app),
        f"{scheme}://127.0.0.1:{_env(port_var)}/{app}/api/{api_ver}/notification",
        headers={"X-Api-Key": _api_key(app)},
        timeout=TIMEOUT,
    )
    assert status == 200, f"[{app}] GET notification failed: {status} {body[:200]}"
    return json.loads(body)


def _supports_jellyfin(app: str, running_containers: dict) -> bool:
    """Whether the app offers a MediaBrowser implementation at all."""
    skip_if_not_running(app, running_containers)
    scheme, port_var, api_ver, _ = ARR_APPS[app]
    status, body = container_http(
        container_name(app),
        f"{scheme}://127.0.0.1:{_env(port_var)}/{app}/api/{api_ver}/notification/schema",
        headers={"X-Api-Key": _api_key(app)},
        timeout=TIMEOUT,
    )
    assert status == 200, f"[{app}] GET notification/schema failed: {status}"
    return any(s.get("implementation") == "MediaBrowser" for s in json.loads(body))


def _jellyfin_connection(app: str, running_containers: dict) -> dict | None:
    matches = [
        n
        for n in _notifications(app, running_containers)
        if n["implementation"] == "MediaBrowser"
    ]
    assert len(matches) <= 1, f"[{app}] expected at most one Jellyfin connection"
    return matches[0] if matches else None


@pytest.mark.wiring_readonly
@pytest.mark.parametrize("app", sorted(ARR_APPS))
def test_jellyfin_connection_matches_what_the_app_supports(app, running_containers):
    """Wired exactly when the app offers MediaBrowser, and not otherwise.

    Readarr does not offer it: Jellyfin does not take a book library from it,
    so its equivalents there are Kavita and Subsonic. Written as an
    equivalence rather than a hardcoded app list so it stays correct if
    upstream adds or drops support.
    """
    if not is_enabled(app):
        pytest.skip(f"service '{app}' profile is disabled")
    if not is_enabled("jellyfin"):
        pytest.skip("jellyfin profile is disabled")
    supported = _supports_jellyfin(app, running_containers)
    wired = _jellyfin_connection(app, running_containers) is not None
    assert wired == supported, (
        f"[{app}] supports MediaBrowser={supported} but wired={wired}"
    )


@pytest.mark.wiring_readonly
@pytest.mark.parametrize("app", sorted(ARR_APPS))
def test_jellyfin_connection_points_at_a_reachable_jellyfin(app, running_containers):
    """Jellyfin is on the media network and the *arr apps are not, so the
    connection has to reach the port Jellyfin publishes on the host. The
    address is probed at wiring time rather than assumed, so assert the
    result is usable rather than equal to any particular value."""
    if not is_enabled(app) or not is_enabled("jellyfin"):
        pytest.skip("app or jellyfin profile is disabled")
    connection = _jellyfin_connection(app, running_containers)
    if connection is None:
        pytest.skip(f"{app} does not support Jellyfin connections")

    host = _field(connection, "host")
    port = _field(connection, "port")
    assert host, f"[{app}] Jellyfin connection has no host"
    assert port == int(_env("JELLYFIN_HTTP_PORT"))
    assert _field(connection, "urlBase") == _env("JELLYFIN_BASE_URL")
    assert _field(connection, "updateLibrary") is True, (
        f"[{app}] updateLibrary is off, so Jellyfin would never be told to rescan"
    )

    status, _ = container_http(
        container_name(app),
        f"http://{host}:{port}{_env('JELLYFIN_BASE_URL')}/System/Info/Public",
        timeout=TIMEOUT,
    )
    assert status == 200, (
        f"[{app}] Jellyfin is not reachable at {host}:{port} from inside the container"
    )


@pytest.mark.wiring_readonly
@pytest.mark.parametrize("app", sorted(ARR_APPS))
def test_jellyfin_connection_has_library_update_triggers(app, running_containers):
    """A connection with no triggers is wired and useless.

    The apps do not agree on the names: Sonarr and Radarr have onDownload,
    Lidarr has onReleaseImport instead, and newer versions add
    onImportComplete. Require at least one of them plus the rename trigger.
    """
    if not is_enabled(app) or not is_enabled("jellyfin"):
        pytest.skip("app or jellyfin profile is disabled")
    connection = _jellyfin_connection(app, running_containers)
    if connection is None:
        pytest.skip(f"{app} does not support Jellyfin connections")

    import_triggers = ("onDownload", "onImportComplete", "onReleaseImport")
    enabled = [t for t in import_triggers if connection.get(t)]
    assert enabled, (
        f"[{app}] no import trigger enabled ({import_triggers}); Jellyfin would "
        "never be told about a finished download"
    )
    assert connection.get("onUpgrade"), f"[{app}] onUpgrade is off"
    assert connection.get("onRename"), f"[{app}] onRename is off"


@pytest.mark.wiring_readonly
@pytest.mark.parametrize("app", sorted(ARR_APPS))
def test_jellyfin_connection_passes_the_apps_own_test(app, running_containers):
    """The check the Test button in the UI performs.

    Asserting the row exists only proves something was written; this proves
    the app can actually talk to Jellyfin with the key and address it stored.
    """
    if not is_enabled(app) or not is_enabled("jellyfin"):
        pytest.skip("app or jellyfin profile is disabled")
    connection = _jellyfin_connection(app, running_containers)
    if connection is None:
        pytest.skip(f"{app} does not support Jellyfin connections")

    scheme, port_var, api_ver, _ = ARR_APPS[app]
    status, body = container_http(
        container_name(app),
        f"{scheme}://127.0.0.1:{_env(port_var)}/{app}/api/{api_ver}/notification/test",
        headers={"X-Api-Key": _api_key(app), "Content-Type": "application/json"},
        method="POST",
        data=json.dumps(connection),
        timeout=60,
    )
    assert status in (200, 202), (
        f"[{app}] Jellyfin connection failed its own Test: {status} {body[:300]}"
    )
