#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for scripts/enable-test-profiles.sh. Every line of the script has to
# run in one of them: `make coverage` runs this file under kcov and fails
# below 100%.
#
# The script edits .env in the current directory from .env.tests, so each
# case runs in a scratch directory. id and podman are stubs on PATH whose
# answers each case sets, and the scripts/seed-vpn-mock.sh it ends with is a
# stub in the scratch directory that only records that it ran.

set -o errexit
set -o pipefail
set -o nounset

__script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/enable-test-profiles.sh"
__bash="$(command -v bash)"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0
work="${__scratch}/work"
mkdir -p "${__scratch}/bin" "${work}/scripts"
# Single quoted on purpose: $PWD and $1 belong to the stubs, expanded when
# they run.
# shellcheck disable=SC2016
{
  printf '#!%s\necho "seed-vpn-mock in $PWD" >>"%s/log"\n' "${__bash}" "${__scratch}" >"${work}/scripts/seed-vpn-mock.sh"
  printf '#!%s\n[[ "$1" == -u ]] && echo 1001 || echo 1002\n' "${__bash}" >"${__scratch}/bin/id"
}
printf '%s\n' "# Test overrides" "" "SONARR_PROFILE=enabled" "VPN_MOCK=true" >"${work}/.env.tests"

# podman_answers <version, or "fail" for a host without podman>
podman_answers() {
  if [[ "${1}" == fail ]]; then
    printf '#!%s\necho "podman: command not found" >&2\nexit 127\n' "${__bash}" >"${__scratch}/bin/podman"
  else
    printf '#!%s\necho %s\n' "${__bash}" "${1}" >"${__scratch}/bin/podman"
  fi
  chmod +x "${__scratch}/bin"/* "${work}/scripts/seed-vpn-mock.sh"
}

env_file() {
  printf '%s\n' SONARR_PROFILE=disabled UID=1000 PODMAN_EXPORTER_PROFILE=enabled \
    PODMAN_LIMITS_EXPORTER_PROFILE=enabled >"${work}/.env"
}

run() {
  rm -f "${__scratch}/log"
  __status=0
  (cd "${work}" && PATH="${__scratch}/bin:${PATH}" bash "${__script}") \
    >"${__scratch}/out" 2>"${__scratch}/err" || __status=$?
}

# check <name> <wanted .env, space separated>
check() {
  local got
  got="$(tr '\n' ' ' <"${work}/.env")"
  if [[ "${__status}" -ne 0 ]]; then
    echo "FAIL ${1}: exit ${__status}" >&2
    cat "${__scratch}/err" >&2
    __failures=$((__failures + 1))
  elif [[ "${got}" != "${2} " ]]; then
    echo "FAIL ${1}: .env is '${got}'" >&2
    __failures=$((__failures + 1))
  elif ! grep --quiet --fixed-strings "seed-vpn-mock in ${work}" "${__scratch}/log"; then
    echo "FAIL ${1}: seed-vpn-mock.sh did not run" >&2
    __failures=$((__failures + 1))
  else
    echo "ok ${1}"
  fi
}

podman_answers 5.8.4
run
if [[ "${__status}" -eq 1 ]] && grep --quiet "ERROR: .env does not exist" "${__scratch}/err"; then
  echo "ok refuses to run without .env"
else
  echo "FAIL refuses to run without .env: exit ${__status}" >&2
  __failures=$((__failures + 1))
fi

env_file
run
check "applies the overrides and the invoking user's ids on podman 5" \
  "SONARR_PROFILE=enabled UID=1001 PODMAN_EXPORTER_PROFILE=enabled PODMAN_LIMITS_EXPORTER_PROFILE=enabled VPN_MOCK=true GID=1002"

env_file
podman_answers 4.9.3
run
check "disables the podman exporters on podman 4" \
  "SONARR_PROFILE=enabled UID=1001 PODMAN_EXPORTER_PROFILE=disabled PODMAN_LIMITS_EXPORTER_PROFILE=disabled VPN_MOCK=true GID=1002"
if grep --quiet --fixed-strings "PODMAN_EXPORTER_PROFILE=disabled (podman 4.x cannot set --userns inside a pod)" "${__scratch}/out"; then
  echo "ok says why it disabled them"
else
  echo "FAIL says why it disabled them" >&2
  __failures=$((__failures + 1))
fi

env_file
podman_answers fail
run
check "leaves the exporters alone without podman" \
  "SONARR_PROFILE=enabled UID=1001 PODMAN_EXPORTER_PROFILE=enabled PODMAN_LIMITS_EXPORTER_PROFILE=enabled VPN_MOCK=true GID=1002"

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
