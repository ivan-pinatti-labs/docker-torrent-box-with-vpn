"""Service API health checks using API keys read from service config files."""

import pytest
import requests
import urllib3

import conftest
from conftest import (
    QBITTORRENT_QUEUEING,
    SERVICES,
    classify_arr_health_response,
    is_download_client_unreachable,
    is_enabled,
    qbittorrent_preferences,
    read_api_key,
    service_base_url,
    skip_if_not_running,
)

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

pytestmark = pytest.mark.services

TIMEOUT = 10

# Services with a dedicated API health endpoint
HEALTH_SERVICES = [name for name, cfg in SERVICES.items() if cfg.get("api_health_path")]


@pytest.mark.parametrize("service_name", HEALTH_SERVICES)
def test_service_api_health(service_name, running_containers):
    """GET the service's health endpoint and assert a 200 response."""
    if not is_enabled(service_name):
        pytest.skip(f"{service_name} profile is disabled")
    skip_if_not_running(service_name, running_containers)

    cfg = SERVICES[service_name]
    path = cfg["api_health_path"]
    api_key = read_api_key(service_name)

    url = service_base_url(service_name) + path
    headers = {}
    params = {}
    if api_key:
        headers["X-Api-Key"] = api_key
        params["apikey"] = api_key

    resp = requests.get(
        url, headers=headers, params=params, verify=False, timeout=TIMEOUT
    )
    assert resp.status_code == 200, (
        f"{service_name} health endpoint {url} returned {resp.status_code}: {resp.text[:200]}"
    )


@pytest.mark.parametrize(
    "message",
    [
        "Unable to communicate with QBittorrent. Connection refused",
        "Unable to communicate with SABnzbd. Connection refused",
    ],
)
def test_is_download_client_unreachable_fails_on_download_client_messages(message):
    """A download client message is the one thing this tier must fail on.

    No live stack needed: this exercises the classification function directly
    with the fabricated message shape a real health endpoint returns, per #124.
    """
    assert is_download_client_unreachable(message)


def test_is_download_client_unreachable_warns_on_environmental_messages():
    """Environmental messages must not trip the fail list, per #124.

    A stack with no real indexers configured is expected, not broken, and
    this tier needs to keep passing against it.
    """
    messages = [
        "All indexers are unavailable due to failures",
        "Indexers unavailable due to failures for more than 24 hours",
    ]
    assert not any(is_download_client_unreachable(m) for m in messages)


def test_classify_arr_health_response_fails_on_download_client_message():
    """The actual health handling branch must fail on a download client message.

    Exercised through classify_arr_health_response, the same function
    test_arr_health_response_empty calls, against a fabricated health
    endpoint response rather than a live stack.
    """
    fabricated_response = [
        {
            "source": "QbittorrentSettingsValidator",
            "type": "error",
            "message": "Unable to communicate with QBittorrent. Connection refused",
            "wikiUrl": "https://wiki.servarr.com/sonarr/system#download-client-unavailable",
        },
        {
            "source": "IndexerRssCheck",
            "type": "warning",
            "message": "All indexers are unavailable due to failures",
            "wikiUrl": "https://wiki.servarr.com/sonarr/system#indexers-are-unavailable",
        },
    ]
    failures, warn_only = classify_arr_health_response(fabricated_response)
    assert failures == ["Unable to communicate with QBittorrent. Connection refused"]
    assert warn_only == ["All indexers are unavailable due to failures"]


def test_classify_arr_health_response_warns_only_on_environmental_messages():
    """A stack with no real indexers configured must only warn, not fail."""
    fabricated_response = [
        {
            "source": "IndexerRssCheck",
            "type": "warning",
            "message": "All indexers are unavailable due to failures",
            "wikiUrl": "https://wiki.servarr.com/sonarr/system#indexers-are-unavailable",
        },
        {
            "source": "IndexerLongTermStatusCheck",
            "type": "warning",
            "message": "Indexers unavailable due to failures for more than 24 hours",
            "wikiUrl": "https://wiki.servarr.com/sonarr/system#indexers-are-unavailable-due-to-failures",
        },
    ]
    failures, warn_only = classify_arr_health_response(fabricated_response)
    assert failures == []
    assert warn_only == [
        "All indexers are unavailable due to failures",
        "Indexers unavailable due to failures for more than 24 hours",
    ]


def test_classify_arr_health_response_treats_malformed_items_as_warnings():
    """A malformed item is not a fail signal, it is just unrecognized.

    None in the list, and a dict with no message key, must not be stringified
    and matched against the fail list (that could false positive on an
    unrelated message) or raise trying to call .lower() on it.
    """
    fabricated_response = [None, {"source": "SomeCheck", "type": "warning"}]
    failures, warn_only = classify_arr_health_response(fabricated_response)
    assert failures == []
    assert warn_only == ["None", "{'source': 'SomeCheck', 'type': 'warning'}"]


@pytest.mark.parametrize(
    "service_name",
    [
        name
        for name in ("sonarr", "radarr", "prowlarr", "readarr", "lidarr")
        if name in SERVICES
    ],
)
def test_arr_health_response_empty(service_name, running_containers):
    """Servarr health endpoints return an empty list when everything is OK."""
    if not is_enabled(service_name):
        pytest.skip(f"{service_name} profile is disabled")
    skip_if_not_running(service_name, running_containers)

    cfg = SERVICES[service_name]
    path = cfg["api_health_path"]
    api_key = read_api_key(service_name)
    if not api_key:
        pytest.skip(f"No API key found for {service_name}")

    url = service_base_url(service_name) + path
    resp = requests.get(
        url, headers={"X-Api-Key": api_key}, verify=False, timeout=TIMEOUT
    )
    assert resp.status_code == 200
    data = resp.json()
    assert isinstance(data, list), f"Expected list from {url}, got {type(data)}"
    # Split health issues into a short, explicit fail list (a download client
    # is unreachable, which is a core function of this stack) and everything
    # else, which stays a warning: most of what these endpoints report is
    # environmental (no indexers, no usenet provider, no real trackers
    # configured in a test environment) and turning all of it into a failure
    # would make this tier useless. See classify_arr_health_response and
    # is_download_client_unreachable in conftest.py for the fail list itself,
    # and #124 for why this split exists.
    if data:
        import warnings

        failures, warn_only = classify_arr_health_response(data)
        if warn_only:
            warnings.warn(
                f"{service_name} reports health issues: {warn_only}",
                UserWarning,
                stacklevel=2,
            )
        assert not failures, (
            f"{service_name} cannot reach a download client: {failures}"
        )


def _fake_qbittorrent(monkeypatch, responses):
    """Answer qbittorrent_preferences' two calls from `responses`, no container.

    Returns the curl calls it made and the cleanup commands it ran.
    """
    calls, cleanup = [], []

    def fake_http(container, url, **kwargs):
        calls.append((container, url, kwargs["extra_args"]))
        return responses.pop(0)

    monkeypatch.setattr(conftest, "container_http", fake_http)
    monkeypatch.setattr(conftest, "container_name", lambda service: service)
    monkeypatch.setattr(conftest, "read_secret", lambda owner, name: "secret")
    monkeypatch.setattr(
        conftest,
        "ENV",
        {"GLUETUN_SERVICES_IP": "172.30.0.2", "QBITTORRENT_HTTPS_PORT": "8085"},
    )
    monkeypatch.setattr(
        conftest.subprocess, "run", lambda cmd, **kwargs: cleanup.append(cmd)
    )
    return calls, cleanup


def _jar(extra_args):
    """The cookie jar path, the argument after -c on login and -b on the read."""
    return extra_args[1]


def test_qbittorrent_preferences_reads_with_one_jar(monkeypatch):
    calls, cleanup = _fake_qbittorrent(
        monkeypatch, [(204, ""), (200, '{"queueing_enabled": true}')]
    )

    assert conftest.qbittorrent_preferences() == {"queueing_enabled": True}
    assert [url for _, url, _ in calls] == [
        "https://172.30.0.2:8085/api/v2/auth/login",
        "https://172.30.0.2:8085/api/v2/app/preferences",
    ]
    jar = _jar(calls[0][2])
    assert _jar(calls[1][2]) == jar
    assert cleanup == [["podman", "exec", "qbittorrent", "rm", "-f", jar]]


def test_qbittorrent_preferences_login_failure(monkeypatch):
    calls, cleanup = _fake_qbittorrent(monkeypatch, [(401, "")])

    with pytest.raises(AssertionError, match="qBittorrent login failed: 401"):
        conftest.qbittorrent_preferences()
    assert len(calls) == 1
    assert cleanup == [["podman", "exec", "qbittorrent", "rm", "-f", _jar(calls[0][2])]]


def test_qbittorrent_preferences_fetch_failure(monkeypatch):
    calls, cleanup = _fake_qbittorrent(monkeypatch, [(204, ""), (503, "down")])

    with pytest.raises(AssertionError, match="GET app/preferences failed: 503"):
        conftest.qbittorrent_preferences()
    assert len(calls) == 2
    assert cleanup == [["podman", "exec", "qbittorrent", "rm", "-f", _jar(calls[0][2])]]


def test_qbittorrent_preferences_jar_is_per_call(monkeypatch):
    calls, _ = _fake_qbittorrent(monkeypatch, [(204, ""), (200, "{}")] * 2)

    conftest.qbittorrent_preferences()
    conftest.qbittorrent_preferences()
    assert _jar(calls[0][2]) != _jar(calls[2][2])


def test_qbittorrent_queueing(running_containers):
    """qBittorrent runs with the torrent queue settings its seed holds.

    Read live, since qBittorrent writes its running state over
    qBittorrent.conf on shutdown: a value changed in the WebUI, or reset by
    an upgrade, would otherwise replace the seeded one with nothing to say so.
    test_qbittorrent_seed_queueing checks the seed itself. See
    QBITTORRENT_QUEUEING in conftest.py for why each value is what it is.
    """
    if not is_enabled("qbittorrent"):
        pytest.skip("qbittorrent profile is disabled")
    skip_if_not_running("qbittorrent", running_containers)

    preferences = qbittorrent_preferences()
    expected = {name: value for _, name, value in QBITTORRENT_QUEUEING}
    actual = {name: preferences.get(name) for name in expected}
    assert actual == expected, "qBittorrent's queue settings differ from its seed"
