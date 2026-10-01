#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
# cspell:ignore PYTHONPATH
#
# Tests for scripts/rotate-passwords.sh. Every line of the script has to run
# in one of them: `make coverage` runs this file under kcov and fails below
# 100%.
#
# The script runs in a scratch repository against stand ins for podman and
# the rest (tests/unit/stack-stubs.bash). deployment() builds a stack where
# every service is up and accepts its new password, as rules for each app's
# API keyed on the URL its curl asks for; each scenario adds rules of its own,
# which win. Two more stand ins are this test's own: head, which hands out
# predictable passwords (Pw0001xxxxxxxxxx, Pw0002..., or one starting with a
# dash on request) in place of the random ones gen_password cuts from
# /dev/urandom, and a bcrypt module for the Python the script runs.

set -o errexit
set -o pipefail
set -o nounset

__script_name=rotate-passwords.sh
# shellcheck source=tests/unit/stack-stubs.bash
source "$(dirname "${BASH_SOURCE[0]}")/stack-stubs.bash"

cat >"${__bin}/head" <<'EOF'
#!/usr/bin/env bash
# head -c <length>, as gen_password calls it.
exec 9>>"${STUB_STATE}/head.lock"
flock 9
count=$(($(cat "${STUB_STATE}/head-count" 2>/dev/null || echo 0) + 1))
echo "${count}" >"${STUB_STATE}/head-count"
if [[ -f "${STUB_STATE}/dash-first" ]]; then
  rm "${STUB_STATE}/dash-first"
  pw="-dash"
else
  pw="$(printf 'Pw%04d' "${count}")"
fi
while [[ ${#pw} -lt ${2} ]]; do pw+=x; done
printf '%s' "${pw:0:${2}}"
EOF
chmod +x "${__bin}/head"
mkdir -p "${__scratch}/python"
cat >"${__scratch}/python/bcrypt.py" <<'EOF'
"""Stand in for the bcrypt package: a fixed salt and a readable hash."""


def gensalt():
    return b"$2b$12$"


def hashpw(password, salt):
    return salt + b"hash-of-" + password
EOF
export PYTHONPATH="${__scratch}/python"

readonly SERVICES=(audiobookshelf bazarr calibre calibre-web grafana jdownloader2 jellyfin lazylibrarian lidarr mylar nzbhydra2 prowlarr qbittorrent radarr readarr sabnzbd sonarr whisparr)

# sql <file> <statement>...: runs statements against a database under the
# scratch repository, printing the rows of the last.
sql() {
  mkdir -p "$(dirname "${__repo}/${1}")"
  python3 - "${__repo}/${1}" "${@:2}" <<'EOF'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
for statement in sys.argv[2:]:
    rows = conn.execute(statement).fetchall()
conn.commit()
for row in rows:
    print("|".join(str(v) for v in row))
EOF
}

downloads_db() {
  sql "${1}" "CREATE TABLE DownloadClients (Id INTEGER PRIMARY KEY, ConfigContract TEXT, Settings TEXT)" \
    "INSERT INTO DownloadClients VALUES (1, 'QBittorrentSettings', '{\"username\": \"qbittorrent\", \"password\": \"qbt-old\"}')" \
    "INSERT INTO DownloadClients VALUES (2, 'SabnzbdSettings', '{\"apiKey\": \"sab-old\"}')"
}

# A stack where every service is enabled, up, and takes its new password.
deployment() {
  fresh_repo <<'EOF'
CONTAINER_PREFIX=
ROTATE_PASSWORD_LENGTH=16
ROTATE_PASSWORD_SPECIAL_CHARS=false
AUDIOBOOKSHELF_HTTP_PORT=13378
BAZARR_HTTP_PORT=6767
CALIBRE_GUI_WEB_HTTP_PORT=8081
CALIBRE_DESKTOP_HTTPS_PORT=8181
CALIBRE_WEB_CONTAINER_HTTPS_PORT=8483
CALIBRE_WEB_CONTAINER_HTTP_PORT=8083
JDOWNLOADER2_HTTP_PORT=5800
JELLYFIN_HTTP_PORT=8096
JELLYFIN_BASE_URL=/jellyfin
LAZYLIBRARIAN_HTTP_PORT=5299
LIDARR_HTTPS_PORT=8687
MYLAR_HTTPS_PORT=8091
NZBHYDRA2_HTTPS_PORT=5077
PROWLARR_HTTPS_PORT=9697
QBITTORRENT_HTTPS_PORT=8443
GLUETUN_SERVICES_IP=10.0.0.2
RADARR_HTTPS_PORT=7879
READARR_HTTPS_PORT=8788
SABNZBD_HTTPS_PORT=9090
SONARR_HTTP_PORT=8989
WHISPARR_HTTPS_PORT=6970
AUDIOBOOKSHELF_PROFILE=enabled
BAZARR_PROFILE=enabled
CALIBRE_PROFILE=enabled
CALIBREWEB_PROFILE=enabled
GRAFANA_PROFILE=enabled
JDOWNLOADER2_PROFILE=enabled
JELLYFIN_PROFILE=enabled
LAZYLIBRARIAN_PROFILE=enabled
LIDARR_PROFILE=enabled
MYLAR_PROFILE=enabled
NZBHYDRA2_PROFILE=enabled
PROWLARR_PROFILE=enabled
QBITTORRENT_PROFILE=enabled
RADARR_PROFILE=enabled
READARR_PROFILE=enabled
SABNZBD_PROFILE=enabled
SONARR_PROFILE=enabled
WHISPARR_PROFILE=enabled
EOF
  containers "${SERVICES[@]}" homepage qbittorrent_exporter sabnzbd_exporter
  local app k
  for app in sonarr radarr lidarr readarr whisparr prowlarr; do
    k="key-${app}"
    put "configs/${app}/config/config.xml" "<Config><ApiKey>${k}</ApiKey></Config>"
  done
  for app in sonarr/sonarr radarr/radarr lidarr/lidarr readarr/readarr prowlarr/prowlarr; do
    downloads_db "configs/${app%/*}/config/${app#*/}.db"
  done
  put configs/bazarr/config/config/config.yaml '{"auth": {"password": "old"}}' # pragma: allowlist secret
  put configs/grafana/config/grafana.ini $'[security]\nadmin_user = admin\nadmin_password = grafana-old\n'
  put configs/lazylibrarian/config/config.ini <<'EOF'
[General]
http_pass = ll-old
calibre_pass = calibre-old
qbittorrent_pass = qbt-old
[SABNZBD]
sab_pass = sab-old
EOF
  put configs/mylar/config/mylar/config.ini <<'EOF'
[Interface]
http_password = mylar-old
[QBittorrent]
qbittorrent_password = qbt-old
[NZBGet]
nzbget_client_post_processing = True
EOF
  put configs/nzbhydra2/config/nzbhydra.yml '{"auth": {"users": [{"username": "admin", "password": "old"}]}}' # pragma: allowlist secret
  put configs/sabnzbd/config/sabnzbd.ini $'[misc]\nusername = \napi_key = sab-old\n'                          # pragma: allowlist secret
  put configs/notifiarr/config/notifiarr.conf $'[sabnzbd]\napi_key = "sab-old"\n'                             # pragma: allowlist secret
  put configs/jellyfin/secrets/api_key.txt jellyfin-key
  sql configs/audiobookshelf/config/absdatabase.sqlite "CREATE TABLE users (username TEXT, pash TEXT)" \
    "INSERT INTO users VALUES ('root', 'old')"
  sql configs/calibre/config/.config/calibre/server-users.sqlite "CREATE TABLE users (name TEXT, pw TEXT)" \
    "INSERT INTO users VALUES ('calibre', 'old')"
  sql configs/calibre-web/config/app.db "CREATE TABLE user (id INTEGER PRIMARY KEY, name TEXT, role INTEGER, password TEXT)" \
    "INSERT INTO user VALUES (1, 'Guest', 32, '')" "INSERT INTO user VALUES (2, 'calibre', 1, 'old')"

  rule 'curl -sk -H X-Api-Key: \S+ \S+/config/host$' 0 '{"id": 1, "username": ""}'
  rule 'curl -sk -D - -o /dev/null -d username=' 0 $'HTTP/1.1 302 Found\r\nLocation: /\r\n'
  rule 'bazarr curl -s -o /dev/null -w %\{http_code\}' 0 204
  rule 'calibre curl -sk? -o /dev/null -w %\{http_code\}' 0 200
  rule 'calibre-web curl -s -o /dev/null -w %\{http_code\}' 0 200
  rule '/System/Info/Public$' 0 '{"StartupWizardCompleted": true}'
  rule 'jellyfin curl -s --fail -H \S+ \S+ \S+ \S+/Users$' 0 '[{"Name": "other", "Id": "u0"}, {"Name": "jellyfin", "Id": "u1"}]'
  rule '/Users/AuthenticateByName$' 0 200
  rule 'nzbhydra2 curl -sk -o /dev/null -w' 0 "302 https://127.0.0.1:5077/nzbhydra2/"
  rule 'qbittorrent curl -sk -b /tmp/qbt_cookies.txt -o /dev/null -w' 0 200
  rule 'qbittorrent curl -sk -o /dev/null -D -' 0 $'HTTP/2 200\r\nset-cookie: QBT_SID_8443=abc; path=/\r\n\r\n\n200'
  rule 'sabnzbd curl -sk https://127.0.0.1:9090/sabnzbd/api\?mode=queue' 0 '{"queue": {"slots": []}}'
  rule 'curl -sk -o /dev/null -w %\{http_code\} https://127.0.0.1:\d+/(lazylibrarian|mylar)/auth/login$' 0 200
}

# The new password the summary reports for a service.
new_password() {
  awk -v svc="${1}" '$1 == svc && NF == 3 { print $3 }' "${__scratch}/out"
}

ok() { printf '%-14s  OK' "${1}"; }

# Arguments and settings.
deployment
run
check "refuses to run without a target" 1 err "Usage: "

run everything
check "rejects an unknown target" 1 err "Unknown target: everything"

sed -i "s/^ROTATE_PASSWORD_LENGTH=16$/ROTATE_PASSWORD_LENGTH=4/" "${__repo}/.env"
run all
check "refuses a short password length" 1 err "ERROR: ROTATE_PASSWORD_LENGTH must be an integer >= 8 (got '4')"

deployment
sed -i "s/^ROTATE_PASSWORD_LENGTH=16$/ROTATE_PASSWORD_LENGTH=20/; s/^ROTATE_PASSWORD_SPECIAL_CHARS=false$/ROTATE_PASSWORD_SPECIAL_CHARS=TRUE/" "${__repo}/.env"
touch "${__state}/dash-first"
run bazarr
check "a password never starts with a dash" 0 out "bazarr          bazarr          Pw0002xxxxxxxxxxxxxx"

# The whole stack.
deployment
run all
check "all rotates every service" 0 out \
  "Restarting secret consumers: qbittorrent_exporter sabnzbd_exporter calibre jdownloader2" \
  "Recreating homepage to load the new keys..." \
  "[Whisparr DB] No DownloadClients table yet (app never started), skipping."
for service in "${SERVICES[@]}"; do
  if [[ -z "$(new_password "${service}")" ]]; then
    fail "all rotates ${service}"
  fi
  check "all validates ${service}" 0 out "$(ok "${service}")"
done
check "each parallel rotation's output is labeled" 0 out "[grafana] [Grafana] Changing the admin password via the API..."
check "grafana.ini follows the API" 0 configs/grafana/config/grafana.ini "admin_password = $(new_password grafana)"
check "homepage gets Grafana's Basic auth header" 0 configs/grafana/secrets/homepage_auth.txt \
  "Basic $(printf 'admin:%s' "$(new_password grafana)" | base64 -w0)"
check "Grafana is asked with its old password" 0 log "-u admin:grafana-old -X PUT"
check "Bazarr stores an MD5" 0 configs/bazarr/config/config/config.yaml \
  "\"password\": \"$(printf '%s' "$(new_password bazarr)" | md5sum | cut -d' ' -f1)\""
check "NZBHydra2 stores a bcrypt hash" 0 configs/nzbhydra2/config/nzbhydra.yml \
  "\"password\": \"{bcrypt}\$2b\$12\$hash-of-$(new_password nzbhydra2)\""
check "LazyLibrarian gets its own password and Calibre's" 0 configs/lazylibrarian/config/config.ini \
  "http_pass = $(new_password lazylibrarian)" "calibre_pass = $(new_password calibre)" \
  "qbittorrent_pass = $(new_password qbittorrent)" "sab_pass = $(new_password sabnzbd)" "sab_user = sabnzbd" \
  "nzb_downloader_sabnzbd = True"
check "Mylar gets its own password, qBittorrent's and SABnzbd's" 0 configs/mylar/config/mylar/config.ini \
  "http_password = $(new_password mylar)" "qbittorrent_password = $(new_password qbittorrent)" \
  "sab_password = $(new_password sabnzbd)" "nzbget_client_post_processing = False"
check "SABnzbd's own config" 0 configs/sabnzbd/config/sabnzbd.ini "username = sabnzbd" "password = $(new_password sabnzbd)"
check "SABnzbd's key reaches notifiarr" 0 configs/notifiarr/config/notifiarr.conf 'api_key  = "'
check "the secret files" 0 configs/qbittorrent/secrets/password.txt "$(new_password qbittorrent)"
check "Jellyfin's password is kept" 0 configs/jellyfin/secrets/password.txt "$(new_password jellyfin)"
check "Calibre-Web's admin is found by role" 0 out "calibre-web     calibre"
if [[ "$(sql configs/sonarr/config/sonarr.db "SELECT Settings FROM DownloadClients WHERE Id = 1")" != *"$(new_password qbittorrent)"* ]]; then
  fail "the arr apps' qBittorrent client gets the new password"
fi
if [[ "$(sql configs/audiobookshelf/config/absdatabase.sqlite "SELECT pash FROM users")" != "\$2b\$12\$hash-of-$(new_password audiobookshelf)" ]]; then
  fail "Audiobookshelf stores a bcrypt hash"
fi
check "an arr app gets its name as its username" 0 log '"username": "radarr",\n  "password": "'
check "qBittorrent is logged into with the password the arr apps hold" 0 log "--data-urlencode password=qbt-old"
check "jDownloader2's login is checked with its new password" 0 log \
  "podman exec jdownloader2 sh -c jar=\$(mktemp)" "-d \"username=jdownloader2&password=$(new_password jdownloader2)\""
check "Audiobookshelf's login is checked in node" 0 log \
  "podman exec audiobookshelf node -e const [port, username, password] = process.argv.slice(1);" \
  "13378 root $(new_password audiobookshelf)"

# Each service on its own.
for service in "${SERVICES[@]}"; do
  deployment
  run "${service}"
  check "${service} rotates on its own" 0 out "$(ok "${service}")"
  if [[ "$(grep -c '  OK$' "${__scratch}/out")" -ne 1 ]]; then
    fail "${service} on its own validates only itself"
  fi
done

# Services and containers that are off or not up.
deployment
sed -i 's/^WHISPARR_PROFILE=enabled$/WHISPARR_PROFILE=disabled/' "${__repo}/.env"
containers bazarr sonarr radarr readarr prowlarr qbittorrent grafana jellyfin
stopped sonarr
rule '^podman inspect .* radarr$' 0 starting 7
rule '^podman start sonarr$' 0 ""
run all
check "all skips a disabled service" 0 out "[whisparr] Skipped, WHISPARR_PROFILE is disabled"
check "stopped API services are started first" 0 out \
  "Starting stopped containers needed for rotation: sonarr" \
  "Waiting for already-running containers to become healthy: radarr" \
  "  ...still waiting on: sonarr radarr (30s/120s)"
check "a missing container is skipped" 0 out "[lidarr] Skipped, lidarr did not become healthy"
check "one that will not start is skipped" 0 out "[sonarr] Not running; starting it..." \
  "[sonarr] Skipped, sonarr did not become healthy"
check "one that comes up healthy is rotated" 0 out "$(ok radarr)"
check "a missing container is reported" 0 err "[lidarr] Container does not exist; run 'make start' to create it"
refute "no homepage, no recreate" log "podman-compose"

run whisparr
check "a disabled service cannot be named" 1 err "ERROR: WHISPARR_PROFILE is disabled in .env; not rotating whisparr"

run lidarr
check "a service that cannot come up cannot be named" 1 err "ERROR: lidarr did not become healthy; cannot rotate lidarr"

rm -f "${__state}"/rules/*
echo starting >"${__state}/health/radarr"
run radarr
check "a service that stays unhealthy is waited for" 1 out "[radarr] Waiting for it to become healthy..."

rule '^podman start sonarr$' 125 ""
run sonarr
check "a container that will not start stops the run" 1 err "ERROR: could not start: sonarr"

# Apps with nothing to rotate yet.
deployment
sql configs/audiobookshelf/config/absdatabase.sqlite "DELETE FROM users"
sql configs/calibre/config/.config/calibre/server-users.sqlite "DROP TABLE users"
rm "${__repo}/configs/calibre-web/config/app.db"
rule '/System/Info/Public$' 0 '{"StartupWizardCompleted": false}'
containers bazarr audiobookshelf calibre-web jellyfin lazylibrarian
run all
check "first run setup not done yet" 0 out \
  "[audiobookshelf] [Audiobookshelf] No user 'root' yet, skipping." \
  "[calibre-web] [Calibre-Web] No user 'admin' in app.db, skipping." \
  "[jellyfin] [Jellyfin] Setup wizard not completed yet, skipping password rotation." \
  "[Calibre] No content server user 'calibre' in server-users.sqlite yet, skipping."
if grep --quiet --line-regexp "podman stop --time 60 calibre" "${__state}/log"; then
  fail "Calibre's container is not there to stop"
fi

# Jellyfin that cannot be rotated.
deployment
rule 'jellyfin curl -s --fail -H \S+ \S+ \S+ \S+/Users$' 0 '[{"Name": "other", "Id": "u0"}]'
run jellyfin
check "no Jellyfin user stops the rotation" 1 err "[Jellyfin] User 'jellyfin' not found. Aborting Jellyfin rotation."

# qBittorrent that cannot be rotated.
deployment
sql configs/sonarr/config/sonarr.db "DELETE FROM DownloadClients"
run qbittorrent
check "no current qBittorrent password stops the rotation" 1 err "[qBittorrent] Could not read current password from Sonarr DB. Aborting qBittorrent rotation."

deployment
rule 'exec qbittorrent awk' 1 ""
run qbittorrent
check "a refused qBittorrent login stops the rotation" 1 err "[qBittorrent] Login with the current password was refused, so no session was established. Aborting rotation."
check "and the cookie jar is removed" 1 log "podman exec qbittorrent rm -f /tmp/qbt_cookies.txt"

deployment
rule 'qbittorrent curl -sk -b /tmp/qbt_cookies.txt -o /dev/null -w' 0 403
run qbittorrent
check "a refused new qBittorrent password stops the rotation" 1 err "[qBittorrent] setPreferences answered HTTP 403, so the new password was not applied. Aborting rotation."

# homepage that will not recreate.
deployment
rule '^podman-compose ' 1 ""
run grafana
check "homepage that will not recreate fails the run" 1 err "ERROR: homepage still would not recreate after retries"

# New passwords the services do not accept afterwards.
deployment
rule 'curl -sk -D - -o /dev/null -d username=sonarr' 0 $'HTTP/1.1 302 Found\r\nLocation: /login?loginFailed=true\r\n'
rule 'exec audiobookshelf node -e' 1 ""
rule 'bazarr curl -s -o /dev/null -w %\{http_code\}' 0 403
rule 'calibre curl -s -o /dev/null -w %\{http_code\}' 0 000
rule 'calibre curl -sk -o /dev/null -w %\{http_code\}' 0 401 18
rule 'calibre-web curl -s -o /dev/null -w %\{http_code\}' 0 401 18
rule 'exec jdownloader2 sh -c' 1 ""
rule '/Users/AuthenticateByName$' 0 401
rule 'nzbhydra2 curl -sk -o /dev/null -w' 0 "302 https://127.0.0.1:5077/nzbhydra2/login?error"
rule 'qbittorrent curl -sk -o /dev/null -D -' 0 $'HTTP/2 403\r\n\r\n\n403'
rule 'sabnzbd curl -sk https://127.0.0.1:9090/sabnzbd/api\?mode=queue' 0 'API Key Incorrect'
rule 'curl -sk -o /dev/null -w %\{http_code\} https://127.0.0.1:\d+/mylar/auth/login$' 0 502
run all
check "credentials the services refuse fail validation" 1 err \
  "ERROR: validation failed for: audiobookshelf bazarr jdownloader2 jellyfin mylar nzbhydra2 qbittorrent sabnzbd sonarr"
check "Calibre gets one restart of its desktop" 1 out "[Calibre] Not responding after 90s; restarting the desktop service..." \
  "[Calibre] Content server not reachable on port 8081" "$(ok calibre)"
check "Calibre-Web gets one restart" 1 out "[Calibre-Web] Not responding after 90s; restarting..." "$(ok calibre-web)"
check "the desktop service is what restarts" 1 log "podman exec calibre s6-svc -r /run/service/svc-de"

deployment
rule 'calibre curl -sk -o /dev/null -w %\{http_code\}' 0 401
rule 'calibre-web curl -s -o /dev/null -w %\{http_code\}' 0 401
rule 'qbittorrent curl -sk -o /dev/null -D -' 0 $'HTTP/2 200\r\ncontent-type: text/plain\r\n\r\n\n200'
run all
check "Calibre and Calibre-Web that never answer fail validation" 1 err "ERROR: validation failed for: calibre calibre-web qbittorrent"
check "even after their restart" 1 out "$(printf '%-14s  FAILED' calibre)" "$(printf '%-14s  FAILED' calibre-web)"

deployment
rule 'calibre curl -s -o /dev/null -w %\{http_code\}' 0 000
run calibre
check "a Calibre content server that does not answer is only a note" 0 out "[Calibre] Content server not reachable on port 8081"

finish
