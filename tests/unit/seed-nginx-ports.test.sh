#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for scripts/seed-nginx-ports.sh. Every line of the script has to run
# in one of them: `make coverage` runs this file under kcov and fails below
# 100%.
#
# The script edits .env in the current directory, so each case runs in a
# scratch directory. It prompts only when standard input is a terminal; the
# answers are typed through tests/unit/with-tty.py. sudo is a stub on PATH
# that records its arguments, so no kernel setting changes, and the kernel's
# unprivileged port boundary is read from a scratch file
# (UNPRIVILEGED_PORT_START_FILE).

set -o errexit
set -o pipefail
set -o nounset

__here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__script="${__here}/../../scripts/seed-nginx-ports.sh"
__bash="$(command -v bash)"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0
work="${__scratch}/work"
mkdir "${work}" "${__scratch}/bin"

# sudo_exits <status>
sudo_exits() {
  printf '#!%s\necho "sudo $*" >>"%s/log"\nexit %s\n' "${__bash}" "${__scratch}" "${1}" >"${__scratch}/bin/sudo"
  chmod +x "${__scratch}/bin/sudo"
}

defaults() {
  printf '%s\n' NGINX_HTTP_PORT=8080 NGINX_HTTPS_PORT=8443 >"${work}/.env"
}

# run <typed answers, or "" for no terminal>
run() {
  local tty=()
  ((${#1})) && tty=(python3 "${__here}/with-tty.py" "${1}")
  rm -f "${__scratch}/log"
  touch "${__scratch}/log"
  __status=0
  (cd "${work}" && PATH="${__scratch}/bin:${PATH}" \
    UNPRIVILEGED_PORT_START_FILE="${__scratch}/port_start" "${tty[@]}" bash "${__script}" </dev/null) \
    >"${__scratch}/out" 2>"${__scratch}/err" || __status=$?
}

pass() { echo "ok ${1}"; }
fail() {
  echo "FAIL ${1}" >&2
  cat "${__scratch}/err" >&2
  __failures=$((__failures + 1))
}

# expect <name> <file> <text> <wanted .env, space separated>
expect() {
  local got
  got="$(tr '\n' ' ' <"${work}/.env" 2>/dev/null || true)"
  if [[ "${__status}" -ne 0 ]]; then
    fail "${1}: exit ${__status}"
  elif [[ -n "${3}" ]] && ! grep --quiet --fixed-strings -- "${3}" "${__scratch}/${2}"; then
    fail "${1}: '${3}' not in ${2}"
  elif [[ "${got}" != "${4} " ]]; then
    fail "${1}: .env is '${got}'"
  else
    pass "${1}"
  fi
}

sudo_exits 0
run ""
if [[ "${__status}" -eq 0 && ! -e "${work}/.env" ]]; then
  pass "without .env there is nothing to do"
else
  fail "without .env there is nothing to do"
fi

printf '%s\n' NGINX_HTTP_PORT=80 NGINX_HTTPS_PORT=8443 >"${work}/.env"
run $'y\n'
expect "customized ports are left alone, without asking" out "" "NGINX_HTTP_PORT=80 NGINX_HTTPS_PORT=8443"

defaults
run ""
expect "a non interactive run keeps the defaults" out "" "NGINX_HTTP_PORT=8080 NGINX_HTTPS_PORT=8443"

run $'n\n'
expect "declining keeps the defaults" out "Keeping the rootless-safe defaults (8080/8443)." \
  "NGINX_HTTP_PORT=8080 NGINX_HTTPS_PORT=8443"

echo 1024 >"${__scratch}/port_start"
sudo_exits 1
run $'y\n'
expect "keeps the defaults when sudo fails" err "WARNING: Could not lower the port boundary" \
  "NGINX_HTTP_PORT=8080 NGINX_HTTPS_PORT=8443"

sudo_exits 0
run $'Y\n\n'
expect "lowers the boundary with sudo" log "sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80" \
  "NGINX_HTTP_PORT=80 NGINX_HTTPS_PORT=443"
expect "says the change lasts until reboot" out "This only lasts until the next reboot." \
  "NGINX_HTTP_PORT=80 NGINX_HTTPS_PORT=443"

defaults
echo 80 >"${__scratch}/port_start"
run $'yes\n'
expect "skips sudo when the boundary is already low" out "is already 80 (<=80)" \
  "NGINX_HTTP_PORT=80 NGINX_HTTPS_PORT=443"
if [[ ! -s "${__scratch}/log" ]]; then
  pass "sudo is not called"
else
  fail "sudo was called"
fi

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
