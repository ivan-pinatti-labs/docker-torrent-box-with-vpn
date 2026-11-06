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

DASHBOARDS = (
    Path(__file__).resolve().parents[2]
    / "configs/grafana/config/provisioning/dashboards"
)
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


class _ComposeLoader(yaml.SafeLoader):
    """Accepts Compose's own merge tags. A custom route file at the root, which
    the glob below reads too, clears a service's networks with `!reset []`."""


_ComposeLoader.add_multi_constructor("!", lambda loader, suffix, node: None)


def _compose_services() -> set[str]:
    """Parsed rather than grepped, so a service left commented out (notifiarr)
    is not counted."""
    services = set()
    for compose in Path(__file__).resolve().parents[2].glob("docker-compose*.yml"):
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
    """backends.json gives each container a tile in Overview and a block in its
    stack's row, headed by "<container> | State"."""
    panels = _backends_panels()
    titles = {panel.get("title", "") for panel in panels}
    expected = _compose_services() - NOT_ON_DASHBOARDS.keys()
    assert not NOT_ON_DASHBOARDS.keys() - _compose_services()
    assert sorted(expected - titles) == []
    assert sorted(name for name in expected if f"{name} | State" not in titles) == []


def test_every_container_is_in_a_container_stack():
    """podman_containers.json's stack picker lists containers by name, so one
    left out never shows there, whatever stack is picked."""
    doc = json.loads(
        (DASHBOARDS / "node_containers/podman_containers.json").read_text()
    )
    stack = next(v for v in doc["templating"]["list"] if v["name"] == "stack")
    listed = set(stack["allValue"].split("|"))
    expected = _compose_services() - NOT_ON_DASHBOARDS.keys()
    assert sorted(expected - listed) == []
    assert sorted(listed - expected) == []
