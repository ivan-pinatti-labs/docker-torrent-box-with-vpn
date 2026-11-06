"""Keep the provisioned dashboards working under any CONTAINER_PREFIX.

podman_exporter's `name` label is the real container name, which carries
CONTAINER_PREFIX, and Grafana does not interpolate environment variables in
queries. A query that selects a container by its bare name, exactly or as an
anchored regex such as name=~"sonarr|radarr", shows nothing whenever a prefix
is set (#384, the dashboard side of #376). Containers are matched by suffix
instead: name=~".*sonarr", name=~".*(${stack:raw})".
"""

import json
import re
from pathlib import Path

import pytest
import yaml

pytestmark = pytest.mark.unit

REPO_ROOT = Path(__file__).resolve().parents[2]
DASHBOARDS = REPO_ROOT / "configs/grafana/config/provisioning/dashboards"
# PromQL takes double, single and backtick quoted strings. An exact matcher
# never survives a prefix; a regex one does only if it starts with a wildcard
# (.* or .+) or is a dashboard variable that already holds real names.
EXACT_NAME = re.compile(r"\bname\s*(?:=|!=)\s*[\"'`]")
BARE_REGEX_NAME = re.compile(r"\bname\s*(?:=~|!~)\s*[\"'`](?!\.[*+]|\$)")


def _queries() -> list[tuple[str, str]]:
    found = []

    def walk(node, where):
        if isinstance(node, dict):
            for key, value in node.items():
                if key in ("expr", "query", "definition") and isinstance(value, str):
                    found.append((where, value))
                else:
                    walk(value, where)
        elif isinstance(node, list):
            for value in node:
                walk(value, where)

    for path in sorted(DASHBOARDS.glob("**/*.json")):
        walk(json.loads(path.read_text()), str(path.relative_to(DASHBOARDS)))
    return found


def test_the_dashboards_have_queries():
    assert len(_queries()) > 100


def test_no_query_selects_a_container_by_its_exact_name():
    offending = [(where, q) for where, q in _queries() if EXACT_NAME.search(q)]
    assert not offending, (
        "exact name selectors miss a prefixed container name; match the "
        f'suffix with name=~".*<container>" instead: {offending[:5]}'
    )


def test_no_name_regex_assumes_an_empty_prefix():
    offending = [(where, q) for where, q in _queries() if BARE_REGEX_NAME.search(q)]
    assert not offending, (
        "PromQL anchors regex matchers, so a bare name regex misses prefixed "
        f"containers; start it with .* instead: {offending[:5]}"
    )


def _compose_container_names() -> set[str]:
    names = set()
    for compose in Path(__file__).resolve().parents[2].glob("docker-compose*.yml"):
        names.update(
            re.findall(
                r"container_name:\s*\$\{CONTAINER_PREFIX\}(\S+)", compose.read_text()
            )
        )
    return names


def test_every_container_a_query_names_exists():
    # A panel for a container no compose file defines always reads "Down",
    # as the one for the renamed podman_cpu_exporter did (#391).
    known = _compose_container_names()
    assert "gluetun" in known
    unknown = set()
    for where, query in _queries():
        for match in re.finditer(
            r"\bname\s*(?:=~|!~)\s*\"\.\*\(?([A-Za-z0-9_.|-]+)\)?\"", query
        ):
            unknown.update(
                (where, name) for name in match[1].split("|") if name not in known
            )
    assert not unknown, (
        f"queries name containers no compose file defines: {sorted(unknown)}"
    )


def test_the_stack_variable_values_are_matched_by_suffix():
    doc = json.loads(
        (DASHBOARDS / "node_containers/podman_containers.json").read_text()
    )
    container = next(v for v in doc["templating"]["list"] if v["name"] == "container")
    query = container["query"]
    query = query if isinstance(query, str) else query["query"]
    assert 'name=~".*(${stack:raw})"' in query


# Containers deliberately left off the dashboards that list every container,
# each with the reason. Everything else needs its panels (#443): Cleanuparr went
# without any, because nothing tied a new service to them.
NOT_ON_DASHBOARDS = {
    "nzbget": "legacy and disabled by default; the overview is SABnzbd's",
    "vpn_mock": "a CI stand-in for a VPN server, never part of a deployment",
}

# The panels every block in backends.json has, after its "<container> | State".
# Latency is extra, and only where nginx routes to the container.
BLOCK_PANELS = ("State", "CPU", "Memory", "Swap", "Disk IO", "Network IO")


class _ComposeLoader(yaml.SafeLoader):
    """Accepts Compose's own merge tags. A custom route file at the root, which
    the glob below reads too, clears a service's networks with `!reset []`."""


_ComposeLoader.add_multi_constructor("!", lambda loader, suffix, node: None)


def _compose_services(root: Path = REPO_ROOT) -> set[str]:
    """Parsed rather than grepped, so a service left commented out (notifiarr)
    is not counted."""
    services = set()
    for compose in sorted(root.glob("docker-compose*.yml")):
        doc = yaml.load(compose.read_text(), Loader=_ComposeLoader)  # nosec B506 - SafeLoader subclass
        services.update(doc.get("services") or {})
    return services


def _backends_panels() -> list[dict]:
    doc = json.loads((DASHBOARDS / "torrent_box/backends.json").read_text())

    def walk(panels):
        for panel in panels:
            yield panel
            yield from walk(panel.get("panels", []))

    return list(walk(doc["panels"]))


def test_every_container_has_an_overview_tile_and_a_block():
    """backends.json gives each container a tile in Overview and a full block in
    its stack's row, headed by "<container> | State"."""
    panels = _backends_panels()
    titles = {panel.get("title", "") for panel in panels}
    expected = _compose_services() - NOT_ON_DASHBOARDS.keys()
    assert not NOT_ON_DASHBOARDS.keys() - _compose_services()
    assert sorted(expected - titles) == []
    missing = [
        f"{name} | {panel}"
        for name in sorted(expected)
        for panel in BLOCK_PANELS
        if f"{name} | {panel}" not in titles
    ]
    assert missing == []


def test_every_block_has_the_full_panel_set():
    """A block cut short, or one left behind by a removed container, fails
    here: every "<x> | State" has the rest of BLOCK_PANELS beside it."""
    titles = {panel.get("title", "") for panel in _backends_panels()}
    blocks = {t.split(" | ")[0] for t in titles if t.endswith(" | State")}
    missing = [
        f"{name} | {panel}"
        for name in sorted(blocks)
        for panel in BLOCK_PANELS
        if f"{name} | {panel}" not in titles
    ]
    assert missing == []


def test_every_block_panel_selects_its_own_container():
    """A panel copied from another block and only partly renamed would show
    that container's series under this one's title."""
    wrong, checked = [], 0
    for panel in _backends_panels():
        name, sep, _ = panel.get("title", "").partition(" | ")
        if not sep:
            continue
        for target in panel.get("targets", []):
            expr = target.get("expr", "")
            selected = re.findall(r"\bname=~\"\.\*([A-Za-z0-9_.-]+)\"", expr)
            selected += re.findall(r"\bservice=\"([A-Za-z0-9_.-]+)\"", expr)
            checked += len(selected)
            wrong += [(panel["title"], s) for s in selected if s != name]
    assert checked > 200, "the matchers above no longer find the selectors"
    assert wrong == []


def test_every_block_sits_in_one_row():
    """Grafana collapses a row with its panels, so a block split across rows
    shows partly under another stack."""
    doc = json.loads((DASHBOARDS / "torrent_box/backends.json").read_text())
    rows = {}
    for row in doc["panels"]:
        for panel in row.get("panels", []):
            name, sep, _ = panel.get("title", "").partition(" | ")
            if sep:
                rows.setdefault(name, set()).add(row["title"])
    assert {name: r for name, r in rows.items() if len(r) > 1} == {}


def test_every_container_is_in_a_container_stack():
    """podman_containers.json's stack picker lists containers by name, so one
    left out never shows there, whatever stack is picked. Both ways: in "All"
    (allValue) and in exactly one named stack."""
    doc = json.loads(
        (DASHBOARDS / "node_containers/podman_containers.json").read_text()
    )
    stack = next(v for v in doc["templating"]["list"] if v["name"] == "stack")
    listed = set(stack["allValue"].split("|"))
    expected = _compose_services() - NOT_ON_DASHBOARDS.keys()
    assert sorted(expected - listed) == []
    assert sorted(listed - expected) == []
    # "Name : a|b, Other : c" -> every container named once across the stacks.
    entries = stack["query"].split(",")
    assert all(" : " in entry for entry in entries), entries
    grouped = [
        name.strip()
        for entry in entries
        for name in entry.split(" : ", 1)[1].split("|")
    ]
    assert "" not in grouped, stack["query"]
    assert sorted(grouped) == sorted(set(grouped))
    assert set(grouped) == listed


def test_compose_services_reads_a_route_file_with_reset(tmp_path):
    """A custom route file kept at the root, as ROUTE_FILES allows, clears
    networks with Compose's `!reset []`, which yaml.safe_load refuses."""
    (tmp_path / "docker-compose-apps.yml").write_text(
        "services:\n  radarr:\n    profiles: ['${RADARR_PROFILE}']\n"
    )
    (tmp_path / "docker-compose-custom-vpn.yml").write_text(
        "services:\n"
        "  radarr:\n    network_mode: container:gluetun\n    networks: !reset []\n"
        "  gluetun:\n    networks:\n      services:\n        aliases: [radarr]\n"
    )
    assert _compose_services(tmp_path) == {"radarr", "gluetun"}


# Every podman_container_* series something in the stack emits: the podman
# exporter's container collector (collector/container.go upstream, which has no
# swap metric at all) and this repository's scripts/podman-limits-exporter.py.
# The Swap panels queried podman_container_mem_swap_*, which nothing emits, and
# stayed empty unnoticed on every block (#459).
EMITTED_PODMAN_SERIES = {
    # podman_exporter
    "podman_container_block_input_total",
    "podman_container_block_output_total",
    "podman_container_cpu_seconds_total",
    "podman_container_cpu_system_seconds_total",
    "podman_container_created_seconds",
    "podman_container_exit_code",
    "podman_container_exited_seconds",
    "podman_container_health",
    "podman_container_info",
    "podman_container_mem_limit_bytes",
    "podman_container_mem_usage_bytes",
    "podman_container_net_input_dropped_total",
    "podman_container_net_input_errors_total",
    "podman_container_net_input_packets_total",
    "podman_container_net_input_total",
    "podman_container_net_output_dropped_total",
    "podman_container_net_output_errors_total",
    "podman_container_net_output_packets_total",
    "podman_container_net_output_total",
    "podman_container_pids",
    "podman_container_rootfs_size_bytes",
    "podman_container_rw_size_bytes",
    "podman_container_started_seconds",
    "podman_container_state",
    # podman_limits_exporter
    "podman_container_cpu_limit_vcpus",
    "podman_container_pids_limit",
    "podman_container_swap_usage_bytes",
    "podman_container_swap_limit_bytes",
}


def test_every_podman_series_a_query_names_is_emitted():
    queried = {
        name
        for _, query in _queries()
        for name in re.findall(r"\bpodman_container_[a-z_]+", query)
    }
    assert "podman_container_state" in queried
    assert sorted(queried - EMITTED_PODMAN_SERIES) == []


def test_the_limits_exporter_emits_what_it_is_listed_for():
    """The four the list credits to podman_limits_exporter are the four its
    script writes, so the list cannot vouch for a series the script dropped."""
    script = (REPO_ROOT / "scripts/podman-limits-exporter.py").read_text()
    written = set(re.findall(r"# TYPE (podman_container_[a-z_]+) gauge", script))
    assert written == {
        "podman_container_cpu_limit_vcpus",
        "podman_container_pids_limit",
        "podman_container_swap_usage_bytes",
        "podman_container_swap_limit_bytes",
    }
    assert written <= EMITTED_PODMAN_SERIES
