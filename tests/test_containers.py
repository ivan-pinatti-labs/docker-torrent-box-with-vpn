"""Container health: all enabled services must be running with no restart loops."""

import pytest

from conftest import SERVICES, skip_if_disabled, skip_if_not_running, wait_for_healthy

pytestmark = pytest.mark.containers


@pytest.mark.parametrize("service_name", list(SERVICES.keys()))
def test_container_running(service_name, running_containers):
    skip_if_disabled(service_name)
    skip_if_not_running(service_name, running_containers)
    container = running_containers[service_name]
    assert container.status == "running", (
        f"Container '{service_name}' status is '{container.status}', expected 'running'"
    )


@pytest.mark.parametrize("service_name", list(SERVICES.keys()))
def test_container_healthy(service_name, running_containers):
    skip_if_disabled(service_name)
    skip_if_not_running(service_name, running_containers)
    container = running_containers[service_name]
    container.reload()
    health = container.attrs.get("State", {}).get("Health")
    # `is None` alone isn't enough: confirmed live in CI, podman there
    # reports Health as an empty-but-present object with a blank Status
    # for a container with no healthcheck defined at all (recyclarr), not
    # a missing/null Health key the way this repo's own podman does
    # locally. Either shape means the same thing: nothing to check here.
    if not health or not health.get("Status"):
        pytest.skip(f"Container '{service_name}' has no healthcheck defined")
    status = health.get("Status")
    if status != "healthy":
        # A container can still be inside its healthcheck start_period right
        # after a mass restart (e.g. `make test`), so give it a chance to
        # finish coming up before treating this as a real failure.
        wait_for_healthy(service_name)
        container.reload()
        health = container.attrs.get("State", {}).get("Health")
        if not health or not health.get("Status"):
            pytest.skip(f"Container '{service_name}' has no healthcheck defined")
        status = health.get("Status")
    # health.get('Log', [{}]) is not enough on its own: podman reports an
    # explicit Log: null, not a missing key, for a container whose
    # healthcheck genuinely hasn't produced a result yet, and dict.get's
    # default only applies to a missing key, not a present one whose value
    # is None.
    last_log = (health.get("Log") or [{}])[-1].get("Output", "")
    assert status == "healthy", (
        f"Container '{service_name}' health is '{status}' (last log: {last_log})"
    )


@pytest.mark.parametrize("service_name", list(SERVICES.keys()))
def test_no_restart_loop(service_name, running_containers):
    skip_if_disabled(service_name)
    skip_if_not_running(service_name, running_containers)
    container = running_containers[service_name]
    restart_count = container.attrs.get("RestartCount", 0)
    assert restart_count <= 2, (
        f"Container '{service_name}' has restarted {restart_count} times, possible crash loop"
    )


def test_vpn_container_running(running_containers):
    """VPN container must be running when its profile is enabled."""
    from conftest import env

    vpn_provider = env("VPN_PROVIDER", "gluetun")
    vpn_profile = f"{vpn_provider.upper()}_PROFILE"
    if env(vpn_profile, "disabled").lower() != "enabled":
        pytest.skip(f"{vpn_profile} is not enabled")
    skip_if_not_running(vpn_provider, running_containers)
    container = running_containers[vpn_provider]
    assert container.status == "running"
