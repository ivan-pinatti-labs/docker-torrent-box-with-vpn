"""A retired service left in VPN_ON is ignored, not refused (#545).

Every make target parses VPN_ON before it runs, so refusing a token an older
.env still carries would stop `make update` too. The unit tier runs in a
container without make, so the Makefile is read as text.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

MAKEFILE = (Path(__file__).resolve().parents[2] / "Makefile").read_text()


def _value(name: str) -> list[str]:
    match = re.search(rf"^{name} := (.*)$", MAKEFILE, re.MULTILINE)
    assert match, f"{name} is not set in the Makefile"
    return match.group(1).split()


def test_readarr_is_retired_not_routable() -> None:
    assert "readarr" in _value("VPN_RETIRED_TOKENS")
    assert "readarr" not in _value("VPN_ROUTE_SERVICES")


def test_retired_tokens_are_not_unknown() -> None:
    assert _value("VPN_UNKNOWN_TOKENS") == [
        "$(filter-out",
        "$(VPN_VALID_TOKENS)",
        "$(VPN_RETIRED_TOKENS),$(VPN_ON_LIST))",
    ]


def test_a_retired_token_in_use_is_named() -> None:
    assert "\n$(warning VPN_ON names [$(VPN_RETIRED_IN_USE)]" in MAKEFILE
