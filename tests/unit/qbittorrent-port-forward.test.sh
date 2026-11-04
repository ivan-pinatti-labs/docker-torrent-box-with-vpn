#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for scripts/qbittorrent-port-forward.sh. Every line of the script has
# to run in one of them: `make coverage` runs this file under kcov and fails
# below 100%.
#
# The script talks to qBittorrent only through wget, so wget is a stub first
# on PATH that plays qBittorrent's login, setPreferences and logout from
# STUB_* variables and logs each request (path and body) to a file. The
# worker runs directly under bash, since kcov traces bash and not the
# /bin/sh the dispatcher starts it with in the background; one case drives
# the dispatcher end to end and waits for the background worker. sleep is a
# function exported into the script, so the retry loop runs at once.

set -o errexit
set -o pipefail
set -o nounset

__script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/qbittorrent-port-forward.sh"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0
__bin="${__scratch}/bin"
__secrets="${__scratch}/secrets"
__status_file="${__scratch}/forwarded_port"
__requests="${__scratch}/requests"
mkdir -p "${__bin}" "${__secrets}"

# The stub. STUB_LOGIN_EXIT is the exit status of the first logins (4 is a
# network failure, 8 an HTTP error whose status line, STUB_LOGIN_HTTP, goes to
# standard error as wget --server-response prints it), STUB_LOGIN_FAILURES how
# many logins fail with it before one succeeds (default: all of them), and
# STUB_LOGIN_DELAY seconds every login takes. STUB_SID=no answers a login with
# no session cookie, STUB_SET_EXIT and STUB_LOGOUT_EXIT fail those two calls.
cat >"${__bin}/wget" <<'STUB'
#!/usr/bin/env bash
cookies="" reply="" body="" url=""
for arg in "$@"; do
  case "${arg}" in
  --save-cookies=*) cookies="${arg#*=}" ;;
  --output-document=*) reply="${arg#*=}" ;;
  --post-file=*) body="$(cat "${arg#*=}")" ;;
  --post-data=*) body="${arg#*=}" ;;
  https://*) url="${arg}" ;;
  esac
done
path="${url#https://*/api/v2}"
echo "${path} ${body}" >>"${STUB_REQUESTS}"
case "${path}" in
/auth/login)
  command sleep "${STUB_LOGIN_DELAY:-0}"
  logins="$(grep --count '^/auth/login' "${STUB_REQUESTS}")"
  if [[ -n "${STUB_LOGIN_EXIT:-}" && "${logins}" -le "${STUB_LOGIN_FAILURES:-1000}" ]]; then
    [[ -n "${STUB_LOGIN_HTTP:-}" ]] && echo "  HTTP/1.1 ${STUB_LOGIN_HTTP}" >&2
    exit "${STUB_LOGIN_EXIT}"
  fi
  echo "  HTTP/1.1 200 OK" >&2
  if [[ "${STUB_SID:-yes}" == yes ]]; then
    printf 'qbt\tFALSE\t/\tFALSE\t0\tSID\tabc\n' >"${cookies}"
    printf 'Ok.' >"${reply}"
  else
    printf 'Fails.' >"${reply}"
  fi
  ;;
/app/setPreferences) exit "${STUB_SET_EXIT:-0}" ;;
/auth/logout) exit "${STUB_LOGOUT_EXIT:-0}" ;;
esac
STUB
chmod +x "${__bin}/wget"

sleep() {
  :
}
export -f sleep

# Resets the secrets, the forwarded port file and the request log, then runs
# the worker for port 51413 with the given extra environment.
worker() {
  printf 'admin\n' >"${__secrets}/qbittorrent_username"
  printf 'p&ss w+rd%%' >"${__secrets}/qbittorrent_password"
  printf '51413\n1234' >"${__status_file}"
  : >"${__requests}"
  __status=0
  env PATH="${__bin}:${PATH}" STUB_REQUESTS="${__requests}" \
    GLUETUN_SERVICES_IP=192.0.2.10 QBITTORRENT_HTTPS_PORT=8443 \
    QBITTORRENT_SECRETS_DIR="${__secrets}" VPN_PORT_FORWARDING_STATUS_FILE="${__status_file}" \
    QBITTORRENT_PORT_FORWARD_ATTEMPTS=3 QBITTORRENT_PORT_FORWARD_DELAY=0 \
    QBITTORRENT_PORT_FORWARD_LOCK="${__scratch}/lock" \
    "$@" bash "${__script}" --worker 51413 >"${__scratch}/out" 2>&1 || __status=$?
}

result() {
  if [[ "${2}" == yes ]]; then
    echo "ok ${1}"
  else
    echo "FAIL ${1}" >&2
    cat "${__scratch}/out" >&2
    __failures=$((__failures + 1))
  fi
}

said() {
  grep --quiet --fixed-strings -- "${1}" "${__scratch}/out" && echo yes || echo no
}

requests() {
  cut --delimiter=' ' --fields=1 "${__requests}" | paste --serial --delimiters=' '
}

# Dispatcher: the port is checked before anything runs.
for bad in "" "abc" "12x,34"; do
  __status=0
  bash "${__script}" "${bad}" >"${__scratch}/out" 2>&1 || __status=$?
  [[ "${__status}" -eq 1 ]] && ok="$(said "no forwarded port given (got '${bad}')")" || ok=no
  result "rejects the port list '${bad}'" "${ok}"
done

# Dispatcher end to end: returns at once and the background worker sets the
# first of the ports gluetun passed.
printf 'admin' >"${__secrets}/qbittorrent_username"
printf 'secret' >"${__secrets}/qbittorrent_password"
printf '40000\n40001' >"${__status_file}"
: >"${__requests}"
: >"${__scratch}/log"
__status=0
env PATH="${__bin}:${PATH}" STUB_REQUESTS="${__requests}" \
  GLUETUN_SERVICES_IP=192.0.2.10 QBITTORRENT_HTTPS_PORT=8443 \
  QBITTORRENT_SECRETS_DIR="${__secrets}" VPN_PORT_FORWARDING_STATUS_FILE="${__status_file}" \
  QBITTORRENT_PORT_FORWARD_LOG="${__scratch}/log" QBITTORRENT_PORT_FORWARD_DELAY=0 \
  QBITTORRENT_PORT_FORWARD_LOCK="${__scratch}/lock" STUB_LOGIN_DELAY=2 \
  bash "${__script}" 40000,40001 >"${__scratch}/out" 2>&1 || __status=$?
# The login takes 2 seconds, so a dispatcher that waited for the worker would
# find the result already logged here.
[[ "${__status}" -eq 0 ]] && ! grep --quiet 'listen port set' "${__scratch}/log" &&
  ok="$(said "setting qBittorrent's listen port to 40000 in the background")" || ok=no
result "the dispatcher returns while the worker is still logging in, naming the first port" "${ok}"
for _ in $(seq 1 100); do
  grep --quiet 'listen port set' "${__scratch}/log" && break
  command sleep 0.1
done
grep --quiet --fixed-strings '[PORTFWD] qBittorrent listen port set to 40000' "${__scratch}/log" &&
  grep --quiet --fixed-strings '/app/setPreferences json=%7B%22listen_port%22%3A40000%7D' "${__requests}" &&
  ok=yes || ok=no
result "the background worker logs to the given output and sets the first port" "${ok}"

worker
[[ "${__status}" -eq 0 ]] && ok="$(said "[PORTFWD] qBittorrent listen port set to 51413")" || ok=no
result "logs in, sets the port and logs out" "${ok}"
[[ "$(requests)" == "/auth/login /app/setPreferences /auth/logout" ]] && ok=yes || ok=no
result "makes exactly those three requests, in order" "${ok}"
grep --quiet --line-regexp --fixed-strings '/auth/login username=admin&password=p%26ss%20w%2Brd%25' "${__requests}" &&
  ok=yes || ok=no
result "form encodes the login and drops the username's trailing newline" "${ok}"

worker STUB_LOGOUT_EXIT=8
[[ "${__status}" -eq 0 ]] && ok="$(said "listen port set to 51413")" || ok=no
result "a failed logout does not fail the run" "${ok}"

worker STUB_LOGIN_EXIT=4 STUB_LOGIN_FAILURES=2
[[ "${__status}" -eq 0 && "$(requests)" == "/auth/login /auth/login /auth/login /app/setPreferences /auth/logout" ]] &&
  ok=yes || ok=no
result "retries while qBittorrent is unreachable, then sets the port" "${ok}"

worker STUB_LOGIN_EXIT=4
[[ "${__status}" -eq 1 ]] && ok="$(said "WARN: qBittorrent unreachable after 0 seconds, port 51413 not applied")" || ok=no
result "gives up after the last attempt" "${ok}"
[[ "$(requests)" == "/auth/login /auth/login /auth/login" ]] && ok=yes || ok=no
result "tries exactly QBITTORRENT_PORT_FORWARD_ATTEMPTS times" "${ok}"

worker STUB_LOGIN_EXIT=8 STUB_LOGIN_HTTP="503 Service Unavailable" STUB_LOGIN_FAILURES=1
[[ "${__status}" -eq 0 && "$(requests)" == "/auth/login /auth/login /app/setPreferences /auth/logout" ]] &&
  ok=yes || ok=no
result "retries a login answered with a 5xx, then sets the port" "${ok}"

worker STUB_LOGIN_EXIT=8 STUB_LOGIN_HTTP="403 Forbidden"
[[ "${__status}" -eq 1 && "$(requests)" == "/auth/login" ]] && ok="$(said "refused the login (wget exit 8)")" || ok=no
result "stops after one login answered with a 4xx, such as a ban" "${ok}"

worker STUB_LOGIN_EXIT=6
[[ "${__status}" -eq 1 ]] && ok="$(said "refused the login (wget exit 6)")" || ok=no
result "stops on a refused login" "${ok}"
[[ "$(requests)" == "/auth/login" ]] && ok=yes || ok=no
result "tries a refused login only once, clear of the failed login ban" "${ok}"

worker STUB_SID=no
[[ "${__status}" -eq 1 ]] && ok="$(said "login gave no session (Fails.)")" || ok=no
result "stops when the login gives no session cookie" "${ok}"

worker STUB_SET_EXIT=8
[[ "${__status}" -eq 1 ]] && ok="$(said "did not accept listen port 51413")" || ok=no
result "reports a refused setPreferences" "${ok}"
[[ "$(requests)" == "/auth/login /app/setPreferences /auth/logout" ]] && ok=yes || ok=no
result "logs out after a refused setPreferences too" "${ok}"

# Another copy holds the lock while gluetun moves to a new port: this one
# waits, then sees the new port and stops without a request.
flock "${__scratch}/lock" bash -c "command sleep 1; printf 51999 >'${__status_file}'" &
__holder=$!
command sleep 0.3
worker
wait "${__holder}"
[[ "${__status}" -eq 0 && ! -s "${__requests}" ]] && ok="$(said "port 51413 is no longer the forwarded port")" || ok=no
result "waits for another copy's attempt, then checks the forwarded port again" "${ok}"

printf '51999' >"${__scratch}/forwarded_port_next"
worker VPN_PORT_FORWARDING_STATUS_FILE="${__scratch}/forwarded_port_next"
[[ "${__status}" -eq 0 && ! -s "${__requests}" ]] && ok="$(said "port 51413 is no longer the forwarded port, stopping")" || ok=no
result "stops without a request once gluetun forwards another port" "${ok}"

worker VPN_PORT_FORWARDING_STATUS_FILE="${__scratch}/missing"
[[ "${__status}" -eq 0 && ! -s "${__requests}" ]] && ok="$(said "is no longer the forwarded port")" || ok=no
result "stops once gluetun clears or has no port file" "${ok}"

worker GLUETUN_SERVICES_IP=
[[ "${__status}" -eq 1 && ! -s "${__requests}" ]] && ok="$(said "GLUETUN_SERVICES_IP or QBITTORRENT_HTTPS_PORT unset")" || ok=no
result "stops when the stack's address is missing" "${ok}"

worker QBITTORRENT_HTTPS_PORT=
[[ "${__status}" -eq 1 && ! -s "${__requests}" ]] && ok="$(said "GLUETUN_SERVICES_IP or QBITTORRENT_HTTPS_PORT unset")" || ok=no
result "stops when qBittorrent's port is missing" "${ok}"

worker QBITTORRENT_SECRETS_DIR="${__scratch}/nowhere"
[[ "${__status}" -eq 1 && ! -s "${__requests}" ]] && ok="$(said "nowhere/qbittorrent_username missing")" || ok=no
result "stops when a secret is missing" "${ok}"

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failure(s)" >&2
  exit 1
fi
