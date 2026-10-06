"""Runtime version-pin consistency: what is running versus what is pinned.

The reason this file exists. PR #137 offered `linuxserver/qbittorrent`
`5.2.2 -> 20.04.1` as a "major upgrade". `20.04.1` was never a qBittorrent
version: verified with `skopeo inspect`, the pinned `5.2.2` was built
2026-07-05 (`org.opencontainers.image.version` label `5.2.2_v2.0.13-ls465`),
and the proposed `20.04.1` was built 2021-11-29
(`14.3.9.99202110311443-7435-01519b5e7ubuntu20.04.1-ls163`). LinuxServer
briefly tagged this image by Ubuntu base release around that build, and
Renovate's default docker versioning ranks `20.04.1` above `5.x`. The
qBittorrent bundled inside that four-and-a-half-year-old image is actually
`4.3.9`. It booted, reported healthy, and satisfied the entire integration
suite anyway: `Tests Verified` read SUCCESS. Nothing in this repository
checked that the software inside the container was the software the pin
named.

This file does, by asking each running application what version it believes
itself to be, over its own API, and comparing that against the pin in
`.env`. Not image metadata: qBittorrent's own `build_version` label for the
substituted image *contains* the literal text `20.04.1`
(`14.3.9.99202110311443-7435-01519b5e7ubuntu20.04.1-ls163`), so a check that
reads the label and asks whether it contains the pinned tag would have
passed both the real `5.2.2` image and the fake `20.04.1` one. An image
label describes what LinuxServer built, not what is actually running; a
bind-mounted patch or an entrypoint override can desync the two (see the
patched-image hold in `.github/renovate.json5`), and this incident shows a
tag can simply lie. Asking the process itself is the only check that
survives both.

`test_version_match_rejects_the_pr_137_pair` below proves the comparison
this file uses on the real pair rather than asserting it would work: both
version strings are real, captured live from standalone containers of the
actual `5.2.2` and `20.04.1` images (2026-09-02), and it demonstrates the
label-substring trap in the same breath.

Comparison is by parsed integer version components, and it is a *prefix*
match against what is reported, not string equality: several of these apps
answer with more precision than their pin carries. Sonarr's own
`/api/v3/system/status` answers `4.0.19.2979` for a pin of `4.0.19`
(confirmed live); the extra build number is real precision, not a mismatch.
It is deliberately not a substring/contains check, which is the exact hole
above: parsed-component comparison never mistakes `20.04.1`'s components for
a match against `5.2.2`'s, in either direction, because comparison is
numeric per component rather than textual.

Covered, each confirmed live against a standalone container of the pinned
image before being wired into this file: qBittorrent (`/api/v2/app/version`,
authenticated); Sonarr, Radarr, Lidarr, Prowlarr, Readarr
(`system/status` beside each app's own already-registered `/health` path,
same API prefix, same API key); Bazarr (`/api/system/status`); SABnzbd
(`mode=version`, unauthenticated by design upstream); Jellyfin
(`/System/Info/Public`, unauthenticated); Grafana
(`/api/frontend/settings`, authenticated, because `hide_version` masks
`/api/health`); Prometheus
(`/api/v1/status/buildinfo`).

Not covered, and why, so this is not a test that silently skips everything
while looking thorough:

    Whisparr is pinned to the floating `v3` channel tag (see `FLOATING` in
    test_renovate_pins.py), which names no fixed version to compare against.

    nginx (`stable-alpine`) and Plex (`latest`) are the same: floating
    channel tags with nothing fixed pinned. Plex is also not in the default
    stack (`PLEX_PROFILE=disabled`).

    nzbget is not part of the default stack (SABnzbd is the usenet client
    actually enabled) and now has its Renovate updates switched off
    entirely (see `.github/renovate.json5`); it is out of scope for the same
    reason it gets no other coverage in this repository.

    lazylibrarian and mylar3 are locally built wrapper images pinned to a
    LinuxServer commit/build tag rather than an application version, and
    jackett has no compose service at all to query.

    Everything else pinned in `.env.example` (the exporters, cAdvisor,
    node_exporter, Loki, Alloy, nginx_exporter, homepage, flaresolverr,
    notifiarr, nzbhydra2, korsync, calibre, calibre-web, audiobookshelf,
    gluetun, wireguard/vpn_mock, log_rotator, jdownloader-2) was not
    attempted here. Jellyfin and Bazarr, both covered above, suggest several
    of these likely expose a version too; confirming and wiring each one up
    is follow-on work, not required to close the gap PR #137 and #97
    actually exposed.
"""

import re
import subprocess  # nosec B404 - podman CLI, see the call sites

import pytest
import requests
import urllib3

from conftest import (
    GRAFANA_INI,
    SERVICES,
    base_url,
    container_name,
    env,
    grafana_admin_credentials,
    is_enabled,
    read_api_key,
    read_secret,
    service_base_url,
    skip_if_not_running,
)

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

pytestmark = pytest.mark.version_pins

TIMEOUT = 10
BASE = base_url(https=True)

# The leading run of dot-separated digits in a string, wherever it starts.
# Matches "5.2.2" inside "v5.2.2" and "4.0.19" inside "4.0.19.2979"; stops at
# the first non-digit, non-dot character, so "0.4.19-nightly" yields
# "0.4.19" and a LinuxServer suffix like "_v2.0.13-ls465" is never reached
# because the digest/tag is split off before this runs.
_LEADING_VERSION = re.compile(r"\d+(?:\.\d+)*")


def _components(raw: str) -> tuple:
    """Parse a version string into a tuple of leading integer components.

    "5.2.2@sha256:dd24a5f3..." -> (5, 2, 2)
    "v5.2.2"                   -> (5, 2, 2)
    "4.0.19.2979"               -> (4, 0, 19, 2979)
    "0.4.19-nightly"            -> (0, 4, 19)
    """
    tag = raw.split("@", 1)[0]
    match = _LEADING_VERSION.search(tag)
    assert match, f"{raw!r} has no dotted numeric version to compare"
    return tuple(int(part) for part in match.group().split("."))


def _assert_running_matches_pin(
    pinned_raw: str, reported: str, service: str, pin_name: str
):
    """The pin's components must be an exact prefix of what is actually running.

    Prefix, not equality: several apps here self-report more precision than
    the pin records (Sonarr's own API answers "4.0.19.2979" for a pin of
    "4.0.19"). Prefix, not substring/contains: that is the exact hole PR #137
    went through, where the substituted image's own label contained the
    pinned tag's literal text. Comparing parsed integer components instead of
    raw strings closes it, because "20.04.1"'s components are never a prefix
    match, nor a match of any prefix length, against "5.2.2"'s.
    """
    pinned = _components(pinned_raw)
    got = _components(reported)
    assert got[: len(pinned)] == pinned, (
        f"{service} is pinned to {pinned_raw!r} ({pin_name}) but its own API "
        f"reports running {reported!r}. This is not the version {pin_name} "
        f"asked for."
    )


def test_version_match_rejects_the_pr_137_pair():
    """Proof, not assertion: run the real pair through the real comparison.

    Both version strings below are real, captured live (2026-09-02) from
    standalone containers of the two actual images at the center of PR #137,
    queried the same way the live tests below query the running stack
    (`POST /api/v2/auth/login`, then `GET /api/v2/app/version`):

    `linuxserver/qbittorrent:5.2.2` (this repository's pin) answers "v5.2.2".
    `linuxserver/qbittorrent:20.04.1` (what PR #137 offered) answers
    "v4.3.9" -- the qBittorrent release actually bundled inside that
    four-and-a-half-year-old LinuxServer build. "20.04.1" was never a
    qBittorrent version; LinuxServer briefly tagged this image by Ubuntu
    base release, and it outranked "5.x" only because Renovate's default
    docker versioning compares it as a bare version string.

    The real pinned tag string is used too, digest and all, so this exercises
    exactly the string `_assert_running_matches_pin` receives from `.env` in
    the live tests below.
    """
    pinned = (
        "5.2.2@sha256:dd24a5f3db32bc1425d3f8dc95e8aca8ac5a35905d798171230edf33f516d9a4"
    )

    # The real 5.2.2 image, queried live: must not raise.
    _assert_running_matches_pin(pinned, "v5.2.2", "qbittorrent", "QBITTORRENT_VERSION")

    # The real 20.04.1 image PR #137 offered, queried live: must raise.
    with pytest.raises(AssertionError):
        _assert_running_matches_pin(
            pinned, "v4.3.9", "qbittorrent", "QBITTORRENT_VERSION"
        )

    # And the trap this replaces, spelled out: the substituted image's own
    # label contains the pinned tag's literal text, so a "label contains the
    # pin" check would have passed it. This function is not that check.
    substituted_image_label = "14.3.9.99202110311443-7435-01519b5e7ubuntu20.04.1-ls163"
    assert "20.04.1" in substituted_image_label, "the trap: looks like a match"
    assert _components(substituted_image_label) != _components(pinned), (
        "the real comparison is not fooled by the label containing the pinned tag"
    )


# ---------------------------------------------------------------------------
# qBittorrent
# ---------------------------------------------------------------------------


def _qbittorrent_password():
    return read_secret("qbittorrent", "password.txt") or env(
        "QBITTORRENT_PASSWORD", "qbittorrent"
    )


def test_qbittorrent_running_version_matches_pin(running_containers):
    if not is_enabled("qbittorrent"):
        pytest.skip("qbittorrent profile is disabled")
    skip_if_not_running("qbittorrent", running_containers)

    session = requests.Session()
    session.verify = False
    password = _qbittorrent_password()
    username = SERVICES["qbittorrent"]["username"]
    login = session.post(
        f"{BASE}/qbittorrent/api/v2/auth/login",
        data={"username": username, "password": password},
        timeout=TIMEOUT,
    )
    assert 200 <= login.status_code < 300, (
        f"qBittorrent login failed: {login.status_code} {login.text!r}"
    )

    resp = session.get(f"{BASE}/qbittorrent/api/v2/app/version", timeout=TIMEOUT)
    assert resp.status_code == 200, (
        f"qBittorrent version endpoint returned {resp.status_code}: {resp.text[:200]}"
    )
    _assert_running_matches_pin(
        env("QBITTORRENT_VERSION"),
        resp.text.strip(),
        "qbittorrent",
        "QBITTORRENT_VERSION",
    )


# ---------------------------------------------------------------------------
# Servarr apps: Sonarr, Radarr, Lidarr, Prowlarr, Readarr
# ---------------------------------------------------------------------------

_ARR_VERSION_VAR = {
    "sonarr": "SONARR_VERSION",
    "radarr": "RADARR_VERSION",
    "lidarr": "LIDARR_VERSION",
    "prowlarr": "PROWLARR_VERSION",
    "readarr": "READARR_VERSION",
}


@pytest.mark.parametrize("service_name", sorted(_ARR_VERSION_VAR))
def test_arr_running_version_matches_pin(service_name, running_containers):
    """`system/status` sits beside the `/health` path SERVICES already knows.

    Same API prefix (api/v3 for Sonarr and Radarr, api/v1 for the rest) and
    the same API key; confirmed live against standalone containers of
    Sonarr, Prowlarr and Readarr that all three answer a `version` field at
    `system/status` in this shape (Radarr and Lidarr share the same Servarr
    codebase and API convention).
    """
    if not is_enabled(service_name):
        pytest.skip(f"{service_name} profile is disabled")
    skip_if_not_running(service_name, running_containers)

    api_key = read_api_key(service_name)
    if not api_key:
        pytest.skip(f"No API key found for {service_name}")

    cfg = SERVICES[service_name]
    api_prefix = cfg["api_health_path"].rsplit("/health", 1)[0]
    url = service_base_url(service_name) + api_prefix + "/system/status"
    resp = requests.get(
        url, headers={"X-Api-Key": api_key}, verify=False, timeout=TIMEOUT
    )
    assert resp.status_code == 200, (
        f"{service_name} system/status returned {resp.status_code}: {resp.text[:200]}"
    )
    reported = resp.json().get("version")
    assert reported, (
        f"{service_name} system/status returned no version: {resp.text[:200]}"
    )
    _assert_running_matches_pin(
        env(_ARR_VERSION_VAR[service_name]),
        reported,
        service_name,
        _ARR_VERSION_VAR[service_name],
    )


# ---------------------------------------------------------------------------
# Bazarr
# ---------------------------------------------------------------------------


def test_bazarr_running_version_matches_pin(running_containers):
    if not is_enabled("bazarr"):
        pytest.skip("bazarr profile is disabled")
    skip_if_not_running("bazarr", running_containers)

    api_key = read_api_key("bazarr")
    if not api_key:
        pytest.skip("No Bazarr API key found")

    resp = requests.get(
        f"{BASE}/bazarr/api/system/status",
        headers={"X-API-KEY": api_key},
        verify=False,
        timeout=TIMEOUT,
    )
    assert resp.status_code == 200, (
        f"bazarr system/status returned {resp.status_code}: {resp.text[:200]}"
    )
    reported = resp.json().get("data", {}).get("bazarr_version")
    assert reported, f"bazarr system/status returned no version: {resp.text[:200]}"
    _assert_running_matches_pin(
        env("BAZARR_VERSION"), reported, "bazarr", "BAZARR_VERSION"
    )


# ---------------------------------------------------------------------------
# SABnzbd
# ---------------------------------------------------------------------------


def test_sabnzbd_running_version_matches_pin(running_containers):
    """`mode=version` is unauthenticated by design upstream (see test_auth.py's
    comment on why that made it unsuitable for an auth test); that is exactly
    what makes it convenient here.
    """
    if not is_enabled("sabnzbd"):
        pytest.skip("sabnzbd profile is disabled")
    skip_if_not_running("sabnzbd", running_containers)

    resp = requests.get(
        f"{BASE}/sabnzbd/api",
        params={"mode": "version", "output": "json"},
        verify=False,
        timeout=TIMEOUT,
    )
    assert resp.status_code == 200, (
        f"SABnzbd version endpoint returned {resp.status_code}: {resp.text[:200]}"
    )
    reported = resp.json().get("version")
    assert reported, f"SABnzbd version endpoint returned no version: {resp.text[:200]}"
    _assert_running_matches_pin(
        env("SABNZBD_VERSION"), reported, "sabnzbd", "SABNZBD_VERSION"
    )


# ---------------------------------------------------------------------------
# Jellyfin
# ---------------------------------------------------------------------------


def test_jellyfin_running_version_matches_pin(running_containers):
    if not is_enabled("jellyfin"):
        pytest.skip("jellyfin profile is disabled")
    skip_if_not_running("jellyfin", running_containers)

    # Jellyfin serves its API under JELLYFIN_BASE_URL (`/jellyfin` by
    # default), on its direct port as well as through nginx, the same way
    # scripts/rotate-api-keys.sh builds the URL. Without the prefix the request
    # got Jellyfin's HTML redirect to the web client, and this test skipped on
    # the non JSON body on every run, checking nothing.
    jellyfin_base = service_base_url("jellyfin") + env("JELLYFIN_BASE_URL")
    resp = requests.get(
        f"{jellyfin_base}/System/Info/Public", verify=False, timeout=TIMEOUT
    )
    assert resp.status_code == 200, (
        f"Jellyfin System/Info/Public returned {resp.status_code}: {resp.text[:200]}"
    )
    # A failure rather than a skip: the profile is enabled and the container
    # is running, so anything but JSON here means Jellyfin is not serving the
    # base URL this stack configures, which is worth knowing.
    content_type = resp.headers.get("Content-Type", "")
    assert "json" in content_type.lower(), (
        "Jellyfin System/Info/Public did not answer with JSON "
        f"(Content-Type {content_type!r}): {resp.text[:200]}"
    )
    reported = resp.json().get("Version")
    assert reported, (
        f"Jellyfin System/Info/Public returned no version: {resp.text[:200]}"
    )
    _assert_running_matches_pin(
        env("JELLYFIN_VERSION"), reported, "jellyfin", "JELLYFIN_VERSION"
    )


# ---------------------------------------------------------------------------
# Grafana and Prometheus
#
# Both requested by name for #97 (Grafana 11.6.5 -> 13.0.2, Prometheus
# v2.55.1 -> v3.14.0): confirmed live against standalone containers of all
# four versions (both endpoints, both pinned and target) that the field
# names below are stable across the bump.
# ---------------------------------------------------------------------------


def test_grafana_running_version_matches_pin(running_containers):
    if not is_enabled("grafana"):
        pytest.skip("grafana profile is disabled")
    skip_if_not_running("grafana", running_containers)

    # Not /api/health, and not because of authentication. configs/grafana/
    # config/grafana.ini.example sets hide_version = true under
    # [auth.anonymous], and Grafana applies that flag to /api/health
    # unconditionally: the handler omits version and commit whenever the flag
    # is set, without ever consulting whether the caller is signed in. So
    # /api/health answers {"database": "ok"} to an anonymous request and to a
    # correctly authenticated one alike, and a version check built on it fails
    # identically whichever Grafana is running. Verified directly against
    # grafana-oss:11.6.5 with that flag on.
    #
    # /api/frontend/settings is the endpoint that honours the flag as its
    # comment in grafana.ini describes, masking the version "for
    # unauthenticated users" only: signed out it reports
    # buildInfo.hideVersion true with version "", signed in it reports
    # hideVersion false with the real version.
    # Grafana's own admin credentials, from grafana.ini, which is the only
    # place they are set: ADMIN_USER and ADMIN_PASSWORD name no Grafana
    # setting and are not in .env.example at all, so the "admin"/"admin"
    # fallback they used here was the upstream default password sent to a
    # Grafana whose grafana.ini overrides it. See grafana_admin_credentials.
    admin_user, admin_password = grafana_admin_credentials()
    assert admin_user and admin_password, (
        "no Grafana admin credentials found in "
        f"{GRAFANA_INI} or its .example, so GRAFANA_VERSION cannot be verified"
    )

    session = requests.Session()
    session.verify = False
    session.auth = (admin_user, admin_password)
    resp = session.get(
        base_url(https=True) + "/admin/grafana/api/frontend/settings",
        timeout=TIMEOUT,
    )
    assert resp.status_code == 200, (
        f"Grafana frontend settings returned {resp.status_code}: {resp.text[:200]}"
    )
    build_info = resp.json().get("buildInfo") or {}

    # Grafana states here whether it treated this request as signed in, so
    # the credentials are checked by the same call that reads the version
    # rather than inferred from a status code. Anonymous access is enabled in
    # this stack, so rejected credentials do not produce a 401: they produce a
    # 200 carrying an empty version. That is a real failure and must not be a
    # skip, or wrong credentials would leave GRAFANA_VERSION unverified while
    # the suite reported success.
    assert not build_info.get("hideVersion", True), (
        "Grafana served this request anonymously, so it masked the version "
        f"and GRAFANA_VERSION went unverified. The admin credentials in "
        f"{GRAFANA_INI} were rejected. buildInfo: {build_info}"
    )
    reported = build_info.get("version")
    assert reported, f"Grafana reported no version while signed in: {build_info}"

    _assert_running_matches_pin(
        env("GRAFANA_VERSION"), reported, "grafana", "GRAFANA_VERSION"
    )


# ---------------------------------------------------------------------------
# Calibre, which reaches lazylibrarian through a build-time mod rather than a
# pin of its own
# ---------------------------------------------------------------------------


def test_lazylibrarian_carries_the_calibre_mod(running_containers):
    """The wrapper's whole reason to exist is present in the running container.

    `build/lazylibrarian/Dockerfile` layers ghcr.io/linuxserver/mods:universal-calibre
    onto the stock image, which ships no Calibre at all, so a wrapper that
    silently lost the layer would start, report healthy and serve the web UI
    while Calibredb import quietly did nothing.

    Deliberately no assertion on *which* Calibre. The mod is digest pinned in
    that Dockerfile, so the version is already fixed by the digest, and
    hardcoding the version here as well would fail this test on every
    Renovate digest bump and take the automerge path down with it. What is
    asserted is what the digest cannot promise on its own: that the layer
    survived the build and the binary actually runs.
    """
    # Not is_enabled(): lazylibrarian is not a SERVICES entry, so that reads no
    # profile variable at all and always answered disabled, which skipped this
    # test on every run. Adding it to SERVICES would parametrize it into every
    # registry driven test as well, so read its profile directly instead.
    if env("LAZYLIBRARIAN_PROFILE", "disabled").lower() != "enabled":
        pytest.skip("LAZYLIBRARIAN_PROFILE is not enabled")
    skip_if_not_running("lazylibrarian", running_containers)

    # CALIBRE_RELEASE ships in the mod and the Dockerfile copies it in; it is
    # the one file that records which Calibre the layer carried.
    release = subprocess.run(  # nosec B607 - podman is a trusted, fixed CLI in this stack
        ["podman", "exec", container_name("lazylibrarian"), "cat", "/CALIBRE_RELEASE"],
        capture_output=True,
        text=True,
        timeout=TIMEOUT,
    )
    assert release.returncode == 0, (
        "/CALIBRE_RELEASE is missing from the lazylibrarian container, so the "
        f"universal-calibre layer did not survive the build: {release.stderr[:200]}"
    )
    assert release.stdout.strip(), "/CALIBRE_RELEASE is present but empty"

    # The file existing only proves the COPY ran. This proves the tarball was
    # unpacked and calibre_postinstall completed.
    binary = subprocess.run(  # nosec B607 - podman is a trusted, fixed CLI in this stack
        [
            "podman",
            "exec",
            container_name("lazylibrarian"),
            "/app/calibre/calibredb",
            "--version",
        ],
        capture_output=True,
        text=True,
        timeout=TIMEOUT,
    )
    assert binary.returncode == 0, (
        "/app/calibre/calibredb did not run in the lazylibrarian container, so "
        f"Calibre is present as files but not usable: {binary.stderr[:200]}"
    )
    assert "calibre" in binary.stdout.lower(), (
        f"unexpected calibredb --version output: {binary.stdout[:200]}"
    )


def test_prometheus_running_version_matches_pin(running_containers):
    if not is_enabled("prometheus"):
        pytest.skip("prometheus profile is disabled")
    skip_if_not_running("prometheus", running_containers)

    resp = requests.get(
        base_url() + "/admin/prometheus/api/v1/status/buildinfo",
        verify=False,
        timeout=TIMEOUT,
    )
    assert resp.status_code == 200, f"Prometheus buildinfo returned {resp.status_code}"
    data = resp.json()
    assert data.get("status") == "success", f"Prometheus buildinfo: {data}"
    reported = data.get("data", {}).get("version")
    assert reported, f"Prometheus buildinfo returned no version: {resp.text[:200]}"
    _assert_running_matches_pin(
        env("PROMETHEUS_VERSION"), reported, "prometheus", "PROMETHEUS_VERSION"
    )
