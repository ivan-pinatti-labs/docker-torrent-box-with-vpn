import configparser
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).parent.parent


def test_audiobookshelf_mounts_full_metadata_tree():
    compose = yaml.safe_load(
        (REPO_ROOT / "docker-compose-media-library.yml").read_text()
    )
    volumes = compose["services"]["audiobookshelf"]["volumes"]

    assert "${CONFIG_FOLDER}/audiobookshelf/metadata:/metadata:z" in volumes


# These read services.yaml.template, not the runtime-generated
# services.yaml: the generated file is filtered down to whatever profiles
# are actually enabled (scripts/generate-homepage-services.py), and
# Whisparr/NZBHydra2/Grafana/cAdvisor all ship disabled by default
# (.env.example), so a filtered-file assertion about one of them fails on
# any environment using those defaults, including a genuinely fresh
# bootstrap. The template carries every entry unconditionally, which is
# what these are actually checking: the widget definition itself, not
# which profiles happen to be on in a given deployment.


def test_homepage_whisparr_uses_radarr_widget():
    services = yaml.safe_load(
        (REPO_ROOT / "configs/homepage/config/services.yaml.template").read_text()
    )
    servarr_group = next(group["Servarr"] for group in services if "Servarr" in group)
    whisparr = next(
        service["Whisparr"] for service in servarr_group if "Whisparr" in service
    )

    assert whisparr["widget"]["type"] == "radarr"


def test_homepage_calibreweb_widget_and_cadvisor_link():
    services = yaml.safe_load(
        (REPO_ROOT / "configs/homepage/config/services.yaml.template").read_text()
    )
    media_group = next(
        group["Media & Library"] for group in services if "Media & Library" in group
    )
    calibre_web = next(
        service["Calibre Web"] for service in media_group if "Calibre Web" in service
    )
    observability_group = next(
        group["Observability"] for group in services if "Observability" in group
    )
    cadvisor = next(
        service["cAdvisor"] for service in observability_group if "cAdvisor" in service
    )

    assert calibre_web["widget"]["type"] == "calibreweb"
    assert cadvisor["href"] == "/admin/cadvisor/containers/"


def test_homepage_footer_shows_version():
    settings = yaml.safe_load(
        (REPO_ROOT / "configs/homepage/config/settings.yaml").read_text()
    )

    assert settings["hideVersion"] is False


def test_homepage_group_and_media_ordering():
    # See the comment above test_homepage_whisparr_uses_radarr_widget: reads
    # the template, not the profile-filtered generated file.
    services = yaml.safe_load(
        (REPO_ROOT / "configs/homepage/config/services.yaml.template").read_text()
    )
    group_names = [next(iter(group)) for group in services]
    indexers_downloaders = next(
        group["Indexers & Downloaders"]
        for group in services
        if "Indexers & Downloaders" in group
    )
    media_group = next(
        group["Media & Library"] for group in services if "Media & Library" in group
    )

    assert "Indexers" not in group_names
    assert "Downloads" not in group_names
    assert [next(iter(service)) for service in indexers_downloaders] == [
        "qBittorrent",
        "SABnzbd",
        "Prowlarr",
        "NZBHydra2",
        "JDownloader2",
    ]

    media_services = [next(iter(service)) for service in media_group]
    assert media_services.index("Calibre Web") < media_services.index("Calibre")


def test_homepage_observability_widgets():
    # See the comment above test_homepage_whisparr_uses_radarr_widget: reads
    # the template, not the profile-filtered generated file.
    services = yaml.safe_load(
        (REPO_ROOT / "configs/homepage/config/services.yaml.template").read_text()
    )
    observability_group = next(
        group["Observability"] for group in services if "Observability" in group
    )
    grafana = next(
        service["Grafana"] for service in observability_group if "Grafana" in service
    )
    prometheus = next(
        service["Prometheus"]
        for service in observability_group
        if "Prometheus" in service
    )

    assert grafana["widget"] == {
        "type": "grafana",
        "url": "http://grafana:3000/admin/grafana",
        "version": 2,
        "alerts": "grafana",
        "headers": {
            "Authorization": "{{HOMEPAGE_FILE_GRAFANA_AUTH}}",
        },
    }
    assert prometheus["widget"] == {
        "type": "prometheus",
        "url": "http://prometheus:9090/admin/prometheus",
    }


def test_mylar_seed_torznab_disabled_ddl_enabled():
    text = (REPO_ROOT / "configs/mylar/config/mylar/config.ini.example").read_text()
    parser = configparser.ConfigParser(strict=False)
    parser.read_string(text)

    assert parser.get("Torznab", "enable_torznab") == "False", (
        "enable_torznab should stay off: extra_torznabs ships empty"
    )
    assert parser.get("DDL", "enable_ddl") == "True"


def test_mylar_seed_has_no_nzbhydra2():
    text = (REPO_ROOT / "configs/mylar/config/mylar/config.ini.example").read_text()
    assert "nzbhydra2" not in text.lower(), (
        "Mylar's seed should not reference nzbhydra2: NZBHYDRA2_PROFILE is "
        "disabled by default, so a seeded entry points at a container that "
        "never starts"
    )


def test_lazylibrarian_seed_has_no_nzbhydra2():
    text = (REPO_ROOT / "configs/lazylibrarian/config/config.ini.example").read_text()
    assert "nzbhydra2" not in text.lower(), (
        "LazyLibrarian's seed should not reference nzbhydra2: NZBHYDRA2_PROFILE "
        "is disabled by default, so a seeded entry points at a container that "
        "never starts"
    )
    assert "[Newznab_0]" not in text
    assert "[Torznab_0]" not in text


def test_lazylibrarian_seed_generic_provider_hosts_blanked():
    """KAT/TPB/TDL/SLSK are LazyLibrarian's own hardcoded provider defaults.

    They render in the UI regardless of whether config.ini mentions them at
    all (lazylibrarian/configdefs.py), pointing at a piracy site or a
    Soulseek daemon nothing in this stack runs. Explicitly seeding a blank
    host overrides LazyLibrarian's own default with an empty one, confirmed
    live via the rendered Settings page.
    """
    text = (REPO_ROOT / "configs/lazylibrarian/config/config.ini.example").read_text()
    parser = configparser.ConfigParser(strict=False)
    parser.read_string(text)

    for section, key in (
        ("KAT", "KAT_HOST"),
        ("TPB", "TPB_HOST"),
        ("TDL", "TDL_HOST"),
        ("SLSK", "SLSK_HOST"),
    ):
        assert parser.get(section, key) == "", f"[{section}] {key} should be blank"


def test_bazarr_seed_listens_on_all_interfaces():
    config = yaml.safe_load(
        (REPO_ROOT / "configs/bazarr/config/config/config.yaml.example").read_text()
    )
    assert config["general"]["ip"] == "0.0.0.0", (  # nosec B104 - asserting a config value, not binding a socket
        "Bazarr's own listen address should not be hardcoded to another "
        "service's IP (this was previously set to Gluetun's fixed address, "
        "which Bazarr's container never actually holds)"
    )


def test_sabnzbd_seed_has_prowlarr_category():
    """Prowlarr's own SABnzbd download client needs this category to exist.

    SABnzbd validates its category strictly (unlike qBittorrent, which
    creates an empty one silently) and 400s creating a download client with
    one that doesn't already exist there, confirmed live.
    """
    text = (REPO_ROOT / "configs/sabnzbd/config/sabnzbd.ini.example").read_text()
    assert "[[prowlarr]]" in text


def test_nginx_scopes_mylar_and_lazylibrarian_cookies():
    """Each app's session cookie is scoped to its own URL prefix.

    Mylar and LazyLibrarian are both cherrypy apps that default to a
    session cookie literally named session_id, scoped to Path=/. Without
    the rewrite, a browser holds only one such cookie for the whole domain,
    so visiting one app overwrites the other's session; confirmed live,
    it evicted Mylar's session on the very next request after logging into
    LazyLibrarian in the same cookie jar.
    """
    template = (REPO_ROOT / "configs/nginx/templates/default.conf.template").read_text()

    for app in ("mylar", "lazylibrarian"):
        start = template.index(f"location /{app}/ {{")
        end = template.index("\n  }", start)
        block = template[start:end]
        assert f"proxy_cookie_path            / /{app}/;" in block, (
            f"/{app}/ location is missing its proxy_cookie_path rewrite"
        )


# The services given longer than the default ten seconds between SIGTERM and
# SIGKILL. docs/CONTAINER_LIMITS.md, "Shutdown grace periods", says why each
# needs it and which ways of stopping the stack honour it.
STOP_GRACE_PERIODS = [
    ("docker-compose-nzb.yml", "nzbhydra2", "120s"),
    ("docker-compose-observability.yml", "alloy", "30s"),
    ("docker-compose-observability.yml", "prometheus", "30s"),
]


@pytest.mark.parametrize(("compose_file", "service", "grace"), STOP_GRACE_PERIODS)
def test_stop_grace_period(compose_file, service, grace):
    """Read from the compose file, not the running container.

    podman-compose 1.6.0, the latest release, passes stop_grace_period as `-t`
    to its own stop, restart and down, which is what `make stop_all` and
    `make restart` use, but does not give it to `podman create`, so the
    container's own StopTimeout stays at podman's ten seconds. The compose
    file is the one place the setting is guaranteed to be.
    """
    compose = yaml.safe_load((REPO_ROOT / compose_file).read_text())
    assert compose["services"][service].get("stop_grace_period") == grace
