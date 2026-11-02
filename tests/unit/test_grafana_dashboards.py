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

pytestmark = pytest.mark.unit

DASHBOARDS = (
    Path(__file__).resolve().parents[2]
    / "configs/grafana/config/provisioning/dashboards"
)
# PromQL takes double, single and backtick quoted strings. An exact matcher
# never survives a prefix; a regex one does only if it starts with a wildcard
# (.* or .+) or is a dashboard variable that already holds real names.
EXACT_NAME = re.compile(r"\bname\s*(?:=|!=)\s*[\"'`]")
BARE_REGEX_NAME = re.compile(r"\bname\s*(?:=~|!~)\s*[\"'`](?![.$])")


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


def test_the_stack_variable_values_are_matched_by_suffix():
    doc = json.loads(
        (DASHBOARDS / "node_containers/podman_containers.json").read_text()
    )
    container = next(v for v in doc["templating"]["list"] if v["name"] == "container")
    query = container["query"]
    query = query if isinstance(query, str) else query["query"]
    assert 'name=~".*(${stack:raw})"' in query
