"""Service API health checks using API keys read from service config files."""

import pytest
import requests
import urllib3

from conftest import (
    SERVICES,
    classify_arr_health_response,
    is_download_client_unreachable,
    is_enabled,
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
