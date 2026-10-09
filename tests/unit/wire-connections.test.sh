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

# The script falls back to an inherited NGINX_SERVICES_IP when .env has none,
# and `make coverage` exports one; each run below says which it wants.
unset NGINX_SERVICES_IP

readonly ARR_APPS=(sonarr radarr lidarr readarr whisparr)
# Prowlarr's application schema, one implementation per app it can register.
APPLICATIONS_SCHEMA="$(
  for impl in LazyLibrarian Lidarr Mylar Radarr Readarr Sonarr Whisparr; do
    printf '{"implementation": "%s", "fields": [{"name": "prowlarrUrl"}, {"name": "baseUrl"}, {"name": "apiKey"}, {"name": "other"}]}\n' "${impl}"
  done | python3 -c 'import json, sys; print(json.dumps([json.loads(line) for line in sys.stdin]))'
)"
readonly APPLICATIONS_SCHEMA
readonly ALL_CONTAINERS=(audiobookshelf calibre calibre-web jellyfin "${ARR_APPS[@]}" prowlarr flaresolverr lazylibrarian mylar qbittorrent)
# What bootstrap seeds Jellyfin's key file with, a key Jellyfin never issued.
readonly JELLYFIN_PLACEHOLDER=0123456789abcdef0123456789abcdef # pragma: allowlist secret
readonly QBT_PREFERENCES='exec qbittorrent curl -sk --fail -b \S+ \S+/api/v2/app/preferences$'

# calibre_web_db [<library dir>] [<users>]: Calibre-Web's app.db with its
# settings row, or with no settings table at all when given "none".
calibre_web_db() {
  rm -f "${__repo}/configs/calibre-web/config/app.db"
  mkdir -p "${__repo}/configs/calibre-web/config"
  python3 - "${__repo}/configs/calibre-web/config/app.db" "${1-/data/media/calibre-library}" "${2-2}" <<'EOF'
import sqlite3, sys
path, library, users = sys.argv[1], sys.argv[2], int(sys.argv[3])
conn = sqlite3.connect(path)
conn.execute("CREATE TABLE user (id INTEGER PRIMARY KEY, name TEXT, role INTEGER, password TEXT)")
conn.executemany("INSERT INTO user VALUES (?, ?, ?, ?)", [(i, f"user{i}", 1, "") for i in range(1, users + 1)])
if library != "none":
    conn.execute("CREATE TABLE settings (id INTEGER PRIMARY KEY, config_calibre_dir TEXT)")
    conn.execute("INSERT INTO settings VALUES (1, ?)", (library,))
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
SONARR_HTTP_PORT=8989
RADARR_HTTPS_PORT=7879
LIDARR_HTTPS_PORT=8687
READARR_HTTPS_PORT=8788
WHISPARR_HTTPS_PORT=6970
PROWLARR_HTTPS_PORT=9697
LAZYLIBRARIAN_HTTP_PORT=5299
MYLAR_HTTPS_PORT=8091
JELLYFIN_HTTP_PORT=8096
JELLYFIN_BASE_URL=/jellyfin
AUDIOBOOKSHELF_HTTP_PORT=13378
CALIBREWEB_VERSION=0.6
FLARESOLVERR_HTTP_PORT=8191
NGINX_SERVICES_IP=10.0.0.5
EOF
  containers "${ALL_CONTAINERS[@]}"
  local app k
  for app in "${ARR_APPS[@]}" prowlarr; do
    k="key-${app}"
    put "configs/${app}/config/config.xml" "<Config><ApiKey>${k}</ApiKey></Config>"
  done
  put configs/lazylibrarian/config/config.ini "api_key = key-lazylibrarian"
  put configs/mylar/config/mylar/config.ini "api_key = key-mylar"
  put configs/qbittorrent/secrets/username.txt qbittorrent
  put configs/qbittorrent/secrets/password.txt qbittorrent-password # pragma: allowlist secret
  put configs/sabnzbd/secrets/api_key.txt sabnzbd-key
  put configs/jellyfin/secrets/api_key.txt jellyfin-key
  put configs/jellyfin/secrets/api_key.txt.example "${JELLYFIN_PLACEHOLDER}"
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
  rule 'curl -sk --fail -H X-Api-Key: \S+ \S+/config/host$' 0 '{"id": 1, "username": "someone"}'
  rule 'curl -sk --fail -H X-Api-Key: \S+ \S+/downloadclient$' 0 '[
    {"id": 1, "implementation": "QBittorrent", "fields": [{"name": "host", "value": "10.0.0.2"}, {"name": "port", "value": 8443}]},
    {"id": 2, "implementation": "Sabnzbd", "fields": [{"name": "host", "value": "10.0.0.2"}, {"name": "port", "value": 8080}]}]'
  rule 'curl -sk --fail -H X-Api-Key: \S+ \S+/notification$' 0 '[{"implementation": "MediaBrowser"}]'
  rule 'curl -sk --fail -H X-Api-Key: \S+ \S+/notification/schema$' 0 \
    '[{"implementation": "MediaBrowser", "fields": [{"name": "host"}, {"name": "apiKey"}]}]'
  # Connections are sent without --fail, so the app's answer survives: its
  # body, then the status curl's -w appends.
  rule 'curl -sSk -X POST .*/notification$' 0 $'{"id": 7}\n201'
  rule 'curl -sSk -X PUT .*/notification/[0-9]+$' 0 $'{"id": 4}\n202'
  rule 'curl -sk --fail -H X-Api-Key: \S+ \S+/config/development$' 0 '{"id": 1, "metadataSource": "https://api.bookinfo.pro"}'
  # Prowlarr, with its tagged proxy, every application, the indexer, and
  # that indexer in every arr app.
  rule 'prowlarr curl -sk --fail -H X-Api-Key: \S+ \S+/indexerproxy$' 0 '[{"id": 4, "implementation": "FlareSolverr", "tags": [5]}]'
  rule 'prowlarr curl -sk --fail -X POST .*/prowlarr/api/v1/tag$' 0 '{"id": 5, "label": "flaresolverr"}'
  rule 'prowlarr curl -sk --fail -H X-Api-Key: \S+ \S+/applications$' 0 \
    '[{"name": "LazyLibrarian"}, {"name": "Lidarr"}, {"name": "Mylar"}, {"name": "Radarr"}, {"name": "Readarr"}, {"name": "Sonarr"}, {"name": "Whisparr"}]'
  rule 'prowlarr curl -sk --fail -H X-Api-Key: \S+ \S+/prowlarr/api/v1/indexer$' 0 '[{"id": 3, "name": "Internet Archive", "enable": true}]'
  rule '/prowlarr/api/v1/indexerstatus$' 0 '[]'
  rule 'exec (lidarr|radarr|readarr|sonarr) curl -sk --fail -H X-Api-Key: \S+ \S+/api/v[13]/indexer$' 0 '[{"id": 1}]'
  # Mylar answering.
  rule 'mylar curl -sk --max-time 10 -o /dev/null' 0 200
  # qBittorrent, already trusting only nginx as its reverse proxy.
  rule "${QBT_PREFERENCES}" 0 '{"web_ui_reverse_proxy_enabled": true, "web_ui_reverse_proxies_list": "10.0.0.5"}'
}

# Run A: nothing is set up yet.
deployment
put configs/jellyfin/secrets/api_key.txt placeholder
calibre_web_db "" 0
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
run
check "qBittorrent trusts only nginx" 0 out \
  "[qBittorrent] Trusting only nginx (10.0.0.5) as its reverse proxy..." "[qBittorrent] Done."
check "qBittorrent is given nginx's address" 0 log \
  'json={"web_ui_reverse_proxy_enabled":true,"web_ui_reverse_proxies_list":"10.0.0.5"}' \
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
  "[sonarr] Creating Jellyfin connection..." "[Readarr] Metadata provider source set." \
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
if [[ "$(query configs/calibre-web/config/app.db 'SELECT config_calibre_dir FROM settings')" != "[('/data/media/calibre-library',)]" ]]; then
  fail "Calibre-Web gets its library"
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
  "[Readarr] Metadata provider source already set, skipping." \
  "[Prowlarr] FlareSolverr indexer proxy already exists, skipping." \
  "[Prowlarr] Application 'Sonarr' already exists, skipping." \
  "[Prowlarr] Indexer 'Internet Archive' already exists, skipping." \
  "[Prowlarr] Indexers present in every enabled arr app." "[Mylar] Already has comics, skipping placeholder." \
  "[qBittorrent] Already trusts only nginx (10.0.0.5) as its reverse proxy, skipping."
refute "nothing is created" out "Creating"
refute "qBittorrent's preferences are left alone" log "setPreferences"
refute "nothing is updated" log "-X PUT"
refute "nothing is restarted" log "podman restart"

# Run C: no containers at all.
deployment
containers
run
check "missing containers are skipped" 0 out \
  "[Audiobookshelf] Container doesn't exist, skipping." "[Calibre] Container doesn't exist, skipping." \
  "[Calibre-Web] Container doesn't exist, skipping." "[Jellyfin] Container doesn't exist, skipping." \
  "[sonarr] Container does not exist, skipping." \
  "[Prowlarr] Container doesn't exist (PROWLARR_PROFILE=disabled), skipping." \
  "[Mylar] Container doesn't exist, skipping." "[qBittorrent] Container doesn't exist, skipping."

# Run D: most things fail.
deployment
put configs/sonarr/config/config.xml "<Config></Config>"
calibre_web_db none
mylar_db 0
rule 'wget -qO- http://127.0.0.1:13378/status$' 1 ""
rule 'exec jellyfin curl .*/System/Info/Public$' 7 ""
rule 'exec whisparr curl .*/system/status$' 7 ""
rule 'exec radarr curl -sk --fail -H X-Api-Key: \S+ \S+/downloadclient$' 0 '[
  {"id": 1, "implementation": "QBittorrent", "fields": [{"name": "host", "value": "10.9.9.9"}, {"name": "port", "value": 8443}]},
  {"id": 2, "implementation": "Sabnzbd", "fields": [{"name": "host", "value": "10.0.0.2"}, {"name": "port", "value": 9090}]}]'
rule 'exec radarr curl -sk --fail -X PUT .*/downloadclient/1$' 22 "curl: (22) The requested URL returned error: 400"
rule 'exec radarr curl -sk --fail -H X-Api-Key: \S+ \S+/notification$' 22 ""
rule 'exec lidarr curl -sk --fail -H X-Api-Key: \S+ \S+/downloadclient$' 0 '[]'
rule 'exec lidarr curl -sk --fail -H X-Api-Key: \S+ \S+/downloadclient/schema$' 0 \
  '[{"implementation": "QBittorrent", "fields": []}, {"implementation": "Sabnzbd", "fields": []}]'
rule 'exec lidarr curl -sk --fail -X POST' 22 "curl: (22) The requested URL returned error: 400"
rule 'exec lidarr curl -sk --fail -H X-Api-Key: \S+ \S+/notification$' 0 '[]'
rule 'exec lidarr curl -sk --fail -H X-Api-Key: \S+ \S+/notification/schema$' 22 ""
rule 'exec readarr curl -sk --fail -H X-Api-Key: \S+ \S+/notification$' 0 '[]'
rule 'exec readarr curl -sk --fail -H X-Api-Key: \S+ \S+/notification/schema$' 0 '[{"implementation": "Kavita"}]'
rule 'exec readarr curl -sk --fail -H X-Api-Key: \S+ \S+/config/development$' 0 '{"id": 1, "metadataSource": "https://old"}'
rule 'exec readarr curl -sk --fail -X PUT .*/config/development/1$' 22 "curl: (22) The requested URL returned error: 500"
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
rule 'exec (lidarr|radarr|readarr|sonarr) curl -sk --fail -H X-Api-Key: \S+ \S+/api/v[13]/indexer$' 0 '[]'
rule 'mylar curl -sk --max-time 10 -o /dev/null' 28 000
rule 'exec qbittorrent curl .*/api/v2/auth/login$' 7 ""
run
check "failures are reported and the rest carries on" 0 out \
  "[qBittorrent] ...still waiting (30s/120s)" "[qBittorrent] Not reachable, skipping reverse proxy trust." \
  "[Audiobookshelf] ...still waiting (30s/180s)" "[Audiobookshelf] Not reachable, skipping." \
  "[Calibre-Web] app.db not initialized yet after 180s, skipping." \
  "[Jellyfin] Not reachable, skipping." "[whisparr] Not reachable, skipping." \
  "[radarr] qBittorrent download client host/port stale (10.9.9.9:8443), correcting to 10.0.0.2:8443..." \
  "[radarr] WARNING: failed to update qBittorrent download client host: curl: (22) The requested URL returned error: 400" \
  "[radarr] SABnzbd download client host/port stale (10.0.0.2:9090), correcting to 10.0.0.2:8080..." \
  "[radarr] Updated." \
  "[radarr] WARNING: could not read its notification list; skipping its Jellyfin connection." \
  "[lidarr] WARNING: failed to create qBittorrent download client: curl: (22)" \
  "[lidarr] WARNING: failed to create SABnzbd download client: curl: (22)" \
  "[lidarr] WARNING: could not read its notification schema; skipping its Jellyfin connection." \
  "[readarr] Does not support Jellyfin connections, skipping." \
  "[Readarr] WARNING: failed to set metadata provider source: curl: (22) The requested URL returned error: 500" \
  "[Prowlarr] WARNING: could not create the 'flaresolverr' tag, continuing without it." \
  "[Prowlarr] WARNING: failed to add FlareSolverr indexer proxy: curl: (22)" \
  "[Prowlarr] LazyLibrarian not reachable after 300s, skipping its registration." \
  "[Prowlarr] Failed to register 'Radarr': curl: (22)" \
  "[Prowlarr] Failed to add indexer 'Internet Archive'." \
  "[Prowlarr] Indexers still in failure backoff; syncing anyway." \
  "[Prowlarr] WARNING: some arr apps still have no indexer (lidarr radarr readarr)." \
  "[Prowlarr]   - LazyLibrarian (not reachable)" "[Prowlarr]   - Radarr" "[Prowlarr]   - indexer Internet Archive" \
  "[Jellyfin]   - radarr" "[Jellyfin]   - lidarr" "[arr]   - radarr" "[arr]   - lidarr" \
  "[arr]   - sonarr (exit 1)" \
  "[Mylar] WARNING: did not answer within 420s of restarting; its Homepage widget may still fail."
check "the FlareSolverr proxy goes untagged" 0 log '"tags": []'
if [[ "$(grep -c 'prowlarr curl -skS --fail -X POST .*"name": "Radarr"' "${__state}/log")" -ne 3 ]]; then
  fail "a failed registration is tried three times"
fi
refute "readarr's own failure is not a Jellyfin one" out "[Jellyfin]   - readarr"

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
  {"id": 1, "implementation": "QBittorrent", "fields": [{"name": "host", "value": "10.9.9.9"}, {"name": "port", "value": 8443}]},
  {"id": 2, "implementation": "Sabnzbd", "fields": [{"name": "host", "value": "10.9.9.9"}, {"name": "port", "value": 8080}, {"name": "apiKey", "value": "kept"}]}]'
rule 'exec radarr curl -sk --fail -X PUT .*/downloadclient/2$' 22 "curl: (22) The requested URL returned error: 400"
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
  "[radarr] Updated." "[radarr] WARNING: failed to update SABnzbd download client host: curl: (22)" \
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
containers jellyfin sonarr radarr lidarr whisparr prowlarr lazylibrarian mylar qbittorrent
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
  "[Prowlarr] Readarr container doesn't exist, skipping registration." \
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

# Run H: a .env seeded before NGINX_SERVICES_IP existed.
deployment
sed -i '/^NGINX_SERVICES_IP=/d' "${__repo}/.env"
containers
run
check "qBittorrent is skipped without nginx's address" 0 out \
  "[qBittorrent] NGINX_SERVICES_IP is not set, skipping reverse proxy trust."
NGINX_SERVICES_IP=10.0.0.7 run
check "the address make exports stands in for .env" 0 out "[qBittorrent] Container doesn't exist, skipping."
refute "and is not reported missing" out "NGINX_SERVICES_IP is not set"

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

finish
