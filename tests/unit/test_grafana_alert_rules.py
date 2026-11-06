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


def _port_mismatch_rule() -> dict:
    return next(r for r in _rules() if r["uid"] == "qbittorrent-port-mismatch")


def test_port_mismatch_compares_the_listen_port_to_the_forwarded_port():
    rule = _port_mismatch_rule()
    assert _exprs(rule) == [
        'max(qbittorrent_listen_port{job="qbittorrent"} > 0)',
        'max(gluetun_forwarded_port{job="qbittorrent"} > 0)',
    ]
    nodes = {query["refId"]: query["model"] for query in rule["data"]}
    assert nodes[rule["condition"]]["expression"] == "$C != $D"
    assert (nodes["C"]["expression"], nodes["D"]["expression"]) == ("A", "B")
    # Both ports are named in the alert.
    description = rule["annotations"]["description"]
    assert "$values.C.Value" in description
    assert "$values.D.Value" in description


def test_port_mismatch_ignores_a_missing_port():
    # A 0 or a missing series is qBittorrent down or no port forwarded, which
    # qbittorrent-down and gluetun-natpmp-port-lost report. A VPN without port
    # forwarding would otherwise alert forever.
    assert _port_mismatch_rule()["noDataState"] == "OK"


def _script_default(name: str) -> int:
    script = Path(__file__).resolve().parents[2] / "scripts/qbittorrent-port-forward.sh"
    match = re.search(rf'"\$\{{{name}:-(\d+)\}}"', script.read_text())
    assert match, f"no default for {name} in {script}"
    return int(match.group(1))


def test_port_mismatch_outlasts_the_port_forward_retries():
    # qBittorrent starts minutes after gluetun, and the up command keeps
    # retrying until it does. A mismatch inside that window is not a fault.
    retries = _script_default("QBITTORRENT_PORT_FORWARD_ATTEMPTS") * _script_default(
        "QBITTORRENT_PORT_FORWARD_DELAY"
    )
    pending = re.fullmatch(r"(\d+)m", _port_mismatch_rule()["for"])
    assert pending, _port_mismatch_rule()["for"]
    assert int(pending.group(1)) * 60 >= retries
