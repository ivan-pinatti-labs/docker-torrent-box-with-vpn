"""Keep the provisioned alert rules working under any CONTAINER_PREFIX.

podman_exporter's `name` label is the real container name, which carries
CONTAINER_PREFIX, and Grafana does not interpolate environment variables in
rule queries (measured on 13.0.2: a ${CONTAINER_PREFIX} in a rule's expr is
stored and queried literally). A rule that selects a container by its exact
name therefore sees no data whenever a prefix is set, and with noDataState
Alerting it fires forever, which is what issue #376 reported for Gluetun
Container Down.
"""

import re
from pathlib import Path

import pytest
import yaml

pytestmark = pytest.mark.unit

RULES = (
    Path(__file__).resolve().parents[2]
    / "configs/grafana/config/provisioning/alerting/rules.yaml"
)
# PromQL takes double, single and backtick quoted strings.
EXACT_NAME = re.compile(r"\bname\s*=\s*[\"'`]")


def _rules() -> list[dict]:
    doc = yaml.safe_load(RULES.read_text())
    return [rule for group in doc["groups"] for rule in group["rules"]]


def _exprs(rule: dict) -> list[str]:
    return [
        query["model"]["expr"]
        for query in rule["data"]
        if "expr" in query.get("model", {})
    ]


def test_no_rule_selects_a_container_by_its_exact_name():
    offending = {
        rule["uid"]: expr
        for rule in _rules()
        for expr in _exprs(rule)
        if EXACT_NAME.search(expr)
    }
    assert not offending, (
        "exact name= selectors miss a prefixed container name; match the "
        f"suffix with name=~ instead: {offending}"
    )


def test_no_rule_relies_on_environment_interpolation_in_a_query():
    offending = {
        rule["uid"]: expr for rule in _rules() for expr in _exprs(rule) if "${" in expr
    }
    assert not offending, (
        f"Grafana queries a ${{...}} in a rule's expr literally: {offending}"
    )


def test_gluetun_container_down_matches_any_prefix():
    rule = next(r for r in _rules() if r["uid"] == "gluetun-container-down")
    assert _exprs(rule) == ['podman_container_state{name=~".*gluetun"}']
    # No data still alerts, and says it is about missing data.
    assert rule["noDataState"] == "Alerting"
    description = rule["annotations"]["description"]
    assert "{{ if $labels.name }}" in description
    assert "its state is unknown" in description
