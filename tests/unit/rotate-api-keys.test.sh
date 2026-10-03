#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for scripts/rotate-api-keys.sh. Every line of the script has to run in
# one of them: `make coverage` runs this file under kcov and fails below 100%.
#
# The script runs in a scratch repository against stand ins for podman and
# the rest (tests/unit/stack-stubs.bash). Each app's API answers through the
# podman stub's rules, keyed on the URL its curl asks for, and every call the
# script makes lands in the stub's log, which the checks below read. The new
# keys come from the openssl stub, numbered from 0001ffff..., in the order the
# script asks for them.

set -o errexit
set -o pipefail
set -o nounset

__script_name=rotate-api-keys.sh
# shellcheck source=tests/unit/stack-stubs.bash
source "$(dirname "${BASH_SOURCE[0]}")/stack-stubs.bash"

key() { printf '%04dffffffffffffffffffffffffffff' "${1}"; }

# The summary's row for a service, keys shown by their first four characters.
row() { printf '%-12s  %-12s  %-12s' "${1}" "${2}****" "${3}****"; }

# The validation's line for a service that passed.
ok() { printf '%-14s  OK' "${1}"; }

# arr_xml <app> <ssl> <port> <ssl port> <url base> [<api key>]
arr_xml() {
  local api_key="${6-old-${1}}"
  put "configs/${1}/config/config.xml" <<EOF
<Config>
  <Port>${3}</Port>
  <SslPort>${4}</SslPort>
  <EnableSsl>${2}</EnableSsl>
  <UrlBase>${5}</UrlBase>
  <ApiKey>${api_key}</ApiKey>
</Config>
EOF
}

# indexers_db <path>: an arr app's database with one indexer pointing at
# NZBHydra2 and one that does not.
indexers_db() {
  mkdir -p "$(dirname "${__repo}/${1}")"
  python3 - "${__repo}/${1}" <<'EOF'
import json, sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute("CREATE TABLE Indexers (Id INTEGER PRIMARY KEY, Settings TEXT)")
conn.execute("INSERT INTO Indexers VALUES (1, ?)", (json.dumps({"baseUrl": "http://nzbhydra2:5076", "apiKey": "0000hydra"}),))  # pragma: allowlist secret
conn.execute("INSERT INTO Indexers VALUES (2, ?)", (json.dumps({"baseUrl": "http://elsewhere", "apiKey": "other"}),))  # pragma: allowlist secret
conn.commit()
EOF
}

db_settings() {
  python3 -c 'import sqlite3, sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT Settings FROM Indexers WHERE Id = ?", (sys.argv[2],)).fetchone()[0])' "${__repo}/${1}" "${2}"
}

# A complete deployment: every service enabled, every container present, and
# every config file the script edits in place.
deployment() {
  fresh_repo <<'EOF'
CONTAINER_PREFIX=
JELLYFIN_HTTP_PORT=8096
JELLYFIN_BASE_URL=/jellyfin
BAZARR_HTTP_PORT=6767
LAZYLIBRARIAN_HTTP_PORT=5299
SONARR_PROFILE=enabled
RADARR_PROFILE=enabled
LIDARR_PROFILE=enabled
READARR_PROFILE=enabled
WHISPARR_PROFILE=enabled
PROWLARR_PROFILE=enabled
BAZARR_PROFILE=enabled
LAZYLIBRARIAN_PROFILE=enabled
MYLAR_PROFILE=enabled
NZBHYDRA2_PROFILE=enabled
JELLYFIN_PROFILE=enabled
EOF
  containers sonarr radarr lidarr readarr whisparr prowlarr bazarr lazylibrarian mylar nzbhydra2 jellyfin homepage
  arr_xml sonarr False 8989 9898 ""
  arr_xml radarr True 7878 7879 /radarr/
  arr_xml lidarr True 8686 8687 lidarr
  arr_xml readarr True 8787 8788 readarr
  arr_xml whisparr True 6969 6970 whisparr
  arr_xml prowlarr True 9696 9697 prowlarr
  put configs/bazarr/config/config/config.yaml '{"auth": {"apikey": "old-bazarr"}, "sonarr": {"apikey": "old-sonarr"}, "radarr": {"apikey": "old-radarr"}}' # pragma: allowlist secret

  put configs/recyclarr/config/secrets.yml '{"sonarr_apikey": "old-sonarr", "radarr_apikey": "old-radarr"}' # pragma: allowlist secret
  put configs/lazylibrarian/config/config.ini <<'EOF'
[General]
api_key = old-lazylibrarian
[Torznab_0]
host = https://prowlarr:9697/prowlarr/1/
api = old-prowlarr
[Newznab_0]
host = http://nzbhydra2:5076
api = 0000hydra
[Newznab_1]
host = http://elsewhere
api = untouched
EOF
  put configs/mylar/config/mylar/config.ini <<'EOF'
[Interface]
api_key = old-mylar
enable_https = True
http_port = 8090
http_root = mylar/
[Newznab]
extra_newznabs = nzbhydra2, http://nzbhydra2:5076/nzbhydra2, 1, 0000hydra, 0
EOF
  put configs/nzbhydra2/config/nzbhydra.yml '{"main": {"apiKey": "{OBF}old", "port": 5076, "ssl": true, "urlBase": "nzbhydra2"}}'
  put configs/jellyfin/secrets/api_key.txt old-jellyfin
  indexers_db configs/sonarr/config/sonarr.db
  indexers_db configs/whisparr/config/whisparr3.db
  # Prowlarr's applications, without one for Mylar.
  rule 'prowlarr curl -sk -H .*/prowlarr/api/v1/applications$' 0 '[
    {"id": 1, "name": "Sonarr", "fields": [{"name": "apiKey", "value": "old-sonarr"}, {"name": "baseUrl", "value": "x"}]},
    {"id": 2, "name": "Radarr", "fields": [{"name": "apiKey", "value": "old-radarr"}]},
    {"id": 3, "name": "Lidarr", "fields": [{"name": "apiKey", "value": "old-lidarr"}]},
    {"id": 4, "name": "Readarr", "fields": [{"name": "apiKey", "value": "old-readarr"}]},
    {"id": 5, "name": "Whisparr", "fields": [{"name": "apiKey", "value": "old-whisparr"}]},
    {"id": 6, "name": "LazyLibrarian", "fields": [{"name": "apiKey", "value": "old-lazylibrarian"}]}]'
  # Each arr app's indexers, one pushed by Prowlarr and one added by hand.
  local indexers='[
    {"id": 7, "name": "Archive (Prowlarr)", "fields": [{"name": "baseUrl", "value": "https://prowlarr:9697/prowlarr/1/"}, {"name": "apiKey", "value": "old-prowlarr"}]},
    {"id": 8, "name": "By hand", "fields": [{"name": "baseUrl", "value": "https://elsewhere/"}]},
    {"id": 9, "name": "No fields"}]'
  rule 'curl -sk --fail -H X-Api-Key: \S+ \S+/indexer$' 0 "${indexers}"
  rule '/System/Info/Public$' 0 '{"StartupWizardCompleted": true}'
  rule 'curl -s --fail -H Authorization: MediaBrowser Token="old-jellyfin" \S+/Auth/Keys$' 0 \
    '{"Items": [{"AccessToken": "old-jellyfin", "DateCreated": "1"}, {"AccessToken": "new-jellyfin", "DateCreated": "3"}, {"AccessToken": "other", "DateCreated": "2"}]}'
  rule 'lazylibrarian/api\?cmd=getVersion' 0 '{"Success": true}'
  rule 'mylar curl -sk https://127.0.0.1:8090/mylar/api\?cmd=getVersion' 0 '{"success": true}'
  rule 'nzbhydra2 curl -sk https://127.0.0.1:5076/nzbhydra2/api\?t=caps' 0 '<caps/>'
}

# Arguments.
deployment
run
check "refuses to run without a target" 1 err "Usage: "

deployment
run sonarr radarr
check "refuses more than one target" 1 err "Usage: "

deployment
run everything
check "rejects an unknown target" 1 err "Unknown target: everything"

# The whole stack.
deployment
run all
check "all rotates every service" 0 out \
  "$(row sonarr old- 0001)" "$(row radarr old- 0002)" "$(row lidarr old- 0003)" \
  "$(row readarr old- 0004)" "$(row whisparr old- 0005)" "$(row prowlarr old- 0006)" \
  "$(row bazarr old- 0007)" "$(row lazylibrarian old- 0008)" "$(row mylar old- 0009)" \
  "$(row nzbhydra2 0006 0010)" "$(row jellyfin old- new-)"
check "all validates every new key" 0 out \
  "$(ok sonarr)" "$(ok radarr)" "$(ok lidarr)" "$(ok readarr)" "$(ok whisparr)" "$(ok prowlarr)" \
  "$(ok bazarr)" "$(ok lazylibrarian)" "$(ok mylar)" "$(ok nzbhydra2)" "$(ok jellyfin)"
check "the new ApiKey is in config.xml" 0 configs/sonarr/config/config.xml "<ApiKey>$(key 1)</ApiKey>"
check "the new key is the homepage secret" 0 configs/sonarr/secrets/api_key.txt "$(key 1)"
check "Bazarr learns Sonarr's and Radarr's keys and its own" 0 configs/bazarr/config/config/config.yaml \
  "\"apikey\": \"$(key 1)\"" "\"apikey\": \"$(key 2)\"" "\"apikey\": \"$(key 7)\""
check "recyclarr learns Sonarr's and Radarr's keys" 0 configs/recyclarr/config/secrets.yml \
  "\"sonarr_apikey\": \"$(key 1)\"" "\"radarr_apikey\": \"$(key 2)\""
check "LazyLibrarian gets its own key, Prowlarr's and NZBHydra2's" 0 configs/lazylibrarian/config/config.ini \
  "api_key = $(key 8)" "api = $(key 6)" "api = $(key 10)" "api = untouched"
check "Mylar gets its own key and NZBHydra2's" 0 configs/mylar/config/mylar/config.ini \
  "api_key = $(key 9)" "http://nzbhydra2:5076/nzbhydra2, 1, $(key 10), 0"
check "NZBHydra2's key is written plain" 0 configs/nzbhydra2/config/nzbhydra.yml "\"apiKey\": \"$(key 10)\""
if [[ "$(db_settings configs/sonarr/config/sonarr.db 1)" != *"$(key 10)"* || "$(db_settings configs/whisparr/config/whisparr3.db 2)" != *other* ]]; then
  fail "only the NZBHydra2 indexer row changes"
fi
check "Prowlarr's application for Sonarr gets the new key" 0 log \
  "podman exec prowlarr curl -sk --fail -X PUT -H X-Api-Key: old-prowlarr -H Content-Type: application/json -d {\n  \"id\": 1,\n  \"name\": \"Sonarr\",\n  \"fields\": [\n    {\n      \"name\": \"apiKey\",\n      \"value\": \"$(key 1)\"" \
  "https://127.0.0.1:9697/prowlarr/api/v1/applications/1?forceSave=true"
check "an app without a Prowlarr application is skipped" 0 out "[Prowlarr] No application entry named 'Mylar', skipping."
check "Prowlarr's new key reaches the indexers it pushed" 0 out \
  "[Prowlarr] Updated sonarr's indexer 'Archive (Prowlarr)' with the new API key." \
  "[Prowlarr] Updated LazyLibrarian's Torznab entry with the new API key."
refute "hand added indexers keep their key" out "indexer 'By hand'"
check "the arr apps are reached where their config.xml says" 0 log \
  "http://127.0.0.1:8989/api/v3/health" "https://127.0.0.1:7879/radarr/api/v3/health" \
  "https://127.0.0.1:8687/lidarr/api/v1/health"
check "Mylar is stopped without the long timeout" 0 log "podman stop mylar"
check "the others get the long timeout" 0 log "podman stop --time 60 sonarr"
check "Jellyfin's new key replaces the old one" 0 configs/jellyfin/secrets/api_key.txt new-jellyfin
check "Jellyfin's old key is revoked" 0 log "-X DELETE -H Authorization: MediaBrowser Token=\"new-jellyfin\" http://127.0.0.1:8096/jellyfin/Auth/Keys/old-jellyfin"
check "homepage is recreated" 0 log "podman-compose --file docker-compose.yml --profile enabled up -d --force-recreate homepage"
check "permissions are repaired" 0 log "permissions.py repair --runtime podman --recursive"

# Each service on its own.
for service in sonarr radarr lidarr readarr whisparr prowlarr bazarr lazylibrarian mylar nzbhydra2 jellyfin; do
  deployment
  run "${service}"
  check "${service} rotates on its own" 0 out "$(ok "${service}")"
  if [[ "$(grep -c '  OK$' "${__scratch}/out")" -ne 1 ]]; then
    fail "${service} on its own validates only itself"
  fi
done

# Containers prefixed for a second checkout.
deployment
sed -i 's/^CONTAINER_PREFIX=$/CONTAINER_PREFIX=dev-/' "${__repo}/.env"
containers dev-bazarr
run bazarr
check "container names carry CONTAINER_PREFIX" 0 log "podman stop --time 60 dev-bazarr" "podman start dev-bazarr"
refute "no homepage, no recreate" log "podman-compose"

# Profiles and containers.
deployment
sed -i 's/^SONARR_PROFILE=enabled$/SONARR_PROFILE=disabled/' "${__repo}/.env"
containers radarr lidarr readarr whisparr bazarr lazylibrarian mylar nzbhydra2 jellyfin
rule '/System/Info/Public$' 0 '{"StartupWizardCompleted": false}'
run all
check "all skips a disabled service" 0 out "[sonarr] Skipped, SONARR_PROFILE is disabled"
check "all skips a missing container" 0 out "[prowlarr] Skipped, container doesn't exist"
check "no Prowlarr, no application update" 0 out \
  "[Prowlarr] Container doesn't exist, skipping application update for 'Radarr'."
check "Jellyfin waits for its setup wizard" 0 out "[Jellyfin] Setup wizard not completed yet, skipping API key rotation."

run sonarr
check "a disabled service cannot be named" 1 err "ERROR: SONARR_PROFILE is disabled in .env; not rotating sonarr"

run prowlarr
check "a missing container cannot be named" 1 err "ERROR: container 'prowlarr' doesn't exist; not rotating it"

# Prowlarr down: the first wait spends the whole budget, the rest one check.
deployment
rule 'prowlarr curl .*/system/status$' 7 ""
run all
check "a Prowlarr that never answers is skipped" 0 out \
  "[Prowlarr] Didn't come up in time, skipping application update for 'Sonarr'." \
  "[Prowlarr] Didn't come back up with the new key in time, skipping indexer key propagation."
# 24 tries over the first 120s, then one each for Radarr, Lidarr, Readarr,
# Whisparr, Prowlarr's own propagation, LazyLibrarian and Mylar.
if [[ "$(grep -c 'prowlarr/api/v1/system/status' "${__state}/log")" -ne 31 ]]; then
  fail "only the first wait is a long one: Prowlarr's status asked $(grep -c 'prowlarr/api/v1/system/status' "${__state}/log") times"
fi

# Prowlarr's own rotation, against apps that are missing or not answering.
deployment
containers sonarr radarr lidarr readarr prowlarr homepage
arr_xml readarr True 8787 8788 readarr ""
rule 'radarr curl -sk --fail -H X-Api-Key: \S+ \S+/indexer$' 22 ""
rule 'lidarr curl -sk --fail -X PUT' 22 ""
run prowlarr
check "an indexer that will not take the key is reported" 0 out \
  "[Prowlarr] WARNING: failed to update lidarr's indexer 'Archive (Prowlarr)' with the new API key."
refute "an app without a key is left alone" log "readarr curl"
refute "LazyLibrarian without a container is left alone" out "LazyLibrarian's Torznab"

# The container disappears between the checks.
deployment
containers sonarr
rule '^podman container exists prowlarr$' 0 "" 1
run prowlarr
check "Prowlarr gone before propagation skips it" 0 out "$(row prowlarr old- 0001)"
refute "and nothing is re-synced" log "ApplicationIndexerSync"

# A container that will not start again.
deployment
rule '^podman start sonarr$' 125 "" 2
rule '^podman stop --time 60 radarr$' 0 ""
run all
check "a start that fails is retried" 0 out "$(row sonarr old- 0001)"
check "a container still running is not started again" 0 out "$(row radarr old- 0002)"
refute "radarr was never down" log "podman start radarr"

deployment
rule '^podman start sonarr$' 125 ""
run sonarr
check "a start that keeps failing is reported" 0 err "ERROR: could not start: sonarr"

# config.xml that does not take the new key.
deployment
touch "${__state}/xmlstarlet-noop"
run radarr
check "an ApiKey that did not change stops the run" 1 err "[Radarr] ERROR: ApiKey did not update as expected in configs/radarr/config/config.xml"
check "and the app is started again" 1 log "podman start radarr"

# Apps that have not finished their first boot, and files not there.
deployment
put configs/lazylibrarian/config/config.ini "[General]"
put configs/mylar/config/mylar/config.ini "[Interface]"
rm "${__repo}/configs/recyclarr/config/secrets.yml"
run all
check "LazyLibrarian without an api_key is skipped" 0 out "[LazyLibrarian] No api_key in config.ini yet (let it finish its first boot), skipping."
check "Mylar without an api_key is skipped" 0 out "[Mylar] No api_key in config.ini yet (let it finish its first boot), skipping."
check "no recyclarr secrets, nothing to update" 0 out "[recyclarr] configs/recyclarr/config/secrets.yml doesn't exist, skipping."

# Jellyfin that does not hand out a new key.
deployment
rule 'Auth/Keys$' 0 '{"Items": [{"AccessToken": "old-jellyfin", "DateCreated": "1"}]}'
run jellyfin
check "no new Jellyfin key is fatal" 1 err "[Jellyfin] ERROR: could not obtain the newly created API key"

# homepage that will not recreate.
deployment
rule '^podman-compose ' 1 ""
run bazarr
check "homepage that will not recreate fails the run" 1 err "ERROR: homepage still would not recreate after retries"

# Keys the services do not accept afterwards.
deployment
rule 'lazylibrarian/api\?cmd=getVersion' 0 "Incorrect API key"
rule 'mylar curl -sk https://127.0.0.1:8090/mylar/api\?cmd=getVersion' 0 "Invalid apikey"
rule 'nzbhydra2 curl -sk https://127.0.0.1:5076/nzbhydra2/api\?t=caps' 0 '<error code="100"/>'
put configs/nzbhydra2/config/nzbhydra.yml '{"main": {"apiKey": "{OBF}old", "port": 5076, "urlBase": null}}'
run all
check "keys the services refuse fail validation" 1 err "ERROR: validation failed for: lazylibrarian mylar nzbhydra2"
check "NZBHydra2 without ssl or urlBase is plain http at the root" 1 log "nzbhydra2 curl -sk http://127.0.0.1:5076/api?t=caps"

finish
