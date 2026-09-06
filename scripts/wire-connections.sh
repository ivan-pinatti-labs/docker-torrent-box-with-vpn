#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
set -euo pipefail

# Usage: ./scripts/wire-connections.sh
#
# Wires the app-to-app connections that can only exist through each app's own
# live API: qBittorrent and SABnzbd as download clients inside Sonarr, Radarr,
# Lidarr, Readarr, and Whisparr, and those apps (plus LazyLibrarian and Mylar)
# registered as Applications in Prowlarr, if it's enabled. Prowlarr also gets
# Internet Archive added as its one default indexer, a legal public source
# (a nonprofit digital library) whose categories actually cover what the arr
# apps search for (Movies/TV/Audio/Books/PC), so the Applications above have
# something real to sync to and Prowlarr's search actually returns results
# out of the box. Along the way it
# also creates each arr app's initial WebUI login (the placeholder
# username/password the README's login table documents) and relaxes
# CertificateValidation for internal addresses, since download client
# creation needs both and nothing else in this stack sets them up.
#
# It also attempts the first-run setup that Jellyfin, Audiobookshelf,
# Calibre's content server, and Calibre-Web each need before they have any
# usable account at all (see the "First-run setup" section below), since
# scripts/rotate-*.sh can't rotate a credential that doesn't exist yet. This
# reliably succeeds for three of the four; Jellyfin's is unreliable for
# reasons not fully understood (see that function's own comment) and often
# needs a one-time manual visit to its web UI instead.
#
# These specifically cannot be seeded from a template the way most of this
# stack's config is: they live in each arr app's SQLite database
# (DownloadClients / Applications tables), which is deliberately never
# tracked or pre-populated (see docs/HARDENING.md). Two related connections
# are NOT handled here because they already work out of the box:
#   - Bazarr's Sonarr/Radarr connections: configs/bazarr/config/config/
#     config.yaml.example already ships ip/port/base_url/ssl plus the same
#     placeholder API key sonarr/radarr's own config.xml.example uses, so
#     they match by construction.
#   - Mylar/LazyLibrarian's qBittorrent/SABnzbd connections: their
#     config.ini.example files are pre-filled the same way, since both apps
#     are configured from a flat file rather than a database.
# See docs/CONNECTIONS.md for the full picture.
#
# Idempotent: every creation is preceded by a check for an existing entry, so
# re-running this after `make start` again, or after rotating credentials, is
# always safe and just confirms everything is still wired.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
cd "$REPO_ROOT"

# Read a variable from .env without sourcing it (.env defines UID, which is a
# readonly bash builtin, so `source .env` fails).
env_value() {
  local key="$1"
  grep -m1 "^${key}=" .env | cut -d= -f2-
}

# Container names carry CONTAINER_PREFIX, which is empty for a deployment and
# set in a second checkout's .env so its containers do not collide with the
# deployment's on podman's global container namespace. Service names stay
# unprefixed everywhere else in this script, and this is resolved at the point
# podman is invoked and nowhere else, so no caller can prefix something twice.
CONTAINER_PREFIX="$(env_value CONTAINER_PREFIX)"
cname() { printf '%s%s' "$CONTAINER_PREFIX" "$1"; }

LAN_IP="$(env_value LAN_IP)"
GLUETUN_SERVICES_IP="$(env_value GLUETUN_SERVICES_IP)"
QBITTORRENT_HTTPS_PORT="$(env_value QBITTORRENT_HTTPS_PORT)"
SABNZBD_HTTP_PORT="$(env_value SABNZBD_HTTP_PORT)"
SONARR_HTTP_PORT="$(env_value SONARR_HTTP_PORT)"
RADARR_HTTPS_PORT="$(env_value RADARR_HTTPS_PORT)"
LIDARR_HTTPS_PORT="$(env_value LIDARR_HTTPS_PORT)"
READARR_HTTPS_PORT="$(env_value READARR_HTTPS_PORT)"
WHISPARR_HTTPS_PORT="$(env_value WHISPARR_HTTPS_PORT)"
PROWLARR_HTTPS_PORT="$(env_value PROWLARR_HTTPS_PORT)"
LAZYLIBRARIAN_HTTP_PORT="$(env_value LAZYLIBRARIAN_HTTP_PORT)"
MYLAR_HTTPS_PORT="$(env_value MYLAR_HTTPS_PORT)"
JELLYFIN_HTTP_PORT="$(env_value JELLYFIN_HTTP_PORT)"
JELLYFIN_BASE_URL="$(env_value JELLYFIN_BASE_URL)"
AUDIOBOOKSHELF_HTTP_PORT="$(env_value AUDIOBOOKSHELF_HTTP_PORT)"
CALIBREWEB_VERSION="$(env_value CALIBREWEB_VERSION)"
FLARESOLVERR_HTTP_PORT="$(env_value FLARESOLVERR_HTTP_PORT)"
readonly LAN_IP GLUETUN_SERVICES_IP QBITTORRENT_HTTPS_PORT SABNZBD_HTTP_PORT \
  SONARR_HTTP_PORT RADARR_HTTPS_PORT LIDARR_HTTPS_PORT READARR_HTTPS_PORT \
  WHISPARR_HTTPS_PORT PROWLARR_HTTPS_PORT LAZYLIBRARIAN_HTTP_PORT MYLAR_HTTPS_PORT \
  JELLYFIN_BASE_URL CALIBREWEB_VERSION \
  JELLYFIN_HTTP_PORT AUDIOBOOKSHELF_HTTP_PORT FLARESOLVERR_HTTP_PORT

readonly SONARR_XML="configs/sonarr/config/config.xml"
readonly RADARR_XML="configs/radarr/config/config.xml"
readonly LIDARR_XML="configs/lidarr/config/config.xml"
readonly READARR_XML="configs/readarr/config/config.xml"
readonly WHISPARR_XML="configs/whisparr/config/config.xml"
readonly PROWLARR_XML="configs/prowlarr/config/config.xml"
readonly LAZYLIBRARIAN_INI="configs/lazylibrarian/config/config.ini"
readonly MYLAR_INI="configs/mylar/config/mylar/config.ini"
readonly MYLAR_DB="configs/mylar/config/mylar/mylar.db"

readonly QBITTORRENT_USERNAME_FILE="configs/qbittorrent/secrets/username.txt"
readonly QBITTORRENT_PASSWORD_FILE="configs/qbittorrent/secrets/password.txt" # pragma: allowlist secret
readonly SABNZBD_API_KEY_FILE="configs/sabnzbd/secrets/api_key.txt"           # pragma: allowlist secret

readonly JELLYFIN_API_KEY_FILE="configs/jellyfin/secrets/api_key.txt"             # pragma: allowlist secret
readonly AUDIOBOOKSHELF_API_KEY_FILE="configs/audiobookshelf/secrets/api_key.txt" # pragma: allowlist secret
readonly CALIBRE_USERS_DB_CONTAINER_PATH="/config/.config/calibre/server-users.sqlite"
readonly CALIBRE_PASSWORD_FILE="configs/calibre/secrets/password.txt" # pragma: allowlist secret
readonly CALIBREWEB_DB="configs/calibre-web/config/app.db"
readonly CALIBRE_CONTENT_SERVER_USER="calibre"
readonly CALIBRE_LIBRARY_DIR="/data/media/calibre-library"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

get_xml_apikey() {
  grep -oPm1 '(?<=<ApiKey>)[^<]+' "$1"
}

get_ini_apikey() {
  grep -oPm1 '(?<=^api_key = ).*' "$1"
}

# Run curl inside the target app's own container, hitting its own loopback
# address directly. Apps aren't published to the host on the current bridge
# network. Mirrors scripts/rotate-api-keys.sh's container_curl().
container_curl() {
  local container_name="$1"
  shift
  podman exec "$(cname "$container_name")" curl "$@"
}

# Podman's default stop timeout is 10 seconds. The servarr apps shut down
# cleanly well inside that when idle (measured: sonarr 3s, prowlarr 3s,
# lazylibrarian 5s), but during bootstrap they can be mid-request when the
# stop lands, and Prowlarr's indexer queries alone can block for up to 100s
# against a slow tracker. When that happens podman escalates to SIGKILL, and
# these apps keep their state in SQLite, which is exactly the "killed
# mid-write" corruption this repo warns about elsewhere. A generous timeout
# is free when they are idle and only spends time when it is preventing that.
#
# Mylar is deliberately exempt: its s6 init never forwards SIGTERM to the app
# (measured: it burns the entire timeout, 45s against a 45s limit, where the
# others take 3-5s), so it is always SIGKILLed regardless. Waiting longer for
# it would add minutes to every bootstrap and change nothing.
readonly STOP_TIMEOUT=60
readonly STOP_TIMEOUT_EXEMPT=(mylar)

stop_container() {
  local c exempt=() normal=()
  for c in "$@"; do
    if [[ " ${STOP_TIMEOUT_EXEMPT[*]} " == *" ${c} "* ]]; then
      exempt+=("$(cname "$c")")
    else
      normal+=("$(cname "$c")")
    fi
  done
  # Both batches run concurrently so an exempt container waiting out its
  # timeout never serializes behind the others.
  if [[ ${#normal[@]} -gt 0 ]]; then
    podman stop --time "$STOP_TIMEOUT" "${normal[@]}" >/dev/null &
  fi
  if [[ ${#exempt[@]} -gt 0 ]]; then
    podman stop "${exempt[@]}" >/dev/null &
  fi
  wait
}

# Retry a command every 5 seconds until it succeeds or timeout (in seconds).
# Apps can still be warming up right after `make start`. Prints a heartbeat
# every 30s so a long wait (Jellyfin's Startup/User retry alone can run up
# to 180s) doesn't sit silent with no sign anything is happening.
# Args: timeout label command...
retry() {
  local timeout="$1" label="$2"
  shift 2
  local elapsed=0
  until "$@" >/dev/null 2>&1; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [[ $elapsed -ge $timeout ]]; then
      return 1
    fi
    if ((elapsed % 30 == 0)); then
      echo "${label} ...still waiting (${elapsed}s/${timeout}s)"
    fi
  done
}

# Every unit below (one app's first-run setup, one arr app's download client
# wiring, Prowlarr's application registrations) touches its own container and
# its own config/database, with no dependency on any other unit's result, so
# they all run as background jobs instead of one after another. That matters
# because several of them poll for up to 180s while an app is still warming
# up: run sequentially, worst case adds up (Jellyfin alone can burn 360s);
# run in parallel, the whole batch takes as long as its single slowest job.
# Output streams live rather than being captured and printed after the job
# finishes: every echo in these functions already prefixes its own app name
# (e.g. "[Jellyfin] ..."), so interleaved lines from concurrent jobs stay
# attributable, and a slow job (Calibre-Web, Jellyfin) no longer looks like
# nothing is happening for minutes at a time.
declare -A JOB_PID

start_job() {
  local name="$1"
  shift
  "$@" &
  JOB_PID["$name"]=$!
}

wait_job() {
  local name="$1"
  wait "${JOB_PID[$name]}"
}

# ---------------------------------------------------------------------------
# First-run setup
#
# Four apps in this stack ship with no usable account at all until a human
# completes their own first-run setup wizard once: Jellyfin, Audiobookshelf,
# Calibre's content server, and Calibre-Web. Nothing else in this project's
# bootstrap flow creates that initial account, so their credentials were
# previously stuck skipping rotation forever (see docs/ROTATION.md). Each
# one is driven here through its own documented first-run API (Jellyfin,
# Audiobookshelf), a documented non-interactive CLI flag (Calibre's content
# server), or a direct one-time database write while stopped, matching the
# project's existing stop-edit-start convention (Calibre-Web, which has no
# API or env var for this), using the same placeholder
# username = password = app name convention already used everywhere else.
# ---------------------------------------------------------------------------

# Once BaseUrl is configured, every route Jellyfin serves moves under that
# prefix; a request to the bare host:port doesn't 404 (curl --fail treats
# that as success), it 302s to the web UI instead, confirmed live to
# silently break every later call in this function (empty body where JSON
# was expected) after a prior run already set BaseUrl. Sets
# JELLYFIN_DETECTED_BASE_URL as a side effect since retry() only checks
# exit status, not output.
detect_jellyfin_base_url() {
  # 8096 rather than JELLYFIN_HTTP_PORT, deliberately. This curl runs inside
  # the jellyfin container, and docker-compose-media-library.yml publishes the
  # service as `${JELLYFIN_HTTP_PORT}:8096`, so that variable is the HOST side
  # of the mapping while the server itself always listens on 8096. The two
  # coincide with .env.example's default and the bug stays invisible; change
  # the published port, which .env exists to allow, and this dialled a port
  # nothing listens on. Confirmed live with JELLYFIN_HTTP_PORT=18096: inside
  # the container 18096 is refused and 8096 answers 200, so first-run setup
  # burned the full 180s retry and was skipped on every single start.
  # jellyfin_host_for is the opposite case and correctly keeps the variable:
  # it runs inside an arr container, reaching Jellyfin across the host, where
  # the published port is exactly what it must use.
  local host_url="http://127.0.0.1:8096"
  local info
  # `jq -e '.StartupWizardCompleted'` looked right but isn't: jq -e's exit
  # status reflects the truthiness of the printed value, not whether the key
  # exists, so it reports failure on a genuinely fresh instance where the
  # value is a real, valid `false`. Confirmed live: this made
  # detect_jellyfin_base_url report "not reachable" for the full 180s retry
  # against a perfectly reachable, freshly booted Jellyfin, so first-run
  # setup (and the BaseUrl fix) never even started. `has(...)` only checks
  # the key is present, regardless of its value.
  info=$(container_curl jellyfin -s "${host_url}/System/Info/Public" 2>/dev/null)
  if echo "$info" | jq -e 'has("StartupWizardCompleted")' >/dev/null 2>&1; then
    JELLYFIN_DETECTED_BASE_URL="$host_url"
    return 0
  fi
  info=$(container_curl jellyfin -s "${host_url}${JELLYFIN_BASE_URL}/System/Info/Public" 2>/dev/null)
  if echo "$info" | jq -e 'has("StartupWizardCompleted")' >/dev/null 2>&1; then
    JELLYFIN_DETECTED_BASE_URL="${host_url}${JELLYFIN_BASE_URL}"
    return 0
  fi
  return 1
}

ensure_jellyfin_setup() {
  if ! podman container exists "$(cname jellyfin)" 2>/dev/null; then
    echo "[Jellyfin] Container doesn't exist, skipping."
    return 0
  fi

  local JELLYFIN_DETECTED_BASE_URL=""
  if ! retry 180 "[Jellyfin]" detect_jellyfin_base_url; then
    echo "[Jellyfin] Not reachable, skipping."
    return 0
  fi
  local base_url="$JELLYFIN_DETECTED_BASE_URL"
  if [[ "$(container_curl jellyfin -sS --fail "${base_url}/System/Info/Public" | jq -r '.StartupWizardCompleted')" == "true" ]]; then
    echo "[Jellyfin] Setup wizard already completed, skipping."
    ensure_jellyfin_homepage_wiring "$base_url"
    return 0
  fi

  echo "[Jellyfin] Completing first-run setup wizard..."
  container_curl jellyfin -sS --fail -X POST -H "Content-Type: application/json" \
    -d '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' \
    "${base_url}/Startup/Configuration" >/dev/null

  # UpdateStartupUser() (POST /Startup/User) updates Jellyfin's own
  # lazily-created default user (internally named "abc") by calling
  # _userManager.Users.First(), which throws "Sequence contains no
  # elements" until something has already triggered that lazy creation.
  # A plain GET /Startup/User is exactly that trigger: confirmed live that
  # it 401s pre-wizard the same as GET /Users, but afterward the very next
  # POST /Startup/User reliably returns 204 instead of 500. This is what
  # was previously documented here as unreliable even after 10 minutes of
  # retrying the POST alone; the actual fix was never retrying the POST at
  # all but calling this GET first.
  container_curl jellyfin -s -o /dev/null "${base_url}/Startup/User"

  if ! retry 180 "[Jellyfin]" container_curl jellyfin -s --fail -X POST -H "Content-Type: application/json" \
    -d '{"Name":"jellyfin","Password":"jellyfin"}' "${base_url}/Startup/User"; then # pragma: allowlist secret
    echo "[Jellyfin] Startup/User did not succeed after 180s, skipping the rest of setup."
    echo "[Jellyfin] This step is unreliable; visit http://localhost:${JELLYFIN_HTTP_PORT}/"
    echo "[Jellyfin] once in a browser to complete it, then re-run 'make wire_connections'."
    return 0
  fi

  container_curl jellyfin -sS --fail -X POST -H "Content-Type: application/json" \
    -d '{"EnableRemoteAccess":false,"EnableAutomaticPortMapping":false}' \
    "${base_url}/Startup/RemoteAccess" >/dev/null
  container_curl jellyfin -sS --fail -X POST "${base_url}/Startup/Complete" >/dev/null

  ensure_jellyfin_homepage_wiring "$base_url"
  echo "[Jellyfin] Done."
}

# Both of these only ever ran once, right after first-run setup completed:
# the API key Homepage's widget needs, and nginx's BaseUrl requirement (see
# that block's own comment below). Gating them behind "wizard not yet
# completed" means neither can ever self-heal on a later run if it silently
# failed the one time it ran, which is exactly what happened live: after
# repeated Jellyfin resets during testing, the API key file was left empty
# with the wizard already marked complete, so Homepage's widget kept
# getting HTTP 401 with an empty api_key forever, with nothing to fix it
# short of wiping Jellyfin's whole config again. Called both right after
# first-run setup and on every later run too, via the "setup wizard already
# completed" branch above, so both stay correct no matter what state a
# given Jellyfin instance was already in.
ensure_jellyfin_homepage_wiring() {
  local base_url="$1"
  local token
  token=$(container_curl jellyfin -sS --fail -X POST \
    -H "Content-Type: application/json" \
    -H 'X-Emby-Authorization: MediaBrowser Client="wire-connections", Device="bootstrap", DeviceId="bootstrap", Version="1.0.0"' \
    -d '{"Username":"jellyfin","Pw":"jellyfin"}' \
    "${base_url}/Users/AuthenticateByName" 2>/dev/null | jq -r '.AccessToken // empty')
  if [[ -z "$token" ]]; then
    echo "[Jellyfin] Could not authenticate as the placeholder user, skipping API key/BaseUrl check."
    return 0
  fi

  # A non-empty file isn't proof of a real key: bootstrap seeds this file
  # from api_key.txt.example (a placeholder Jellyfin has never issued and
  # never will validate), so checking for content alone treats that
  # placeholder as already done and skips creating a real one forever,
  # confirmed live. Checking it against Jellyfin's own live key list is the
  # only way to tell a real, working key from a leftover placeholder.
  local existing_keys current_key
  existing_keys=$(container_curl jellyfin -sS --fail -H "Authorization: MediaBrowser Token=\"${token}\"" \
    "${base_url}/Auth/Keys" | jq -r '.Items[].AccessToken')
  current_key=$(cat "$JELLYFIN_API_KEY_FILE" 2>/dev/null || true)
  if ! grep -qxF "$current_key" <<<"$existing_keys"; then
    echo "[Jellyfin] Creating initial API key..."
    container_curl jellyfin -sS --fail -X POST -H "Authorization: MediaBrowser Token=\"${token}\"" \
      "${base_url}/Auth/Keys?App=homepage" >/dev/null
    local api_key
    api_key=$(container_curl jellyfin -sS --fail -H "Authorization: MediaBrowser Token=\"${token}\"" \
      "${base_url}/Auth/Keys" | jq -r '.Items | sort_by(.DateCreated) | last.AccessToken')
    printf '%s' "$api_key" >"$JELLYFIN_API_KEY_FILE"
    chmod 644 "$JELLYFIN_API_KEY_FILE"
  fi

  # nginx's /jellyfin/ location proxies the request URI through unchanged
  # (no rewrite), so it only works if Jellyfin itself has been told its own
  # BaseUrl is /jellyfin; nothing before this ever configured that
  # (Jellyfin has no env var for it, only its Network Configuration API or
  # a direct network.xml write), so every request under that prefix 404'd,
  # confirmed live down to the exact reported URL. BaseUrl only takes
  # effect after a restart.
  local network_config
  network_config=$(container_curl jellyfin -sS --fail -H "Authorization: MediaBrowser Token=\"${token}\"" \
    "${base_url}/System/Configuration/network")
  if [[ "$(echo "$network_config" | jq -r '.BaseUrl')" != "$JELLYFIN_BASE_URL" ]]; then
    echo "[Jellyfin] Setting BaseUrl to ${JELLYFIN_BASE_URL}..."
    local updated_network_config
    updated_network_config=$(echo "$network_config" | jq --arg baseUrl "$JELLYFIN_BASE_URL" '.BaseUrl = $baseUrl')
    container_curl jellyfin -sS --fail -X POST -H "Authorization: MediaBrowser Token=\"${token}\"" \
      -H "Content-Type: application/json" -d "$updated_network_config" \
      "${base_url}/System/Configuration/network" >/dev/null
    podman restart "$(cname jellyfin)" >/dev/null
  fi
}

# Audiobookshelf's own image ships no curl, only wget (verified directly),
# so this talks to it the same way scripts/rotate-passwords.sh's
# homepage_http() talks to Homepage for the same reason.
ensure_audiobookshelf_setup() {
  if ! podman container exists "$(cname audiobookshelf)" 2>/dev/null; then
    echo "[Audiobookshelf] Container doesn't exist, skipping."
    return 0
  fi

  local base_url="http://127.0.0.1:${AUDIOBOOKSHELF_HTTP_PORT}"
  if ! retry 180 "[Audiobookshelf]" podman exec "$(cname audiobookshelf)" wget -qO- "${base_url}/status"; then
    echo "[Audiobookshelf] Not reachable, skipping."
    return 0
  fi
  local status
  status=$(podman exec "$(cname audiobookshelf)" wget -qO- "${base_url}/status")
  if [[ "$(echo "$status" | jq -r '.isInit')" != "true" ]]; then
    echo "[Audiobookshelf] Creating initial root user..."
    local init_payload='{"newRoot":{"username":"root","password":"audiobookshelf"}}' # pragma: allowlist secret
    podman exec "$(cname audiobookshelf)" wget -qO- --header='Content-Type: application/json' \
      --post-data="$init_payload" "${base_url}/init" >/dev/null
  fi

  ensure_audiobookshelf_api_key "$base_url"
  echo "[Audiobookshelf] Done."
}

# Homepage's widget uses a real, non-expiring API key (Audiobookshelf's own
# Settings > API Keys feature, POST /api/api-keys with no expiresIn), not
# the short-lived JWT /login returns, per rotate-passwords.sh's own comment
# that "Homepage talks to it with a JWT API token, not the password, so no
# consumer cascade is needed", a comment that assumed this key already got
# created somewhere, but nothing ever did. bootstrap seeds this file from
# api_key.txt.example ("changeme"), which is not a key Audiobookshelf will
# ever accept, so the widget silently ran on a placeholder forever,
# confirmed live. Only attempts this with the placeholder root/audiobookshelf
# login: if that's been rotated since, this can't authenticate and skips
# with a note, matching ensure_jellyfin_homepage_wiring's same fallback.
ensure_audiobookshelf_api_key() {
  local base_url="$1"
  local login_response token
  local login_payload='{"username":"root","password":"audiobookshelf"}' # pragma: allowlist secret
  login_response=$(podman exec "$(cname audiobookshelf)" wget -qO- --header='Content-Type: application/json' \
    --post-data="$login_payload" "${base_url}/login" 2>/dev/null)
  token=$(echo "$login_response" | jq -r '.user.token // empty')
  if [[ -z "$token" ]]; then
    echo "[Audiobookshelf] Could not authenticate as the placeholder root user, skipping API key check."
    return 0
  fi

  # GET /api/api-keys only ever returns each key's id/metadata, never the
  # secret value again after creation, so there's no way to compare the
  # file's content directly the way ensure_jellyfin_homepage_wiring does; a
  # name unique to this script is enough to tell "already made one" from
  # "never made one, or it's still the seeded placeholder".
  if podman exec "$(cname audiobookshelf)" wget -qO- --header="Authorization: Bearer ${token}" \
    "${base_url}/api/api-keys" | jq -e '.apiKeys[] | select(.name == "wire-connections")' >/dev/null 2>&1; then
    return 0
  fi

  echo "[Audiobookshelf] Creating initial API key..."
  local user_id
  user_id=$(echo "$login_response" | jq -r '.user.id')
  local key_response
  key_response=$(podman exec "$(cname audiobookshelf)" wget -qO- --header="Authorization: Bearer ${token}" \
    --header='Content-Type: application/json' \
    --post-data="$(jq -n --arg userId "$user_id" '{name: "wire-connections", userId: $userId, isActive: true}')" \
    "${base_url}/api/api-keys")
  local api_key
  api_key=$(echo "$key_response" | jq -r '.apiKey.apiKey')
  printf '%s' "$api_key" >"$AUDIOBOOKSHELF_API_KEY_FILE"
  chmod 644 "$AUDIOBOOKSHELF_API_KEY_FILE"
}

# calibre-server --manage-users is a real, non-interactive CLI command
# (verified directly), unlike the desktop GUI/noVNC login, which is already
# usable from its own committed secret file.
ensure_calibre_content_server_user() {
  if ! podman container exists "$(cname calibre)" 2>/dev/null; then
    echo "[Calibre] Container doesn't exist, skipping."
    return 0
  fi
  if podman exec "$(cname calibre)" calibre-server --userdb "$CALIBRE_USERS_DB_CONTAINER_PATH" \
    --manage-users -- list 2>/dev/null | grep -qx "$CALIBRE_CONTENT_SERVER_USER"; then
    echo "[Calibre] Content server user already exists, skipping."
    return 0
  fi

  echo "[Calibre] Creating content server user..."
  local password
  password=$(cat "$CALIBRE_PASSWORD_FILE")
  podman exec "$(cname calibre)" calibre-server --userdb "$CALIBRE_USERS_DB_CONTAINER_PATH" \
    --manage-users -- add "$CALIBRE_CONTENT_SERVER_USER" "$password" >/dev/null
  echo "[Calibre] Done."
}

# Calibre-Web has no API, env var, or config file for this (confirmed by
# inspecting its image and GitHub wiki directly): only its own admin UI at
# /admin/dbconfig, which every request redirects to until config_calibre_dir
# is set. Writes straight to app.db's settings row while stopped, matching
# this project's established stop-edit-start convention.
#
# This deliberately only sets config_calibre_dir. Also setting
# config_certfile/config_keyfile (Calibre-Web repurposes its single
# config_port for HTTPS once those are set, rather than adding a second
# port) reproducibly wiped the entire `user` table on the very next start,
# including the built-in "Guest" row, in live testing; the mechanism
# wasn't identified in the time available, so this stays off rather than
# risk it. See docs/ROTATION.md: Calibre-Web is only ever configured for
# plain HTTP here, and its default admin user keeps the image's own
# hardcoded username ("admin"), not this project's usual per-app placeholder.
calibre_web_db_ready() {
  python3 - <<PYEOF
import sqlite3, sys
conn = sqlite3.connect('$CALIBREWEB_DB')
row = conn.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='settings'").fetchone()
conn.close()
sys.exit(0 if row else 1)
PYEOF
}

calibre_web_user_count() {
  python3 - <<PYEOF
import sqlite3
conn = sqlite3.connect('$CALIBREWEB_DB')
row = conn.execute("SELECT COUNT(*) FROM user").fetchone()
conn.close()
print(row[0] if row else 0)
PYEOF
}

# Calibre-Web's own init_db() (cps/ub.py) only seeds the default admin and
# Guest rows when app.db does not already exist as a file; if one exists
# (even schema-only, zero rows), it takes the migrate-and-clean branch
# instead and never seeds anything, on this run or any future one. An
# app.db in exactly that state (confirmed live, cause not fully identified:
# most likely the "universal-calibre" mod's package install outlasting a
# liveness probe mid-init_db(), between the schema DDL and the two
# INSERT+commit calls that follow it) is otherwise permanent: no amount of
# restarting or waiting fixes it, since the file already exists. Repairs it
# by asking Calibre-Web's own code for a real default row set (same image,
# scratch path, so the exact column defaults/hashing match what a genuine
# first boot would have produced) and copying those rows into the real
# app.db in place of whatever (typically nothing) is there now.
ensure_calibre_web_users() {
  if [[ "$(calibre_web_user_count)" -gt 0 ]]; then
    return 0
  fi
  echo "[Calibre-Web] app.db has no users (never seeded or lost mid-init), repairing..."
  local scratch
  scratch=$(mktemp -d)
  podman run --rm -v "${scratch}:/scratch:z" --entrypoint python3 \
    "docker.io/linuxserver/calibre-web:${CALIBREWEB_VERSION}" -c "
import sys
sys.path.insert(0, '/app/calibre-web')
from cps import ub
ub.init_db('/scratch/fresh_app.db')
" >/dev/null
  python3 - <<PYEOF
import sqlite3
fresh = sqlite3.connect('${scratch}/fresh_app.db')
cols = [r[1] for r in fresh.execute("PRAGMA table_info(user)")]
rows = fresh.execute(f"SELECT {','.join(cols)} FROM user ORDER BY id").fetchall()
fresh.close()

conn = sqlite3.connect('$CALIBREWEB_DB')
conn.execute("DELETE FROM user")
placeholders = ','.join('?' for _ in cols)
conn.executemany(f"INSERT INTO user ({','.join(cols)}) VALUES ({placeholders})", rows)
conn.commit()
conn.close()
PYEOF
  rm -rf "$scratch"
  echo "[Calibre-Web] Restored the default admin/Guest users."
}

ensure_calibre_web_setup() {
  if ! podman container exists "$(cname calibre-web)" 2>/dev/null; then
    echo "[Calibre-Web] Container doesn't exist, skipping."
    return 0
  fi
  # app.db's own schema (created by Calibre-Web itself on first boot) may
  # not exist yet the moment the container is created, especially since it
  # reinstalls its Calibre mod on every start.
  if ! retry 180 "[Calibre-Web]" calibre_web_db_ready; then
    echo "[Calibre-Web] app.db not initialized yet after 180s, skipping."
    return 0
  fi

  local configured
  configured=$(
    python3 - <<PYEOF
import sqlite3
conn = sqlite3.connect('$CALIBREWEB_DB')
row = conn.execute('SELECT config_calibre_dir FROM settings WHERE id = 1').fetchone()
conn.close()
print('yes' if row and row[0] else 'no')
PYEOF
  )
  if [[ "$configured" == "yes" && "$(calibre_web_user_count)" -gt 0 ]]; then
    echo "[Calibre-Web] Already configured, skipping."
    return 0
  fi

  echo "[Calibre-Web] Configuring library path..."
  stop_container calibre-web
  # app.db was just created live by the container under its own remapped
  # UID; the one-time `permissions.py repair` earlier in bootstrap ran
  # before this file existed, so it isn't host-writable yet without this.
  ./scripts/permissions.py repair --runtime podman --recursive >/dev/null 2>&1 || true
  ensure_calibre_web_users
  python3 - <<PYEOF
import sqlite3
conn = sqlite3.connect('$CALIBREWEB_DB')
conn.execute(
    "UPDATE settings SET config_calibre_dir = ? WHERE id = 1",
    ('$CALIBRE_LIBRARY_DIR',),
)
conn.commit()
conn.close()
PYEOF
  podman start "$(cname calibre-web)" >/dev/null
  echo "[Calibre-Web] Done."
}

# Homepage's Mylar widget (gethomepage's own bundled component.jsx, verified
# directly) unconditionally calls three Mylar API commands and shows an
# error badge if any of them fails; one, seriesjsonListing, does
# `SELECT ... FROM comics` and returns Mylar's own success:false "no data
# returned" whenever that table is empty, which it always is on a fresh
# bootstrap, since nothing has added a comic yet. There's no Homepage config
# to skip that call. Mylar's own addComic API requires a real Comic Vine
# lookup (network access, a real series ID), which doesn't fit a synthetic,
# zero-legal-risk placeholder, so this inserts one directly into mylar.db
# instead, following this project's stop-edit-start convention for a
# running app's database. Status stays "Paused" so Mylar never actually
# searches or downloads anything for it.
#
# The restart below has to be waited out, not just fired. Mylar's own
# unpatched mylar/__init__.py runs a synchronous, timeout-less SABnzbd
# connectivity check (sabnzbd.py's sab_versioncheck, which calls
# webserve.py's SABtest) on its main thread, before it ever calls
# webstart.initialize() to open its HTTPS port. Confirmed live: when that
# connect attempt does not fail fast, Mylar's own log shows the SABtest
# warning landing well over a minute after the "Remapping the sorting"
# line that precedes it, and nothing answers on MYLAR_HTTPS_PORT until
# after that. This function's own restart is the last synchronous step of
# bootstrap, immediately before the test suite starts, so without a wait
# here, Homepage's Mylar widget test starts its own, much shorter, retry
# budget on a container whose webserver has not opened its port yet, and
# reports a 500 (issue #130). Every other widget's backing container had
# that same startup delay behind it long before the test suite ever ran.
ensure_mylar_placeholder_comic() {
  if ! podman container exists "$(cname mylar)" 2>/dev/null; then
    echo "[Mylar] Container doesn't exist, skipping."
    return 0
  fi
  local count
  count=$(
    python3 - <<PYEOF
import sqlite3
conn = sqlite3.connect('$MYLAR_DB')
print(conn.execute("SELECT COUNT(*) FROM comics").fetchone()[0])
PYEOF
  )
  if [[ "$count" -gt 0 ]]; then
    echo "[Mylar] Already has comics, skipping placeholder."
    return 0
  fi

  echo "[Mylar] Adding a placeholder comic so its Homepage widget has data..."
  stop_container mylar
  python3 - <<PYEOF
import sqlite3
from datetime import date

conn = sqlite3.connect('$MYLAR_DB')
conn.execute(
    "INSERT INTO comics (ComicID, ComicName, ComicYear, DateAdded, Status, Have, Total, ComicPublisher) "
    "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    (
        "0000000",
        "Example Series (placeholder, not a real comic)",
        str(date.today().year),
        str(date.today()),
        "Paused",
        0,
        0,
        "wire-connections.sh placeholder",
    ),
)
conn.commit()
conn.close()
PYEOF
  podman start "$(cname mylar)" >/dev/null
  # Same status codes the container's own healthcheck accepts (see the
  # mylar service's healthcheck in docker-compose-servarr.yml), so "ready"
  # here means the same thing it means everywhere else in this stack, and
  # a 401 (WebUI auth enabled) does not read as unready the way plain
  # curl --fail would treat it. 420s, not the healthcheck's own shorter
  # window: confirmed live, mylar.SABtest makes two of those timeout-less
  # connection attempts back to back on startup (an HTTPS one, then an
  # HTTP fallback once the first fails), each taking a full OS connect
  # timeout on its own, well over two minutes apiece, so the pair alone
  # can burn upward of four and a half minutes before Mylar ever calls
  # webstart.initialize() to open its HTTPS port. --max-time bounds each
  # attempt on its own: this probe is checking for exactly the kind of
  # connection that never completes, so an unbounded curl could block past
  # the 420s budget below instead of retrying within it.
  # `timeout 15`, not just curl's own --max-time 10, wraps the whole
  # `podman exec`: --max-time only bounds curl itself once it starts, and
  # podman exec establishing that connection is a step this probe cannot
  # otherwise put a bound on.
  mylar_answering() {
    local status
    status=$(timeout 15 podman exec "$(cname mylar)" curl -sk --max-time 10 -o /dev/null \
      -w '%{http_code}' "https://127.0.0.1:${MYLAR_HTTPS_PORT}/mylar/") || return 1
    [[ "$status" == "200" || "$status" == "303" || "$status" == "401" ]]
  }
  # A hand rolled wait rather than the shared `retry` above: that helper
  # counts only its own 5s sleeps toward the timeout, not the time an
  # attempt itself takes, which is fine for the rest of this file's
  # sub-second checks but not here, where a single attempt is deliberately
  # allowed to take up to 10s. Counting elapsed wall clock time instead
  # keeps the 420s figure in the comment above an actual bound rather than
  # a lower one.
  local start=$SECONDS elapsed
  until mylar_answering; do
    elapsed=$((SECONDS - start))
    if ((elapsed >= 420)); then
      echo "[Mylar] WARNING: did not answer within 420s of restarting; its Homepage widget may still fail."
      break
    fi
    sleep 5
    elapsed=$((SECONDS - start))
    if ((elapsed % 30 < 5)); then
      echo "[Mylar] ...still waiting (${elapsed}s/420s)"
    fi
  done
  echo "[Mylar] Done."
}

# ---------------------------------------------------------------------------
# Arr app host prerequisites
#
# Two things block every download client POST below until they're in place,
# and both live in config/host rather than config.xml (config.xml only holds
# the small set of bootstrap settings the app needs before its database is
# available):
#   - CertificateValidation defaults to "enabled", which rejects this stack's
#     self-signed cert on qBittorrent/SABnzbd's internal addresses.
#   - AuthenticationMethod=Forms requires a non-empty username/password
#     before config/host accepts ANY update, including one that only touches
#     CertificateValidation (FluentValidation validates the whole object).
#     Nothing else in this stack creates that initial WebUI login, so it's
#     done here using the same per-app placeholder credential (username =
#     password = app name) the README's login table already documents.
# ---------------------------------------------------------------------------

# Args: app_name container scheme port api_ver api_key
ensure_arr_host_prereqs() {
  local app_name="$1" container="$2" scheme="$3" port="$4" api_ver="$5" api_key="$6"
  local base_url="${scheme}://127.0.0.1:${port}/${app_name}/api/${api_ver}/config/host"

  local current
  current=$(container_curl "$container" -sk --fail -H "X-Api-Key: ${api_key}" "$base_url")
  if [[ "$(echo "$current" | jq -r '.username')" != "" ]]; then
    echo "[$app_name] WebUI login already set up, skipping."
    return 0
  fi

  echo "[$app_name] Setting up initial WebUI login and relaxing certificate validation for internal addresses..."
  local id updated
  id=$(echo "$current" | jq -r '.id')
  updated=$(echo "$current" | jq \
    --arg cred "$app_name" \
    '.username = $cred | .password = $cred | .passwordConfirmation = $cred |
    .certificateValidation = "disabledForLocalAddresses"')

  container_curl "$container" -sk --fail -X PUT \
    -H "X-Api-Key: ${api_key}" -H "Content-Type: application/json" \
    -d "$updated" "${base_url}/${id}" >/dev/null # pragma: allowlist secret
  echo "[$app_name] Done."
}

# Readarr's own upstream metadata hub went offline when the project was
# retired (see README's Known Issues); the community-run rreading-glasses
# mirror (https://api.bookinfo.pro) restores search and library refresh.
# This is Settings > Development > Metadata Provider Source in Readarr's
# own UI, backed by GET/PUT /api/v1/config/development/{id}
# (DevelopmentConfigResource.MetadataSource in Readarr's own source,
# src/Readarr.Api.V1/Config/DevelopmentConfigController.cs). Not yet
# confirmed live against a running Readarr; the field name assumes the
# same camelCase JSON convention every other Servarr resource in this
# script already uses.
ensure_readarr_metadata_source() {
  local container="$1" scheme="$2" port="$3" api_ver="$4" api_key="$5"
  local base_url="${scheme}://127.0.0.1:${port}/readarr/api/${api_ver}/config/development"
  local target="https://api.bookinfo.pro"

  local current
  current=$(container_curl "$container" -sk --fail -H "X-Api-Key: ${api_key}" "$base_url")
  if [[ "$(echo "$current" | jq -r '.metadataSource')" == "$target" ]]; then
    echo "[Readarr] Metadata provider source already set, skipping."
    return 0
  fi

  echo "[Readarr] Setting metadata provider source to the rreading-glasses mirror..."
  local id updated
  id=$(echo "$current" | jq -r '.id')
  updated=$(echo "$current" | jq --arg source "$target" '.metadataSource = $source')

  local response
  if ! response=$(container_curl "$container" -sk --fail -X PUT \
    -H "X-Api-Key: ${api_key}" -H "Content-Type: application/json" \
    -d "$updated" "${base_url}/${id}" 2>&1); then
    echo "[Readarr] WARNING: failed to set metadata provider source: ${response:0:300}"
    return 1
  fi
  echo "[Readarr] Metadata provider source set."
}

# ---------------------------------------------------------------------------
# Download clients (Sonarr/Radarr/Lidarr/Readarr/Whisparr -> qBittorrent/SABnzbd)
#
# Rather than hand-building the fields array, this fetches the app's own
# /downloadclient/schema for the implementation, which already carries every
# field at its sensible default, and only overrides the handful of fields
# that are actually connection-specific. The category is always passed
# explicitly rather than trusted from either implementation's schema
# default: qBittorrent's own categories.json uses each app's bare name
# (radarr, sonarr, ...), but e.g. Sonarr's own qBittorrent schema defaults
# tvCategory to "tv-sonarr" instead of "sonarr": qBittorrent doesn't
# validate the category on creation, it just silently auto-creates an empty
# one, which would silently break the pre-configured save-path layout.
# SABnzbd's genre-based categories (tv, movies, ebooks, ...) are unrelated
# to qBittorrent's app-named ones, so each caller passes both explicitly.
# ---------------------------------------------------------------------------

# Args: app_name container scheme port api_ver api_key category
ensure_qbittorrent_client() {
  local app_name="$1" container="$2" scheme="$3" port="$4" api_ver="$5" api_key="$6" category="$7"
  local base_url="${scheme}://127.0.0.1:${port}/${app_name}/api/${api_ver}/downloadclient"

  local existing
  existing=$(container_curl "$container" -sk --fail -H "X-Api-Key: ${api_key}" "$base_url" |
    jq 'map(select(.implementation == "QBittorrent")) | first')
  if [[ -n "$existing" && "$existing" != "null" ]]; then
    # Found is not the same as correct: the host, and the port since it is
    # set from config at creation the same way, can drift out from under an
    # already wired client whenever GLUETUN_SERVICES_IP changes, for example
    # a subnet change or a second checkout whose gateway differs (issue
    # #112). Reconciling only when a stored value differs, rather than
    # unconditionally, keeps a rerun quiet when nothing changed. The update
    # payload is built from $existing itself, not the schema used for
    # creation, so username and password stay exactly what the client
    # already has instead of being read from files and resupplied here.
    local existing_host existing_port
    existing_host=$(jq -r '.fields[] | select(.name == "host") | .value' <<<"$existing")
    existing_port=$(jq -r '.fields[] | select(.name == "port") | .value' <<<"$existing")
    if [[ "$existing_host" == "$GLUETUN_SERVICES_IP" && "$existing_port" == "$QBITTORRENT_HTTPS_PORT" ]]; then
      echo "[$app_name] qBittorrent download client already exists, skipping."
      return 0
    fi

    echo "[$app_name] qBittorrent download client host/port stale (${existing_host}:${existing_port}), correcting to ${GLUETUN_SERVICES_IP}:${QBITTORRENT_HTTPS_PORT}..."
    local id payload
    id=$(jq -r '.id' <<<"$existing")
    payload=$(jq \
      --arg host "$GLUETUN_SERVICES_IP" \
      --arg port "$QBITTORRENT_HTTPS_PORT" \
      '.fields |= map(
        if .name == "host" then .value = $host
        elif .name == "port" then .value = ($port | tonumber)
        else . end)' <<<"$existing")

    local response
    if ! response=$(container_curl "$container" -sk --fail -X PUT \
      -H "X-Api-Key: ${api_key}" -H "Content-Type: application/json" \
      -d "$payload" "${base_url}/${id}" 2>&1); then
      echo "[$app_name] WARNING: failed to update qBittorrent download client host: ${response:0:300}"
      return 1
    fi
    echo "[$app_name] Updated."
    return 0
  fi

  local username password
  username=$(cat "$QBITTORRENT_USERNAME_FILE")
  password=$(cat "$QBITTORRENT_PASSWORD_FILE")

  echo "[$app_name] Creating qBittorrent download client..."
  local schema
  schema=$(container_curl "$container" -sk --fail -H "X-Api-Key: ${api_key}" "${base_url}/schema" |
    jq 'map(select(.implementation == "QBittorrent")) | first')

  local payload
  payload=$(echo "$schema" | jq \
    --arg host "$GLUETUN_SERVICES_IP" \
    --arg port "$QBITTORRENT_HTTPS_PORT" \
    --arg username "$username" \
    --arg password "$password" \
    --arg category "$category" \
    '.name = "QBittorrent" | .enable = true |
    .fields |= map(
      if .name == "host" then .value = $host
      elif .name == "port" then .value = ($port | tonumber)
      elif .name == "useSsl" then .value = true
      elif .name == "username" then .value = $username
      elif .name == "password" then .value = $password
      elif (.name | test("Category$")) and ((.name | test("Imported")) | not) then .value = $category
      else . end)')

  # Caught explicitly rather than left to a bare --fail under this script's
  # set -e: a caller that isolates a failure here with `cmd || warn` does
  # not actually protect the commands *inside* this function (a documented
  # bash errexit gotcha: set -e stops applying to everything on the left
  # of a && / || / if, including nested subshells), so an unhandled failure
  # here would otherwise fall through to the unconditional "Created." line
  # below despite nothing having been created.
  local response
  if ! response=$(container_curl "$container" -sk --fail -X POST \
    -H "X-Api-Key: ${api_key}" -H "Content-Type: application/json" \
    -d "$payload" "$base_url" 2>&1); then # pragma: allowlist secret
    echo "[$app_name] WARNING: failed to create qBittorrent download client: ${response:0:300}"
    return 1
  fi
  echo "[$app_name] Created."
}

# Args: app_name container scheme port api_ver api_key category
ensure_sabnzbd_client() {
  local app_name="$1" container="$2" scheme="$3" port="$4" api_ver="$5" api_key="$6" category="$7"
  local base_url="${scheme}://127.0.0.1:${port}/${app_name}/api/${api_ver}/downloadclient"

  local existing
  existing=$(container_curl "$container" -sk --fail -H "X-Api-Key: ${api_key}" "$base_url" |
    jq 'map(select(.implementation == "Sabnzbd")) | first')
  if [[ -n "$existing" && "$existing" != "null" ]]; then
    # See ensure_qbittorrent_client's matching comment: same drift, same
    # reasoning for reconciling conditionally and for basing the update
    # payload on $existing so its apiKey is preserved rather than reread and
    # resupplied.
    local existing_host existing_port
    existing_host=$(jq -r '.fields[] | select(.name == "host") | .value' <<<"$existing")
    existing_port=$(jq -r '.fields[] | select(.name == "port") | .value' <<<"$existing")
    if [[ "$existing_host" == "$GLUETUN_SERVICES_IP" && "$existing_port" == "$SABNZBD_HTTP_PORT" ]]; then
      echo "[$app_name] SABnzbd download client already exists, skipping."
      return 0
    fi

    echo "[$app_name] SABnzbd download client host/port stale (${existing_host}:${existing_port}), correcting to ${GLUETUN_SERVICES_IP}:${SABNZBD_HTTP_PORT}..."
    local id payload
    id=$(jq -r '.id' <<<"$existing")
    payload=$(jq \
      --arg host "$GLUETUN_SERVICES_IP" \
      --arg port "$SABNZBD_HTTP_PORT" \
      '.fields |= map(
        if .name == "host" then .value = $host
        elif .name == "port" then .value = ($port | tonumber)
        else . end)' <<<"$existing")

    local response
    if ! response=$(container_curl "$container" -sk --fail -X PUT \
      -H "X-Api-Key: ${api_key}" -H "Content-Type: application/json" \
      -d "$payload" "${base_url}/${id}" 2>&1); then # pragma: allowlist secret
      echo "[$app_name] WARNING: failed to update SABnzbd download client host: ${response:0:300}"
      return 1
    fi
    echo "[$app_name] Updated."
    return 0
  fi

  local sab_api_key
  sab_api_key=$(cat "$SABNZBD_API_KEY_FILE")

  echo "[$app_name] Creating SABnzbd download client..."
  local schema
  schema=$(container_curl "$container" -sk --fail -H "X-Api-Key: ${api_key}" "${base_url}/schema" |
    jq 'map(select(.implementation == "Sabnzbd")) | first')

  local payload
  payload=$(echo "$schema" | jq \
    --arg host "$GLUETUN_SERVICES_IP" \
    --arg port "$SABNZBD_HTTP_PORT" \
    --arg urlBase "/sabnzbd" \
    --arg apiKey "$sab_api_key" \
    --arg category "$category" \
    '.name = "SABnzbd" | .enable = true |
    .fields |= map(
      if .name == "host" then .value = $host
      elif .name == "port" then .value = ($port | tonumber)
      elif .name == "useSsl" then .value = false
      elif .name == "urlBase" then .value = $urlBase
      elif .name == "apiKey" then .value = $apiKey
      elif (.name | test("Category$")) and ((.name | test("Imported")) | not) then .value = $category
      else . end)')

  # See ensure_qbittorrent_client's matching comment: this is caught
  # explicitly, not left to a bare --fail, since a caller-side `|| warn`
  # cannot protect commands inside this function from set -e's own
  # exit-on-failure semantics being suppressed for everything on the left
  # of that ||.
  local response
  if ! response=$(container_curl "$container" -sk --fail -X POST \
    -H "X-Api-Key: ${api_key}" -H "Content-Type: application/json" \
    -d "$payload" "$base_url" 2>&1); then # pragma: allowlist secret
    echo "[$app_name] WARNING: failed to create SABnzbd download client: ${response:0:300}"
    return 1
  fi
  echo "[$app_name] Created."
}

# ---------------------------------------------------------------------------
# Arr app dispatch: host prereqs plus both download clients for one app.
# curl's -k is harmless against a plain http:// URL (Sonarr's own scheme),
# so every caller can pass it uniformly rather than branching on scheme.
# ---------------------------------------------------------------------------

# Args: app_name container scheme port api_ver qbit_category sab_category
# Finds an address the *arr container can actually reach Jellyfin on.
#
# There is no container-to-container route to try: Jellyfin is on the media
# network and the *arr apps are on apps/services, so the connection has to go
# out to the port Jellyfin publishes on the host. Which address reaches the
# host from inside a container is not something to assume, so probe instead.
#
# LAN_IP first, because that is what a hand-configured install ends up using
# and it keeps working if the host alias is unavailable. Then podman's own
# alias for the host, which is what works when LAN_IP is still the
# .env.example placeholder, CI being the case that matters. host.docker
# .internal covers RUNTIME=docker.
# Sets JELLYFIN_REACHABLE_HOST as a side effect rather than printing the
# candidate to stdout, the same reasoning as detect_jellyfin_base_url's own
# comment: the caller wraps this in retry(), and retry() only checks exit
# status, not output.
jellyfin_host_for() {
  local container="$1" candidate
  for candidate in "$LAN_IP" host.containers.internal host.docker.internal; do
    [[ -n "$candidate" && "$candidate" != "192.168.1.x" ]] || continue
    if container_curl "$container" -s --fail --max-time 5 \
      "http://${candidate}:${JELLYFIN_HTTP_PORT}${JELLYFIN_BASE_URL}/System/Info/Public" \
      >/dev/null 2>&1; then
      JELLYFIN_REACHABLE_HOST="$candidate"
      return 0
    fi
  done
  return 1
}

# Names of arr apps whose Jellyfin connection did not succeed this run, so
# the end of the run can report them instead of letting wire_arr_app's own
# handling of ensure_jellyfin_connection make a partial result look
# identical to a complete one, matching PROWLARR_FAILED's own reasoning
# above.
JELLYFIN_FAILED=()

# Names of arr apps whose job failed somewhere other than the Jellyfin
# connection, kept apart from JELLYFIN_FAILED so neither summary claims a
# cause that is not its own. See wire_arr_app for why the two are
# distinguishable at all.
ARR_JOB_FAILED=()

# Exit status wire_arr_app uses for "everything else worked, the Jellyfin
# connection did not". Any other non-zero status from that job means it died
# earlier, under `set -e`, before the Jellyfin call was reached. 90 is chosen
# to sit clear of both the shell's own 1 and 2 and the 126 to 165 range it
# reserves for "cannot execute", "not found" and fatal signals.
readonly JELLYFIN_WIRING_FAILED=90

# Tells Jellyfin to rescan when an import, upgrade or rename changes the
# library. Without it Jellyfin only notices on its own scheduled scan, so a
# finished download can sit there invisible for hours.
ensure_jellyfin_connection() {
  local app_name="$1" container="$2" scheme="$3" port="$4" api_ver="$5" api_key="$6"
  local base_url="${scheme}://127.0.0.1:${port}/${app_name}/api/${api_ver}/notification"

  if ! podman container exists "$(cname jellyfin)" 2>/dev/null; then
    echo "[$app_name] Jellyfin is not running, skipping its connection."
    return 0
  fi
  if [[ ! -s "$JELLYFIN_API_KEY_FILE" ]]; then
    echo "[$app_name] No Jellyfin API key yet, skipping its connection."
    return 0
  fi

  # Both API reads below are checked rather than left bare. This function is
  # called in an `||` list, which suspends `set -e` for everything inside it,
  # so an unguarded `existing=$(...)` that failed would carry on with an empty
  # value and return a confident looking skip. That is the very silent success
  # this change exists to remove, so a read that fails is reported as a
  # failure. `set -o pipefail` at the top of this file is what makes the
  # curl half of each pipeline count, not just jq's status.
  local existing
  if ! existing=$(container_curl "$container" -sk --fail -H "X-Api-Key: ${api_key}" "$base_url" |
    jq 'map(select(.implementation == "MediaBrowser")) | first'); then
    echo "[$app_name] WARNING: could not read its notification list; skipping its Jellyfin connection."
    return 1
  fi
  if [[ -n "$existing" && "$existing" != "null" ]]; then
    echo "[$app_name] Jellyfin connection already exists, skipping."
    return 0
  fi

  local schema
  if ! schema=$(container_curl "$container" -sk --fail -H "X-Api-Key: ${api_key}" "${base_url}/schema" |
    jq 'map(select(.implementation == "MediaBrowser")) | first'); then
    echo "[$app_name] WARNING: could not read its notification schema; skipping its Jellyfin connection."
    return 1
  fi

  # Not every app offers this. Readarr has no MediaBrowser implementation at
  # all, since Jellyfin does not take a book library from it; its equivalents
  # are Kavita and Subsonic. Asking rather than assuming keeps the list of
  # apps here honest as upstream changes.
  #
  # Deliberately answered before the reachability retry below, not after. An
  # app that cannot use a Jellyfin connection at all must not sit through a
  # 120s wait for Jellyfin, and must never be reported as having missed a
  # connection it was never going to make: reachability failing returns
  # non-zero, so with the order reversed an unreachable Jellyfin would file
  # Readarr under JELLYFIN_FAILED.
  if [[ -z "$schema" || "$schema" == "null" ]]; then
    echo "[$app_name] Does not support Jellyfin connections, skipping."
    return 0
  fi

  # Confirmed live (GitHub Actions runs 32176749677 and 32179005406, both on
  # 2026-08-18): this is the actual failure behind
  # test_jellyfin_connection_matches_what_the_app_supports[lidarr], not the
  # POST below. Both runs logged this exact warning for lidarr and nothing
  # else unusual before it; Jellyfin's own setup had already produced a real
  # API key by that point (the check above already passed), so what was not
  # yet ready was the host path this container reaches Jellyfin through, not
  # Jellyfin itself. jellyfin_host_for previously tried each candidate host
  # exactly once with a 5 second cap each, unlike almost every other
  # first-boot readiness check in this file, which retries for up to 180s.
  # Wrapping it the same way self-heals the race instead of giving up on the
  # first attempt.
  local JELLYFIN_REACHABLE_HOST=""
  if ! retry 120 "[$app_name]" jellyfin_host_for "$container"; then
    echo "[$app_name] WARNING: Jellyfin is running but not reachable from this container; skipping its connection."
    return 1
  fi
  local jellyfin_host="$JELLYFIN_REACHABLE_HOST"

  echo "[$app_name] Creating Jellyfin connection..."

  # Triggers come from the schema rather than a fixed list, because the apps
  # do not agree on them: Sonarr has onDownload, Lidarr has no such thing and
  # uses onReleaseImport, and newer versions add onImportComplete. Asking each
  # app what it supports is the only version-proof way to enable the ones that
  # mean "the library changed on disk".
  local payload
  payload=$(echo "$schema" | jq \
    --arg host "$jellyfin_host" \
    --arg port "$JELLYFIN_HTTP_PORT" \
    --arg url_base "$JELLYFIN_BASE_URL" \
    --arg key "$(cat "$JELLYFIN_API_KEY_FILE")" \
    '.name = "Emby / Jellyfin" |
    .fields |= map(
      if .name == "host" then .value = $host
      elif .name == "port" then .value = ($port | tonumber)
      elif .name == "useSsl" then .value = false
      elif .name == "urlBase" then .value = $url_base
      elif .name == "apiKey" then .value = $key
      elif .name == "updateLibrary" then .value = true
      else . end) |
    (if .supportsOnDownload then .onDownload = true else . end) |
    (if .supportsOnImportComplete then .onImportComplete = true else . end) |
    (if .supportsOnReleaseImport then .onReleaseImport = true else . end) |
    (if .supportsOnUpgrade then .onUpgrade = true else . end) |
    (if .supportsOnRename then .onRename = true else . end)')

  # Same reasoning as ensure_qbittorrent_client: caught here rather than left
  # to --fail under set -e, which stops applying inside a function the caller
  # guarded with `|| warn`.
  local response
  if ! response=$(container_curl "$container" -sk --fail -X POST \
    -H "X-Api-Key: ${api_key}" -H "Content-Type: application/json" \
    -d "$payload" "$base_url" 2>&1); then
    echo "[$app_name] WARNING: failed to create the Jellyfin connection: ${response:0:300}"
    return 1
  fi
  echo "[$app_name] Created."
}

wire_arr_app() {
  local app_name="$1" container="$2" scheme="$3" port="$4" api_ver="$5"
  local qbit_category="$6" sab_category="$7"
  local xml="configs/${app_name}/config/config.xml"

  if ! podman container exists "$(cname "$container")" 2>/dev/null; then
    echo "[$app_name] Container does not exist, skipping."
    return 0
  fi

  if ! retry 180 "[$app_name]" container_curl "$container" -sk --fail -H "X-Api-Key: $(get_xml_apikey "$xml")" \
    "${scheme}://127.0.0.1:${port}/${app_name}/api/${api_ver}/system/status"; then
    echo "[$app_name] Not reachable, skipping."
    return 0
  fi

  local key
  key=$(get_xml_apikey "$xml")
  ensure_arr_host_prereqs "$app_name" "$container" "$scheme" "$port" "$api_ver" "$key"
  ensure_qbittorrent_client "$app_name" "$container" "$scheme" "$port" "$api_ver" "$key" "$qbit_category"
  ensure_sabnzbd_client "$app_name" "$container" "$scheme" "$port" "$api_ver" "$key" "$sab_category"
  # Not "|| true": the caller needs to know whether this actually succeeded,
  # so the dispatch loop below can collect it into JELLYFIN_FAILED instead of
  # this looking the same as every legitimate skip inside the function itself
  # (Jellyfin disabled, no API key yet, connection already there, app doesn't
  # support it), all of which still return 0 on purpose.
  #
  # Reported as JELLYFIN_WIRING_FAILED rather than a plain non-zero status
  # because the three calls above are not guarded, so under `set -e` any one
  # of them failing kills this job before the Jellyfin call is ever reached.
  # A bare "did this job fail" test cannot tell those apart, and would file a
  # failed qBittorrent client under Jellyfin and tell the reader to re-run
  # once Jellyfin is up, which would not fix it.
  local jellyfin_status=0
  ensure_jellyfin_connection "$app_name" "$container" "$scheme" "$port" "$api_ver" "$key" || jellyfin_status=$?

  if [[ "$app_name" == "readarr" ]]; then
    ensure_readarr_metadata_source "$container" "$scheme" "$port" "$api_ver" "$key" || true
  fi

  if [[ "$jellyfin_status" -ne 0 ]]; then
    return "$JELLYFIN_WIRING_FAILED"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Prowlarr Applications (Sonarr/Radarr/Lidarr/Readarr/Whisparr/LazyLibrarian/
# Mylar registered so Prowlarr can push indexer sync to them). Skipped
# entirely if the prowlarr container doesn't exist, matching how
# scripts/rotate-api-keys.sh's update_prowlarr_application() already treats
# a missing entry as a no-op rather than an error.
# ---------------------------------------------------------------------------

# Names of applications whose registration didn't succeed this run, so the
# end of wire_prowlarr_apps can report them instead of letting a partial
# result look identical to a complete one.
PROWLARR_FAILED=()

wire_prowlarr_apps() {
  if ! podman container exists "$(cname prowlarr)" 2>/dev/null; then
    echo "[Prowlarr] Container doesn't exist (PROWLARR_PROFILE=disabled), skipping."
    return 0
  fi
  # Prowlarr runs real SQLite migrations on first boot, including creating
  # and populating its IndexerDefinitionVersions table (confirmed live in
  # its own startup log), which is slower than the other arr apps' first
  # boot and competes with every other container in the stack also doing
  # its own first-boot work at the same time during a real bootstrap. 180s
  # was not always enough in practice: a real run left Prowlarr with zero
  # Applications and zero indexers, recovered cleanly by just re-running
  # this script once Prowlarr had finished starting. 480s gives it real
  # headroom instead of relying on someone noticing and re-running by hand.
  if ! retry 480 "[Prowlarr]" container_curl prowlarr -sk --fail -H "X-Api-Key: $(get_xml_apikey "$PROWLARR_XML")" \
    "https://127.0.0.1:${PROWLARR_HTTPS_PORT}/prowlarr/api/v1/system/status"; then
    echo "[Prowlarr] Not reachable after 480s, skipping. Re-run 'make wire_connections'"
    echo "[Prowlarr] once it's up to register its Applications and indexer."
    return 0
  fi

  local prowlarr_key
  prowlarr_key=$(get_xml_apikey "$PROWLARR_XML")

  # Every other arr app gets this from wire_arr_app; Prowlarr itself never
  # went through that dispatch, so without this its own WebUI login was
  # never initialized (username stays empty), which rotate_prowlarr's
  # password-only PUT can't fix on its own since it never sets a username.
  # Confirmed live: password rotation silently "succeeded" but login
  # validation then failed for the full 180s retry, since the real
  # username was still empty, not "prowlarr".
  ensure_arr_host_prereqs prowlarr prowlarr https "$PROWLARR_HTTPS_PORT" v1 "$prowlarr_key"

  # Prowlarr's own Download Clients (used by its "Interactive Search" grab
  # button, independent of the arr apps' own download clients wired by
  # wire_arr_app). Same generic helpers those use: Prowlarr shares the same
  # DownloadClients schema shape as every other Servarr app.
  #
  # Each of these three calls is allowed to fail without aborting the
  # Application registrations and indexer below (the same class of bug
  # ensure_prowlarr_application's own comment already documents and guards
  # against, confirmed live here too: an unhandled SABnzbd 400, it
  # validates its category strictly, unlike qBittorrent, which creates an
  # empty one silently, took out every Application and the indexer for the
  # whole run). That protection has to live *inside* each ensure_* function
  # itself (an explicit `if ! cmd; then return 1; fi` around its one
  # create-or-die step), not in a `cmd || warn` wrapper here: bash disables
  # `set -e` for everything inside a command placed on the left of `||`,
  # including nested subshells, so a wrapper here cannot make a failure
  # inside the function stop where it actually happened.
  ensure_qbittorrent_client prowlarr prowlarr https "$PROWLARR_HTTPS_PORT" v1 "$prowlarr_key" prowlarr || true
  ensure_sabnzbd_client prowlarr prowlarr https "$PROWLARR_HTTPS_PORT" v1 "$prowlarr_key" prowlarr || true

  ensure_prowlarr_indexer_proxy "$prowlarr_key" || true

  # https, not http, despite the port variable's name: LazyLibrarian
  # repurposes its single configured port for HTTPS once https_enabled=True
  # (the shipped default in config.ini.example), the same way Calibre-Web
  # does, rather than adding a second port. nginx's own upstream definition
  # already accounts for this (LAZYLIBRARIAN_UPSTREAM_SCHEME=https paired
  # with LAZYLIBRARIAN_HTTP_PORT); this call didn't, and Prowlarr's POST
  # failed outright when it tried to verify connectivity to the wrong
  # scheme, aborting the rest of this function under set -e, confirmed live
  # by the "Connection reset by peer" a plain http request gets back.
  ensure_prowlarr_application lazylibrarian "LazyLibrarian" "LazyLibrarian" "LazyLibrarianSettings" \
    "https://lazylibrarian:${LAZYLIBRARIAN_HTTP_PORT}/lazylibrarian" \
    "$(get_ini_apikey "$LAZYLIBRARIAN_INI")" "$prowlarr_key"

  ensure_prowlarr_application lidarr "Lidarr" "Lidarr" "LidarrSettings" \
    "https://lidarr:${LIDARR_HTTPS_PORT}/lidarr" "$(get_xml_apikey "$LIDARR_XML")" "$prowlarr_key"

  ensure_prowlarr_application mylar "Mylar" "Mylar" "MylarSettings" \
    "https://mylar:${MYLAR_HTTPS_PORT}/mylar" "$(get_ini_apikey "$MYLAR_INI")" "$prowlarr_key"

  ensure_prowlarr_application radarr "Radarr" "Radarr" "RadarrSettings" \
    "https://radarr:${RADARR_HTTPS_PORT}/radarr" "$(get_xml_apikey "$RADARR_XML")" "$prowlarr_key"

  ensure_prowlarr_application readarr "Readarr" "Readarr" "ReadarrSettings" \
    "https://readarr:${READARR_HTTPS_PORT}/readarr" "$(get_xml_apikey "$READARR_XML")" "$prowlarr_key"

  ensure_prowlarr_application sonarr "Sonarr" "Sonarr" "SonarrSettings" \
    "http://sonarr:${SONARR_HTTP_PORT}/sonarr" "$(get_xml_apikey "$SONARR_XML")" "$prowlarr_key"

  ensure_prowlarr_application whisparr "Whisparr" "Whisparr" "WhisparrSettings" \
    "https://whisparr:${WHISPARR_HTTPS_PORT}/whisparr" "$(get_xml_apikey "$WHISPARR_XML")" "$prowlarr_key" \
    "https://prowlarr:${PROWLARR_HTTPS_PORT}"

  # A fresh Prowlarr has zero indexers, so there's nothing for the
  # Applications above to actually sync until at least one exists. Internet
  # Archive is a public, legal source (a nonprofit digital library; public
  # domain and openly-licensed works only) that Prowlarr's own bundled
  # definition tags with real Movies/TV/Audio/Books/PC categories (verified
  # live against its own /indexer/schema), unlike LinuxTracker (tried first,
  # confirmed live to only carry a PC/ISO category), which Prowlarr's own
  # Application sync silently excludes from every arr app for since none of
  # them search PC/software content: LinuxTracker satisfied "have a legal
  # indexer" but never actually verified any app-to-app connection, since it
  # had nothing in common with what any arr app searches for.
  ensure_prowlarr_indexer internetarchive "Internet Archive" "https://archive.org/" "$prowlarr_key"
  sync_prowlarr_indexers "$prowlarr_key"

  if [[ ${#PROWLARR_FAILED[@]} -gt 0 ]]; then
    echo "[Prowlarr] WARNING: these applications were NOT registered:"
    local failed
    for failed in "${PROWLARR_FAILED[@]}"; do
      echo "[Prowlarr]   - ${failed}"
    done
    echo "[Prowlarr] Re-run 'make wire_connections' once those apps are up."
  fi
}

# Creates a Prowlarr tag by label, or returns the id of the one that
# already carries that label: POSTing an existing label is idempotent
# (Prowlarr returns the same id rather than a duplicate), confirmed live.
# Args: prowlarr_api_key label
ensure_prowlarr_tag() {
  local prowlarr_api_key="$1" label="$2"
  local payload
  payload=$(jq -n --arg label "$label" '{label: $label}')
  container_curl prowlarr -sk --fail -X POST \
    -H "X-Api-Key: ${prowlarr_api_key}" -H "Content-Type: application/json" \
    -d "$payload" "https://127.0.0.1:${PROWLARR_HTTPS_PORT}/prowlarr/api/v1/tag" |
    jq -r '.id'
}

# Registers FlareSolverr as a Prowlarr Indexer Proxy, so it's available to
# select on any indexer that needs a Cloudflare bypass. Prowlarr doesn't
# apply a proxy to an indexer on its own; that's still a per-indexer choice
# left to you (Settings > Indexers > <indexer> > Proxy), the same way
# LazyLibrarian's own book sources are ("Book sources" in
# docs/LAZYLIBRARIAN.md): this only makes sure the proxy itself exists to
# choose from. Skipped entirely if FlareSolverr's container doesn't exist
# (FLARESOLVERR_PROFILE=disabled), matching every other ensure_* helper here.
# Args: prowlarr_api_key
ensure_prowlarr_indexer_proxy() {
  local prowlarr_api_key="$1"
  local base_url="https://127.0.0.1:${PROWLARR_HTTPS_PORT}/prowlarr/api/v1/indexerproxy"

  if ! podman container exists "$(cname flaresolverr)" 2>/dev/null; then
    echo "[Prowlarr] FlareSolverr container doesn't exist, skipping indexer proxy."
    return 0
  fi

  # Tagged "flaresolverr" so it (and, going forward, anything else tagged
  # the same way) is easy to find/filter on in Prowlarr's own UI. Creating
  # an existing label is idempotent (Prowlarr returns the same id instead
  # of a duplicate, confirmed live), so this always runs, not just on first
  # creation.
  local tag_id
  if ! tag_id=$(ensure_prowlarr_tag "$prowlarr_api_key" "flaresolverr"); then
    echo "[Prowlarr] WARNING: could not create the 'flaresolverr' tag, continuing without it."
    tag_id=""
  fi

  local existing
  existing=$(container_curl prowlarr -sk --fail -H "X-Api-Key: ${prowlarr_api_key}" "$base_url" |
    jq 'map(select(.implementation == "FlareSolverr")) | first')
  if [[ -n "$existing" && "$existing" != "null" ]]; then
    if [[ -n "$tag_id" ]] && ! echo "$existing" | jq -e --argjson t "$tag_id" '.tags | index($t)' >/dev/null; then
      echo "[Prowlarr] FlareSolverr indexer proxy exists but isn't tagged, adding the tag..."
      local retagged
      retagged=$(echo "$existing" | jq --argjson t "$tag_id" '.tags += [$t]')
      local id
      id=$(echo "$existing" | jq -r '.id')
      if ! container_curl prowlarr -sk --fail -X PUT \
        -H "X-Api-Key: ${prowlarr_api_key}" -H "Content-Type: application/json" \
        -d "$retagged" "${base_url}/${id}" >/dev/null; then
        echo "[Prowlarr] WARNING: failed to tag the existing FlareSolverr indexer proxy."
      fi
    else
      echo "[Prowlarr] FlareSolverr indexer proxy already exists, skipping."
    fi
    return 0
  fi

  echo "[Prowlarr] Adding FlareSolverr indexer proxy..."
  local schema
  schema=$(container_curl prowlarr -sk --fail -H "X-Api-Key: ${prowlarr_api_key}" "${base_url}/schema" |
    jq 'map(select(.implementation == "FlareSolverr")) | first')

  local payload
  payload=$(echo "$schema" | jq \
    --arg host "http://flaresolverr:${FLARESOLVERR_HTTP_PORT}" \
    --argjson tags "$([[ -n "$tag_id" ]] && echo "[$tag_id]" || echo "[]")" \
    '.name = "FlareSolverr" | .tags = $tags |
    .fields |= map(if .name == "host" then .value = $host else . end)')

  # See ensure_qbittorrent_client's matching comment on why this is caught
  # explicitly rather than left to a bare --fail.
  local response
  if ! response=$(container_curl prowlarr -sk --fail -X POST \
    -H "X-Api-Key: ${prowlarr_api_key}" -H "Content-Type: application/json" \
    -d "$payload" "$base_url" 2>&1); then
    echo "[Prowlarr] WARNING: failed to add FlareSolverr indexer proxy: ${response:0:300}"
    return 1
  fi
  echo "[Prowlarr] FlareSolverr indexer proxy added."
}

# Args: definition_name display_name base_url prowlarr_api_key
ensure_prowlarr_indexer() {
  local definition_name="$1" display_name="$2" base_url="$3" prowlarr_api_key="$4"
  local indexer_url="https://127.0.0.1:${PROWLARR_HTTPS_PORT}/prowlarr/api/v1/indexer"

  local existing
  existing=$(container_curl prowlarr -sk --fail -H "X-Api-Key: ${prowlarr_api_key}" "$indexer_url" |
    jq --arg name "$display_name" 'map(select(.name == $name)) | first')
  if [[ -n "$existing" && "$existing" != "null" ]]; then
    echo "[Prowlarr] Indexer '${display_name}' already exists, skipping."
    return 0
  fi

  echo "[Prowlarr] Adding indexer '${display_name}'..."
  local schema
  schema=$(container_curl prowlarr -sk --fail -H "X-Api-Key: ${prowlarr_api_key}" "${indexer_url}/schema" |
    jq --arg def "$definition_name" 'map(select(.definitionName == $def)) | first')

  # Created disabled first, then enabled, and both halves matter.
  #
  # Prowlarr only runs its live connectivity test when the provider being
  # saved is enabled, and forceSave does not skip it on a normal create. That
  # test fans out one heavy query per category and archive.org throttles the
  # burst: measured live, the enabled create sat for exactly 100s and then
  # returned 400 "indexer's server is unavailable", even though a single one
  # of those same queries answers in 0.4s from this very container. Under
  # `set -e` that failure also killed this whole background job before the
  # sync below ever ran, leaving Prowlarr with no indexer at all. Creating
  # disabled skips the test entirely (201 in 0.009s measured) and the
  # follow-up enable with forceSave=true skips it too (202 in 0.012s), so the
  # indexer reliably ends up present and enabled. Whether it exists is a
  # local database write; it should not hinge on a third party's rate limiter.
  local payload
  payload=$(echo "$schema" | jq \
    --arg baseUrl "$base_url" \
    '.appProfileId = 1 | .enable = false |
    .fields |= (map(select(.name != "baseUrl")) + [{"name": "baseUrl", "value": $baseUrl}])')

  local created new_id
  created=$(container_curl prowlarr -sk --fail -X POST \
    -H "X-Api-Key: ${prowlarr_api_key}" -H "Content-Type: application/json" \
    -d "$payload" "$indexer_url" 2>/dev/null) || true
  new_id=$(echo "$created" | jq -r '.id // empty' 2>/dev/null)

  if [[ -n "$new_id" ]]; then
    container_curl prowlarr -sk --fail -X PUT \
      -H "X-Api-Key: ${prowlarr_api_key}" -H "Content-Type: application/json" \
      -d "$(echo "$created" | jq '.enable = true')" \
      "${indexer_url}/${new_id}?forceSave=true" >/dev/null 2>&1 || true
  fi

  # Judge success by re-querying, not by the POST's status code: Prowlarr can
  # return a validation error for the connectivity test while having already
  # created the record (confirmed live: a POST answered 400 yet the indexer
  # was present with a real id immediately afterwards). Trusting the status
  # code reported a failure for an indexer that actually existed.
  if container_curl prowlarr -sk --fail -H "X-Api-Key: ${prowlarr_api_key}" "$indexer_url" |
    jq -e --arg name "$display_name" 'any(.[]; .name == $name and .enable)' >/dev/null 2>&1; then
    echo "[Prowlarr] Added."
  else
    echo "[Prowlarr] Failed to add indexer '${display_name}'."
    PROWLARR_FAILED+=("indexer ${display_name}")
  fi
}

# True when no indexer is currently in Prowlarr's failure backoff. An entry in
# indexerstatus means Prowlarr has temporarily disabled that indexer after
# failed queries, and while that's true it answers the arr apps' capability
# probe with 429.
prowlarr_indexers_healthy() {
  local prowlarr_api_key="$1"
  local count
  count=$(container_curl prowlarr -sk --fail -H "X-Api-Key: ${prowlarr_api_key}" \
    "https://127.0.0.1:${PROWLARR_HTTPS_PORT}/prowlarr/api/v1/indexerstatus" | jq 'length')
  [[ "$count" == "0" ]]
}

# True when the given arr app already holds at least one indexer.
# Args: app scheme port api_version api_key
arr_has_indexer() {
  local app="$1" scheme="$2" port="$3" api_version="$4" api_key="$5"
  local count
  count=$(container_curl "$app" -sk --fail -H "X-Api-Key: ${api_key}" \
    "${scheme}://127.0.0.1:${port}/${app}/api/${api_version}/indexer" 2>/dev/null | jq 'length' 2>/dev/null)
  [[ -n "$count" && "$count" != "null" && "$count" -gt 0 ]]
}

# Push Prowlarr's indexers into every registered Application, and confirm they
# actually landed.
#
# Prowlarr does sync implicitly when an indexer is added, but that implicit
# sync is not reliable here and silently produced the "no indexers in any arr
# app" symptom: Internet Archive's advancedsearch API is slow and
# intermittently times out, Prowlarr reacts by putting the indexer into a
# failure backoff, and while it's backed off Prowlarr answers the arr apps'
# capability probe (t=caps) with 429. The arr app then rejects the pushed
# indexer with 400 Invalid Request and nothing retries. Confirmed live end to
# end, including Sonarr's own log rejecting it for exactly that reason, and
# the same sync succeeding for all four arr apps once the backoff cleared.
sync_prowlarr_indexers() {
  local prowlarr_api_key="$1"

  if ! retry 300 "[Prowlarr] waiting for indexer failure backoff to clear" \
    prowlarr_indexers_healthy "$prowlarr_api_key"; then
    echo "[Prowlarr] Indexers still in failure backoff; syncing anyway."
  fi

  # Alphabetical, matching this file's dispatch. Fields: app scheme port apiver
  #
  # Whisparr is deliberately absent here, not an oversight. Its Application
  # entry only syncs indexers matching its syncCategories (adult content,
  # 6000-series only), and the seeded default indexer, Internet Archive,
  # doesn't serve that category at all (confirmed live via its own
  # capabilities.categories: 2000/3000/4000/5000/7000/8000, no 6000s). Zero
  # synced indexers is therefore the structurally correct outcome for
  # Whisparr with the default indexer, not a wiring failure, so it can never
  # satisfy this check and would falsely warn on every run. Registration in
  # wire_prowlarr_apps() above is still Whisparr's real success signal; an
  # indexer actually appears once the user adds one that serves that
  # category.
  local targets=(
    "lidarr https ${LIDARR_HTTPS_PORT} v1"
    "radarr https ${RADARR_HTTPS_PORT} v3"
    "readarr https ${READARR_HTTPS_PORT} v1"
    "sonarr http ${SONARR_HTTP_PORT} v3"
  )

  local attempt
  for attempt in 1 2 3; do
    echo "[Prowlarr] Syncing indexers to registered applications (attempt ${attempt})..."
    container_curl prowlarr -sk --fail -X POST \
      -H "X-Api-Key: ${prowlarr_api_key}" -H "Content-Type: application/json" \
      -d '{"name":"ApplicationIndexerSync"}' \
      "https://127.0.0.1:${PROWLARR_HTTPS_PORT}/prowlarr/api/v1/command" >/dev/null || true
    sleep 15

    local missing=() entry app scheme port api_version xml_var key
    for entry in "${targets[@]}"; do
      read -r app scheme port api_version <<<"$entry"
      podman container exists "$(cname "$app")" 2>/dev/null || continue
      xml_var="$(echo "$app" | tr '[:lower:]' '[:upper:]')_XML"
      key=$(get_xml_apikey "${!xml_var}" 2>/dev/null) || continue
      arr_has_indexer "$app" "$scheme" "$port" "$api_version" "$key" || missing+=("$app")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
      echo "[Prowlarr] Indexers present in every enabled arr app."
      return 0
    fi
    echo "[Prowlarr] Still missing indexers in: ${missing[*]}"
  done

  echo "[Prowlarr] WARNING: some arr apps still have no indexer (${missing[*]})."
  echo "[Prowlarr] Prowlarr re-syncs on its own schedule; or re-run 'make wire_connections'."
}

# Args: container display_name implementation config_contract app_url app_api_key prowlarr_api_key
ensure_prowlarr_application() {
  local container="$1" display_name="$2" implementation="$3" config_contract="$4"
  local app_url="$5" app_api_key="$6"
  local prowlarr_api_key="$7"
  # Every app but Whisparr accepts (and needs, since Prowlarr's own
  # UrlBase is /prowlarr) a urlBase-suffixed prowlarrUrl. Whisparr's own
  # WhisparrV3Proxy application-link validator rejects that suffix
  # outright with "Prowlarr URL is invalid", confirmed live: the exact
  # same payload passes with https://prowlarr:<port> and fails with
  # https://prowlarr:<port>/prowlarr. The URL without a suffix still resolves
  # (Prowlarr 307-redirects bare-root API requests to the prefixed path),
  # and this field is only used for Whisparr's own connectivity sanity
  # check, not for the actual indexer push which Prowlarr always
  # initiates against Whisparr's own baseUrl/apiKey.
  local prowlarr_url_override="${8:-}"
  local base_url="https://127.0.0.1:${PROWLARR_HTTPS_PORT}/prowlarr/api/v1/applications"

  # A disabled app's container doesn't exist, so there's nothing to
  # register and no point asking Prowlarr to test connectivity to a host
  # that isn't there. Every entry in this dispatch runs sequentially in
  # one function, so skipping cleanly here (like every other ensure_*
  # helper in this file already does) matters beyond just this one app:
  # one entry failing outright used to abort every entry after it too,
  # confirmed live when a wrong URL scheme for one app silently prevented
  # every other app from ever being registered.
  if ! podman container exists "$(cname "$container")" 2>/dev/null; then
    echo "[Prowlarr] ${display_name} container doesn't exist, skipping registration."
    return 0
  fi

  local existing
  existing=$(container_curl prowlarr -sk --fail -H "X-Api-Key: ${prowlarr_api_key}" "$base_url" |
    jq --arg name "$display_name" 'map(select(.name == $name)) | first')
  if [[ -n "$existing" && "$existing" != "null" ]]; then
    echo "[Prowlarr] Application '${display_name}' already exists, skipping."
    return 0
  fi

  # Prowlarr validates the POST by actually connecting to the app, so the app
  # has to be up first or the whole registration 400s. The arr apps already
  # get a readiness wait from wire_arr_app, but LazyLibrarian and Mylar are
  # only ever touched here and had none: since wire_connections was
  # parallelized, this function races ahead and reaches them seconds into
  # bootstrap, long before they finish starting. Confirmed live: a real
  # bootstrap 400'd on LazyLibrarian for exactly this reason, while the same
  # registration returns 201 once it's healthy. Probing from inside the
  # prowlarr container tests the same path Prowlarr itself will use; no
  # --fail here on purpose, since any HTTP response (401, 303, ...) proves
  # it's listening, and only a connection-level failure means "not up yet".
  if ! retry 300 "[Prowlarr] waiting for ${display_name}" \
    container_curl prowlarr -sk -o /dev/null --max-time 10 "$app_url"; then
    echo "[Prowlarr] ${display_name} not reachable after 300s, skipping its registration."
    PROWLARR_FAILED+=("$display_name (not reachable)")
    return 0
  fi

  echo "[Prowlarr] Registering application '${display_name}'..."
  local schema
  schema=$(container_curl prowlarr -sk --fail -H "X-Api-Key: ${prowlarr_api_key}" "${base_url}/schema" |
    jq --arg impl "$implementation" 'map(select(.implementation == $impl)) | first')

  local payload
  payload=$(echo "$schema" | jq \
    --arg name "$display_name" \
    --arg prowlarrUrl "${prowlarr_url_override:-https://prowlarr:${PROWLARR_HTTPS_PORT}/prowlarr}" \
    --arg baseUrl "$app_url" \
    --arg apiKey "$app_api_key" \
    '.name = $name | .syncLevel = "fullSync" |
    .fields |= map(
      if .name == "prowlarrUrl" then .value = $prowlarrUrl
      elif .name == "baseUrl" then .value = $baseUrl
      elif .name == "apiKey" then .value = $apiKey
      else . end)')

  # Deliberately not fatal. Every entry in wire_prowlarr_apps runs in one
  # function inside one background job, so under `set -e` a single failing
  # POST used to kill that job outright, silently skipping every remaining
  # app AND the indexer, with the `|| true` on this job's own wait_job call
  # swallowing the failure so nothing in the bootstrap output even hinted at
  # it. (That `|| true` used to live inside wait_job itself; it moved to the
  # call sites when the arr jobs started reporting their Jellyfin status, and
  # the Prowlarr job kept it.) Confirmed live: a real
  # bootstrap printed "Registering application 'LazyLibrarian'..." and then
  # nothing at all, leaving Prowlarr with zero applications and zero
  # indexers. Record the failure, keep going, and surface it in the summary.
  #
  # This POST makes Prowlarr call back into the app to verify the link,
  # which for some apps (confirmed live: Lidarr) includes the app's own
  # HttpClient validating *our* self-signed cert against the bare container
  # hostname ("prowlarr"), which isn't in the cert's SAN list. Fatal only in
  # the split second right after the app's HTTP listener first binds: this
  # app's own reachability retry above only proves the listener answers, not
  # that its TLS/cert subsystem has finished warming up, and every
  # observed failure was Lidarr's very first attempt at an outbound HTTPS
  # connection to "prowlarr" (its own log showed "Now listening" one second
  # before "Certificate validation for prowlarr failed"). Retrying moments
  # later, once the app is no longer freshly started, self-heals: confirmed
  # live, re-running registration by hand right after this same failure
  # succeeded immediately.
  local response attempt
  for attempt in 1 2 3; do
    if response=$(container_curl prowlarr -skS --fail -X POST \
      -H "X-Api-Key: ${prowlarr_api_key}" -H "Content-Type: application/json" \
      -d "$payload" "$base_url" 2>&1); then # pragma: allowlist secret
      echo "[Prowlarr] Registered."
      return 0
    fi
    [[ $attempt -lt 3 ]] && sleep 15
  done
  echo "[Prowlarr] Failed to register '${display_name}': ${response:0:300}"
  PROWLARR_FAILED+=("$display_name")
  return 0
}

# ---------------------------------------------------------------------------
# Dispatch: alphabetical by service, matching the convention documented in
# docs/ROTATION.md for the sibling rotation scripts.
# ---------------------------------------------------------------------------

# All ten jobs are launched together, immediately after this one combined
# header, and their output streams live rather than being sorted into
# separate per-section headers: every echo in these functions already
# prefixes its own app name (e.g. "[Jellyfin] ..."), so a single stream of
# self-labeled lines from ten concurrent jobs stays readable without needing
# a fixed section to sort each line under. Waiting on the jobs afterward
# just lets the script exit only once everything is actually done; the
# order below doesn't gate when each job's output appears on screen.
echo "======================================================================"
echo " First-run setup, download client wiring, and Prowlarr registration"
echo " (running concurrently; each line is prefixed with its own app name)"
echo "======================================================================"
start_job audiobookshelf ensure_audiobookshelf_setup
start_job calibre ensure_calibre_content_server_user
start_job calibre-web ensure_calibre_web_setup
start_job jellyfin ensure_jellyfin_setup
start_job lidarr wire_arr_app lidarr lidarr https "$LIDARR_HTTPS_PORT" v1 lidarr music
start_job radarr wire_arr_app radarr radarr https "$RADARR_HTTPS_PORT" v3 radarr movies
start_job readarr wire_arr_app readarr readarr https "$READARR_HTTPS_PORT" v1 readarr ebooks
start_job sonarr wire_arr_app sonarr sonarr http "$SONARR_HTTP_PORT" v3 sonarr tv
start_job whisparr wire_arr_app whisparr whisparr https "$WHISPARR_HTTPS_PORT" v3 whisparr mature
start_job prowlarr wire_prowlarr_apps

for name in audiobookshelf calibre calibre-web jellyfin prowlarr; do
  wait_job "$name" || true
done

# Each of these five ran wire_arr_app, which now reports whether its own
# Jellyfin connection succeeded (see ensure_jellyfin_connection and
# JELLYFIN_FAILED above), so their status is worth keeping instead of
# discarding like the jobs above. JELLYFIN_WIRING_FAILED is the only status
# that means the Jellyfin connection specifically; anything else non-zero is
# a job that died earlier and is recorded separately rather than blamed on
# Jellyfin.
for name in lidarr radarr readarr sonarr whisparr; do
  arr_status=0
  wait_job "$name" || arr_status=$?
  if [[ "$arr_status" -eq "$JELLYFIN_WIRING_FAILED" ]]; then
    JELLYFIN_FAILED+=("$name")
  elif [[ "$arr_status" -ne 0 ]]; then
    ARR_JOB_FAILED+=("$name (exit ${arr_status})")
  fi
done

if [[ ${#JELLYFIN_FAILED[@]} -gt 0 ]]; then
  echo "[Jellyfin] WARNING: these apps did NOT get their Jellyfin connection wired:"
  for failed in "${JELLYFIN_FAILED[@]}"; do
    echo "[Jellyfin]   - ${failed}"
  done
  echo "[Jellyfin] Re-run 'make wire_connections' once Jellyfin and the app are both up."
fi

if [[ ${#ARR_JOB_FAILED[@]} -gt 0 ]]; then
  echo "[arr] WARNING: these apps did not finish wiring, and stopped before"
  echo "[arr] their Jellyfin connection was even attempted:"
  for failed in "${ARR_JOB_FAILED[@]}"; do
    echo "[arr]   - ${failed}"
  done
  echo "[arr] Check the output above for the first error each one printed."
fi

# Sequential, not part of the parallel batch above: this stops/starts the
# mylar container, which would otherwise race with wire_prowlarr_apps'
# concurrent connectivity check against that same container.
ensure_mylar_placeholder_comic

echo ""
echo "======================================================================"
echo " Done. Bazarr's Sonarr/Radarr connections and Mylar/LazyLibrarian's"
echo " qBittorrent/SABnzbd connections are pre-wired via their .example"
echo " templates and need no action here. See docs/CONNECTIONS.md."
echo "======================================================================"
