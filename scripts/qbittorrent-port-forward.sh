#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# gluetun's VPN_PORT_FORWARDING_UP_COMMAND (set in docker-compose-vpn.yml):
# sets qBittorrent's listen port to the port the VPN forwarded. It runs inside
# gluetun, so it only uses what gluetun's image ships: GNU Wget, and BusyBox
# tools, which take short options only (head -n, grep -q).
#
# qBittorrent asks gluetun for a login like every other client. Its login
# bypass covers Readarr's address alone (#411), and gluetun's address is
# shared by every container in its network namespace, so widening the bypass
# to it would let SABnzbd and JDownloader2 in too. The login comes from the
# compose secrets the qBittorrent exporter uses, read on every run, so a
# password rotation needs no gluetun restart (#419).
#
# gluetun waits for the up command to exit, and for its output to close,
# before it starts keeping the forwarded port alive
# (internal/portforward/service/start.go and command.go, v3.41.3). qBittorrent
# starts minutes after gluetun on a full `make start`, so waiting for it here
# would hold up the port renewals. The script therefore hands the work to a
# copy of itself in the background, logging to gluetun's own output, and
# returns at once. That copy gives up when gluetun has forwarded another port
# in the meantime. Each attempt (login, setPreferences, logout) holds a lock
# shared by every copy and checks the forwarded port again once it has it, so
# an older copy can never apply its port after a newer one; the lock is
# released while a copy waits between attempts.
#
# Usage: qbittorrent-port-forward.sh <ports>   (gluetun's {{PORTS}}, comma separated)
set -u

log_target="${QBITTORRENT_PORT_FORWARD_LOG:-/proc/1/fd/1}"
status_file="${VPN_PORT_FORWARDING_STATUS_FILE:-/tmp/gluetun/forwarded_port}"
secrets_dir="${QBITTORRENT_SECRETS_DIR:-/run/secrets}"
attempts="${QBITTORRENT_PORT_FORWARD_ATTEMPTS:-180}"
delay="${QBITTORRENT_PORT_FORWARD_DELAY:-10}"
lock_file="${QBITTORRENT_PORT_FORWARD_LOCK:-/tmp/qbittorrent-port-forward.lock}"
# Both come from the stack's .env, which gluetun reads through its env_file.
services_ip="${GLUETUN_SERVICES_IP:-}"
https_port="${QBITTORRENT_HTTPS_PORT:-}"
base_url="https://${services_ip}:${https_port}/api/v2"

# Form encoding for the login body. One line on purpose: kcov counts every
# line of a multi line awk program as a shell line that never ran. Reads only
# the first line, so a trailing newline in a hand edited secret file does not
# end up in the password.
urlencode() {
  LC_ALL=C awk 'BEGIN { for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i } NR == 1 { for (i = 1; i <= length($0); i++) { c = substr($0, i, 1); if (c ~ /[A-Za-z0-9._~-]/) printf "%s", c; else printf "%%%02X", ord[c] } }' "$1"
}

login_body() {
  printf 'username='
  urlencode "${secrets_dir}/qbittorrent_username"
  printf '&password='
  urlencode "${secrets_dir}/qbittorrent_password"
}

# gluetun writes one forwarded port per line and clears the file when the
# forwarding stops.
still_forwarded() {
  [ "$(head -n 1 "$status_file" 2>/dev/null)" = "$port" ]
}

# --server-response puts the reply's status line on standard error even with
# --quiet, which is how a 5xx is told apart from a refusal: wget exits 8 for
# both.
qbt() {
  wget --quiet --server-response --no-check-certificate --tries=1 --timeout=10 --load-cookies="${work_dir}/cookies" --save-cookies="${work_dir}/cookies" --keep-session-cookies --output-document="${work_dir}/reply" "$@" 2>"${work_dir}/headers"
}

server_error() {
  awk '$1 ~ /^HTTP\// { code = $2 } END { exit !(code ~ /^5/) }' "${work_dir}/headers"
}

dispatch() {
  port="${1:-}"
  port="${port%%,*}"
  case "$port" in
  '' | *[!0-9]*)
    echo "[PORTFWD] ERROR: no forwarded port given (got '${1:-}')"
    exit 1
    ;;
  esac
  /bin/sh "$0" --worker "$port" </dev/null >>"$log_target" 2>&1 &
  echo "[PORTFWD] setting qBittorrent's listen port to ${port} in the background"
  exit 0
}

[ "${1:-}" = "--worker" ] || dispatch "$@"

port="$2"

if [ -z "$services_ip" ] || [ -z "$https_port" ]; then
  echo "[PORTFWD] ERROR: GLUETUN_SERVICES_IP or QBITTORRENT_HTTPS_PORT unset, port ${port} not applied"
  exit 1
fi

for secret in qbittorrent_username qbittorrent_password; do
  if [ ! -r "${secrets_dir}/${secret}" ]; then
    echo "[PORTFWD] ERROR: ${secrets_dir}/${secret} missing, port ${port} not applied"
    exit 1
  fi
done

work_dir="$(mktemp -d)" || exit 1
trap 'rm -rf "$work_dir"' EXIT
exec 9>"$lock_file"

# The body goes through a file, not --post-data, so the password never shows
# up in a process list.
login_body >"${work_dir}/login"

# 4 is a network failure (qBittorrent not up yet) and 8 with a 5xx a server
# error: both are worth another attempt. Anything else is an answer from
# qBittorrent (a refused login, a ban, a refused setting) and stops the run,
# since every retried login would count towards its failed login ban.
retryable() {
  [ "$1" -eq 4 ] || { [ "$1" -eq 8 ] && server_error; }
}

logout() {
  qbt --post-data='' "${base_url}/auth/logout" || true
}

# One attempt is login, setPreferences and logout, under the lock. A failure
# worth retrying at either step waits and starts the attempt over.
i=1
while :; do
  flock 9
  if ! still_forwarded; then
    echo "[PORTFWD] port ${port} is no longer the forwarded port, stopping"
    exit 0
  fi
  : >"${work_dir}/cookies"
  status=0
  qbt --post-file="${work_dir}/login" "${base_url}/auth/login" || status=$?
  if [ "$status" -eq 0 ]; then
    # qBittorrent before 5.2 answers a wrong password with 200 "Fails." and
    # no session cookie.
    if ! grep -q SID "${work_dir}/cookies"; then
      echo "[PORTFWD] ERROR: qBittorrent login gave no session ($(head -c 40 "${work_dir}/reply")), port ${port} not applied"
      exit 1
    fi
    qbt --post-data="json=%7B%22listen_port%22%3A${port}%7D" "${base_url}/app/setPreferences" || status=$?
    # Decided before the logout, which replaces the saved status line.
    if [ "$status" -eq 0 ]; then
      logout
      echo "[PORTFWD] qBittorrent listen port set to ${port}"
      exit 0
    fi
    if ! retryable "$status"; then
      logout
      echo "[PORTFWD] ERROR: qBittorrent did not accept listen port ${port} (wget exit ${status})"
      exit 1
    fi
    logout
  elif ! retryable "$status"; then
    echo "[PORTFWD] ERROR: qBittorrent refused the login (wget exit ${status}), port ${port} not applied"
    exit 1
  fi
  if [ "$i" -ge "$attempts" ]; then
    echo "[PORTFWD] WARN: qBittorrent unreachable after $((attempts * delay)) seconds, port ${port} not applied"
    exit 1
  fi
  i=$((i + 1))
  flock -u 9
  sleep "$delay"
done
