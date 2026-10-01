#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
set -euo pipefail

# Usage: ./scripts/rotate-api-keys.sh [sonarr|radarr|lidarr|readarr|whisparr|prowlarr|bazarr|lazylibrarian|mylar|nzbhydra2|jellyfin|all]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
cd "$REPO_ROOT"

readonly USAGE="Usage: $0 [sonarr|radarr|lidarr|readarr|whisparr|prowlarr|bazarr|lazylibrarian|mylar|nzbhydra2|jellyfin|all]"

if [[ $# -ne 1 ]]; then
  echo "$USAGE" >&2
  exit 1
fi

readonly TARGET="$1"

# Read the network and port variables we need from .env without sourcing it
# (.env defines UID, which is a readonly bash builtin, so `source .env` fails).
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

JELLYFIN_HTTP_PORT="$(env_value JELLYFIN_HTTP_PORT)"
# BaseUrl is a server-wide Jellyfin setting (see wire-connections.sh), not an
# nginx-only rewrite, so every direct call here needs it too: a bare
# http://127.0.0.1:<port>/... 302-redirects instead of answering, which
# curl --fail treats as success, silently breaking every call below it.
JELLYFIN_BASE_URL="$(env_value JELLYFIN_BASE_URL)"
BAZARR_HTTP_PORT="$(env_value BAZARR_HTTP_PORT)"
LAZYLIBRARIAN_HTTP_PORT="$(env_value LAZYLIBRARIAN_HTTP_PORT)"
# The *arr apps, Mylar, and NZBHydra2 deliberately have no port variables here:
# their scheme, port, and UrlBase are read from each app's own config by
# arr_endpoint()/mylar_endpoint()/nzbhydra_endpoint(), which are authoritative
# where .env is only aspirational.
readonly JELLYFIN_HTTP_PORT JELLYFIN_BASE_URL \
  BAZARR_HTTP_PORT LAZYLIBRARIAN_HTTP_PORT

# ---------------------------------------------------------------------------
# Current (old) API keys, read from config.xml at rotation time
# ---------------------------------------------------------------------------

get_xml_apikey() {
  local xml_file="$1"
  # `|| true`: see get_ini_apikey below for why a grep no-match here must
  # not be allowed to kill the whole script under `set -e`. The *arr apps
  # write ApiKey into config.xml synchronously on their very first boot, so
  # this is far less likely to be empty in practice than LazyLibrarian's or
  # Mylar's, but the failure mode if it ever is would be identical.
  grep -oPm1 '(?<=<ApiKey>)[^<]+' "$xml_file" || true
}

# Every *arr call below (Prowlarr's application/indexer updates and the final
# validation pass) used to hardcode a scheme, a port from .env, and a UrlBase
# equal to the app's own name. That silently assumes each app is configured
# exactly the way config.xml.example ships it. When an app is not, every one
# of those calls targets a port nothing is listening on and reports the app
# as broken even though its key rotated correctly. Confirmed live: five apps
# whose config.xml had been regenerated with stock defaults (EnableSsl False,
# empty UrlBase) answered fine on plain HTTP while the script kept probing
# HTTPS and failing them all.
#
# The app's own config.xml is the authority on where it listens, so read the
# endpoint from the same file this script already edits, rather than assuming.
# Echoes "scheme port urlbase"; urlbase is "" or "/foo" (trailing slash
# stripped, since callers always append a path starting with "/").
arr_endpoint() {
  local xml="$1" ssl base port scheme
  ssl=$(grep -oPm1 '(?<=<EnableSsl>)[^<]*' "$xml" || true)
  base=$(grep -oPm1 '(?<=<UrlBase>)[^<]*' "$xml" || true)
  if [[ "${ssl,,}" == "true" ]]; then
    scheme=https
    port=$(grep -oPm1 '(?<=<SslPort>)[^<]*' "$xml" || true)
  else
    scheme=http
    port=$(grep -oPm1 '(?<=<Port>)[^<]*' "$xml" || true)
  fi
  base="${base%/}"
  [[ -n "$base" && "$base" != /* ]] && base="/$base"
  echo "$scheme ${port} ${base}"
}

readonly SONARR_XML="configs/sonarr/config/config.xml"
readonly RADARR_XML="configs/radarr/config/config.xml"
readonly LIDARR_XML="configs/lidarr/config/config.xml"
readonly READARR_XML="configs/readarr/config/config.xml"
readonly WHISPARR_XML="configs/whisparr/config/config.xml"
readonly PROWLARR_XML="configs/prowlarr/config/config.xml"

readonly BAZARR_CONFIG="configs/bazarr/config/config/config.yaml"
readonly RECYCLARR_SECRETS="configs/recyclarr/config/secrets.yml" # pragma: allowlist secret

# Single source of truth for each app's API key, consumed via compose
# `secrets:` by homepage instead of being copied into its .env.secrets.
# See docs/COMPOSE_CONVENTIONS.md.
readonly SONARR_API_KEY_SECRET="configs/sonarr/secrets/api_key.txt"     # pragma: allowlist secret
readonly RADARR_API_KEY_SECRET="configs/radarr/secrets/api_key.txt"     # pragma: allowlist secret
readonly READARR_API_KEY_SECRET="configs/readarr/secrets/api_key.txt"   # pragma: allowlist secret
readonly BAZARR_API_KEY_SECRET="configs/bazarr/secrets/api_key.txt"     # pragma: allowlist secret
readonly PROWLARR_API_KEY_SECRET="configs/prowlarr/secrets/api_key.txt" # pragma: allowlist secret
readonly LIDARR_API_KEY_SECRET="configs/lidarr/secrets/api_key.txt"     # pragma: allowlist secret
readonly WHISPARR_API_KEY_SECRET="configs/whisparr/secrets/api_key.txt" # pragma: allowlist secret
readonly MYLAR_API_KEY_SECRET="configs/mylar/secrets/api_key.txt"       # pragma: allowlist secret
# Jellyfin has no independent source of truth for its own current key (it is
# created/revoked live via Jellyfin's own API); this file is that record.
readonly JELLYFIN_API_KEY_SECRET="configs/jellyfin/secrets/api_key.txt" # pragma: allowlist secret
readonly LAZYLIBRARIAN_INI="configs/lazylibrarian/config/config.ini"
readonly MYLAR_INI="configs/mylar/config/mylar/config.ini"
readonly NZBHYDRA_YML="configs/nzbhydra2/config/nzbhydra.yml"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

gen_key() {
  openssl rand -hex 16
}

mask() {
  local val="$1"
  echo "${val:0:4}****"
}

# Write a value shared via compose `secrets:` (path, not name=value, so it can
# be delivered to consumers spelling it differently, e.g. HOMEPAGE_FILE_*
# alongside an app's own config.xml). No trailing newline: consumers read the
# file's contents verbatim, and homepage substitutes them straight into its
# config. Mode 644: rootless podman maps this host file to uid 0 inside the
# container while the app runs as another UID, so 640/600 are unreadable.
# Args: path new_value
write_secret_file() {
  local path="$1"
  local new_value="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s' "$new_value" >"$path"
  chmod 644 "$path"
}

# Run curl inside the target app's own container, hitting its own loopback
# address directly. Apps aren't published to the host on the current bridge
# network, and this avoids routing admin/rotation traffic through nginx.
# Args: container_name curl_args...
container_curl() {
  local container_name="$1"
  shift
  podman exec "$(cname "$container_name")" curl "$@"
}

# Stop the listed containers if they exist, remembering which ones were
# stopped so start_stopped() can bring exactly those back.
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
  local c exempt=() normal=() pids=()
  for c in "$@"; do
    if [[ " ${STOP_TIMEOUT_EXEMPT[*]} " == *" ${c} "* ]]; then
      exempt+=("$(cname "$c")")
    else
      normal+=("$(cname "$c")")
    fi
  done
  # Both batches run concurrently so an exempt container waiting out its
  # timeout never serializes behind the others. A bare `wait` (no PIDs)
  # always returns 0 regardless of how its background jobs exited, which
  # under `set -e` silently turned a real `podman stop` failure into
  # success; waiting on each PID by name surfaces it instead.
  if [[ ${#normal[@]} -gt 0 ]]; then
    podman stop --time "$STOP_TIMEOUT" "${normal[@]}" >/dev/null &
    pids+=("$!")
  fi
  if [[ ${#exempt[@]} -gt 0 ]]; then
    podman stop "${exempt[@]}" >/dev/null &
    pids+=("$!")
  fi
  wait "${pids[@]}"
}

STOPPED_CONTAINERS=()
stop_existing() {
  STOPPED_CONTAINERS=()
  local c
  for c in "$@"; do
    if podman container exists "$(cname "$c")" 2>/dev/null; then
      stop_container "$c"
      STOPPED_CONTAINERS+=("$c")
    fi
  done
}

container_running() {
  podman container inspect -f '{{.State.Running}}' "$(cname "$1")" 2>/dev/null | grep -q '^true$'
}

# podman start can transiently fail with "container state improper" when
# this app's container is also being touched right now by a concurrently
# running rotation of the same app (its own password rotation, most
# commonly, since both scripts stop/start the same container independently
# and rotation_isolated's own parallel test tier runs both at once). That
# isn't a real failure: it resolves itself within a few seconds once the
# other script's own stop/start cycle finishes, so this is retried the same
# way homepage's own recreate step already is, for the same reason, rather
# than treated as fatal on the first attempt.
start_containers_retrying() {
  local timeout=30 elapsed=0 remaining=("$@") still_remaining c
  while [[ ${#remaining[@]} -gt 0 ]]; do
    still_remaining=()
    for c in "${remaining[@]}"; do
      container_running "$c" && continue
      podman start "$(cname "$c")" >/dev/null 2>&1 || still_remaining+=("$c")
    done
    remaining=("${still_remaining[@]}")
    [[ ${#remaining[@]} -eq 0 ]] && return 0
    sleep 5
    elapsed=$((elapsed + 5))
    if [[ $elapsed -ge $timeout ]]; then
      echo "ERROR: could not start: ${remaining[*]}" >&2
      return 1
    fi
  done
}

start_stopped() {
  if [[ ${#STOPPED_CONTAINERS[@]} -gt 0 ]]; then
    start_containers_retrying "${STOPPED_CONTAINERS[@]}"
  fi
}

# Retry a command every 5 seconds until it succeeds or timeout (in seconds).
retry() {
  local timeout="$1"
  shift
  local elapsed=0
  until "$@" >/dev/null 2>&1; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [[ $elapsed -ge $timeout ]]; then
      return 1
    fi
  done
}

# *arr apps silently ignore apiKey changes sent through the config/host API
# endpoint (it's treated as self-protecting, read-only over that route): a
# PUT returns 202 but echoes back the unchanged old key. The only way to
# actually change it is to edit config.xml directly and restart the app so it
# re-reads the key into memory at startup.
# Args: app_name container_name xml_path
rotate_arr_apikey() {
  local app_name="$1"
  local container_name="$2"
  local xml_path="$3"
  local new_key
  new_key=$(gen_key)

  # The apps read config.xml only at startup and can rewrite it on state
  # changes, so the edit happens while the container is stopped.
  echo "[$app_name] Stopping container and writing new ApiKey to $xml_path..." >&2
  stop_container "$container_name"

  xmlstarlet --quiet ed --inplace --update '/Config/ApiKey' \
    --value "$new_key" "$xml_path" # pragma: allowlist secret

  local written
  written=$(get_xml_apikey "$xml_path")
  if [[ "$written" != "$new_key" ]]; then
    echo "[$app_name] ERROR: ApiKey did not update as expected in $xml_path" >&2
    start_containers_retrying "$container_name"
    return 1
  fi

  start_containers_retrying "$container_name"
  echo "$new_key"
}

# Waits for Prowlarr's own API to answer before anything below tries to talk
# to it. Prowlarr can still be mid-startup here, either because `make start`
# hasn't finished settling yet or because an earlier step in this same run
# stopped/started it, and a curl against a port nothing is listening on yet
# fails immediately with exit 7, aborting the whole rotation under `set -e`
# instead of just waiting the extra few seconds.
#
# `rotate_all` asks Prowlarr for this up to six times (once per downstream
# app plus once for Prowlarr's own key). A Prowlarr that is actually down,
# rather than just slow, used to cost the full 120s retry budget on every
# one of those six calls, over 10 minutes of pure waiting before the run
# even reached Bazarr. Once a wait has genuinely timed out, later calls
# only get a single quick check instead of repaying the full budget; the
# first miss already answered "is it coming up soon", the rest just confirm
# that cheaply. Prowlarr's own rotation step still gets the full budget on
# its first attempt regardless (PROWLARR_KNOWN_DOWN resets on any success),
# since that is the call right after its own container was restarted and
# the moment it is most likely to actually come up.
# Builds a Prowlarr API URL from Prowlarr's own config.xml, so these calls
# follow it if it is not serving HTTPS on the port .env advertises.
# Args: path (starting with "/")
prowlarr_url() {
  local scheme port base
  read -r scheme port base <<<"$(arr_endpoint "$PROWLARR_XML")"
  echo "${scheme}://127.0.0.1:${port}${base}$1"
}

# Args: prowlarr_key
PROWLARR_KNOWN_DOWN=""
wait_for_prowlarr_ready() {
  local prowlarr_key="$1"
  local budget=120
  [[ -n "$PROWLARR_KNOWN_DOWN" ]] && budget=0
  if retry "$budget" container_curl prowlarr -sk --fail -o /dev/null --max-time 10 \
    -H "X-Api-Key: ${prowlarr_key}" \
    "$(prowlarr_url /api/v1/system/status)"; then
    PROWLARR_KNOWN_DOWN=""
    return 0
  fi
  PROWLARR_KNOWN_DOWN=1
  return 1
}

# Update one application entry in Prowlarr with a new downstream API key.
# The entry is looked up by name; apps without a Prowlarr application entry
# are skipped, and so is a Prowlarr container that doesn't exist at all
# (PROWLARR_PROFILE=disabled) rather than letting `podman exec` fail the
# whole rotation under `set -e`.
# Args: prowlarr_key app_name new_downstream_key
update_prowlarr_application() {
  local prowlarr_key="$1"
  local app_name="$2"
  local new_key="$3"

  if ! podman container exists "$(cname prowlarr)" 2>/dev/null; then
    echo "[Prowlarr] Container doesn't exist, skipping application update for '${app_name}'."
    return 0
  fi

  if ! wait_for_prowlarr_ready "$prowlarr_key"; then
    echo "[Prowlarr] Didn't come up in time, skipping application update for '${app_name}'."
    echo "[Prowlarr] Once it's healthy, re-run 'make wire_connections' to fix this."
    return 0
  fi

  local app_json
  app_json=$(container_curl prowlarr -sk -H "X-Api-Key: $prowlarr_key" "$(prowlarr_url /api/v1/applications)" | jq --arg name "$app_name" 'map(select(.name == $name)) | first')

  if [[ -z "$app_json" || "$app_json" == "null" ]]; then
    echo "[Prowlarr] No application entry named '${app_name}', skipping."
    return 0
  fi

  local app_id
  app_id=$(echo "$app_json" | jq -r '.id')
  echo "[Prowlarr] Updating application '${app_name}' (id=${app_id}) with new key..."

  local updated
  updated=$(echo "$app_json" | jq --arg key "$new_key" '.fields[] |= if .name == "apiKey" then .value = $key else . end')

  # forceSave skips Prowlarr's connection validation: the downstream app has
  # not been restarted with the new key yet at this point (restarts happen at
  # the end), so a validated PUT would always fail with a 401 from the app.
  # --fail surfaces any real API error instead of silently discarding it.
  container_curl prowlarr -sk --fail -X PUT \
    -H "X-Api-Key: $prowlarr_key" \
    -H "Content-Type: application/json" \
    -d "$updated" \
    "$(prowlarr_url "/api/v1/applications/${app_id}?forceSave=true")" \
    >/dev/null
}

# When Prowlarr's own API key rotates, every indexer it already pushed into
# a downstream app still carries the *old* key, because Prowlarr embeds its
# current key into an indexer record at sync time and does not refresh it
# on every later sync. Confirmed live: after rotating Prowlarr's key and
# manually re-running ApplicationIndexerSync, LazyLibrarian's Torznab entry
# picked up the new key (Prowlarr updates it there through LazyLibrarian's
# own live "changeprovider" API, which this same command call reaches), but
# Radarr's Indexers row still had the old key in its apiKey field. The arr
# apps need an explicit PUT to their own indexer API to pick up the new key;
# LazyLibrarian/Mylar are already fixed by the resync below.
# Args: new_key
propagate_prowlarr_key() {
  local new_key="$1"

  if ! podman container exists "$(cname prowlarr)" 2>/dev/null; then
    return 0
  fi

  if ! wait_for_prowlarr_ready "$new_key"; then
    echo "[Prowlarr] Didn't come back up with the new key in time, skipping indexer key propagation."
    echo "[Prowlarr] Once it's healthy, re-run 'make wire_connections' to fix this."
    return 0
  fi

  echo "[Prowlarr] Re-syncing indexers to registered applications with the new key..."
  container_curl prowlarr -sk --fail -X POST \
    -H "X-Api-Key: ${new_key}" -H "Content-Type: application/json" \
    -d '{"name":"ApplicationIndexerSync"}' \
    "$(prowlarr_url /api/v1/command)" >/dev/null || true
  sleep 15

  # Scheme/port/UrlBase come from each app's own config.xml (see arr_endpoint),
  # not from .env, so this follows an app that is not serving where .env says.
  local targets=("sonarr v3 ${SONARR_XML}" "radarr v3 ${RADARR_XML}" "lidarr v1 ${LIDARR_XML}" "readarr v1 ${READARR_XML}" "whisparr v3 ${WHISPARR_XML}")
  local entry app scheme port base api_version xml_path app_key indexers
  for entry in "${targets[@]}"; do
    read -r app api_version xml_path <<<"$entry"
    podman container exists "$(cname "$app")" 2>/dev/null || continue
    app_key=$(get_xml_apikey "$xml_path") || continue
    [[ -n "$app_key" ]] || continue
    read -r scheme port base <<<"$(arr_endpoint "$xml_path")"
    indexers=$(container_curl "$app" -sk --fail -H "X-Api-Key: ${app_key}" "${scheme}://127.0.0.1:${port}${base}/api/${api_version}/indexer" 2>/dev/null) || continue

    local rec id name updated
    # Read through a descriptor opened here rather than `done < <(...)`, a
    # line kcov never sees run.
    exec 3< <(echo "$indexers" | jq -c '.[] | select(.fields[]? | .name == "baseUrl" and (.value | test("://prowlarr[:/]")))')
    while IFS= read -r -u 3 rec; do
      [[ -z "$rec" ]] && continue
      id=$(echo "$rec" | jq -r '.id')
      name=$(echo "$rec" | jq -r '.name')
      updated=$(echo "$rec" | jq --arg key "$new_key" '.fields |= map(if .name == "apiKey" then .value = $key else . end)')
      if container_curl "$app" -sk --fail -X PUT -H "X-Api-Key: ${app_key}" \
        -H "Content-Type: application/json" -d "$updated" \
        "${scheme}://127.0.0.1:${port}${base}/api/${api_version}/indexer/${id}?forceSave=true" >/dev/null; then
        echo "[Prowlarr] Updated ${app}'s indexer '${name}' with the new API key."
      else
        echo "[Prowlarr] WARNING: failed to update ${app}'s indexer '${name}' with the new API key."
      fi
    done
    exec 3<&-
  done

  # LazyLibrarian stores its own copy of Prowlarr's key too, in whichever
  # Torznab_N section Prowlarr's own indexer sync created (see
  # docs/CONNECTIONS.md: LazyLibrarian ships with no Prowlarr Torznab entry
  # of its own, Prowlarr populates it live). This was missing entirely:
  # confirmed live, that section's api value stayed at its pre-sync
  # placeholder across a real rotation. LazyLibrarian persists its config
  # on shutdown like every other INI-configured app in this stack, so the
  # edit needs the same stop-edit-start as rotate_nzbhydra2() already uses
  # for the same file, not a live write.
  if [[ -f "$LAZYLIBRARIAN_INI" ]] && podman container exists "$(cname lazylibrarian)" 2>/dev/null; then
    stop_existing lazylibrarian
    python3 - <<PYEOF
from pathlib import Path

new_key = '$new_key'
ll = Path('$LAZYLIBRARIAN_INI')
lines = ll.read_text().splitlines()
section_hosts = {}
current = None
for line in lines:
    if line.startswith('['):
        current = line
    elif line.startswith('host = ') and current:
        section_hosts[current] = line
current = None
for i, line in enumerate(lines):
    if line.startswith('['):
        current = line
    elif line.startswith('api = ') and 'prowlarr' in section_hosts.get(current, '').lower():
        lines[i] = f"api = {new_key}"
ll.write_text("\n".join(lines) + "\n")
PYEOF
    start_stopped
    echo "[Prowlarr] Updated LazyLibrarian's Torznab entry with the new API key."
  fi
}

# ---------------------------------------------------------------------------
# Per-app rotation functions
# ---------------------------------------------------------------------------

rotate_sonarr() {
  local old_key
  old_key=$(get_xml_apikey "$SONARR_XML")
  local new_key
  new_key=$(rotate_arr_apikey "Sonarr" "sonarr" "$SONARR_XML")

  local prowlarr_key
  prowlarr_key=$(get_xml_apikey "$PROWLARR_XML")
  update_prowlarr_application "$prowlarr_key" "Sonarr" "$new_key"

  echo "[Bazarr] Updating sonarr.apikey in config.yaml..."
  yq -i ".sonarr.apikey = \"$new_key\"" "$BAZARR_CONFIG"

  if [[ -f "$RECYCLARR_SECRETS" ]]; then
    echo "[recyclarr] Updating sonarr_apikey in secrets.yml..."
    yq -i ".sonarr_apikey = \"$new_key\"" "$RECYCLARR_SECRETS"
  else
    echo "[recyclarr] $RECYCLARR_SECRETS doesn't exist, skipping."
  fi

  write_secret_file "$SONARR_API_KEY_SECRET" "$new_key"

  SUMMARY_SONARR_OLD="$old_key"
  SUMMARY_SONARR_NEW="$new_key"
}

rotate_radarr() {
  local old_key
  old_key=$(get_xml_apikey "$RADARR_XML")
  local new_key
  new_key=$(rotate_arr_apikey "Radarr" "radarr" "$RADARR_XML")

  local prowlarr_key
  prowlarr_key=$(get_xml_apikey "$PROWLARR_XML")
  update_prowlarr_application "$prowlarr_key" "Radarr" "$new_key"

  echo "[Bazarr] Updating radarr.apikey in config.yaml..."
  yq -i ".radarr.apikey = \"$new_key\"" "$BAZARR_CONFIG"

  if [[ -f "$RECYCLARR_SECRETS" ]]; then
    echo "[recyclarr] Updating radarr_apikey in secrets.yml..."
    yq -i ".radarr_apikey = \"$new_key\"" "$RECYCLARR_SECRETS"
  else
    echo "[recyclarr] $RECYCLARR_SECRETS doesn't exist, skipping."
  fi

  write_secret_file "$RADARR_API_KEY_SECRET" "$new_key"

  SUMMARY_RADARR_OLD="$old_key"
  SUMMARY_RADARR_NEW="$new_key"
}

rotate_lidarr() {
  local old_key
  old_key=$(get_xml_apikey "$LIDARR_XML")
  local new_key
  new_key=$(rotate_arr_apikey "Lidarr" "lidarr" "$LIDARR_XML")

  local prowlarr_key
  prowlarr_key=$(get_xml_apikey "$PROWLARR_XML")
  update_prowlarr_application "$prowlarr_key" "Lidarr" "$new_key"

  write_secret_file "$LIDARR_API_KEY_SECRET" "$new_key"

  SUMMARY_LIDARR_OLD="$old_key"
  SUMMARY_LIDARR_NEW="$new_key"
}

rotate_readarr() {
  local old_key
  old_key=$(get_xml_apikey "$READARR_XML")
  local new_key
  new_key=$(rotate_arr_apikey "Readarr" "readarr" "$READARR_XML")

  local prowlarr_key
  prowlarr_key=$(get_xml_apikey "$PROWLARR_XML")
  update_prowlarr_application "$prowlarr_key" "Readarr" "$new_key"

  write_secret_file "$READARR_API_KEY_SECRET" "$new_key"

  SUMMARY_READARR_OLD="$old_key"
  SUMMARY_READARR_NEW="$new_key"
}

rotate_whisparr() {
  local old_key
  old_key=$(get_xml_apikey "$WHISPARR_XML")
  local new_key
  new_key=$(rotate_arr_apikey "Whisparr" "whisparr" "$WHISPARR_XML")

  local prowlarr_key
  prowlarr_key=$(get_xml_apikey "$PROWLARR_XML")
  update_prowlarr_application "$prowlarr_key" "Whisparr" "$new_key"

  write_secret_file "$WHISPARR_API_KEY_SECRET" "$new_key"

  SUMMARY_WHISPARR_OLD="$old_key"
  SUMMARY_WHISPARR_NEW="$new_key"
}

rotate_prowlarr() {
  local old_key
  old_key=$(get_xml_apikey "$PROWLARR_XML")
  local new_key
  new_key=$(rotate_arr_apikey "Prowlarr" "prowlarr" "$PROWLARR_XML")

  write_secret_file "$PROWLARR_API_KEY_SECRET" "$new_key"

  propagate_prowlarr_key "$new_key"

  SUMMARY_PROWLARR_OLD="$old_key"
  SUMMARY_PROWLARR_NEW="$new_key"
}

rotate_bazarr() {
  # Bazarr does not expose an API endpoint to change its own API key.
  # The key is read from config.yaml and written back directly.
  local old_key
  old_key=$(yq '.auth.apikey' "$BAZARR_CONFIG")
  local new_key
  new_key=$(gen_key)

  # Bazarr reads config.yaml at startup; edit it while stopped.
  echo "[Bazarr] Stopping container and updating auth.apikey in config.yaml..."
  stop_container bazarr
  yq -i ".auth.apikey = \"$new_key\"" "$BAZARR_CONFIG"
  podman start "$(cname bazarr)" >/dev/null

  write_secret_file "$BAZARR_API_KEY_SECRET" "$new_key"

  SUMMARY_BAZARR_OLD="$old_key"
  SUMMARY_BAZARR_NEW="$new_key"
}

# LazyLibrarian and Mylar keep their API key as a unique "api_key = ..." line
# in their config.ini and read it only at startup. Confirmed live: on a
# LazyLibrarian that has never fully completed its own first boot, that line
# doesn't exist yet (every other section is already written), so grep finds
# no match. `|| true` keeps that a plain empty result instead of a nonzero
# exit: under `set -e`, `old_key=$(get_ini_apikey ...)` otherwise dies right
# there with no error text at all, since grep prints nothing on no-match,
# taking the entire `rotate_all` run down with it partway through Bazarr's
# own rotation (confirmed live: the container that broke it was two steps
# later in the sequence, with the config file already showing its new key).
get_ini_apikey() {
  grep -oPm1 '(?<=^api_key = ).*' "$1" || true
}

rotate_lazylibrarian() {
  local old_key new_key
  old_key=$(get_ini_apikey "$LAZYLIBRARIAN_INI")
  if [[ -z "$old_key" ]]; then
    echo "[LazyLibrarian] No api_key in config.ini yet (let it finish its first boot), skipping."
    return 0
  fi
  new_key=$(gen_key)

  # LazyLibrarian persists its in-memory config on shutdown, which would
  # clobber a live file edit; stop it first, edit, then start.
  echo "[LazyLibrarian] Stopping container and writing new api_key..."
  stop_container lazylibrarian
  sed -i "s|^api_key = .*|api_key = ${new_key}|" "$LAZYLIBRARIAN_INI"
  podman start "$(cname lazylibrarian)" >/dev/null

  local prowlarr_key
  prowlarr_key=$(get_xml_apikey "$PROWLARR_XML")
  update_prowlarr_application "$prowlarr_key" "LazyLibrarian" "$new_key"

  SUMMARY_LAZYLIBRARIAN_OLD="$old_key"
  SUMMARY_LAZYLIBRARIAN_NEW="$new_key"
}

rotate_mylar() {
  local old_key new_key
  old_key=$(get_ini_apikey "$MYLAR_INI")
  if [[ -z "$old_key" ]]; then
    echo "[Mylar] No api_key in config.ini yet (let it finish its first boot), skipping."
    return 0
  fi
  new_key=$(gen_key)

  # Mylar persists its in-memory config on shutdown, which would clobber a
  # live file edit; stop it first, edit, then start.
  echo "[Mylar] Stopping container and writing new api_key..."
  stop_container mylar
  sed -i "s|^api_key = .*|api_key = ${new_key}|" "$MYLAR_INI"
  podman start "$(cname mylar)" >/dev/null

  local prowlarr_key
  prowlarr_key=$(get_xml_apikey "$PROWLARR_XML")
  update_prowlarr_application "$prowlarr_key" "Mylar" "$new_key"

  write_secret_file "$MYLAR_API_KEY_SECRET" "$new_key"

  SUMMARY_MYLAR_OLD="$old_key"
  SUMMARY_MYLAR_NEW="$new_key"
}

rotate_nzbhydra2() {
  # nzbhydra.yml stores the key obfuscated ({OBF}...), so the plain current
  # key is read from a consumer (LazyLibrarian's Newznab entry). Writing a
  # plain value back is fine: NZBHydra re-obfuscates it on its next save.
  # `old_key` is only for the summary line below, so an empty read (no such
  # entry yet, e.g. LazyLibrarian hasn't synced with NZBHydra2 yet) should
  # not stop the rotation itself; `|| true` keeps a grep no-match from
  # killing the whole script under `set -e` the way it did here live.
  local old_key new_key
  old_key=$(grep -oPm1 '(?<=^api = ).*' "$LAZYLIBRARIAN_INI" || true)
  new_key=$(gen_key)

  # NZBHydra2, LazyLibrarian, and Mylar persist their configs on shutdown,
  # and the arr apps' Indexers tables are edited on disk, so everything in
  # the blast radius is stopped for the duration of the edits.
  echo "[NZBHydra2] Stopping consumers for config and database edits..."
  stop_existing nzbhydra2 lazylibrarian mylar sonarr radarr lidarr readarr whisparr

  echo "[NZBHydra2] Writing new main.apiKey to $NZBHYDRA_YML..."
  apiKey="$new_key" yq -i '(.main.apiKey) = strenv(apiKey)' "$NZBHYDRA_YML"

  echo "[NZBHydra2] Updating consumers (arr Indexers tables, LazyLibrarian, Mylar)..."
  python3 - <<PYEOF
import json
import re
import sqlite3
from pathlib import Path

new_key = '$new_key'

dbs = {
    "sonarr": "configs/sonarr/config/sonarr.db",
    "radarr": "configs/radarr/config/radarr.db",
    "lidarr": "configs/lidarr/config/lidarr.db",
    "readarr": "configs/readarr/config/readarr.db",
    "whisparr": "configs/whisparr/config/whisparr3.db",
}
for app, db in dbs.items():
    if not Path(db).exists():
        continue
    conn = sqlite3.connect(db)
    cur = conn.cursor()
    for row_id, raw in cur.execute("SELECT Id, Settings FROM Indexers").fetchall():
        settings = json.loads(raw)
        if "nzbhydra" not in str(settings.get("baseUrl", "")).lower():
            continue
        settings["apiKey"] = new_key
        cur.execute("UPDATE Indexers SET Settings = ? WHERE Id = ?", (json.dumps(settings), row_id))
    conn.commit()
    conn.close()

# LazyLibrarian: api = ... lines inside sections whose host points at NZBHydra
ll = Path('$LAZYLIBRARIAN_INI')
lines = ll.read_text().splitlines()
section_hosts = {}
current = None
for line in lines:
    if line.startswith('['):
        current = line
    elif line.startswith('host = ') and current:
        section_hosts[current] = line
current = None
for i, line in enumerate(lines):
    if line.startswith('['):
        current = line
    elif line.startswith('api = ') and current and 'nzbhydra' in section_hosts.get(current, '').lower():
        lines[i] = f"api = {new_key}"
ll.write_text("\n".join(lines) + "\n")

# Mylar: extra_newznabs/extra_torznabs CSV entries carry the key after the URL
my = Path('$MYLAR_INI')
text = my.read_text()
text = re.sub(
    r"(https?://[^,]*nzbhydra[^,]*,\s*\d+,\s*)[A-Za-z0-9]+",
    lambda m: m.group(1) + new_key,
    text,
)
my.write_text(text)
PYEOF

  start_stopped

  SUMMARY_NZBHYDRA2_OLD="$old_key"
  SUMMARY_NZBHYDRA2_NEW="$new_key"
}

rotate_jellyfin() {
  # Jellyfin API keys are created and revoked through its own API; the value
  # cannot be chosen, so the flow is: create new, adopt it, revoke old. That
  # API only works once Jellyfin's own first-run setup wizard has created an
  # admin account, which nothing in this stack automates (unlike the arr
  # apps' WebUI login, it involves real choices: media libraries, metadata
  # language, remote access): skip with a note rather than aborting the
  # whole rotation run over a step that's inherently manual.
  local base_url="http://127.0.0.1:${JELLYFIN_HTTP_PORT}${JELLYFIN_BASE_URL}"
  if [[ "$(container_curl jellyfin -s --fail "${base_url}/System/Info/Public" | jq -r '.StartupWizardCompleted')" != "true" ]]; then
    echo "[Jellyfin] Setup wizard not completed yet, skipping API key rotation."
    echo "[Jellyfin] Finish it at http://localhost:${JELLYFIN_HTTP_PORT}/, then re-run"
    echo "[Jellyfin] 'make rotate_all SERVICE=jellyfin'."
    return 0
  fi

  local old_key new_key
  old_key=$(cat "$JELLYFIN_API_KEY_SECRET")

  echo "[Jellyfin] Creating a new API key..."
  container_curl jellyfin -s --fail -X POST \
    -H "Authorization: MediaBrowser Token=\"${old_key}\"" \
    "${base_url}/Auth/Keys?App=homepage" >/dev/null

  new_key=$(container_curl jellyfin -s --fail -H "Authorization: MediaBrowser Token=\"${old_key}\"" "${base_url}/Auth/Keys" | jq -r --arg old "$old_key" '[.Items[] | select(.AccessToken != $old)] | sort_by(.DateCreated) | last.AccessToken')

  if [[ -z "$new_key" || "$new_key" == "null" ]]; then
    echo "[Jellyfin] ERROR: could not obtain the newly created API key" >&2
    return 1
  fi

  write_secret_file "$JELLYFIN_API_KEY_SECRET" "$new_key"

  echo "[Jellyfin] Revoking the old API key..."
  container_curl jellyfin -s --fail -X DELETE \
    -H "Authorization: MediaBrowser Token=\"${new_key}\"" \
    "${base_url}/Auth/Keys/${old_key}" >/dev/null

  SUMMARY_JELLYFIN_OLD="$old_key"
  SUMMARY_JELLYFIN_NEW="$new_key"
}

# ---------------------------------------------------------------------------
# Summary variables (populated by rotation functions)
# ---------------------------------------------------------------------------

SUMMARY_SONARR_OLD=""
SUMMARY_SONARR_NEW=""
SUMMARY_RADARR_OLD=""
SUMMARY_RADARR_NEW=""
SUMMARY_LIDARR_OLD=""
SUMMARY_LIDARR_NEW=""
SUMMARY_READARR_OLD=""
SUMMARY_READARR_NEW=""
SUMMARY_WHISPARR_OLD=""
SUMMARY_WHISPARR_NEW=""
SUMMARY_PROWLARR_OLD=""
SUMMARY_PROWLARR_NEW=""
SUMMARY_BAZARR_OLD=""
SUMMARY_BAZARR_NEW=""
SUMMARY_LAZYLIBRARIAN_OLD=""
SUMMARY_LAZYLIBRARIAN_NEW=""
SUMMARY_MYLAR_OLD=""
SUMMARY_MYLAR_NEW=""
SUMMARY_NZBHYDRA2_OLD=""
SUMMARY_NZBHYDRA2_NEW=""
SUMMARY_JELLYFIN_OLD=""
SUMMARY_JELLYFIN_NEW=""

# Rotate one service, but only when its compose profile is enabled (and, for
# arr apps, only when the container it needs stopped/exec'd into actually
# exists). Mirrors rotate-passwords.sh's rotate_if_enabled(): in "all" mode a
# disabled service is skipped with a note; an explicitly requested disabled
# service is an error.
# Args: profile_var_prefix container_name rotate_function
rotate_if_enabled() {
  local profile_var="$1" container_name="$2" func="$3"
  if [[ "$(env_value "${profile_var}_PROFILE")" != "enabled" ]]; then
    if [[ "$TARGET" == "all" ]]; then
      echo "[$container_name] Skipped, ${profile_var}_PROFILE is disabled"
      return
    fi
    echo "ERROR: ${profile_var}_PROFILE is disabled in .env; not rotating $container_name" >&2
    exit 1
  fi
  if ! podman container exists "$(cname "$container_name")" 2>/dev/null; then
    if [[ "$TARGET" == "all" ]]; then
      echo "[$container_name] Skipped, container doesn't exist"
      return
    fi
    echo "ERROR: container '$container_name' doesn't exist; not rotating it" >&2
    exit 1
  fi
  "$func"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

case "$TARGET" in
sonarr) rotate_if_enabled SONARR sonarr rotate_sonarr ;;
radarr) rotate_if_enabled RADARR radarr rotate_radarr ;;
lidarr) rotate_if_enabled LIDARR lidarr rotate_lidarr ;;
readarr) rotate_if_enabled READARR readarr rotate_readarr ;;
whisparr) rotate_if_enabled WHISPARR whisparr rotate_whisparr ;;
prowlarr) rotate_if_enabled PROWLARR prowlarr rotate_prowlarr ;;
bazarr) rotate_if_enabled BAZARR bazarr rotate_bazarr ;;
lazylibrarian) rotate_if_enabled LAZYLIBRARIAN lazylibrarian rotate_lazylibrarian ;;
mylar) rotate_if_enabled MYLAR mylar rotate_mylar ;;
nzbhydra2) rotate_if_enabled NZBHYDRA2 nzbhydra2 rotate_nzbhydra2 ;;
jellyfin) rotate_if_enabled JELLYFIN jellyfin rotate_jellyfin ;;
all)
  rotate_if_enabled SONARR sonarr rotate_sonarr
  rotate_if_enabled RADARR radarr rotate_radarr
  rotate_if_enabled LIDARR lidarr rotate_lidarr
  rotate_if_enabled READARR readarr rotate_readarr
  rotate_if_enabled WHISPARR whisparr rotate_whisparr
  rotate_if_enabled PROWLARR prowlarr rotate_prowlarr
  rotate_if_enabled BAZARR bazarr rotate_bazarr
  rotate_if_enabled LAZYLIBRARIAN lazylibrarian rotate_lazylibrarian
  rotate_if_enabled MYLAR mylar rotate_mylar
  rotate_if_enabled NZBHYDRA2 nzbhydra2 rotate_nzbhydra2
  rotate_if_enabled JELLYFIN jellyfin rotate_jellyfin
  ;;
*)
  echo "Unknown target: $TARGET" >&2
  echo "$USAGE" >&2
  exit 1
  ;;
esac

# ---------------------------------------------------------------------------
# Homepage reads every key this script writes from a bind-mounted compose
# `secrets:` file. That is not the same as a live bind mount: Compose's
# file-based secrets are snapshotted once, at container creation, the same
# as env_file, and a plain restart does not re-read the host file if it
# changed since then. Confirmed live on a real deployment: a rotated
# sonarr key on disk did not match what homepage's own mounted secret
# still held after a restart. --force-recreate is the only thing that
# actually re-snapshots it.
#
# This step runs on every invocation of this script, including single-app
# targets, so two rotations for different apps started around the same time
# both land here. Podman refuses this while homepage is mid-transition from
# the other invocation ("container state improper"), so it is retried
# instead of treated as fatal; the other invocation's recreate finishes in
# a couple of seconds and this one succeeds right after.
# ---------------------------------------------------------------------------

if podman container exists "$(cname homepage)" 2>/dev/null; then
  echo ""
  echo "Recreating homepage to load the new keys..."
  if ! retry 30 podman-compose --file docker-compose.yml --profile enabled up -d --force-recreate homepage; then
    echo "ERROR: homepage still would not recreate after retries" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Host-side SQLite writes above can leave -wal/-shm files owned by the host
# user, which the app user inside the container cannot open after a restart;
# normalize ownership before finishing.
# ---------------------------------------------------------------------------

"$SCRIPT_DIR/permissions.py" repair --runtime podman --recursive >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Summary table
# ---------------------------------------------------------------------------

echo ""
echo "======================================================================"
echo " API key rotation summary  (shown as: first4****)"
echo "======================================================================"
printf "%-12s  %-12s  %-12s\n" "Service" "Old key" "New key"
echo "----------------------------------------------------------------------"

print_row() {
  local svc="$1" old="$2" new="$3"
  if [[ -n "$old" ]]; then
    printf "%-12s  %-12s  %-12s\n" "$svc" "$(mask "$old")" "$(mask "$new")"
  fi
}

print_row "sonarr" "$SUMMARY_SONARR_OLD" "$SUMMARY_SONARR_NEW"
print_row "radarr" "$SUMMARY_RADARR_OLD" "$SUMMARY_RADARR_NEW"
print_row "lidarr" "$SUMMARY_LIDARR_OLD" "$SUMMARY_LIDARR_NEW"
print_row "readarr" "$SUMMARY_READARR_OLD" "$SUMMARY_READARR_NEW"
print_row "whisparr" "$SUMMARY_WHISPARR_OLD" "$SUMMARY_WHISPARR_NEW"
print_row "prowlarr" "$SUMMARY_PROWLARR_OLD" "$SUMMARY_PROWLARR_NEW"
print_row "bazarr" "$SUMMARY_BAZARR_OLD" "$SUMMARY_BAZARR_NEW"
print_row "lazylibrarian" "$SUMMARY_LAZYLIBRARIAN_OLD" "$SUMMARY_LAZYLIBRARIAN_NEW"
print_row "mylar" "$SUMMARY_MYLAR_OLD" "$SUMMARY_MYLAR_NEW"
print_row "nzbhydra2" "$SUMMARY_NZBHYDRA2_OLD" "$SUMMARY_NZBHYDRA2_NEW"
print_row "jellyfin" "$SUMMARY_JELLYFIN_OLD" "$SUMMARY_JELLYFIN_NEW"

echo "======================================================================"
# ---------------------------------------------------------------------------
# Validation: prove each rotated API key is accepted by its service. Each
# check retries while the restarted container comes back up.
# ---------------------------------------------------------------------------

# Endpoint comes from the app's own config.xml (see arr_endpoint) so a key
# is never reported broken merely because the app serves plain HTTP, or on a
# different port/UrlBase, than config.xml.example assumes.
# Args: container xml_path api_ver key
arr_key_ok() {
  local container="$1" xml_path="$2" api_ver="$3" key="$4"
  local scheme port base
  read -r scheme port base <<<"$(arr_endpoint "$xml_path")"
  container_curl "$container" -sk --fail -o /dev/null -H "X-Api-Key: ${key}" \
    "${scheme}://127.0.0.1:${port}${base}/api/${api_ver}/health"
}

bazarr_key_ok() {
  container_curl bazarr -s --fail -o /dev/null -H "X-API-KEY: $1" \
    "http://127.0.0.1:${BAZARR_HTTP_PORT}/bazarr/api/system/status"
}

lazylibrarian_key_ok() {
  local body
  # LazyLibrarian serves HTTPS on its port when https_enabled is set
  body=$(container_curl lazylibrarian -sk "https://127.0.0.1:${LAZYLIBRARIAN_HTTP_PORT}/lazylibrarian/api?cmd=getVersion&apikey=$1")
  [[ -n "$body" && "$body" != *"Incorrect API key"* ]]
}

# Mylar's and NZBHydra2's own configs are authoritative for where they listen,
# for the same reason arr_endpoint() exists: .env only says where they were
# meant to listen. Both echo "scheme port urlbase" with urlbase "" or "/foo".
mylar_endpoint() {
  local ssl port base scheme
  ssl=$(grep -oPm1 '(?<=^enable_https = ).*' "$MYLAR_INI" || true)
  port=$(grep -oPm1 '(?<=^http_port = ).*' "$MYLAR_INI" || true)
  base=$(grep -oPm1 '(?<=^http_root = ).*' "$MYLAR_INI" || true)
  [[ "${ssl,,}" == "true" ]] && scheme=https || scheme=http
  base="${base%/}"
  [[ -n "$base" && "$base" != /* ]] && base="/$base"
  echo "$scheme ${port} ${base}"
}

nzbhydra_endpoint() {
  local ssl port base scheme
  port=$(yq -r '.main.port // ""' "$NZBHYDRA_YML" 2>/dev/null || true)
  ssl=$(yq -r '.main.ssl // false' "$NZBHYDRA_YML" 2>/dev/null || true)
  base=$(yq -r '.main.urlBase // ""' "$NZBHYDRA_YML" 2>/dev/null || true)
  [[ "${ssl,,}" == "true" ]] && scheme=https || scheme=http
  [[ "$base" == "null" ]] && base=""
  base="${base%/}"
  [[ -n "$base" && "$base" != /* ]] && base="/$base"
  echo "$scheme ${port} ${base}"
}

mylar_key_ok() {
  local body scheme port base
  read -r scheme port base <<<"$(mylar_endpoint)"
  body=$(container_curl mylar -sk "${scheme}://127.0.0.1:${port}${base}/api?cmd=getVersion&apikey=$1")
  [[ -n "$body" && "$body" != *"Incorrect API key"* && "$body" != *"Invalid apikey"* ]]
}

nzbhydra_key_ok() {
  local body scheme port base
  read -r scheme port base <<<"$(nzbhydra_endpoint)"
  body=$(container_curl nzbhydra2 -sk "${scheme}://127.0.0.1:${port}${base}/api?t=caps&apikey=$1")
  [[ -n "$body" && "$body" != *"<error"* ]]
}

jellyfin_key_ok() {
  container_curl jellyfin -s --fail -o /dev/null \
    -H "Authorization: MediaBrowser Token=\"$1\"" \
    "http://127.0.0.1:${JELLYFIN_HTTP_PORT}${JELLYFIN_BASE_URL}/Auth/Keys"
}

VALIDATION_FAILURES=()
validate() {
  local name="$1" timeout="$2"
  shift 2
  if retry "$timeout" "$@"; then
    printf "%-14s  OK\n" "$name"
  else
    printf "%-14s  FAILED\n" "$name"
    VALIDATION_FAILURES+=("$name")
  fi
}

echo ""
echo "======================================================================"
echo " Validating rotated API keys"
echo "======================================================================"
[[ -n "$SUMMARY_SONARR_NEW" ]] && validate sonarr 180 arr_key_ok sonarr "$SONARR_XML" v3 "$SUMMARY_SONARR_NEW"
[[ -n "$SUMMARY_RADARR_NEW" ]] && validate radarr 180 arr_key_ok radarr "$RADARR_XML" v3 "$SUMMARY_RADARR_NEW"
[[ -n "$SUMMARY_LIDARR_NEW" ]] && validate lidarr 180 arr_key_ok lidarr "$LIDARR_XML" v1 "$SUMMARY_LIDARR_NEW"
[[ -n "$SUMMARY_READARR_NEW" ]] && validate readarr 180 arr_key_ok readarr "$READARR_XML" v1 "$SUMMARY_READARR_NEW"
[[ -n "$SUMMARY_WHISPARR_NEW" ]] && validate whisparr 180 arr_key_ok whisparr "$WHISPARR_XML" v3 "$SUMMARY_WHISPARR_NEW"
[[ -n "$SUMMARY_PROWLARR_NEW" ]] && validate prowlarr 180 arr_key_ok prowlarr "$PROWLARR_XML" v1 "$SUMMARY_PROWLARR_NEW"
[[ -n "$SUMMARY_BAZARR_NEW" ]] && validate bazarr 180 bazarr_key_ok "$SUMMARY_BAZARR_NEW"
[[ -n "$SUMMARY_LAZYLIBRARIAN_NEW" ]] && validate lazylibrarian 180 lazylibrarian_key_ok "$SUMMARY_LAZYLIBRARIAN_NEW"
[[ -n "$SUMMARY_MYLAR_NEW" ]] && validate mylar 300 mylar_key_ok "$SUMMARY_MYLAR_NEW"
[[ -n "$SUMMARY_NZBHYDRA2_NEW" ]] && validate nzbhydra2 240 nzbhydra_key_ok "$SUMMARY_NZBHYDRA2_NEW"
[[ -n "$SUMMARY_JELLYFIN_NEW" ]] && validate jellyfin 120 jellyfin_key_ok "$SUMMARY_JELLYFIN_NEW"
echo "======================================================================"

if [[ ${#VALIDATION_FAILURES[@]} -gt 0 ]]; then
  echo ""
  echo "ERROR: validation failed for: ${VALIDATION_FAILURES[*]}" >&2
  exit 1
fi
