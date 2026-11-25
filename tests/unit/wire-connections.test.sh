#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for scripts/wire-connections.sh. Every line of the script has to run
# in one of them: `make coverage` runs this file under kcov and fails below
# 100%.
#
# The script runs in a scratch repository against stand ins for podman and
# the rest (tests/unit/stack-stubs.bash). deployment() builds a stack where
# everything is already wired, as rules for each app's API keyed on the URL
# its curl asks for; each scenario then adds rules of its own, which win, for
# what differs. Every call the script makes lands in the stub's log, which
# the checks below read.

set -o errexit
set -o pipefail
set -o nounset

__script_name=wire-connections.sh
# shellcheck source=tests/unit/stack-stubs.bash
source "$(dirname "${BASH_SOURCE[0]}")/stack-stubs.bash"

# A value make exports stands in for a key .env lacks; each run below that
# wants one passes it.
unset NGINX_SERVICES_IP CONTAINER_PREFIX

readonly ARR_APPS=(sonarr radarr lidarr whisparr)
# Prowlarr's application schema, one implementation per app it can register.
APPLICATIONS_SCHEMA="$(
  for impl in LazyLibrarian Lidarr Mylar Radarr Sonarr Whisparr; do
    printf '{"implementation": "%s", "fields": [{"name": "prowlarrUrl"}, {"name": "baseUrl"}, {"name": "apiKey"}, {"name": "other"}]}\n' "${impl}"
  done | python3 -c 'import json, sys; print(json.dumps([json.loads(line) for line in sys.stdin]))'
)"
readonly APPLICATIONS_SCHEMA
readonly ALL_CONTAINERS=(audiobookshelf calibre calibre-web jellyfin "${ARR_APPS[@]}" prowlarr flaresolverr lazylibrarian mylar qbittorrent cleanuparr)
# Cleanuparr's API, as its curl asks for it: the method, then the path.
readonly CLEANUPARR='cleanuparr curl -sS -X'
readonly CLEANUPARR_API='\S+/cleanuparr/api'
# What Cleanuparr calls each arr app, and where it reaches it.
declare -A CLEANUPARR_NAME=([lidarr]=Lidarr [radarr]=Radarr [sonarr]=Sonarr [whisparr]=Whisparr)
declare -A CLEANUPARR_URL=([lidarr]=https://lidarr:8687/lidarr [radarr]=https://radarr:7879/radarr
  [sonarr]=https://sonarr:9899/sonarr [whisparr]=https://whisparr:6970/whisparr)
readonly CLEANUPARR_NAME CLEANUPARR_URL
# The queue cleaner as wire-connections.sh leaves it.
readonly QUEUE_CLEANER_WIRED='{"enabled":true,"cronExpression":"0 0/5 * * * ?","failedImport":{"maxStrikes":3,"patternMode":"Include","patterns":[".exe",".scr",".bat",".cmd",".pif",".msi",".lnk",".vbs",".ps1"]}}'
# What bootstrap seeds Jellyfin's key file with, a key Jellyfin never issued.
readonly JELLYFIN_PLACEHOLDER=0123456789abcdef0123456789abcdef # pragma: allowlist secret
readonly QBT_PREFERENCES='exec qbittorrent curl -sk --fail -b \S+ \S+/api/v2/app/preferences$'
readonly QBT_CATEGORIES='exec qbittorrent curl -sk --fail -b \S+ \S+/api/v2/torrents/categories$'

# calibre_web_db [<database dir>] [<users>] [<books dir>]: Calibre-Web's
# app.db with its settings row, or with no settings table at all when given
# "none". The library is split when the books dir is not empty, which is what
# wire-connections.sh sets up; a pre-#402 one has the books dir as its
# database dir and no split.
calibre_web_db() {
  rm -f "${__repo}/configs/calibre-web/config/app.db"
  mkdir -p "${__repo}/configs/calibre-web/config"
  python3 - "${__repo}/configs/calibre-web/config/app.db" "${1-/calibre-db}" "${2-2}" "${3-/data/media/calibre-library}" <<'EOF'
import sqlite3, sys
path, library, users, books = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
conn = sqlite3.connect(path)
conn.execute("CREATE TABLE user (id INTEGER PRIMARY KEY, name TEXT, role INTEGER, password TEXT)")
conn.executemany("INSERT INTO user VALUES (?, ?, ?, ?)", [(i, f"user{i}", 1, "") for i in range(1, users + 1)])
if library != "none":
    conn.execute(
        "CREATE TABLE settings (id INTEGER PRIMARY KEY, config_calibre_dir TEXT,"
        " config_calibre_split BOOLEAN, config_calibre_split_dir TEXT)"
    )
    conn.execute("INSERT INTO settings VALUES (1, ?, ?, ?)", (library, 1 if books else 0, books or None))
conn.commit()
EOF
}

# mylar_db <comics>: mylar.db holding that many comics.
mylar_db() {
  rm -f "${__repo}/configs/mylar/config/mylar/mylar.db"
  mkdir -p "${__repo}/configs/mylar/config/mylar"
  python3 - "${__repo}/configs/mylar/config/mylar/mylar.db" "${1}" <<'EOF'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute(
    "CREATE TABLE comics (ComicID TEXT, ComicName TEXT, ComicYear TEXT, DateAdded TEXT, Status TEXT,"
    " Have INTEGER, Total INTEGER, ComicPublisher TEXT)"
)
for i in range(int(sys.argv[2])):
    conn.execute("INSERT INTO comics (ComicID) VALUES (?)", (str(i),))
conn.commit()
EOF
}

# arr_db <path> <api key>: an arr app's database holding a Jellyfin
# (MediaBrowser) connection that stores that key.
arr_db() {
  rm -f "${__repo}/${1}"
  mkdir -p "$(dirname "${__repo}/${1}")"
  python3 - "${__repo}/${1}" "${2}" <<'EOF'
import json, sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute("CREATE TABLE Notifications (Id INTEGER PRIMARY KEY, Implementation TEXT, Settings TEXT)")
conn.execute("INSERT INTO Notifications VALUES (4, 'MediaBrowser', ?)", (json.dumps({"host": "x", "apiKey": sys.argv[2]}),))
conn.commit()
EOF
}

# arr_db_settings <path> <settings>: the same, with Settings exactly as given,
# or SQL NULL for the word NULL.
arr_db_settings() {
  arr_db "${1}" unused
  python3 - "${__repo}/${1}" "${2}" <<'EOF'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute("UPDATE Notifications SET Settings = ?", (None if sys.argv[2] == "NULL" else sys.argv[2],))
conn.commit()
EOF
}

query() {
  python3 -c 'import sqlite3, sys; print(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchall())' "${__repo}/${1}" "${2}"
}

# A stack where every connection already exists.
deployment() {
  fresh_repo <<'EOF'
CONTAINER_PREFIX=
LAN_IP=192.168.1.x
GLUETUN_SERVICES_IP=10.0.0.2
QBITTORRENT_HTTPS_PORT=8443
SABNZBD_HTTP_PORT=8080
SABNZBD_HTTPS_PORT=8090
SONARR_HTTP_PORT=8989
SONARR_HTTPS_PORT=9899
RADARR_HTTPS_PORT=7879
LIDARR_HTTPS_PORT=8687
WHISPARR_HTTPS_PORT=6970
PROWLARR_HTTPS_PORT=9697
LAZYLIBRARIAN_HTTP_PORT=5299
MYLAR_HTTPS_PORT=8091
JELLYFIN_HTTP_PORT=8096
JELLYFIN_BASE_URL=/jellyfin
AUDIOBOOKSHELF_HTTP_PORT=13378
CALIBREWEB_VERSION=0.6
FLARESOLVERR_HTTP_PORT=8191
NGINX_SERVICES_IP=192.0.2.5
SERVICES_SUBNET=10.0.0.0/24
CLEANUPARR_HTTP_PORT=11011
EOF
  containers "${ALL_CONTAINERS[@]}"
  local app k
  for app in "${ARR_APPS[@]}" prowlarr; do
    k="key-${app}"
    put "configs/${app}/config/config.xml" "<Config><ApiKey>${k}</ApiKey></Config>"
  done
  # Download client addresses where the .env above says.
  put configs/lazylibrarian/config/config.ini <<'EOF'
[GENERAL]
audiobook_type = m4b, m4a, mp3, flac, opus, ogg, aac
api_key = key-lazylibrarian
[SABNZBD]
sab_host = https://10.0.0.2
sab_port = 8090
[QBITTORRENT]
qbittorrent_host = https://10.0.0.2
qbittorrent_port = 8443
EOF
  put configs/mylar/config/mylar/config.ini <<'EOF'
api_key = key-mylar
[SABnzbd]
sab_host = https://10.0.0.2:8090/sabnzbd
[qBittorrent]
qbittorrent_host = https://10.0.0.2:8443
[DDL]
jd2_url = http://10.0.0.2:3128
EOF
  put configs/qbittorrent/secrets/username.txt qbittorrent
  put configs/qbittorrent/secrets/password.txt qbittorrent-password # pragma: allowlist secret
  put configs/sabnzbd/secrets/api_key.txt sabnzbd-key
  put configs/jellyfin/secrets/api_key.txt jellyfin-key
  put configs/jellyfin/secrets/api_key.txt.example "${JELLYFIN_PLACEHOLDER}"
  # Each Jellyfin connection the rules below report holds the current key.
  arr_db configs/sonarr/config/sonarr.db jellyfin-key
  arr_db configs/radarr/config/radarr.db jellyfin-key
  arr_db configs/lidarr/config/lidarr.db jellyfin-key
  arr_db configs/whisparr/config/whisparr3.db jellyfin-key
  put configs/audiobookshelf/secrets/api_key.txt abs-key
  put configs/calibre/secrets/password.txt calibre-password
  calibre_web_db
  mylar_db 1

  # Audiobookshelf, initialized, with this script's API key.
  rule 'wget -qO- http://127.0.0.1:13378/status$' 0 '{"isInit": true}'
  rule 'wget -qO- --header=Content-Type: application/json --post-data=\S+ http://127.0.0.1:13378/login$' 0 \
    '{"user": {"id": "root-id", "token": "abs-token"}}'
  rule 'Bearer abs-token http://127.0.0.1:13378/api/api-keys$' 0 '{"apiKeys": [{"name": "wire-connections"}]}'
  # Calibre's content server user.
  rule 'calibre-server --userdb \S+ --manage-users -- list$' 0 $'calibre\n'
  # Jellyfin, set up, with its key and BaseUrl in place.
  rule 'exec jellyfin curl .*/System/Info/Public$' 0 '{"StartupWizardCompleted": true}'
  rule '/Users/AuthenticateByName$' 0 '{"AccessToken": "jellyfin-token"}'
  rule 'jellyfin curl -sS --fail -H Authorization: MediaBrowser Token="jellyfin-token" \S+/Auth/Keys$' 0 \
    '{"Items": [{"AccessToken": "other-key", "DateCreated": "2"}, {"AccessToken": "jellyfin-key", "DateCreated": "1"}]}'
  rule 'jellyfin curl -sS --fail -H Authorization: MediaBrowser Token="jellyfin-token" \S+/System/Configuration/network$' 0 \
    '{"BaseUrl": "/jellyfin", "Other": 1}'
  # The arr apps, each logged in, with both download clients where the .env
  # above says and a Jellyfin connection.
  rule 'curl -sk --fail -H X-Api-Key: \S+ \S+/config/host$' 0 '{"id": 1, "username": "someone", "certificateValidation": "disabledForLocalAddresses"}'
  rule 'curl -sk --fail -H X-Api-Key: \S+ \S+/downloadclient$' 0 '[
    {"id": 1, "implementation": "QBittorrent", "enable": true, "fields": [{"name": "host", "value": "10.0.0.2"}, {"name": "port", "value": 8443}, {"name": "useSsl", "value": true}]},
    {"id": 2, "implementation": "Sabnzbd", "fields": [{"name": "host", "value": "10.0.0.2"}, {"name": "port", "value": 8080}, {"name": "useSsl", "value": false}]}]'
  rule 'curl -sk --fail -H X-Api-Key: \S+ \S+/notification$' 0 '[{"implementation": "MediaBrowser"}]'
  rule 'curl -sk --fail -H X-Api-Key: \S+ \S+/notification/schema$' 0 \
    '[{"implementation": "MediaBrowser", "fields": [{"name": "host"}, {"name": "apiKey"}]}]'
  # Connections are sent without --fail, so the app's answer survives: its
  # body, then the status curl's -w appends.
  rule 'curl -sSk -X POST .*/notification$' 0 $'{"id": 7}\n201'
  rule 'curl -sSk -X PUT .*/notification/[0-9]+$' 0 $'{"id": 4}\n202'
  rule 'curl -sSk -X POST .*/downloadclient$' 0 $'{"id": 1}\n201'
  rule 'curl -sSk -X PUT .*/downloadclient/[0-9]+$' 0 $'{"id": 1}\n202'
  rule 'curl -sSk -X PUT .*/downloadclient/[0-9]+\?forceSave=true$' 0 $'{"id": 1}\n202'
  # Prowlarr, with its tagged proxy, every application, the indexer, and
  # that indexer in every arr app.
  rule 'prowlarr curl -sk --fail -H X-Api-Key: \S+ \S+/indexerproxy$' 0 '[{"id": 4, "implementation": "FlareSolverr", "tags": [5]}]'
  rule 'prowlarr curl -sk --fail -X POST .*/prowlarr/api/v1/tag$' 0 '{"id": 5, "label": "flaresolverr"}'
  rule 'prowlarr curl -sk --fail -H X-Api-Key: \S+ \S+/applications$' 0 \
    '[{"name": "LazyLibrarian"}, {"name": "Lidarr"}, {"name": "Mylar"}, {"name": "Radarr"}, {"name": "Sonarr"}, {"name": "Whisparr"}]'
  rule 'prowlarr curl -sk --fail -H X-Api-Key: \S+ \S+/prowlarr/api/v1/indexer$' 0 '[{"id": 3, "name": "Internet Archive", "enable": true}]'
  rule '/prowlarr/api/v1/indexerstatus$' 0 '[]'
  rule 'exec (lidarr|radarr|sonarr) curl -sk --fail -H X-Api-Key: \S+ \S+/api/v[13]/indexer$' 0 '[{"id": 1}]'
  # Mylar answering.
  rule 'mylar curl -sk --max-time 10 -o /dev/null' 0 200
  # qBittorrent, already trusting only nginx as its reverse proxy.
  rule "${QBT_PREFERENCES}" 0 '{"web_ui_reverse_proxy_enabled": true, "web_ui_reverse_proxies_list": "192.0.2.5"}'
  # ... and removing mylar's torrents with their files at the share limit.
  rule "${QBT_CATEGORIES}" 0 '{"mylar": {"name": "mylar", "share_limit_action": "RemoveWithContent"}, "sonarr": {"name": "sonarr", "share_limit_action": "Default"}}'
  rule 'exec qbittorrent curl -sk --fail -b \S+ \S+/api/v2/app/version$' 0 "v5.3.0"
  # Cleanuparr, set up, with its key saved, qBittorrent and every arr app
  # connected, and its queue cleaner on. Requests carry no --fail, so each
  # answer is the body, then the status curl's -w appends.
  put configs/cleanuparr/secrets/password.txt cleanuparr-password # pragma: allowlist secret
  put configs/cleanuparr/secrets/api_key.txt key-cleanuparr
  rule 'exec cleanuparr curl -sf -o /dev/null http://127.0.0.1:11011/cleanuparr/health$' 0 ""
  rule "${CLEANUPARR} (POST|PUT) .*${CLEANUPARR_API}/configuration/" 0 $'{}\n200'
  rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/auth/status$" 0 $'{"setupCompleted": true}\n200'
  rule "${CLEANUPARR} GET .*X-Api-Key: key-cleanuparr ${CLEANUPARR_API}/account$" 0 $'{"username": "cleanuparr"}\n200'
  rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/configuration/general$" 0 \
    $'{"dryRun": false, "httpCertificateValidation": "DisabledForLocalAddresses"}\n200'
  rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/configuration/download_client$" 0 \
    $'{"clients": [{"id": "qbt-id", "name": "qBittorrent", "host": "https://10.0.0.2:8443/"}]}\n200'
  for app in "${ARR_APPS[@]}"; do
    rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/configuration/${app}$" 0 \
      "{\"instances\": [{\"id\": \"${app}-id\", \"name\": \"${CLEANUPARR_NAME[${app}]}\", \"url\": \"${CLEANUPARR_URL[${app}]}\"}]}"$'\n200'
  done
  rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/configuration/queue_cleaner$" 0 "${QUEUE_CLEANER_WIRED}"$'\n200'
}

# sent_post <app>: the download client that app was asked to create.
sent_post() { grep -F "podman exec ${1} curl -sSk -X POST" "${__state}/log" | grep -F "/downloadclient" || true; }

# Run A: nothing is set up yet.
deployment
put configs/jellyfin/secrets/api_key.txt placeholder
# Configured before #402: metadata.db among the books, no split.
calibre_web_db /data/media/calibre-library 0 ""
mylar_db 0
rule 'wget -qO- http://127.0.0.1:13378/status$' 0 '{"isInit": false}'
rule 'Bearer abs-token http://127.0.0.1:13378/api/api-keys$' 0 '{"apiKeys": [{"name": "someone else"}]}'
rule '--post-data=\{.*\} http://127.0.0.1:13378/api/api-keys$' 0 '{"apiKey": {"apiKey": "new-abs-key"}}' # pragma: allowlist secret
rule 'calibre-server --userdb \S+ --manage-users -- list$' 0 ""
rule 'exec jellyfin curl .*/System/Info/Public$' 0 '{"StartupWizardCompleted": false}'
rule 'jellyfin curl -s --fail -X POST .*/Startup/User$' 22 "" 6
rule 'jellyfin curl -sS --fail -H Authorization: MediaBrowser Token="jellyfin-token" \S+/System/Configuration/network$' 0 '{"BaseUrl": ""}'
rule 'curl -sk --fail -H X-Api-Key: \S+ \S+/config/host$' 0 '{"id": 1, "username": ""}'
rule 'curl -sk --fail -H X-Api-Key: \S+ \S+/downloadclient$' 0 '[]'
rule 'curl -sk --fail -H X-Api-Key: \S+ \S+/downloadclient/schema$' 0 '[
  {"implementation": "QBittorrent", "fields": [{"name": "host"}, {"name": "port"}, {"name": "useSsl"}, {"name": "username"}, {"name": "password"}, {"name": "tvCategory"}, {"name": "tvImportedCategory"}, {"name": "other"}]},
  {"implementation": "Sabnzbd", "fields": [{"name": "host"}, {"name": "port"}, {"name": "useSsl"}, {"name": "urlBase"}, {"name": "apiKey"}, {"name": "tvCategory"}]}]'
rule 'curl -sk --fail -H X-Api-Key: \S+ \S+/notification$' 0 '[]'
rule 'curl -sk --fail -H X-Api-Key: \S+ \S+/notification/schema$' 0 '[
  {"implementation": "Slack"},
  {"implementation": "MediaBrowser", "supportsOnDownload": true, "supportsOnImportComplete": true, "supportsOnReleaseImport": true,
    "supportsOnUpgrade": true, "supportsOnRename": false,
    "fields": [{"name": "host"}, {"name": "port"}, {"name": "useSsl"}, {"name": "urlBase"}, {"name": "apiKey"}, {"name": "updateLibrary"}, {"name": "other"}]}]'
rule 'curl -s --fail --max-time 5 http://host.containers.internal:' 7 ""
rule 'curl -sk --fail -H X-Api-Key: \S+ \S+/config/development$' 0 '{"id": 1, "metadataSource": ""}'
rule 'prowlarr curl -sk --fail -H X-Api-Key: \S+ \S+/indexerproxy$' 0 '[]'
rule 'prowlarr curl -sk --fail -H X-Api-Key: \S+ \S+/indexerproxy/schema$' 0 '[{"implementation": "FlareSolverr", "fields": [{"name": "host"}, {"name": "other"}]}]'
rule 'prowlarr curl -sk --fail -H X-Api-Key: \S+ \S+/applications$' 0 '[]'
rule 'prowlarr curl -sk --fail -H X-Api-Key: \S+ \S+/applications/schema$' 0 "${APPLICATIONS_SCHEMA}"
rule 'prowlarr curl -skS --fail -X POST .*"name": "Lidarr"' 22 "" 1
rule 'prowlarr curl -sk --fail -H X-Api-Key: \S+ \S+/prowlarr/api/v1/indexer$' 0 '[]' 1
rule 'prowlarr curl -sk --fail -H X-Api-Key: \S+ \S+/prowlarr/api/v1/indexer/schema$' 0 \
  '[{"definitionName": "other"}, {"definitionName": "internetarchive", "fields": [{"name": "baseUrl", "value": "x"}, {"name": "other"}]}]'
rule 'prowlarr curl -sk --fail -X POST .*/prowlarr/api/v1/indexer$' 0 '{"id": 3, "enable": false}'
rule '/prowlarr/api/v1/indexerstatus$' 0 '[{"id": 3}]' 6
rule 'exec sonarr curl -sk --fail -H X-Api-Key: \S+ \S+/api/v3/indexer$' 0 '[]' 1
rule 'mylar curl -sk --max-time 10 -o /dev/null' 0 000 7
rule "${QBT_PREFERENCES}" 0 '{"web_ui_reverse_proxy_enabled": false, "web_ui_reverse_proxies_list": ""}'
# Cleanuparr never set up, on a deployment updated to it rather than
# bootstrapped, so its secret files were never seeded. Its queue cleaner holds
# one pattern of its own already. The arr rule comes first so the general
# settings rule, newer, wins over it.
rm "${__repo}/configs/cleanuparr/secrets/password.txt" "${__repo}/configs/cleanuparr/secrets/api_key.txt"
rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/configuration/[a-z]+$" 0 $'{"instances": []}\n200'
rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/auth/status$" 0 $'{"setupCompleted": false}\n200'
rule "${CLEANUPARR} POST .*${CLEANUPARR_API}/auth/setup/(account|complete)$" 0 $'{}\n201'
rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/account$" 0 $'{"title": "Unauthorized"}\n401'
rule "${CLEANUPARR} POST .*${CLEANUPARR_API}/auth/login$" 0 \
  $'{"requiresTwoFactor": false, "tokens": {"accessToken": "cleanuparr-token"}}\n200'
rule "${CLEANUPARR} GET .*Bearer cleanuparr-token ${CLEANUPARR_API}/account/api-key$" 0 $'{"apiKey": "new-cleanuparr-key"}\n200' # pragma: allowlist secret
rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/configuration/general$" 0 \
  $'{"dryRun": false, "httpCertificateValidation": "Enabled"}\n200'
rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/configuration/download_client$" 0 $'{"clients": []}\n200'
rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/configuration/queue_cleaner$" 0 \
  $'{"enabled": false, "cronExpression": "0 0/5 * * * ?", "failedImport": {"maxStrikes": 0, "patternMode": "Exclude", "patterns": [".exe"]}}\n200'
run
check "Cleanuparr is set up from nothing" 0 out \
  "[Cleanuparr] Creating its login..." "[Cleanuparr] Saving its API key..." \
  "[Cleanuparr] Accepting self-signed certificates on local addresses..." \
  "[Cleanuparr] Connecting qBittorrent..." "[Cleanuparr] Connecting Lidarr..." "[Cleanuparr] Connecting Radarr..." \
  "[Cleanuparr] Connecting Sonarr..." "[Cleanuparr] Connecting Whisparr..." \
  "[Cleanuparr] Striking failed imports of the excluded file types..." "[Cleanuparr] Done."
check "a Cleanuparr with no password file gets a random password" 0 \
  configs/cleanuparr/secrets/password.txt 0001ffffffffffffffffffffffffffff                                                  # pragma: allowlist secret
check "Cleanuparr's login is that password" 0 log '{"username":"cleanuparr","password":"0001ffffffffffffffffffffffffffff"}' # pragma: allowlist secret
check "and its key is saved" 0 configs/cleanuparr/secrets/api_key.txt new-cleanuparr-key
for secret in password.txt api_key.txt; do
  if [[ "$(stat -c %a "${__repo}/configs/cleanuparr/secrets/${secret}")" != 600 ]]; then
    fail "Cleanuparr's ${secret} is readable only by its owner"
  fi
done
check "Cleanuparr accepts the stack's certificate" 0 log '"httpCertificateValidation":"DisabledForLocalAddresses"'
check "Cleanuparr logs in to qBittorrent on the services address" 0 log \
  '{"enabled":true,"name":"qBittorrent","typeName":"qBittorrent","host":"https://10.0.0.2:8443","username":"qbittorrent","password":"qbittorrent-password","urlBase":""}' # pragma: allowlist secret
instances=(
  '"name":"Sonarr","url":"https://sonarr:9899/sonarr","apiKey":"key-sonarr","version":4'         # pragma: allowlist secret
  '"name":"Whisparr","url":"https://whisparr:6970/whisparr","apiKey":"key-whisparr","version":3' # pragma: allowlist secret
)
check "Cleanuparr reaches each arr app over HTTPS" 0 log "${instances[@]}"
check "its queue cleaner strikes the excluded file types, keeping the pattern it had" 0 log \
  '"enabled":true' '"maxStrikes":3,"patternMode":"Include","patterns":[".exe",".scr",".bat",".cmd",".pif",".msi",".lnk",".vbs",".ps1"]'
check "qBittorrent trusts only nginx" 0 out \
  "[qBittorrent] Trusting only nginx (192.0.2.5) as its reverse proxy..." "[qBittorrent] Done."
check "qBittorrent is given nginx's address" 0 log \
  'json={"web_ui_reverse_proxy_enabled":true,"web_ui_reverse_proxies_list":"192.0.2.5"}' \
  "podman exec qbittorrent rm -f /tmp/qbt_wire_cookies."
check "a fresh stack is wired" 0 out \
  "[Audiobookshelf] Creating initial root user..." "[Audiobookshelf] Creating initial API key..." "[Audiobookshelf] Done." \
  "[Calibre] Creating content server user..." "[Calibre] Done." \
  "[Calibre-Web] app.db has no users (never seeded or lost mid-init), repairing..." \
  "[Calibre-Web] Restored the default admin/Guest users." "[Calibre-Web] Done." \
  "[Jellyfin] Completing first-run setup wizard..." "[Jellyfin] ...still waiting (30s/180s)" \
  "[Jellyfin] Creating initial API key..." "[Jellyfin] Setting BaseUrl to /jellyfin..." "[Jellyfin] Done." \
  "[sonarr] Setting up initial WebUI login and relaxing certificate validation for internal addresses..." \
  "[sonarr] Creating qBittorrent download client..." "[sonarr] Creating SABnzbd download client..." \
  "[sonarr] Creating Jellyfin connection..." \
  "[Prowlarr] Adding FlareSolverr indexer proxy..." "[Prowlarr] FlareSolverr indexer proxy added." \
  "[Prowlarr] Registering application 'Whisparr'..." "[Prowlarr] Registered." \
  "[Prowlarr] Adding indexer 'Internet Archive'..." "[Prowlarr] Added." \
  "[Prowlarr] waiting for indexer failure backoff to clear ...still waiting (30s/300s)" \
  "[Prowlarr] Still missing indexers in: sonarr" "[Prowlarr] Indexers present in every enabled arr app." \
  "[Mylar] Adding a placeholder comic so its Homepage widget has data..." "[Mylar] ...still waiting (3" \
  "[Mylar] Done."
refute "nothing failed" out "WARNING"
check "Audiobookshelf's new key is saved" 0 configs/audiobookshelf/secrets/api_key.txt new-abs-key
check "Jellyfin's newest key is saved" 0 configs/jellyfin/secrets/api_key.txt other-key
check "Jellyfin restarts for its BaseUrl" 0 log "podman restart jellyfin" '"BaseUrl": "/jellyfin"'
check "Calibre's user gets its password" 0 log "calibre-server --userdb /config/.config/calibre/server-users.sqlite --manage-users -- add calibre calibre-password"
check "Calibre-Web's users come from the image" 0 log "podman run --rm -v "
if [[ "$(query configs/calibre-web/config/app.db 'SELECT name FROM user ORDER BY id')" != "[('admin',), ('Guest',)]" ]]; then
  fail "Calibre-Web gets the image's users"
fi
if [[ "$(query configs/calibre-web/config/app.db 'SELECT config_calibre_dir, config_calibre_split, config_calibre_split_dir FROM settings')" != "[('/calibre-db', 1, '/data/media/calibre-library')]" ]]; then
  fail "Calibre-Web gets its split library"
fi
if [[ "$(query configs/mylar/config/mylar/mylar.db 'SELECT ComicID, Status FROM comics')" != "[('0000000', 'Paused')]" ]]; then
  fail "Mylar gets a paused placeholder"
fi
check "the arr login is the app name" 0 log '"username": "radarr",\n  "password": "radarr"' # pragma: allowlist secret
check "qBittorrent is reached over HTTPS on the services address" 0 log \
  '"name": "QBittorrent",\n  "enable": true' '"name": "host",\n      "value": "10.0.0.2"' '"value": 8443' \
  '"name": "tvCategory",\n      "value": "sonarr"' '"name": "tvImportedCategory"\n' '"value": "qbittorrent-password"' # pragma: allowlist secret
check "SABnzbd gets its key and genre category" 0 log '"value": "sabnzbd-key"' '"name": "tvCategory",\n      "value": "tv"' '"value": "/sabnzbd"'
check "Jellyfin is reached through the host alias that answers" 0 log '"value": "host.docker.internal"' '"onDownload": true' '"onUpgrade": true'
refute "only the triggers the app supports" log '"onRename": true'
check "the FlareSolverr proxy is tagged" 0 log '"tags": [\n    5\n  ]' '"value": "http://flaresolverr:8191"'
check "Whisparr is given Prowlarr's bare URL" 0 log '"value": "https://prowlarr:9697"\n'
check "the others get Prowlarr's UrlBase" 0 log '"value": "https://prowlarr:9697/prowlarr"'
check "the indexer is enabled after creation" 0 log "/prowlarr/api/v1/indexer/3?forceSave=true"

# Run B: everything is already in place.
deployment
run
check "a wired stack is left alone" 0 out \
  "[Audiobookshelf] Done." "[Calibre] Content server user already exists, skipping." \
  "[Calibre-Web] Already configured, skipping." "[Jellyfin] Setup wizard already completed, skipping." \
  "[sonarr] WebUI login already set up, skipping." "[sonarr] qBittorrent download client already exists, skipping." \
  "[sonarr] SABnzbd download client already exists, skipping." "[sonarr] Jellyfin connection already exists, skipping." \
  "[Prowlarr] FlareSolverr indexer proxy already exists, skipping." \
  "[Prowlarr] Application 'Sonarr' already exists, skipping." \
  "[Prowlarr] Indexer 'Internet Archive' already exists, skipping." \
  "[Prowlarr] Indexers present in every enabled arr app." "[Mylar] Already has comics, skipping placeholder." \
  "[qBittorrent] Already trusts only nginx (192.0.2.5) as its reverse proxy, skipping." \
  "[qBittorrent] The mylar category already acts at its share limit (RemoveWithContent), skipping." \
  "[Mylar] Download client addresses already match GLUETUN_SERVICES_IP, skipping." \
  "[LazyLibrarian] Download client addresses already match GLUETUN_SERVICES_IP, skipping." \
  "[LazyLibrarian] Audiobook types already include m4b m4a mp3 flac opus ogg aac, skipping." \
  "[Cleanuparr] qBittorrent already connected, skipping." "[Cleanuparr] Sonarr already connected, skipping." \
  "[Cleanuparr] Whisparr already connected, skipping." "[Cleanuparr] Done."
check "a wired Cleanuparr still has its stored secrets tested" 0 log \
  '"password":"••••••••","urlBase":"","clientId":"qbt-id"' '"apiKey":"••••••••","version":4,"instanceId":"sonarr-id"'
refute "nothing is stopped" log "podman stop"
refute "nothing is created" out "Creating"
refute "qBittorrent's preferences are left alone" log "setPreferences"
refute "nothing is updated" log "-X PUT"
refute "nothing is restarted" log "podman restart"

# Whisparr 3.6 creates its own login on first start, with a random password,
# and leaves certificate validation at its default. A username alone is not
# "already set up": the placeholder login and the relaxed validation still go
# in, or no download client can reach qBittorrent's self-signed address.
rule 'curl -sk --fail -H X-Api-Key: \S+ \S+/config/host$' 0 \
  '{"id": 1, "username": "whisparr", "password": "********", "certificateValidation": "enabled"}' # pragma: allowlist secret
run
check "a login the app made itself is not taken as set up" 0 out \
  "[whisparr] Setting up initial WebUI login and relaxing certificate validation for internal addresses..."
check "it gets the placeholder login and relaxed validation" 0 log \
  '"username": "whisparr",\n  "password": "whisparr"' '"certificateValidation": "disabledForLocalAddresses"' # pragma: allowlist secret
deployment

# Sonarr's database cannot say which key its connection holds: it is left
# alone, and said so.
rm -f "${__repo}/configs/sonarr/config/sonarr.db"
run
check "an unreadable stored key is reported" 0 out \
  "[sonarr] WARNING: could not read the Jellyfin key its connection holds from its database; leaving the connection as it is."
refute "and the connection is not rewritten" log "podman exec sonarr curl -sSk -X PUT"

# Settings that hold no object to read a key from: SQL NULL, JSON null, and
# text that is not JSON at all. Each is the same warning, never a crash.
arr_db_settings configs/sonarr/config/sonarr.db NULL
arr_db_settings configs/radarr/config/radarr.db null
arr_db_settings configs/lidarr/config/lidarr.db '{not json'
run
check "settings with no key in them are reported" 0 out \
  "[sonarr] WARNING: could not read the Jellyfin key" \
  "[radarr] WARNING: could not read the Jellyfin key" \
  "[lidarr] WARNING: could not read the Jellyfin key"
refute "and none of them is rewritten" log "curl -sSk -X PUT"
refute "nor does the read crash" err "Traceback"

# Mylar and LazyLibrarian still on .env.example's address (#379): Mylar is
# running, so it is stopped for the edit and started again; LazyLibrarian is
# stopped, so it is only edited, and a key its file lacks is not added.
deployment
put configs/mylar/config/mylar/config.ini <<'EOF'
api_key = key-mylar
[SABnzbd]
sab_host = https://172.28.0.10:8087/sabnzbd
[qBittorrent]
qbittorrent_host = https://10.0.0.2:8443
[DDL]
jd2_url = http://172.28.0.10:3128
EOF
put configs/lazylibrarian/config/config.ini <<'EOF'
api_key = key-lazylibrarian
[SABNZBD]
sab_host = https://172.28.0.10
sab_port = 8087
[QBITTORRENT]
qbittorrent_host = https://172.28.0.10
EOF
stopped lazylibrarian
run
check "stale addresses are corrected" 0 out \
  "[Mylar] Download client addresses stale, correcting to 10.0.0.2..." \
  "[Mylar]   sab_host = https://10.0.0.2:8090/sabnzbd" "[Mylar]   jd2_url = http://10.0.0.2:3128" "[Mylar] Updated." \
  "[LazyLibrarian]   sab_host = https://10.0.0.2" "[LazyLibrarian]   sab_port = 8090" \
  "[LazyLibrarian]   qbittorrent_host = https://10.0.0.2" "[LazyLibrarian] Updated."
check "Mylar's file holds the new address" 0 configs/mylar/config/mylar/config.ini \
  "sab_host = https://10.0.0.2:8090/sabnzbd" "qbittorrent_host = https://10.0.0.2:8443" "jd2_url = http://10.0.0.2:3128"
check "LazyLibrarian's file holds the new address" 0 configs/lazylibrarian/config/config.ini \
  "sab_host = https://10.0.0.2" "sab_port = 8090" "qbittorrent_host = https://10.0.0.2"
refute "a key the file lacks is not added" configs/lazylibrarian/config/config.ini "qbittorrent_port"
refute "an address that matches is not rewritten" out "[Mylar]   qbittorrent_host"
check "running Mylar is stopped and started around the edit" 0 log "podman stop mylar" "podman start mylar"
refute "stopped LazyLibrarian is not stopped" log "podman stop --time 60 lazylibrarian"
refute "nor started" log "podman start lazylibrarian"

# same_file <name> <path> <content>: the file under the scratch repository
# is exactly that content, byte for byte. check matches each line on its own,
# so it cannot tell a whole file from one that only shares a line with it.
same_file() {
  if ! printf '%s' "${3}" | cmp -s - "${__repo}/${2}"; then
    fail "${1}: ${2} is not exactly what was expected"
  fi
}

# Audiobook types (#547): a list seeded before m4a and the others existed gets
# them appended, kept in its own order and case folded; LazyLibrarian runs, so
# it is stopped for the edit and started again.
deployment
put configs/lazylibrarian/config/config.ini <<'EOF'
[GENERAL]
audiobook_type = M4B, flac, mp3, wav
api_key = key-lazylibrarian
EOF
run
check "missing audiobook types are added" 0 out \
  "[LazyLibrarian] Adding audiobook types: m4a opus ogg aac..." \
  "[LazyLibrarian]   audiobook_type = m4b, flac, mp3, wav, m4a, opus, ogg, aac"
same_file "and kept after the ones it had" configs/lazylibrarian/config/config.ini \
  $'[GENERAL]\naudiobook_type = m4b, flac, mp3, wav, m4a, opus, ogg, aac\napi_key = key-lazylibrarian\n\n'
check "running LazyLibrarian is stopped and started around the edit" 0 log \
  "podman stop --time 60 lazylibrarian" "podman start lazylibrarian"

# A file without the key, LazyLibrarian stopped: the key goes under
# [GENERAL], and nothing is stopped or started.
deployment
put configs/lazylibrarian/config/config.ini <<'EOF'
[GENERAL]
api_key = key-lazylibrarian
EOF
stopped lazylibrarian
run
same_file "a missing key is added under [GENERAL]" configs/lazylibrarian/config/config.ini \
  $'[GENERAL]\napi_key = key-lazylibrarian\naudiobook_type = m4b, m4a, mp3, flac, opus, ogg, aac\n\n'
refute "a stopped LazyLibrarian is not stopped for it" log "podman stop --time 60 lazylibrarian"

# A file with no [GENERAL] section yet is left to LazyLibrarian.
deployment
put configs/lazylibrarian/config/config.ini "api_key = key-lazylibrarian"
run
check "a file without [GENERAL] is left alone" 0 out \
  "[LazyLibrarian] config.ini has no [GENERAL] section yet, leaving its audiobook types to LazyLibrarian."
refute "and gains no key" configs/lazylibrarian/config/config.ini "audiobook_type"

# Spelled the other ways LazyLibrarian's ConfigParser reads it: the key is
# replaced, keeping its types, never added a second time.
deployment
put configs/lazylibrarian/config/config.ini <<'EOF'
[GENERAL]
Audiobook_Type=m4b, wav
api_key = key-lazylibrarian
EOF
stopped lazylibrarian
run
same_file "a key written without spaces is replaced, keeping its types" configs/lazylibrarian/config/config.ini \
  $'[GENERAL]\naudiobook_type = m4b, wav, m4a, mp3, flac, opus, ogg, aac\napi_key = key-lazylibrarian\n\n'
if [[ "$(grep -c -i '^audiobook_type' "${__repo}/configs/lazylibrarian/config/config.ini")" -ne 1 ]]; then
  fail "the key is not added a second time"
fi

# A write that fails still starts LazyLibrarian again, then fails the run.
deployment
put configs/lazylibrarian/config/config.ini $'[GENERAL]\naudiobook_type = mp3\n'
printf '#!/usr/bin/env bash\n[[ "${2:-}" == write ]] && exit 1\nexec %q "$@"\n' "$(command -v python3)" >"${__bin}/python3"
chmod +x "${__bin}/python3"
run
rm "${__bin}/python3"
check "a failed write is reported" 1 out "[LazyLibrarian] WARNING: could not write its audiobook types (exit 1)."
check "and LazyLibrarian is started again" 1 log "podman stop --time 60 lazylibrarian" "podman start lazylibrarian"
same_file "and its file is left as it was" configs/lazylibrarian/config/config.ini $'[GENERAL]\naudiobook_type = mp3\n'

# A write that fails after the new content is written (here, moving it over
# the old file) leaves the original whole and no temporary file behind.
deployment
put configs/lazylibrarian/config/config.ini $'[GENERAL]\naudiobook_type = mp3\n'
mkdir -p "${__scratch}/fail-move"
printf 'import os\n\ndef _fail(*_args, **_named):\n    raise OSError(28, "No space left on device")\n\nos.replace = _fail\n' >"${__scratch}/fail-move/sitecustomize.py"
printf '#!/usr/bin/env bash\nPYTHONPATH=%q exec %q "$@"\n' "${__scratch}/fail-move" "$(command -v python3)" >"${__bin}/python3"
chmod +x "${__bin}/python3"
run
rm "${__bin}/python3"
check "a write that fails midway is reported" 1 out "[LazyLibrarian] WARNING: could not write its audiobook types (exit 1)."
same_file "and the file is left whole" configs/lazylibrarian/config/config.ini $'[GENERAL]\naudiobook_type = mp3\n'
if compgen -G "${__repo}/configs/lazylibrarian/config/.config.ini.*" >/dev/null; then
  fail "no temporary file is left behind"
fi

# A write that fails partway, after some of the new content is out, leaves
# the original whole too.
deployment
put configs/lazylibrarian/config/config.ini $'[GENERAL]\naudiobook_type = mp3\n'
mkdir -p "${__scratch}/fail-write"
cat >"${__scratch}/fail-write/sitecustomize.py" <<'PYEOF'
import builtins
import os

_open = builtins.open


class _Partial:
    def __init__(self, handle):
        self._handle = handle

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        self._handle.close()

    def write(self, text):
        self._handle.write(text[:5])
        self._handle.flush()
        raise OSError(28, "No space left on device")


def _patched(path, mode="r", *args, **named):
    handle = _open(path, mode, *args, **named)
    if "w" in mode and os.path.basename(str(path)).startswith(".config.ini."):
        return _Partial(handle)
    return handle


builtins.open = _patched
PYEOF
printf '#!/usr/bin/env bash\nPYTHONPATH=%q exec %q "$@"\n' "${__scratch}/fail-write" "$(command -v python3)" >"${__bin}/python3"
chmod +x "${__bin}/python3"
run
rm "${__bin}/python3"
check "a write that fails partway is reported" 1 out "[LazyLibrarian] WARNING: could not write its audiobook types (exit 1)."
same_file "and the file is left whole" configs/lazylibrarian/config/config.ini $'[GENERAL]\naudiobook_type = mp3\n'
if compgen -G "${__repo}/configs/lazylibrarian/config/.config.ini.*" >/dev/null; then
  fail "no temporary file is left behind after a partial write"
fi

# Only [GENERAL] is read: a key in another section before it is left alone,
# and a file without [GENERAL] is not changed at all.
deployment
put configs/lazylibrarian/config/config.ini $'[SABNZBD]\naudiobook_type = mp3\n[GENERAL]\naudiobook_type = m4b\n'
stopped lazylibrarian
run
same_file "only the [GENERAL] key changes" configs/lazylibrarian/config/config.ini \
  $'[SABNZBD]\naudiobook_type = mp3\n\n[GENERAL]\naudiobook_type = m4b, m4a, mp3, flac, opus, ogg, aac\n\n'
deployment
put configs/lazylibrarian/config/config.ini $'[SABNZBD]\naudiobook_type = mp3\n'
run
check "a key outside [GENERAL] is not taken for it" 0 out \
  "[LazyLibrarian] config.ini has no [GENERAL] section yet, leaving its audiobook types to LazyLibrarian."
same_file "and the file is unchanged" configs/lazylibrarian/config/config.ini $'[SABNZBD]\naudiobook_type = mp3\n'

# What ConfigParser accepts, LazyLibrarian included, is read the same way: an
# indented section header ends [GENERAL], and a continuation line belongs to
# the value above it.
deployment
put configs/lazylibrarian/config/config.ini $'[GENERAL]\naudiobook_type = m4b,\n  wav\napi_key = key-lazylibrarian\n'
stopped lazylibrarian
run
same_file "a continuation line is part of the value" configs/lazylibrarian/config/config.ini \
  $'[GENERAL]\naudiobook_type = m4b, wav, m4a, mp3, flac, opus, ogg, aac\napi_key = key-lazylibrarian\n\n'
deployment
put configs/lazylibrarian/config/config.ini $'[GENERAL]\n  [SABNZBD]\naudiobook_type = wav\n'
stopped lazylibrarian
run
same_file "an indented header ends [GENERAL]" configs/lazylibrarian/config/config.ini \
  $'[GENERAL]\naudiobook_type = m4b, m4a, mp3, flac, opus, ogg, aac\n\n[SABNZBD]\naudiobook_type = wav\n\n'

# A file the check cannot read fails the run instead of passing as complete.
deployment
put configs/lazylibrarian/config/config.ini $'[GENERAL]\naudiobook_type = mp3\n'
printf '#!/usr/bin/env bash\n[[ "${2:-}" == check ]] && exit 1\nexec %q "$@"\n' "$(command -v python3)" >"${__bin}/python3"
chmod +x "${__bin}/python3"
run
rm "${__bin}/python3"
check "a failed read is reported" 1 out "[LazyLibrarian] WARNING: could not read its audiobook types (exit 1)."
refute "not passed as complete" out "[LazyLibrarian] Audiobook types already include"

# The same for a download client address Mylar's file will not take.
deployment
put configs/mylar/config/mylar/config.ini $'api_key = key-mylar\n[SABnzbd]\nsab_host = https://192.0.2.10:8087/sabnzbd\n'
printf '#!/usr/bin/env bash\n[[ "${*: -1}" == *mylar/config.ini ]] && exit 4\nexec %q "$@"\n' "$(command -v sed)" >"${__bin}/sed"
chmod +x "${__bin}/sed"
run
rm "${__bin}/sed"
check "a failed address edit is reported" 1 out "[Mylar] WARNING: could not edit configs/mylar/config/mylar/config.ini (exit 4)."
check "and Mylar is started again" 1 log "podman stop mylar" "podman start mylar"

# The mylar category's share limit action (#550): set while still Default,
# and only then.
deployment
containers qbittorrent
# The read back after the edit finds the new action.
rule "${QBT_CATEGORIES}" 0 '{"mylar": {"name": "mylar", "savePath": "/data/torrents/comics", "share_limit_action": "RemoveWithContent"}}'
rule "${QBT_CATEGORIES}" 0 '{"mylar": {"name": "mylar", "savePath": "/data/torrents/comics", "share_limit_action": "Default"}}' 1
run
check "a Default mylar action becomes RemoveWithContent" 0 out \
  "[qBittorrent] Removing mylar's torrents with their files at the share limit..." "[qBittorrent] Done."
check "through editCategory, with the action alone" 0 log \
  "--data-urlencode category=mylar --data-urlencode shareLimitAction=RemoveWithContent" \
  "/api/v2/torrents/editCategory"
refute "and not its save path" log "savePath="

# An edit qBittorrent accepts but does not apply is reported.
deployment
containers qbittorrent
rule "${QBT_CATEGORIES}" 0 '{"mylar": {"name": "mylar", "savePath": "/data/torrents/comics", "share_limit_action": "Default"}}'
run
check "an edit that does not take is reported" 0 out \
  "[qBittorrent] WARNING: qBittorrent accepted the edit but mylar's share limit action is still not RemoveWithContent."

# A read back that fails after a successful edit is reported as unconfirmed.
deployment
containers qbittorrent
rule "${QBT_CATEGORIES}" 22 ""
rule "${QBT_CATEGORIES}" 0 '{"mylar": {"name": "mylar", "savePath": "/data/torrents/comics", "share_limit_action": "Default"}}' 1
run
check "a read back that fails after the edit is reported" 0 out \
  "[qBittorrent] Removing mylar's torrents with their files at the share limit..." \
  "[qBittorrent] WARNING: could not read its categories back, so mylar's share limit action is unconfirmed."

# qBittorrent 5.2 reports the action but its editCategory would reset the
# category's other settings, so nothing is sent.
deployment
containers qbittorrent
rule "${QBT_CATEGORIES}" 0 '{"mylar": {"name": "mylar", "savePath": "/data/torrents/comics", "download_path": "/data/incomplete", "ratio_limit": 1.5, "share_limit_action": "Default"}}'
rule 'exec qbittorrent curl -sk --fail -b \S+ \S+/api/v2/app/version$' 0 "v5.2.4"
run
check "qBittorrent 5.2 is left alone" 0 out \
  "[qBittorrent] v5.2.4 cannot set a category's share limit action through its API; mylar's stays Default until qBittorrent is 5.3 or later."
refute "with no edit that would reset it" log "editCategory"

# A version the check cannot parse is treated as too old.
deployment
containers qbittorrent
rule "${QBT_CATEGORIES}" 0 '{"mylar": {"name": "mylar", "share_limit_action": "Default"}}'
rule 'exec qbittorrent curl -sk --fail -b \S+ \S+/api/v2/app/version$' 0 "v5.x.0"
run
check "an unparsable version is left alone" 0 out \
  "[qBittorrent] v5.x.0 cannot set a category's share limit action through its API; mylar's stays Default until qBittorrent is 5.3 or later."
refute "with no edit" log "editCategory"

deployment
containers qbittorrent
rule "${QBT_CATEGORIES}" 0 '{"mylar": {"name": "mylar", "share_limit_action": "Default"}}'
rule 'exec qbittorrent curl -sk --fail -b \S+ \S+/api/v2/app/version$' 22 ""
run
check "an unreadable version is reported" 0 out \
  "[qBittorrent] WARNING: could not read its version, so mylar's share limit action was not set."
refute "and nothing is edited" log "editCategory"

# Without nginx's address, the category is still set.
deployment
sed -i 's/^NGINX_SERVICES_IP=.*/NGINX_SERVICES_IP=/' "${__repo}/.env"
containers qbittorrent
rule "${QBT_CATEGORIES}" 0 '{"mylar": {"name": "mylar", "share_limit_action": "RemoveWithContent"}}'
rule "${QBT_CATEGORIES}" 0 '{"mylar": {"name": "mylar", "share_limit_action": "Default"}}' 1
run
check "an empty nginx address skips only reverse proxy trust" 0 out \
  "[qBittorrent] NGINX_SERVICES_IP is not set, skipping reverse proxy trust." \
  "[qBittorrent] Removing mylar's torrents with their files at the share limit..."

deployment
containers qbittorrent
rule "${QBT_CATEGORIES}" 0 '{"mylar": {"name": "mylar", "share_limit_action": "Stop"}}'
run
check "an action set by hand is kept" 0 out "[qBittorrent] The mylar category already acts at its share limit (Stop), skipping."
refute "and not changed" log "editCategory"

deployment
containers qbittorrent
rule "${QBT_CATEGORIES}" 0 '{"sonarr": {"name": "sonarr"}}'
run
check "no mylar category is skipped" 0 out "[qBittorrent] No mylar category, skipping its share limit action."

deployment
containers qbittorrent
rule "${QBT_CATEGORIES}" 0 '{"mylar": {"name": "mylar", "savePath": "/data/torrents/comics"}}'
run
check "a qBittorrent without per category limits is left alone" 0 out \
  "[qBittorrent] This qBittorrent sets no share limits per category, skipping mylar's."
refute "with no edit" log "editCategory"

deployment
containers qbittorrent
rule "${QBT_CATEGORIES}" 22 ""
run
check "unreadable categories are reported" 0 out \
  "[qBittorrent] WARNING: could not read its categories, so the mylar share limit action was not checked."

# An empty answer is no answer either.
deployment
containers qbittorrent
rule "${QBT_CATEGORIES}" 0 ""
run
check "an empty category answer is reported" 0 out \
  "[qBittorrent] WARNING: could not read its categories, so the mylar share limit action was not checked."
refute "not taken for a set action" out "already acts at its share limit"

deployment
containers qbittorrent
rule "${QBT_CATEGORIES}" 0 '{"mylar": {"name": "mylar", "share_limit_action": "Default"}}'
rule 'exec qbittorrent curl .*/api/v2/torrents/editCategory$' 22 ""
run
check "a refused edit is reported" 0 out \
  "[qBittorrent] WARNING: editCategory failed, so mylar's share limit action was not set."

# Run C: no containers at all, and no LazyLibrarian config.
deployment
containers
rm "${__repo}/configs/lazylibrarian/config/config.ini"
run
check "missing containers are skipped" 0 out \
  "[Audiobookshelf] Container doesn't exist, skipping." "[Calibre] Container doesn't exist, skipping." \
  "[Calibre-Web] Container doesn't exist, skipping." "[Jellyfin] Container doesn't exist, skipping." \
  "[sonarr] Container does not exist, skipping." \
  "[Prowlarr] Container doesn't exist (PROWLARR_PROFILE=disabled), skipping." \
  "[Mylar] Container doesn't exist, skipping." "[qBittorrent] Container doesn't exist, skipping." \
  "[Cleanuparr] Container doesn't exist, skipping." \
  "[Mylar] Download client addresses already match GLUETUN_SERVICES_IP, skipping."
refute "a missing config is left to the seed" out "[LazyLibrarian] Download client"

# Run D: most things fail.
deployment
put configs/sonarr/config/config.xml "<Config></Config>"
calibre_web_db none
mylar_db 0
rule 'wget -qO- http://127.0.0.1:13378/status$' 1 ""
rule 'exec jellyfin curl .*/System/Info/Public$' 7 ""
rule 'exec whisparr curl .*/system/status$' 7 ""
rule 'exec radarr curl -sk --fail -H X-Api-Key: \S+ \S+/downloadclient$' 0 '[
  {"id": 1, "implementation": "QBittorrent", "fields": [{"name": "host", "value": "10.9.9.9"}, {"name": "port", "value": 8443}, {"name": "useSsl", "value": true}]},
  {"id": 2, "implementation": "Sabnzbd", "fields": [{"name": "host", "value": "10.0.0.2"}, {"name": "port", "value": 9090}, {"name": "useSsl", "value": false}]}]'
rule 'exec radarr curl -sSk -X PUT .*/downloadclient/1$' 0 $'[{"errorMessage": "Unable to connect to qBittorrent"}]\n400'
rule 'exec radarr curl -sk --fail -H X-Api-Key: \S+ \S+/notification$' 22 ""
rule 'exec lidarr curl -sk --fail -H X-Api-Key: \S+ \S+/downloadclient$' 0 '[]'
rule 'exec lidarr curl -sk --fail -H X-Api-Key: \S+ \S+/downloadclient/schema$' 0 \
  '[{"implementation": "QBittorrent", "fields": []}, {"implementation": "Sabnzbd", "fields": []}]'
rule 'exec lidarr curl -sSk -X POST .*/downloadclient$' 7 "curl: (7) Failed to connect to 127.0.0.1"
rule 'exec lidarr curl -sk --fail -H X-Api-Key: \S+ \S+/notification$' 0 '[]'
rule 'exec lidarr curl -sk --fail -H X-Api-Key: \S+ \S+/notification/schema$' 22 ""
rule 'prowlarr curl -sk --fail -X POST .*/prowlarr/api/v1/tag$' 22 ""
rule 'prowlarr curl -sk --fail -H X-Api-Key: \S+ \S+/indexerproxy$' 0 '[]'
rule 'prowlarr curl -sk --fail -H X-Api-Key: \S+ \S+/indexerproxy/schema$' 0 '[{"implementation": "FlareSolverr", "fields": []}]'
rule 'prowlarr curl -sk --fail -X POST .*/indexerproxy$' 22 "curl: (22) The requested URL returned error: 400"
rule 'prowlarr curl -sk --fail -H X-Api-Key: \S+ \S+/applications$' 0 '[]'
rule 'prowlarr curl -sk --fail -H X-Api-Key: \S+ \S+/applications/schema$' 0 "${APPLICATIONS_SCHEMA}"
rule 'prowlarr curl -sk -o /dev/null --max-time 10 https://lazylibrarian:' 7 ""
rule 'prowlarr curl -skS --fail -X POST .*"name": "Radarr"' 22 "curl: (22) The requested URL returned error: 400"
rule 'prowlarr curl -sk --fail -H X-Api-Key: \S+ \S+/prowlarr/api/v1/indexer$' 0 '[]'
rule 'prowlarr curl -sk --fail -H X-Api-Key: \S+ \S+/prowlarr/api/v1/indexer/schema$' 0 '[{"definitionName": "internetarchive", "fields": []}]'
rule 'prowlarr curl -sk --fail -X POST .*/prowlarr/api/v1/indexer$' 22 ""
rule '/prowlarr/api/v1/indexerstatus$' 0 '[{"id": 3}]'
rule 'exec (lidarr|radarr|sonarr) curl -sk --fail -H X-Api-Key: \S+ \S+/api/v[13]/indexer$' 0 '[]'
rule 'mylar curl -sk --max-time 10 -o /dev/null' 28 000
rule 'exec qbittorrent curl .*/api/v2/auth/login$' 7 ""
run
check "failures are reported and the rest carries on" 0 out \
  "[qBittorrent] ...still waiting (30s/120s)" "[qBittorrent] Not reachable, skipping reverse proxy trust and mylar's share limit action." \
  "[Audiobookshelf] ...still waiting (30s/180s)" "[Audiobookshelf] Not reachable, skipping." \
  "[Calibre-Web] app.db not initialized yet after 180s, skipping." \
  "[Jellyfin] Not reachable, skipping." "[whisparr] Not reachable, skipping." \
  "[radarr] qBittorrent download client stale (10.9.9.9:8443, useSsl true), correcting to 10.0.0.2:8443, useSsl true..." \
  '[radarr] WARNING: failed to update qBittorrent download client: [{"errorMessage": "Unable to connect to qBittorrent"}]' \
  "[radarr] SABnzbd download client stale (10.0.0.2:9090, useSsl false), correcting to 10.0.0.2:8080, useSsl false..." \
  "[radarr] Updated." \
  "[radarr] WARNING: could not read its notification list; skipping its Jellyfin connection." \
  "[lidarr] WARNING: failed to create qBittorrent download client: curl: (7) Failed to connect" \
  "[lidarr] WARNING: failed to create SABnzbd download client: curl: (7) Failed to connect" \
  "[lidarr] WARNING: could not read its notification schema; skipping its Jellyfin connection." \
  "[Prowlarr] WARNING: could not create the 'flaresolverr' tag, continuing without it." \
  "[Prowlarr] WARNING: failed to add FlareSolverr indexer proxy: curl: (22)" \
  "[Prowlarr] LazyLibrarian not reachable after 300s, skipping its registration." \
  "[Prowlarr] Failed to register 'Radarr': curl: (22)" \
  "[Prowlarr] Failed to add indexer 'Internet Archive'." \
  "[Prowlarr] Indexers still in failure backoff; syncing anyway." \
  "[Prowlarr] WARNING: some arr apps still have no indexer (lidarr radarr)." \
  "[Prowlarr]   - LazyLibrarian (not reachable)" "[Prowlarr]   - Radarr" "[Prowlarr]   - indexer Internet Archive" \
  "[Jellyfin]   - radarr" "[Jellyfin]   - lidarr" "[arr]   - radarr" "[arr]   - lidarr" \
  "[arr]   - sonarr (exit 1)" \
  "[Mylar] WARNING: did not answer within 420s of restarting; its Homepage widget may still fail."
check "the FlareSolverr proxy goes untagged" 0 log '"tags": []'
if [[ "$(grep -c 'prowlarr curl -skS --fail -X POST .*"name": "Radarr"' "${__state}/log")" -ne 3 ]]; then
  fail "a failed registration is tried three times"
fi

# An app with no Jellyfin (MediaBrowser) connection type is skipped before
# Jellyfin's reachability is even tried, and is not counted as a failure.
deployment
containers jellyfin sonarr
rule 'exec sonarr curl -sk --fail -H X-Api-Key: \S+ \S+/notification$' 0 '[]'
rule 'exec sonarr curl -sk --fail -H X-Api-Key: \S+ \S+/notification/schema$' 0 '[{"implementation": "Kavita"}]'
rule 'exec sonarr curl -s --fail --max-time 5' 7 ""
run
check "an app without Jellyfin connections is skipped" 0 out "[sonarr] Does not support Jellyfin connections, skipping."
refute "and is not a Jellyfin failure" out "[Jellyfin]   - sonarr"
refute "nor waits for Jellyfin" out "[sonarr] ...still waiting"

# Calibre-Web has not created app.db yet. Waiting for it must not create one:
# Calibre-Web seeds its users only when the file does not exist (#334).
deployment
rm "${__repo}/configs/calibre-web/config/app.db"
run
check "a missing app.db is waited for" 0 out "[Calibre-Web] app.db not initialized yet after 180s, skipping."
if [[ -e "${__repo}/configs/calibre-web/config/app.db" ]]; then
  fail "waiting for app.db does not create it"
fi

# Run E: half set up, and the rest of the ways things go wrong.
deployment
: >"${__repo}/configs/jellyfin/secrets/api_key.txt"
calibre_web_db ""
# Audiobookshelf refuses the placeholder login: wget exits 8 on a 401.
rule '/login$' 8 ""
rule 'jellyfin curl -s http://127.0.0.1:8096/System/Info/Public$' 0 '<html>redirect</html>'
rule 'exec jellyfin curl .*/jellyfin/System/Info/Public$' 0 '{"StartupWizardCompleted": false}'
rule 'jellyfin curl -s --fail -X POST .*/Startup/User$' 22 ""
rule 'exec radarr curl -sk --fail -H X-Api-Key: \S+ \S+/downloadclient$' 0 '[
  {"id": 1, "implementation": "QBittorrent", "fields": [{"name": "host", "value": "10.9.9.9"}, {"name": "port", "value": 8443}, {"name": "useSsl", "value": true}]},
  {"id": 2, "implementation": "Sabnzbd", "fields": [{"name": "host", "value": "10.9.9.9"}, {"name": "port", "value": 8080}, {"name": "useSsl", "value": false}, {"name": "apiKey", "value": "kept"}]}]'
rule 'exec radarr curl -sSk -X PUT .*/downloadclient/2$' 0 $'[{"errorMessage": "Unable to connect to SABnzbd"}]\n400'
rule 'prowlarr curl .*/system/status$' 7 ""
# A refused login still answers, so the preferences read is what fails. The
# login rule wins over Audiobookshelf's, which matches any /login.
rule 'exec qbittorrent curl .*/api/v2/auth/login$' 0 ""
rule "${QBT_PREFERENCES}" 22 ""
run
check "half set up" 0 out \
  "[qBittorrent] WARNING: could not read its preferences, so reverse proxy trust was not checked." \
  "[Audiobookshelf] Could not authenticate as the placeholder root user, skipping API key check." \
  "[Calibre-Web] Configuring library path..." \
  "[Jellyfin] Startup/User did not succeed after 180s, skipping the rest of setup." \
  "[radarr] Updated." \
  '[radarr] WARNING: failed to update SABnzbd download client: [{"errorMessage": "Unable to connect to SABnzbd"}]' \
  "[sonarr] No Jellyfin API key yet, skipping its connection." \
  "[arr]   - radarr" "[Prowlarr] Not reachable after 480s, skipping. Re-run 'make wire_connections'"
check "Jellyfin found under its BaseUrl" 0 log "jellyfin curl -sS --fail -X POST -H Content-Type: application/json -d {\"UICulture\""
check "the stale client keeps its key" 0 log '"value": "kept"'
refute "users already there are not replaced" log "podman run"
refute "no Jellyfin failures" out "[Jellyfin]   -"

# Run F: Jellyfin answers but the placeholder login does not, and the arr
# apps reach it, or not, in their own ways.
deployment
sed -i 's/^LAN_IP=.*/LAN_IP=192.168.1.50/' "${__repo}/.env"
containers jellyfin sonarr radarr whisparr prowlarr lazylibrarian mylar qbittorrent
# qBittorrent trusts some other proxy, and will not take nginx's address.
rule "${QBT_PREFERENCES}" 0 '{"web_ui_reverse_proxy_enabled": true, "web_ui_reverse_proxies_list": "172.16.0.0/12"}'
rule 'exec qbittorrent curl .*/api/v2/app/setPreferences$' 22 ""
# Jellyfin refuses the placeholder login: curl --fail exits 22 on a 401.
rule '/Users/AuthenticateByName$' 22 ""
for app in sonarr radarr whisparr; do
  rule "exec ${app} curl -sk --fail -H X-Api-Key: \\S+ \\S+/notification\$" 0 '[]'
  rule "exec ${app} curl -sk --fail -H X-Api-Key: \\S+ \\S+/notification/schema\$" 0 '[{"implementation": "MediaBrowser", "fields": []}]'
done
rule 'exec sonarr curl -s --fail --max-time 5' 7 ""
rule 'exec radarr curl -sSk -X POST .*/notification$' 0 $'[{"propertyName": "ApiKey", "errorMessage": "Invalid API Key"}]\n400'
run
check "Jellyfin without its placeholder login" 0 out \
  "[Jellyfin] Could not authenticate as the placeholder user, skipping API key/BaseUrl check." \
  "[sonarr] ...still waiting (30s/120s)" \
  "[sonarr] WARNING: Jellyfin is running but not reachable from this container; skipping its connection." \
  '[radarr] WARNING: failed to create the Jellyfin connection: [{"propertyName": "ApiKey", "errorMessage": "Invalid API Key"}]' \
  "[whisparr] Created." "[Jellyfin]   - sonarr" "[Jellyfin]   - radarr" \
  "[Prowlarr] FlareSolverr container doesn't exist, skipping indexer proxy." \
  "[Prowlarr] Lidarr container doesn't exist, skipping registration." \
  "[qBittorrent] WARNING: setPreferences failed, so reverse proxy trust was not applied."
check "the LAN address is tried first" 0 log "podman exec whisparr curl -s --fail --max-time 5 http://192.168.1.50:8096/jellyfin/System/Info/Public"
refute "no download client failed" out "[arr]"

# Run G: an untagged FlareSolverr proxy, and a Jellyfin that is not there.
deployment
containers prowlarr flaresolverr sonarr
rule 'prowlarr curl -sk --fail -H X-Api-Key: \S+ \S+/indexerproxy$' 0 '[{"id": 4, "implementation": "FlareSolverr", "tags": [1]}]'
run
check "an untagged proxy is tagged" 0 out "[Prowlarr] FlareSolverr indexer proxy exists but isn't tagged, adding the tag..." \
  "[sonarr] Jellyfin is not running, skipping its connection."
check "the tag is added to the ones it has" 0 log '"tags": [\n    1,\n    5\n  ]' "/prowlarr/api/v1/indexerproxy/4"
refute "and that worked" out "WARNING"

rule 'prowlarr curl -sk --fail -X PUT .*/indexerproxy/4$' 22 ""
run
check "a proxy that will not take the tag is reported" 0 out "[Prowlarr] WARNING: failed to tag the existing FlareSolverr indexer proxy."

# Run H: a .env seeded before NGINX_SERVICES_IP and CONTAINER_PREFIX existed
# (#299), whose keys .env.example supplies when make passed nothing down.
deployment
sed -i '/^NGINX_SERVICES_IP=/d; /^CONTAINER_PREFIX=/d' "${__repo}/.env"
put .env.example "$(printf '%s\n' "CONTAINER_PREFIX=" "NGINX_SERVICES_IP=198.51.100.7")"
containers qbittorrent
rule "${QBT_PREFERENCES}" 0 '{"web_ui_reverse_proxy_enabled": false, "web_ui_reverse_proxies_list": ""}'
run
check "keys an older .env lacks come from .env.example" 0 out \
  "[qBittorrent] Trusting only nginx (198.51.100.7) as its reverse proxy..."
check "and the container name takes .env.example's empty prefix" 0 log "podman exec qbittorrent rm -f /tmp/qbt_wire_cookies."
# The value make exports wins over .env.example's, as it does for compose.
NGINX_SERVICES_IP=192.0.2.7 run
check "a value make passes down comes before .env.example's" 0 out \
  "[qBittorrent] Trusting only nginx (192.0.2.7) as its reverse proxy..."

# A key set but empty in .env is respected, not replaced.
deployment
sed -i 's/^NGINX_SERVICES_IP=.*/NGINX_SERVICES_IP=/' "${__repo}/.env"
put .env.example "NGINX_SERVICES_IP=198.51.100.7"
containers qbittorrent
NGINX_SERVICES_IP=192.0.2.7 run
check "reverse proxy trust is skipped when nginx's address is empty" 0 out \
  "[qBittorrent] NGINX_SERVICES_IP is not set, skipping reverse proxy trust."

# A key in neither file stops the run with its name, before any output.
deployment
sed -i '/^CONTAINER_PREFIX=/d' "${__repo}/.env"
containers
run
check "a key in neither file is named" 1 err "ERROR: CONTAINER_PREFIX is set in neither .env nor .env.example, nor in the environment."

# Run I: the key file still holds the seeded placeholder when the run starts,
# the race that stored it in Lidarr and Radarr in CI. Jellyfin's own job
# replaces it, and every connection is made after that job, with the real key.
deployment
containers jellyfin sonarr radarr
put configs/jellyfin/secrets/api_key.txt "${JELLYFIN_PLACEHOLDER}"
rule 'curl -sk --fail -H X-Api-Key: \S+ \S+/notification$' 0 '[]'
run
check "connections wait for Jellyfin's real key" 0 out \
  "[Jellyfin] Creating initial API key..." "[sonarr] Created." "[radarr] Created."
check "and carry it" 0 log '"value": "other-key"'
refute "never the placeholder" log "\"value\": \"${JELLYFIN_PLACEHOLDER}\""

# Jellyfin cannot replace the placeholder (its own login is refused), so there
# is no key to give anyone.
deployment
containers jellyfin sonarr
put configs/jellyfin/secrets/api_key.txt "${JELLYFIN_PLACEHOLDER}"
rule '/Users/AuthenticateByName$' 22 ""
run
check "the placeholder is not a key" 0 out "[sonarr] No Jellyfin API key yet, skipping its connection."
refute "nothing is sent with it" log "curl -sSk -X POST"

# Run J: connections an earlier run left holding a key Jellyfin no longer
# issues: Sonarr's is repaired, Radarr refuses the update, Whisparr's already
# matches. The API masks the key, so the databases are what tell them apart.
deployment
containers jellyfin sonarr radarr whisparr
arr_db configs/sonarr/config/sonarr.db "${JELLYFIN_PLACEHOLDER}"
arr_db configs/radarr/config/radarr.db revoked-key
arr_db configs/whisparr/config/whisparr3.db jellyfin-key
rule 'curl -sk --fail -H X-Api-Key: \S+ \S+/notification$' 0 \
  '[{"id": 4, "implementation": "MediaBrowser", "fields": [{"name": "host", "value": "x"}, {"name": "apiKey", "value": "********"}]}]'
rule 'exec radarr curl -sSk -X PUT .*/notification/4$' 0 $'[{"errorMessage": "Unable to send test message"}]\n400'
run
check "a stale key is replaced" 0 out \
  "[sonarr] Jellyfin connection holds a key Jellyfin no longer issues, updating it..." "[sonarr] Updated." \
  '[radarr] WARNING: failed to update the Jellyfin connection'"'"'s key: [{"errorMessage": "Unable to send test message"}]' \
  "[whisparr] Jellyfin connection already exists, skipping." "[Jellyfin]   - radarr"
check "with the current key, in place" 0 log "podman exec sonarr curl -sSk -X PUT" '"value": "jellyfin-key"'
refute "a matching key is left alone" log "podman exec whisparr curl -sSk -X PUT"

# Run K: useSsl is part of a download client's address (#300). SABnzbd works
# on its HTTP port without TLS and on its HTTPS port with it: Sonarr's client
# is on the second and stays, Radarr's is too but on an old host, Lidarr's
# has TLS off against the HTTPS port and Whisparr's has it on against the
# HTTP port. Whisparr's qBittorrent client has TLS off, which qBittorrent's
# WebUI never answers.
deployment
containers sonarr radarr lidarr whisparr
sab_client() {
  printf '[{"id": 1, "implementation": "QBittorrent", "fields": [{"name": "host", "value": "10.0.0.2"}, {"name": "port", "value": 8443}, {"name": "useSsl", "value": %s}]},
  {"id": 2, "implementation": "Sabnzbd", "fields": [{"name": "host", "value": "%s"}, {"name": "port", "value": %s}, {"name": "useSsl", "value": %s}]}]' "${4:-true}" "${1}" "${2}" "${3}"
}
rule 'exec sonarr curl -sk --fail -H X-Api-Key: \S+ \S+/downloadclient$' 0 "$(sab_client 10.0.0.2 8090 true)"
rule 'exec radarr curl -sk --fail -H X-Api-Key: \S+ \S+/downloadclient$' 0 "$(sab_client 10.9.9.9 8090 true)"
rule 'exec lidarr curl -sk --fail -H X-Api-Key: \S+ \S+/downloadclient$' 0 "$(sab_client 10.0.0.2 8090 false)"
rule 'exec whisparr curl -sk --fail -H X-Api-Key: \S+ \S+/downloadclient$' 0 "$(sab_client 10.0.0.2 8080 true false)"
run
check "TLS moves with the port" 0 out \
  "[sonarr] qBittorrent download client already exists, skipping." \
  "[sonarr] SABnzbd download client already exists, skipping." \
  "[radarr] SABnzbd download client stale (10.9.9.9:8090, useSsl true), correcting to 10.0.0.2:8090, useSsl true..." \
  "[lidarr] SABnzbd download client stale (10.0.0.2:8090, useSsl false), correcting to 10.0.0.2:8080, useSsl false..." \
  "[whisparr] SABnzbd download client stale (10.0.0.2:8080, useSsl true), correcting to 10.0.0.2:8080, useSsl false..." \
  "[whisparr] qBittorrent download client stale (10.0.0.2:8443, useSsl false), correcting to 10.0.0.2:8443, useSsl true..."
refute "the clients that work are not touched" log "podman exec sonarr curl -sSk -X PUT"
refute "nothing is rejected" out "WARNING"
# sent <app> <id>: the update that app's download client <id> was sent.
sent() { grep -F "podman exec ${1} curl -sSk -X PUT" "${__state}/log" | grep -F "/downloadclient/${2}" || true; }
if [[ "$(sent radarr 2)" != *'"value": 8090'* || "$(sent radarr 2)" != *'"name": "useSsl",\n      "value": true'* ]]; then
  fail "Radarr's SABnzbd client keeps the HTTPS port, with TLS"
fi
if [[ "$(sent lidarr 2)" != *'"value": 8080'* || "$(sent lidarr 2)" != *'"name": "useSsl",\n      "value": false'* ]]; then
  fail "Lidarr's SABnzbd client moves to the HTTP port, without TLS"
fi
if [[ "$(sent whisparr 2)" != *'"value": 8080'* || "$(sent whisparr 2)" != *'"name": "useSsl",\n      "value": false'* ]]; then
  fail "Whisparr's SABnzbd client loses TLS on the HTTP port"
fi
if [[ "$(sent whisparr 1)" != *'"value": 8443'* || "$(sent whisparr 1)" != *'"name": "useSsl",\n      "value": true'* ]]; then
  fail "Whisparr's qBittorrent client gets TLS back"
fi

# Run M: Cleanuparr (#398). A connection whose address moved, or whose stored
# secret no longer works, is saved again in place; settings someone raised or
# added in its UI survive.
deployment
containers cleanuparr qbittorrent sonarr
rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/configuration/download_client$" 0 \
  $'{"clients": [{"id": "qbt-id", "name": "qBittorrent", "host": "https://10.9.9.9:8443/"}]}\n200'
rule "${CLEANUPARR} POST .*\"instanceId\":\"sonarr-id\".*${CLEANUPARR_API}/configuration/sonarr/instances/test$" 0 \
  $'{"title": "Connection failed: 401"}\n400'
rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/configuration/queue_cleaner$" 0 \
  $'{"enabled": true, "failedImport": {"maxStrikes": 5, "patternMode": "Include", "patterns": [".exe", "custom"]}}\n200'
run
check "drifted connections are saved again" 0 out \
  "[Cleanuparr] Connecting qBittorrent..." "[Cleanuparr] Connecting Sonarr..." "[Cleanuparr] Done."
check "in place" 0 log "/cleanuparr/api/configuration/download_client/qbt-id" "/cleanuparr/api/configuration/sonarr/instances/sonarr-id"
check "with what the files hold now" 0 log '"host":"https://10.0.0.2:8443"' '"apiKey":"key-sonarr"' # pragma: allowlist secret
check "raised strikes and added patterns survive" 0 log '"maxStrikes":5,"patternMode":"Include","patterns":[".exe","custom",".scr"'

# Cleanuparr not answering.
deployment
containers cleanuparr
rule 'exec cleanuparr curl -sf -o /dev/null http://127.0.0.1:11011/cleanuparr/health$' 7 ""
run
check "an unreachable Cleanuparr is skipped" 0 out "[Cleanuparr] Not reachable, skipping."

# Its setup status cannot be read, then its login is refused.
deployment
containers cleanuparr
rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/auth/status$" 0 $'\n503'
run
check "no status, no wiring" 0 out "[Cleanuparr] WARNING: no usable login, nothing else was wired."
deployment
containers cleanuparr
rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/account$" 0 $'{"title": "Unauthorized"}\n401'
rule "${CLEANUPARR} POST .*${CLEANUPARR_API}/auth/login$" 0 $'{"title": "Invalid credentials"}\n401'
run
check "a refused login is reported" 0 out \
  "[Cleanuparr] WARNING: could not log in as 'cleanuparr' with configs/cleanuparr/secrets/password.txt: {\"title\": \"Invalid credentials\"}" \
  "[Cleanuparr] WARNING: no usable login, nothing else was wired."
refute "and nothing else is tried" log "/cleanuparr/api/configuration/"

# A first setup keeps a password of the user's own, but never the username,
# which anyone could guess.
# A password that cannot be generated stops the setup, rather than sending
# an empty one: openssl failing, and openssl succeeding with no output.
for status in 1 0; do
  deployment
  containers cleanuparr
  rm "${__repo}/configs/cleanuparr/secrets/password.txt"
  rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/auth/status$" 0 $'{"setupCompleted": false}\n200'
  rule '^openssl rand' "${status}" ""
  run
  check "a password that cannot be generated (openssl exit ${status}) stops the setup" 0 out \
    "[Cleanuparr] WARNING: could not generate a password for its login." \
    "[Cleanuparr] WARNING: no usable login, nothing else was wired."
  refute "and no account is created (openssl exit ${status})" log "/cleanuparr/api/auth/setup/account"
  if [[ -e "${__repo}/configs/cleanuparr/secrets/password.txt" ]]; then
    fail "nor is an empty password file left behind (openssl exit ${status})"
  fi
done

for given in my-own-password cleanuparr; do
  deployment
  containers cleanuparr
  put configs/cleanuparr/secrets/password.txt "${given}"
  rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/auth/status$" 0 $'{"setupCompleted": false}\n200'
  rule "${CLEANUPARR} POST .*${CLEANUPARR_API}/auth/setup/(account|complete)$" 0 $'{}\n201'
  run
  expected=my-own-password                                                    # pragma: allowlist secret
  [[ "${given}" == cleanuparr ]] && expected=0001ffffffffffffffffffffffffffff # pragma: allowlist secret
  check "a first setup with '${given}' in the password file logs in with ${expected}" 0 log \
    "{\"username\":\"cleanuparr\",\"password\":\"${expected}\"}"
done

# Logged in, but no key in the answer.
deployment
containers cleanuparr
rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/account$" 0 $'{"title": "Unauthorized"}\n401'
rule "${CLEANUPARR} POST .*${CLEANUPARR_API}/auth/login$" 0 $'{"tokens": {"accessToken": "t"}}\n200'
rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/account/api-key$" 0 $'{"title": "Server error"}\n500'
run
check "a key that cannot be read is not saved" 0 out \
  "[Cleanuparr] WARNING: logged in, but could not read its API key." \
  "[Cleanuparr] WARNING: no usable login, nothing else was wired."
check "and the old key file stays" 0 configs/cleanuparr/secrets/api_key.txt key-cleanuparr

# An arr app whose profile is off is not wired, even with its container left
# behind; one whose profile .env does not name is.
deployment
containers cleanuparr qbittorrent sonarr whisparr
printf 'SONARR_PROFILE=disabled\n' >>"${__repo}/.env"
run
refute "a switched off app is not wired" log "/cleanuparr/api/configuration/sonarr"
check "an app .env names no profile for is" 0 log "/cleanuparr/api/configuration/whisparr"

# Every other part failing, in two runs, each failure reported and none
# stopping the rest.
deployment
containers cleanuparr qbittorrent sonarr
rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/configuration/general$" 0 $'{"httpCertificateValidation": "Enabled"}\n200'
rule "${CLEANUPARR} PUT .*${CLEANUPARR_API}/configuration/general$" 0 $'{"title": "general refused"}\n500'
rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/configuration/download_client$" 0 $'\n500'
rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/configuration/sonarr$" 0 $'{"instances": []}\n200'
rule "${CLEANUPARR} POST .*${CLEANUPARR_API}/configuration/sonarr/instances/test$" 0 $'{"title": "Connection refused"}\n400'
rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/configuration/queue_cleaner$" 0 \
  $'{"enabled": false, "failedImport": {"maxStrikes": 0, "patternMode": "Include", "patterns": []}}\n200'
rule "${CLEANUPARR} PUT .*${CLEANUPARR_API}/configuration/queue_cleaner$" 0 $'{"title": "queue refused"}\n500'
run
check "each failure is reported" 0 out \
  "[Cleanuparr] WARNING: could not save its general settings: {\"title\": \"general refused\"}" \
  "[Cleanuparr] WARNING: Sonarr failed its connection test: {\"title\": \"Connection refused\"}" \
  "[Cleanuparr] WARNING: could not save the queue cleaner: {\"title\": \"queue refused\"}" \
  "[Cleanuparr] WARNING: not everything was wired, see above. Re-run 'make wire_connections'."
refute "a failed part is not reported done" out "[Cleanuparr] Done."
deployment
containers cleanuparr qbittorrent sonarr
rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/configuration/general$" 0 $'\n500'
rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/configuration/sonarr$" 0 $'{"instances": []}\n200'
rule "${CLEANUPARR} POST .*${CLEANUPARR_API}/configuration/sonarr/instances$" 0 $'{"title": "save refused"}\n500'
rule "${CLEANUPARR} GET .*${CLEANUPARR_API}/configuration/queue_cleaner$" 0 $'\n500'
run
check "a refused save is reported" 0 out \
  "[Cleanuparr] WARNING: could not save Sonarr: {\"title\": \"save refused\"}" \
  "[Cleanuparr] WARNING: not everything was wired, see above. Re-run 'make wire_connections'."

# A `podman stop` that fails ends the run before Mylar's database is written
# under a Mylar still running (#405); a bare `wait` used to report it as done.
deployment
mylar_db 0
rule '^podman stop mylar$' 125 ""
run
check "a failed stop ends the run" 125 out "[Mylar] Adding a placeholder comic so its Homepage widget has data..."
if [[ "$(query configs/mylar/config/mylar/mylar.db 'SELECT COUNT(*) FROM comics')" != "[(0,)]" ]]; then
  fail "before Mylar's database is written"
fi
refute "nor is Mylar started again" log "podman start mylar"

# The same for an app stopped with the timeout. Calibre-Web runs as a
# background job, so its stop failing ends that job, named in the summary, and
# leaves its database as it was.
deployment
calibre_web_db /data/media/calibre-library 0 ""
rule '^podman stop --time 60 calibre-web$' 125 ""
run
check "a failed timed stop ends its job" 0 out "[Calibre-Web] Configuring library path..." \
  "[setup] WARNING: these jobs stopped before they finished:" "[setup]   - calibre-web (exit 125)"
if [[ "$(query configs/calibre-web/config/app.db 'SELECT config_calibre_dir, config_calibre_split FROM settings')" != "[('/data/media/calibre-library', 0)]" ]]; then
  fail "before Calibre-Web's database is written"
fi
refute "nor is Calibre-Web started again" log "podman start calibre-web"

finish
