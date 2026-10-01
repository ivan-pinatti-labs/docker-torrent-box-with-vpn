#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# cspell:ignore RTNETLINK
#
# Tests for scripts/detect-system-values.sh. Every line of the script has to
# run in one of them: `make coverage` runs this file under kcov and fails
# below 100%.
#
# The script asks the host for its user, group, time zone and LAN address.
# Here id, timedatectl, ip and hostname are stubs on PATH whose answers each
# case sets, and the time zone files it falls back to live in a scratch
# directory (DETECT_TIMEZONE_FILE, DETECT_LOCALTIME_LINK), so nothing is read
# from the host running the test.

set -o errexit
set -o pipefail
set -o nounset

__script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/detect-system-values.sh"
__bash="$(command -v bash)"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0
env_file="${__scratch}/env"

# Single quoted on purpose: $1 belongs to the stub, expanded when it runs.
# shellcheck disable=SC2016
# host <uid> <gid> <timedatectl answer> <ip answer or "fail"> <hostname -I answer>
host() {
  local bin="${__scratch}/bin"
  rm -rf "${bin}"
  mkdir "${bin}"
  printf '#!%s\n[[ "$1" == -u ]] && echo %s || echo %s\n' "${__bash}" "${1}" "${2}" >"${bin}/id"
  printf '#!%s\necho "%s"\n' "${__bash}" "${3}" >"${bin}/timedatectl"
  if [[ "${4}" == fail ]]; then
    printf '#!%s\necho "RTNETLINK answers: Network is unreachable" >&2\nexit 2\n' "${__bash}" >"${bin}/ip"
  else
    printf '#!%s\necho "%s"\n' "${__bash}" "${4}" >"${bin}/ip"
  fi
  printf '#!%s\necho "%s"\n' "${__bash}" "${5}" >"${bin}/hostname"
  chmod +x "${bin}"/*
}

defaults() {
  printf '%s\n' UID=1000 GID=1000 TIMEZONE=America/Toronto LAN_IP=192.168.1.x >"${env_file}"
}

run() {
  __status=0
  PATH="${__scratch}/bin:${PATH}" DETECT_TIMEZONE_FILE="${__scratch}/timezone" \
    DETECT_LOCALTIME_LINK="${__scratch}/localtime" bash "${__script}" "$@" \
    >"${__scratch}/out" 2>"${__scratch}/err" || __status=$?
}

# check <name> <wanted env file contents, space separated>
check() {
  local got
  got="$(tr '\n' ' ' <"${env_file}")"
  if [[ "${__status}" -ne 0 ]]; then
    echo "FAIL ${1}: exit ${__status}" >&2
    cat "${__scratch}/err" >&2
    __failures=$((__failures + 1))
  elif [[ "${got}" != "${2} " ]]; then
    echo "FAIL ${1}: got '${got}'" >&2
    __failures=$((__failures + 1))
  else
    echo "ok ${1}"
  fi
}

run
if [[ "${__status}" -eq 1 ]] && grep --quiet "Usage:" "${__scratch}/err"; then
  echo "ok no argument is a usage error"
else
  echo "FAIL no argument is a usage error" >&2
  __failures=$((__failures + 1))
fi

host 1001 1002 Europe/Paris "1.1.1.1 via 10.0.0.1 dev eth0 src 10.0.0.5 uid 1001" ""
run "${__scratch}/missing"
if [[ "${__status}" -eq 0 && ! -e "${__scratch}/missing" ]]; then
  echo "ok a missing env file is left missing"
else
  echo "FAIL a missing env file is left missing" >&2
  __failures=$((__failures + 1))
fi

defaults
run "${env_file}"
check "replaces every placeholder with the host's values" \
  "UID=1001 GID=1002 TIMEZONE=Europe/Paris LAN_IP=10.0.0.5"
if grep --quiet --fixed-strings "Set LAN_IP=10.0.0.5 (detected via 'ip route')." "${__scratch}/out"; then
  echo "ok says what it set"
else
  echo "FAIL says what it set" >&2
  __failures=$((__failures + 1))
fi

run "${env_file}"
check "leaves customized values alone" \
  "UID=1001 GID=1002 TIMEZONE=Europe/Paris LAN_IP=10.0.0.5"

defaults
host 1000 1000 "" "1.1.1.1 dev lo" "10.0.0.9 fd00::1"
echo "Asia/Tokyo" >"${__scratch}/timezone"
run "${env_file}"
check "falls back to the time zone file and hostname -I" \
  "UID=1000 GID=1000 TIMEZONE=Asia/Tokyo LAN_IP=10.0.0.9"

defaults
rm "${__scratch}/timezone"
ln -s /usr/share/zoneinfo/Europe/Lisbon "${__scratch}/localtime"
host 1000 1000 "" fail "10.0.0.7"
run "${env_file}"
check "falls back to the localtime link, and to hostname -I when ip fails" \
  "UID=1000 GID=1000 TIMEZONE=Europe/Lisbon LAN_IP=10.0.0.7"

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
