"""The xdist groups that keep rotation_isolated cases for one app together.

A module of its own, imported by tests/conftest.py, so the unit tier can run
it under pytest-xdist without the integration suite's conftest (which imports
the Docker SDK and reads .env). tests/unit/test_xdist_groups.py does that.
"""

import pytest

# Apps whose cases share one group, because rotating either rewrites the same
# files elsewhere. Every other app is a group of its own.
SHARED_GROUPS = {"sonarr": "sonarr-radarr", "radarr": "sonarr-radarr"}


# cspell:words itemcollected
def pytest_itemcollected(item):
    """Keep every rotation_isolated case for one app on a single xdist worker.

    The marker's own premise is that these cases only touch their own
    container, but that holds per file rather than across them: rotating an
    app's API key restarts that app, and the password case for the same app
    needs it up. Split across workers, the api-key case can stop the container
    while the password case is mid-rotation, which surfaces from the script's
    own `podman exec` as "can only create exec sessions on running containers:
    container state improper". Confirmed live in CI on sonarr, where the two
    landed on gw0 and gw3 and the password case failed after waiting out its
    full 120s for a container the other worker had just restarted. It is
    intermittent by nature, which is why the same commit range passed three
    runs and failed four.

    --dist loadgroup (see the Makefile's suite_ci) keeps same-group tests on one
    worker, so grouping by app serialises the pair per app while different apps
    still run concurrently. Applied here rather than as a per-parameter mark so
    it covers both rotation files and anything added to them later.

    Sonarr and Radarr share one group. Rotating either key rewrites Bazarr's
    config.yaml and Recyclarr's secrets and restarts Bazarr, and so does
    restoring it, so on two workers one case read config.yaml while the other
    was rewriting it and got no `sonarr` section back (#305).

    pytest_itemcollected rather than pytest_collection_modifyitems: xdist
    reads xdist_group in its own pytest_collection_modifyitems, which ran
    before that one, so marks added there were never seen and every group
    spread across the workers. Measured with the pinned pytest and xdist: one
    group of eight cases ran two per worker on four workers that way, and all
    on one worker with this hook. Until then none of the grouping above held,
    and Radarr's restore read a config.yaml with an empty `radarr` section
    while Sonarr's case ran on another worker (#328).
    """
    if item.get_closest_marker("rotation_isolated") is None:
        return
    params = getattr(item, "callspec", None)
    app = params.params.get("app") if params else None
    if app:
        item.add_marker(pytest.mark.xdist_group(SHARED_GROUPS.get(app, app)))
