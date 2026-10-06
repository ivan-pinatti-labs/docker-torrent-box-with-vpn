"""Observability stack integration tests.

Checks that the full metrics pipeline is healthy end-to-end:
Prometheus targets → scrape success
podman_exporter   → per-container metrics present
qbittorrent/SABnzbd → exporters reachable and returning metrics
Grafana           → datasource healthy, dashboards provisioned
"""

import json
import re
import subprocess  # nosec B404 - podman CLI, see _podman_cgroups_missing

import pytest
import requests
import urllib3

from conftest import (
    GRAFANA_INI,
    REPO_ROOT,
    base_url,
    container_name,
    env,
    grafana_admin_credentials,
    is_enabled,
    skip_if_not_running,
)

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

pytestmark = pytest.mark.observability

TIMEOUT = 10
PROMETHEUS_PATH = "/admin/prometheus/api/v1"
GRAFANA_PATH = "/admin/grafana/api"

# Scrape jobs whose target only exists when a profile is enabled, mapped to the
# service that provides it. Prometheus's own config is static, so a disabled
# exporter leaves its job configured and its target permanently down, and
# asserting every job is up would then fail for a service nobody asked to run.
# CI disables podman_exporter and podman_limits_exporter because podman 4.9.3
# refuses userns_mode inside a pod; both run on a bench, so `make
# bootstrap_tests` still asserts them.
PROFILE_GATED_PROMETHEUS_JOBS = {
    "podman": "podman_exporter",
    "podman_limits_exporter": "podman_limits_exporter",
}

_ALWAYS_EXPECTED_PROMETHEUS_JOBS = {
    "node_exporter",
    "prometheus",
    "qbittorrent",
    "sabnzbd",
}


def expected_prometheus_jobs() -> set:
    """The scrape jobs that should be up given which profiles are enabled."""
    jobs = set(_ALWAYS_EXPECTED_PROMETHEUS_JOBS)
    for job, service in PROFILE_GATED_PROMETHEUS_JOBS.items():
        if is_enabled(service):
            jobs.add(job)
    return jobs


REPO_POD_NAME = "pod_docker-torrent-box-with-vpn"

EXPECTED_PODMAN_DASHBOARD_STACKS = {
    "Downloaders": {"jdownloader2", "qbittorrent", "sabnzbd"},
    "Indexers": {"nzbhydra2", "prowlarr"},
    "Media & Library": {"jellyfin", "audiobookshelf", "calibre", "calibre-web"},
    "Observability": {
        "cadvisor",
        "podman_exporter",
        "podman_limits_exporter",
        "node_exporter",
        "nginx_exporter",
        "qbittorrent_exporter",
        "sabnzbd_exporter",
        "alloy",
        "prometheus",
        "loki",
        "grafana",
    },
    "VPN": {"gluetun"},
    "Proxy": {"nginx"},
    "Homepage": {"homepage"},
    "Servarr": {
        "bazarr",
        "flaresolverr",
        "lidarr",
        "radarr",
        "readarr",
        "recyclarr",
        "sonarr",
        "whisparr",
        "mylar",
    },
}


# ---------------------------------------------------------------------------
# Prometheus
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def prometheus_url():
    return base_url(https=True) + PROMETHEUS_PATH


def _prom_get(prometheus_url, path, params=None):
    resp = requests.get(
        prometheus_url + path,
        params=params,
        verify=False,
        timeout=TIMEOUT,
    )
    resp.raise_for_status()
    return resp.json()


def _podman_dashboard():
    return json.loads(
        (
            REPO_ROOT
            / "configs/grafana/config/provisioning/dashboards/node_containers/podman_containers.json"
        ).read_text()
    )


def _dashboard_variable(dashboard, name):
    return next(
        item for item in dashboard["templating"]["list"] if item["name"] == name
    )


def _parse_custom_variable_query(query):
    stacks = {}
    for item in query.split(", "):
        label, regex = item.split(" : ", 1)
        stacks[label] = set(regex.split("|"))
    return stacks


def test_prometheus_self_healthy(running_containers):
    """Prometheus /api/v1/query?query=up returns status=success."""
    if not is_enabled("prometheus"):
        pytest.skip("prometheus profile is disabled")
    skip_if_not_running("prometheus", running_containers)

    data = _prom_get(base_url() + PROMETHEUS_PATH, "/query", {"query": "up"})
    assert data["status"] == "success"


def test_prometheus_all_targets_up(running_containers, prometheus_url):
    """All expected scrape jobs are present and in 'up' state."""
    if not is_enabled("prometheus"):
        pytest.skip("prometheus profile is disabled")
    skip_if_not_running("prometheus", running_containers)

    data = _prom_get(prometheus_url, "/targets")
    targets = data["data"]["activeTargets"]
    by_job = {t["scrapePool"]: t for t in targets}

    for job in expected_prometheus_jobs():
        assert job in by_job, (
            f"Prometheus scrape job '{job}' not found (known: {list(by_job)})"
        )
        health = by_job[job]["health"]
        assert health == "up", (
            f"Prometheus job '{job}' is '{health}': {by_job[job].get('lastError', '')}"
        )


def test_prometheus_no_unknown_targets(running_containers, prometheus_url):
    """No scrape target is stuck in 'unknown' state after startup."""
    if not is_enabled("prometheus"):
        pytest.skip("prometheus profile is disabled")
    skip_if_not_running("prometheus", running_containers)

    data = _prom_get(prometheus_url, "/targets")
    unknown = [
        t["scrapePool"]
        for t in data["data"]["activeTargets"]
        if t["health"] == "unknown"
    ]
    assert not unknown, f"Prometheus targets still in 'unknown' state: {unknown}"


# ---------------------------------------------------------------------------
# podman_exporter: per-container metrics
# ---------------------------------------------------------------------------


def test_podman_exporter_container_metrics_present(running_containers, prometheus_url):
    """podman_container_info must report at least the core service containers."""
    if not is_enabled("podman_exporter"):
        pytest.skip("PODMAN_EXPORTER_PROFILE is disabled")
    skip_if_not_running("podman_exporter", running_containers)
    if not is_enabled("prometheus"):
        pytest.skip("prometheus profile is disabled")

    data = _prom_get(prometheus_url, "/query", {"query": "podman_container_info"})
    assert data["status"] == "success"
    results = data["data"]["result"]
    assert results, (
        "podman_container_info returned no series, exporter may not see containers"
    )

    names = {r["metric"].get("name", "") for r in results}
    expected = {"sonarr", "radarr", "gluetun", "prometheus", "grafana", "sabnzbd"}
    missing = expected - names
    assert not missing, f"Expected containers missing from podman metrics: {missing}"


def _podman_cgroups_missing() -> str | None:
    """Why the engine running the stack keeps no cgroup statistics, or None.

    podman_exporter reads CPU and memory from `podman stats`, which reads them
    from each container's cgroup. The nested test runner's engine can have
    none: its containers.conf sets `cgroups = "disabled"`, and even without
    that a rootless engine gets controllers only when the host delegates a
    cgroup to the outer container (devcontainer-airlock docs/IMAGES.md). The
    series then never exist, which says nothing about the exporter.

    Asked of the engine itself, through the same podman CLI the rest of the
    suite drives, rather than inferred from where the suite runs: `podman
    info` for the controllers the engine has, and the exporter's own
    container for whether containers are created with a cgroup at all (a
    libpod field, `HostConfig.Cgroups`, absent from the Docker API). An
    engine that cannot answer is not a reason to skip, so the test runs and
    its own assertion reports.
    """
    info = subprocess.run(  # nosec B607 - podman is a trusted, fixed CLI in this stack
        ["podman", "info", "--format", "json"],
        capture_output=True,
        text=True,
        timeout=TIMEOUT,
    )
    if info.returncode == 0:
        try:
            controllers = json.loads(info.stdout)["host"]["cgroupControllers"]
        except ValueError, KeyError, TypeError:
            controllers = None
        if controllers is not None and not {"cpu", "memory"} <= set(controllers):
            return (
                "the container engine lacks the cpu or memory cgroup controller "
                f"(podman info reports {controllers}), so podman stats has "
                "nothing to read; the host does not delegate cgroups here"
            )
    mode = subprocess.run(  # nosec B607 - podman is a trusted, fixed CLI in this stack
        [
            "podman",
            "container",
            "inspect",
            "--format",
            "{{.HostConfig.Cgroups}}",
            container_name("podman_exporter"),
        ],
        capture_output=True,
        text=True,
        timeout=TIMEOUT,
    )
    if mode.returncode == 0 and mode.stdout.strip() == "disabled":
        return (
            "the container engine creates containers without cgroups "
            '(containers.conf cgroups = "disabled"), so podman stats has '
            "nothing to read"
        )
    return None


def _skip_if_no_cgroups():
    reason = _podman_cgroups_missing()
    if reason:
        pytest.skip(reason)


def test_podman_exporter_cpu_metrics(running_containers, prometheus_url):
    """podman_container_cpu_seconds_total has data for running containers."""
    if not is_enabled("podman_exporter"):
        pytest.skip("PODMAN_EXPORTER_PROFILE is disabled")
    skip_if_not_running("podman_exporter", running_containers)
    if not is_enabled("prometheus"):
        pytest.skip("prometheus profile is disabled")
    _skip_if_no_cgroups()

    data = _prom_get(
        prometheus_url, "/query", {"query": "podman_container_cpu_seconds_total"}
    )
    assert data["status"] == "success"
    assert data["data"]["result"], "No CPU metrics from podman_exporter"


# podman_limits_exporter is the one exporter here whose application this
# repository wrote: the image is a bare Python interpreter and
# scripts/podman-limits-exporter.py is bind mounted in as /exporter.py. Its pin
# is allowed to bump unattended, so these three have to be worth that. The
# container tier proves it runs and its healthcheck answers, but that healthcheck
# is `wget -q -O /dev/null .../metrics`, which discards the body, and a scrape
# target counts as up on an empty-but-parseable response. Neither notices an
# interpreter change that leaves the script serving 200 and producing nothing,
# which is exactly the regression a Python bump would cause, and which would
# break podman_containers.json silently.
def test_podman_limits_exporter_metrics_present(running_containers, prometheus_url):
    """Both series the exporter exists to produce reach Prometheus."""
    if not is_enabled("podman_limits_exporter"):
        pytest.skip("PODMAN_LIMITS_EXPORTER_PROFILE is disabled")
    skip_if_not_running("podman_limits_exporter", running_containers)
    if not is_enabled("prometheus"):
        pytest.skip("prometheus profile is disabled")

    for metric in ("podman_container_cpu_limit_vcpus", "podman_container_pids_limit"):
        data = _prom_get(prometheus_url, "/query", {"query": metric})
        assert data["status"] == "success"
        assert data["data"]["result"], (
            f"No {metric} series from podman_limits_exporter. "
            f"configs/grafana/.../podman_containers.json queries this metric, so "
            f"an empty result is a broken dashboard as well as a broken exporter."
        )


def test_podman_limits_exporter_reports_nonzero_limits(
    running_containers, prometheus_url
):
    """At least one CPU limit is above zero, so an all-zeros result fails.

    Separate from the presence check because zero is the exporter's own documented
    value for "unlimited", which makes a regression that emits nothing but zeros
    indistinguishable from a legitimate reading unless something asserts
    otherwise.
    """
    if not is_enabled("podman_limits_exporter"):
        pytest.skip("PODMAN_LIMITS_EXPORTER_PROFILE is disabled")
    skip_if_not_running("podman_limits_exporter", running_containers)
    if not is_enabled("prometheus"):
        pytest.skip("prometheus profile is disabled")

    data = _prom_get(
        prometheus_url, "/query", {"query": "podman_container_cpu_limit_vcpus > 0"}
    )
    assert data["status"] == "success"
    assert data["data"]["result"], (
        "Every podman_container_cpu_limit_vcpus series is zero. The compose files "
        "set a CPU limit on most services, so this means the exporter is serving "
        "metrics it did not derive from the podman socket."
    )


def test_podman_limits_exporter_agrees_with_the_configured_limit(
    running_containers, prometheus_url
):
    """The exporter's own CPU limit matches what .env asked compose for.

    The strongest of the three, and the one that makes an unattended bump
    defensible: it walks the whole chain, .env to compose to the podman API to the
    exporter to Prometheus, rather than checking that bytes came back. The
    exporter's own container is used as the subject because its limit comes from a
    single variable, TELEMETRY_CPUS, with no per-app override in between.
    """
    if not is_enabled("podman_limits_exporter"):
        pytest.skip("PODMAN_LIMITS_EXPORTER_PROFILE is disabled")
    skip_if_not_running("podman_limits_exporter", running_containers)
    if not is_enabled("prometheus"):
        pytest.skip("prometheus profile is disabled")

    expected = env("TELEMETRY_CPUS")
    if not expected:
        pytest.skip("TELEMETRY_CPUS is not set")

    data = _prom_get(
        prometheus_url,
        "/query",
        {"query": 'podman_container_cpu_limit_vcpus{name="podman_limits_exporter"}'},
    )
    result = data["data"]["result"]
    assert result, "podman_limits_exporter reports no CPU limit for itself"
    reported = float(result[0]["value"][1])
    assert reported == pytest.approx(float(expected)), (
        f"podman_limits_exporter reports its own CPU limit as {reported}, but "
        f"TELEMETRY_CPUS asks compose for {expected}. The exporter is answering, "
        f"and the number it answers with is wrong."
    )


def test_podman_exporter_memory_metrics(running_containers, prometheus_url):
    """podman_container_mem_usage_bytes has data for running containers."""
    if not is_enabled("podman_exporter"):
        pytest.skip("PODMAN_EXPORTER_PROFILE is disabled")
    skip_if_not_running("podman_exporter", running_containers)
    if not is_enabled("prometheus"):
        pytest.skip("prometheus profile is disabled")
    _skip_if_no_cgroups()

    data = _prom_get(
        prometheus_url, "/query", {"query": "podman_container_mem_usage_bytes"}
    )
    assert data["status"] == "success"
    assert data["data"]["result"], "No memory metrics from podman_exporter"


# ---------------------------------------------------------------------------
# qbittorrent exporter
# ---------------------------------------------------------------------------


def test_qbittorrent_exporter_metrics_present(running_containers, prometheus_url):
    """qbittorrent_exporter metrics are scraped into Prometheus."""
    if not is_enabled("qbittorrent_exporter"):
        pytest.skip("QBITTORRENT_EXPORTER_PROFILE is disabled")
    skip_if_not_running("qbittorrent_exporter", running_containers)
    if not is_enabled("prometheus"):
        pytest.skip("prometheus profile is disabled")

    data = _prom_get(
        prometheus_url, "/query", {"query": 'max(qbittorrent_up{job="qbittorrent"})'}
    )
    assert data["status"] == "success"
    assert data["data"]["result"], "qbittorrent_up returned no series"
    assert data["data"]["result"][0]["value"][1] == "1", (
        f"qbittorrent_up is not 1: {data['data']['result']}"
    )

    err_data = _prom_get(prometheus_url, "/targets")
    qbt_target = next(
        (
            t
            for t in err_data["data"]["activeTargets"]
            if t["scrapePool"] == "qbittorrent"
        ),
        None,
    )
    assert qbt_target is not None, "qbittorrent scrape job not found"
    assert qbt_target["health"] == "up", (
        f"qbittorrent scrape job is '{qbt_target['health']}': {qbt_target.get('lastError', '')}"
    )


# ---------------------------------------------------------------------------
# SABnzbd exporter
# ---------------------------------------------------------------------------


def test_sabnzbd_exporter_metrics_present(running_containers, prometheus_url):
    """SABnzbd exporter metrics are scraped into Prometheus."""
    if not is_enabled("sabnzbd_exporter"):
        pytest.skip("SABNZBD_EXPORTER_PROFILE is disabled")
    skip_if_not_running("sabnzbd_exporter", running_containers)
    if not is_enabled("prometheus"):
        pytest.skip("prometheus profile is disabled")

    data = _prom_get(prometheus_url, "/query", {"query": 'up{job="sabnzbd"}'})
    assert data["status"] == "success"
    assert data["data"]["result"], "SABnzbd exporter returned no up series"
    assert data["data"]["result"][0]["value"][1] == "1", (
        f"SABnzbd exporter is not up: {data['data']['result']}"
    )


# ---------------------------------------------------------------------------
# Grafana
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def grafana_url():
    return base_url(https=True) + GRAFANA_PATH


@pytest.fixture(scope="module")
def grafana_session():
    """Return a requests.Session authenticated against Grafana via Basic Auth.

    Two things here were wrong together, and each hid the other.

    The credentials were `ADMIN_USER`/`ADMIN_PASSWORD` with an
    "admin"/"admin" fallback. Those name no Grafana setting and are not in
    `.env.example`, so the fallback always won and sent Grafana the upstream
    default password, which `grafana.ini` overrides. Grafana's admin
    credentials come from `grafana.ini` alone, which is what
    `grafana_admin_credentials` reads.

    The check was `if resp.status_code == 401`, which can never fire. With
    `[auth.anonymous] enabled = true`, Grafana answers wrong Basic Auth with
    HTTP 200 and an anonymous body rather than 401. So the skip never
    triggered, and this fixture has been returning an unauthenticated session
    the whole time. The tests using it passed anyway because an anonymous
    Viewer can read what they assert, which is exactly why nobody noticed.

    `/api/frontend/settings` is asked instead, because Grafana states in
    `buildInfo.hideVersion` whether it treated the request as signed in.
    That is a direct answer rather than an inference from a status code.
    """
    user, password = grafana_admin_credentials()
    assert user and password, (
        f"no Grafana admin credentials found in {GRAFANA_INI} or its .example"
    )

    session = requests.Session()
    session.verify = False
    session.auth = (user, password)
    resp = session.get(
        base_url(https=True) + GRAFANA_PATH + "/frontend/settings",
        timeout=TIMEOUT,
    )
    assert resp.status_code == 200, (
        f"Grafana frontend settings returned {resp.status_code}: {resp.text[:200]}"
    )
    assert not (resp.json().get("buildInfo") or {}).get("hideVersion", True), (
        "Grafana served this request anonymously, so the admin credentials in "
        f"{GRAFANA_INI} were rejected and this session is not authenticated"
    )
    return session


def test_grafana_health(running_containers):
    """Grafana /api/health returns database=ok (no auth required)."""
    if not is_enabled("grafana"):
        pytest.skip("grafana profile is disabled")
    skip_if_not_running("grafana", running_containers)

    resp = requests.get(
        base_url() + GRAFANA_PATH + "/health",
        verify=False,
        timeout=TIMEOUT,
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data.get("database") == "ok", f"Grafana database not ok: {data}"


def test_grafana_prometheus_datasource_healthy(
    running_containers, grafana_url, grafana_session
):
    """Grafana Prometheus datasource uid='prometheus' is configured."""
    if not is_enabled("grafana"):
        pytest.skip("grafana profile is disabled")
    skip_if_not_running("grafana", running_containers)

    resp = grafana_session.get(
        grafana_url + "/datasources/uid/prometheus",
        timeout=TIMEOUT,
    )
    assert resp.status_code == 200, (
        f"Grafana datasource 'prometheus' not found: {resp.status_code} {resp.text[:200]}"
    )
    data = resp.json()
    assert data.get("type") == "prometheus"


def test_grafana_dashboards_provisioned(
    running_containers, grafana_url, grafana_session
):
    """All expected dashboards are present in Grafana."""
    if not is_enabled("grafana"):
        pytest.skip("grafana profile is disabled")
    skip_if_not_running("grafana", running_containers)

    resp = grafana_session.get(
        grafana_url + "/search?type=dash-db",
        timeout=TIMEOUT,
    )
    assert resp.status_code == 200
    titles = {d["title"] for d in resp.json()}

    expected = {
        "Node Exporter",
        "Docker Containers",
        "qBittorrent",
        "SABnzbd",
        "Podman Containers",
    }
    missing = expected - titles
    assert not missing, f"Grafana dashboards missing: {missing} (found: {titles})"


def test_podman_dashboard_stack_filters_match_app_groups():
    dashboard = _podman_dashboard()
    stack = _dashboard_variable(dashboard, "stack")

    assert (
        _parse_custom_variable_query(stack["query"]) == EXPECTED_PODMAN_DASHBOARD_STACKS
    )
    assert "lazylibrarian" not in stack["query"]


def test_podman_dashboard_default_stack_filter_is_repo_only():
    dashboard = _podman_dashboard()
    stack = _dashboard_variable(dashboard, "stack")
    all_value = stack["allValue"]
    expected_containers = set().union(*EXPECTED_PODMAN_DASHBOARD_STACKS.values())

    assert set(all_value.split("|")) == expected_containers
    assert re.fullmatch(all_value, "pihole-mcp-360657") is None
    assert re.fullmatch(all_value, "podman_cpu_exporter") is None


def test_podman_dashboard_container_variable_is_repo_scoped():
    dashboard = _podman_dashboard()
    container = _dashboard_variable(dashboard, "container")

    assert f'pod_name="{REPO_POD_NAME}"' in container["query"]
    assert 'name=~"${stack:raw}"' in container["query"]


def test_podman_dashboard_podman_exporter_queries_are_repo_scoped():
    dashboard = _podman_dashboard()
    unscoped = []

    for panel in dashboard["panels"]:
        for target in panel.get("targets") or []:
            expr = target.get("expr", "")
            if "podman_container_" not in expr:
                continue
            if "podman_container_cpu_limit_vcpus" in expr:
                continue
            if "podman_container_pids_limit" in expr:
                continue
            if f'pod_name="{REPO_POD_NAME}"' not in expr:
                unscoped.append((panel["title"], expr))

    assert not unscoped


def test_torrent_box_overview_uses_sabnzbd_not_nzbget():
    dashboard = (
        REPO_ROOT
        / "configs/grafana/config/provisioning/dashboards/torrent_box/backends.json"
    ).read_text()
    assert "nzbget" not in dashboard.lower()
    assert "sabnzbd" in dashboard.lower()


def test_qbittorrent_dashboard_uses_bit_rates():
    dashboard = json.loads(
        (
            REPO_ROOT
            / "configs/grafana/config/provisioning/dashboards/downloaders/qbittorrent.json"
        ).read_text()
    )
    panels = {panel["title"]: panel for panel in dashboard["panels"]}

    for title in (
        "Session Transfer Rate",
        "Active Download Limit",
        "Active Upload Limit",
        "VPN Network I/O",
    ):
        panel = panels[title]
        assert panel["fieldConfig"]["defaults"]["unit"] == "bps"
        for target in panel["targets"]:
            assert target["expr"].endswith(" * 8")

    assert panels["Disk I/O"]["fieldConfig"]["defaults"]["unit"] == "Bps"


def test_qbittorrent_dashboard_uses_decimal_byte_sizes():
    dashboard = json.loads(
        (
            REPO_ROOT
            / "configs/grafana/config/provisioning/dashboards/downloaders/qbittorrent.json"
        ).read_text()
    )
    panels = {panel["title"]: panel for panel in dashboard["panels"]}

    for title in (
        "All Time Downloaded",
        "All Time Uploaded",
        "Session Downloaded",
        "Session Uploaded",
        "Free Space",
        "qBittorrent Memory Usage",
        "Download Disk Free",
        "Swap Usage",
    ):
        assert panels[title]["fieldConfig"]["defaults"]["unit"] == "decbytes"
