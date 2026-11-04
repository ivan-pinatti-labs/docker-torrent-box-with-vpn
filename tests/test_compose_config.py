import configparser
import re
from pathlib import Path

import pytest
import yaml
from dotenv import dotenv_values

from conftest import (
    QBITTORRENT_EXCLUDED_FILE_NAMES,
    QBITTORRENT_QUEUEING,
    cleanuparr_failed_import_patterns,
)

REPO_ROOT = Path(__file__).parent.parent


def test_audiobookshelf_mounts_full_metadata_tree():
    compose = yaml.safe_load(
        (REPO_ROOT / "docker-compose-media-library.yml").read_text()
    )
    volumes = compose["services"]["audiobookshelf"]["volumes"]

    assert "${CONFIG_FOLDER}/audiobookshelf/metadata:/metadata:z" in volumes


@pytest.mark.parametrize("service", ["calibre", "calibre-web"])
def test_calibre_database_is_kept_off_data(service):
    """Both apps open metadata.db from local storage, never from /data.

    /data can be a CIFS share, and SMB refuses the lock upgrade every SQLite
    commit needs, so a database there could be read but never written (#402).
    """
    compose = yaml.safe_load(
        (REPO_ROOT / "docker-compose-media-library.yml").read_text()
    )
    definition = compose["services"][service]

    assert (
        definition["environment"]["CALIBRE_OVERRIDE_DATABASE_PATH"]
        == "/calibre-db/metadata.db"
    )
    assert "${CONFIG_FOLDER}/calibre/library-db:/calibre-db:z" in definition["volumes"]


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


@pytest.mark.parametrize(
    ("key", "expected"), [(key, value) for key, _, value in QBITTORRENT_QUEUEING]
)
def test_qbittorrent_seed_queueing(key, expected):
    """The seed holds the queue settings test_qbittorrent_queueing reads live.

    Interpolation is off because the seed's scheduler times hold a bare `%`.
    """
    text = (
        REPO_ROOT / "configs/qbittorrent/config/qBittorrent/qBittorrent.conf.example"
    ).read_text()
    parser = configparser.ConfigParser(strict=False, interpolation=None)
    parser.read_string(text)

    assert parser.get("BitTorrent", key) == str(expected).lower()


def test_qbittorrent_seed_excludes_executables():
    """The seed turns qBittorrent's excluded file names on, with the list (#125).

    The list does nothing without the switch, which sits in [BitTorrent]
    itself rather than under Session\\ like the list.
    """
    parser = configparser.ConfigParser(strict=False, interpolation=None)
    parser.read_string(
        (
            REPO_ROOT
            / "configs/qbittorrent/config/qBittorrent/qBittorrent.conf.example"
        ).read_text()
    )

    assert parser.get("BitTorrent", "ExcludedFileNamesEnabled") == "true"
    assert (
        parser.get("BitTorrent", "Session\\ExcludedFileNames").split(", ")
        == QBITTORRENT_EXCLUDED_FILE_NAMES
    )


def test_cleanuparr_strikes_what_qbittorrent_excludes():
    """Cleanuparr's patterns are the excluded extensions, less two.

    .com and .js also turn up in legitimate status messages, in release titles
    and URLs and as part of .json, so striking on them would remove downloads
    that are fine.
    """
    excluded = {name.removeprefix("*") for name in QBITTORRENT_EXCLUDED_FILE_NAMES}

    assert set(cleanuparr_failed_import_patterns()) == excluded - {".com", ".js"}


def test_cleanuparr_runs_locked_down():
    """Its own user, no capabilities, nothing writable but /config (#398)."""
    compose = yaml.safe_load((REPO_ROOT / "docker-compose-servarr.yml").read_text())
    service = compose["services"]["cleanuparr"]

    assert service["profiles"] == ["${CLEANUPARR_PROFILE}"]
    assert service["user"] == "${CLEANUPARR_UID}:${CLEANUPARR_GID}"
    assert service["read_only"] is True
    assert service["cap_drop"] == ["ALL"]
    assert "no-new-privileges:true" in service["security_opt"]
    assert service["volumes"] == [
        "/etc/localtime:/etc/localtime:ro",
        "${CONFIG_FOLDER}/cleanuparr/config:/config:z",
    ]


def test_cleanuparr_serves_under_its_base_path():
    """nginx proxies /cleanuparr/ unchanged, so the app serves under it."""
    compose = yaml.safe_load((REPO_ROOT / "docker-compose-servarr.yml").read_text())
    service = compose["services"]["cleanuparr"]

    assert service["environment"]["BASE_PATH"] == "/cleanuparr"
    assert "/cleanuparr/health" in service["healthcheck"]["test"]
    assert service["networks"] == {
        "apps": {"aliases": ["cleanuparr-http"]},
        "services": {},
    }


def test_nginx_refuses_the_cleanuparr_setup():
    """Nobody but the wiring may create Cleanuparr's first account.

    Its setup endpoints answer anyone until an account exists, and the
    wiring reaches them from inside the container, never through nginx.
    """
    template = (REPO_ROOT / "configs/nginx/templates/default.conf.template").read_text()
    # Case-insensitive: Cleanuparr routes /api/auth/SETUP/ the same way.
    assert (
        "  location ~* ^/cleanuparr/api/auth/setup(?:/|$) {\n    return 403;\n  }"
        in template
    )


def test_nginx_variables_hash_fits_every_upstream():
    """One `set` per upstream outgrew nginx's default, which warns on reload."""
    assert (
        "variables_hash_max_size 2048;"
        in (REPO_ROOT / "configs/nginx/nginx.conf").read_text()
    )


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


def _env_example(key: str) -> str:
    for line in (REPO_ROOT / ".env.example").read_text().splitlines():
        if line.startswith(f"{key}="):
            return line.split("=", 1)[1]
    raise AssertionError(f"{key} is not in .env.example")


@pytest.mark.parametrize(
    ("seed", "section", "key", "template"),
    [
        (
            "configs/mylar/config/mylar/config.ini.example",
            "SABnzbd",
            "sab_host",
            "https://{ip}:{sab}/sabnzbd",
        ),
        (
            "configs/mylar/config/mylar/config.ini.example",
            "qBittorrent",
            "qbittorrent_host",
            "https://{ip}:{qbt}",
        ),
        (
            "configs/lazylibrarian/config/config.ini.example",
            "SABNZBD",
            "sab_host",
            "https://{ip}",
        ),
        (
            "configs/lazylibrarian/config/config.ini.example",
            "SABNZBD",
            "sab_port",
            "{sab}",
        ),
        (
            "configs/lazylibrarian/config/config.ini.example",
            "QBITTORRENT",
            "qbittorrent_host",
            "https://{ip}",
        ),
        (
            "configs/lazylibrarian/config/config.ini.example",
            "QBITTORRENT",
            "qbittorrent_port",
            "{qbt}",
        ),
    ],
)
def test_download_client_seeds_match_env_example(seed, section, key, template):
    """The seeded addresses are the ones wire-connections.sh would write.

    ensure_ini_client_addresses rewrites these from GLUETUN_SERVICES_IP and
    the HTTPS ports, restarting the app to do it, so a seed that drifted from
    .env.example would cost every default checkout a restart on every wiring
    run, and a wrong address costs Mylar minutes on every start (#379).
    """
    parser = configparser.ConfigParser(strict=False, interpolation=None)
    parser.read_string((REPO_ROOT / seed).read_text())
    expected = template.format(
        ip=_env_example("GLUETUN_SERVICES_IP"),
        sab=_env_example("SABNZBD_HTTPS_PORT"),
        qbt=_env_example("QBITTORRENT_HTTPS_PORT"),
    )

    assert parser.get(section, key) == expected


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


@pytest.mark.parametrize("app", ["qbittorrent", "sabnzbd", "cleanuparr"])
def test_nginx_overwrites_forwarded_for_to_downloaders(app):
    """nginx sends the real client as X-Forwarded-For, never the browser's.

    qBittorrent trusts nginx and takes the client from that header, and lets
    READARR_SERVICES_IP in without a login. Appending to what the browser sent
    would let any browser claim Readarr's address through nginx (#411).
    Cleanuparr trusts no forwarded header, and gets the same header anyway.
    """
    template = (REPO_ROOT / "configs/nginx/templates/default.conf.template").read_text()
    start = template.index(f"location /{app}/ {{")
    end = template.index("\n  }", start)
    block = template[start:end]

    assert "proxy_set_header            X-Forwarded-For $remote_addr;" in block
    assert "$proxy_add_x_forwarded_for" not in block


def test_env_tests_moves_every_network_address():
    """.env.tests moves every subnet, range and fixed address .env.example sets.

    The integration suite runs on subnets of its own, so an address left at
    .env.example's value sits outside its network there, and make start
    refuses READARR_SERVICES_IP outright (#411).
    """
    pattern = re.compile(r"^([A-Z_]+_(?:IP|SUBNET|IP_RANGE))=(.*)$", re.MULTILINE)
    example = dict(pattern.findall((REPO_ROOT / ".env.example").read_text()))
    tests = dict(pattern.findall((REPO_ROOT / ".env.tests").read_text()))
    example.pop("LAN_IP")

    unmoved = sorted(
        key for key, value in example.items() if tests.get(key, value) == value
    )
    assert not unmoved, f".env.tests keeps .env.example's value for {unmoved}"


def test_readarr_has_its_fixed_services_address():
    """qBittorrent lets this one address in without a login, so it is pinned."""
    compose = yaml.safe_load((REPO_ROOT / "docker-compose-servarr.yml").read_text())
    services = compose["services"]["readarr"]["networks"]["services"]

    assert services == {"ipv4_address": "${READARR_SERVICES_IP}"}


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


# The error pages for an app that is switched off or not answering (#415).
NGINX_TEMPLATE = REPO_ROOT / "configs/nginx/templates/default.conf.template"


def _nginx_map(name: str) -> dict[str, str]:
    """A `map $request_uri $<name>` of the template, key to value, quotes dropped."""
    block = re.search(
        rf"^map \$request_uri \${name} \{{\n(.*?)^\}}",
        NGINX_TEMPLATE.read_text(),
        re.M | re.S,
    )
    assert block, f"no ${name} map in {NGINX_TEMPLATE.name}"
    entries = {}
    for line in block.group(1).splitlines():
        key, value = line.split(None, 1)
        entries[key] = value.rstrip(";").strip('"')
    return entries


def _main_https_locations() -> list[str]:
    """Every live `location` path of the HTTPS server Homepage is served from."""
    text = NGINX_TEMPLATE.read_text()
    start = text.index("## Homepage")
    end = text.index("server_name ${JELLYFIN_PROXY_DOMAIN};")
    return re.findall(r"^  location (?:= |\^~ )?(\S+) \{", text[start:end], re.M)


def _keys_matching(path: str) -> list[str]:
    """The $app_profile keys whose regex matches a request for `path`."""
    return [
        key
        for key in _nginx_map("app_profile")
        if key != "default" and re.search(key.removeprefix("~"), path)
    ]


def test_nginx_names_the_app_and_profile_of_the_same_paths():
    names, profiles = _nginx_map("app_name"), _nginx_map("app_profile")
    assert names.keys() == profiles.keys()
    assert names["default"] == "Homepage"
    assert profiles["default"] == "HOMEPAGE_PROFILE"


def test_nginx_maps_every_proxied_path_to_one_app():
    """Each location, and a request under it, matches exactly one key.

    `location /` is the default (Homepage), and the error pages' own location
    is internal. A path matching no key would be named as Homepage, and one
    matching two would take whichever comes first.
    """
    locations = [
        path for path in _main_https_locations() if path not in ("/", "/_errors/")
    ]
    assert "/nzbhydra2/" in locations
    for path in locations:
        # /stub_status is an exact location, with nothing under it.
        under = [] if path == "/stub_status" else [path.rstrip("/") + "/login?next=1"]
        for request in (path, *under):
            assert len(_keys_matching(request)) == 1, (request, _keys_matching(request))
    # A longer app name sharing a prefix is its own app.
    assert _keys_matching("/calibre_web/") == ["~^/calibre_web(?:[/?]|$)"]
    assert _keys_matching("/sonarr_extra/") == []


def test_nginx_maps_only_real_profiles():
    example = dotenv_values(REPO_ROOT / ".env.example")
    for profile in _nginx_map("app_profile").values():
        assert profile == "" or profile in example, profile


def test_nginx_serves_the_error_pages_with_their_status():
    text = NGINX_TEMPLATE.read_text()
    assert "include /etc/nginx/generated/*.conf;" in text
    assert "if ($app_refused) {\n    return 503;\n  }" in text
    assert "error_page 503     /_errors/disabled.html;" in text
    assert "error_page 502 504 /_errors/unavailable.html;" in text
    # Off, so an app's own error statuses reach the browser unchanged.
    assert not re.search(r"^\s*proxy_intercept_errors\s", text, re.M)
    for page, words in (
        ("disabled", "is disabled"),
        ("unavailable", "is not answering"),
    ):
        html = (REPO_ROOT / f"configs/nginx/errors/{page}.html").read_text()
        assert f'<!--# echo var="app_name" --> {words}' in html
        assert '<!--# echo var="app_profile" -->' in html
        # The head both share is written once (configs/nginx/errors/head.html).
        assert '<!--# include file="head.html" -->' in html


def test_nginx_mounts_the_error_pages_and_the_disabled_list():
    compose = yaml.safe_load((REPO_ROOT / "docker-compose-proxy.yml").read_text())
    volumes = compose["services"]["nginx"]["volumes"]
    assert "${CONFIG_FOLDER}/nginx/errors:/etc/nginx/errors:ro,z" in volumes
    assert "${CONFIG_FOLDER}/nginx/generated:/etc/nginx/generated:ro,z" in volumes
    # Tracked, so the directory exists for the mount in every clone.
    assert (REPO_ROOT / "configs/nginx/generated/.gitignore").is_file()


def test_nginx_hides_its_version():
    assert "server_tokens off;" in (REPO_ROOT / "configs/nginx/nginx.conf").read_text()
