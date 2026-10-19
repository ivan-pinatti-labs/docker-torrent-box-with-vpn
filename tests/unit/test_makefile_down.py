"""`make down` hands podman to scripts/podman-down.sh.

tests/unit/podman-down.test.sh runs the script itself, so it keeps passing if
the recipe stops calling it. These tests read the recipe instead: the unit
tier runs in a container without make, so the Makefile is read as text.
"""

from __future__ import annotations

from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

REPO_ROOT = Path(__file__).resolve().parents[2]
MAKEFILE = REPO_ROOT / "Makefile"


def _recipe(target: str) -> list[str]:
    """The recipe lines of `target`, the tab indented lines after its rule."""
    lines = MAKEFILE.read_text().splitlines()
    start = lines.index(f"{target}:")
    recipe = []
    for line in lines[start + 1 :]:
        if not line.startswith("\t"):
            break
        recipe.append(line.strip())
    return recipe


def _branches() -> tuple[list[str], list[str]]:
    """The podman and the other branch of the down recipe's runtime test."""
    recipe = _recipe("down")
    test = next(i for i, line in enumerate(recipe) if '"$(RUNTIME)" = "podman"' in line)
    otherwise = recipe.index("else \\", test)
    end = recipe.index("fi", otherwise)
    return recipe[test + 1 : otherwise], recipe[otherwise + 1 : end]


def test_podman_runs_the_script() -> None:
    podman, _ = _branches()
    assert podman == [
        "PODMAN_DOWN_TIMEOUT=$(PODMAN_DOWN_TIMEOUT) ./scripts/podman-down.sh; \\"
    ]


def test_the_script_is_executable() -> None:
    assert (REPO_ROOT / "scripts/podman-down.sh").stat().st_mode & 0o111


def test_docker_keeps_compose_down() -> None:
    _, docker = _branches()
    assert docker == [
        "$(COMPOSE) $(STOP_COMPOSE_FILES) --profile enabled down --timeout 60; \\"
    ]


def test_the_vpn_routes_are_forgotten_last() -> None:
    assert _recipe("down")[-1] == "@rm -f $(VPN_STATE_FILE)"
