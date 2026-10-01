#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for scripts/auto-start.sh. Every line of the script has to run in one
# of them: `make coverage` runs this file under kcov and fails below 100%.
#
# The script waits two minutes, polls the container runtime until it answers
# and then runs `make start`. Here sleep, podman, docker and make are stubs in
# a scratch directory, and PATH holds nothing else (plus dirname, which the
# script needs to find the repository), so no real runtime is asked anything,
# nothing sleeps, and the stack is never started.

set -o errexit
set -o pipefail
set -o nounset

__repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
__script="${__repo}/scripts/auto-start.sh"
__bash="$(command -v bash)"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0

# Writes an executable stub. Stubs are pure bash, so they need nothing on PATH.
stub() {
  local dir="${1}" name="${2}" body="${3}"
  mkdir -p "${dir}"
  printf '#!%s\n%s\n' "${__bash}" "${body}" >"${dir}/${name}"
  chmod +x "${dir}/${name}"
}

# A bin directory holding the stubs every case shares. The runtime stub
# answers `ps` with a failure first and a success after, so the wait loop
# goes round once.
fresh_bin() {
  local bin="${__scratch}/${1}"
  rm -rf "${bin}" "${__scratch}/log" "${__scratch}/count"
  mkdir -p "${bin}"
  ln -s "$(command -v dirname)" "${bin}/dirname"
  stub "${bin}" sleep "echo \"sleep \$*\" >>'${__scratch}/log'"
  stub "${bin}" make "echo \"make \$* in \$PWD\" >>'${__scratch}/log'"
  echo "${bin}"
}

runtime_stub() {
  stub "${1}" "${2}" "n=0
[[ -f '${__scratch}/count' ]] && n=\$(<'${__scratch}/count')
n=\$((n + 1))
echo \"\${n}\" >'${__scratch}/count'
echo \"${2} \$*\" >>'${__scratch}/log'
[[ \"\${n}\" -gt 1 ]]"
}

run() {
  __status=0
  PATH="${1}" "${__bash}" "${__script}" >"${__scratch}/out" 2>"${__scratch}/err" ||
    __status=$?
}

check() {
  local name="${1}" file="${2}" want="${3}"
  if [[ "${__status}" -ne 0 ]]; then
    echo "FAIL ${name}: exit ${__status}" >&2
    cat "${__scratch}/err" >&2
    __failures=$((__failures + 1))
  elif ! grep --quiet --fixed-strings -- "${want}" "${__scratch}/${file}"; then
    echo "FAIL ${name}: '${want}' not in ${file}" >&2
    __failures=$((__failures + 1))
  else
    echo "ok ${name}"
  fi
}

bin="$(fresh_bin podman-bin)"
runtime_stub "${bin}" podman
run "${bin}"
check "waits for the host to settle" log "sleep 120"
check "polls podman until it answers" out "Waiting for podman to be ready..."
check "polls again after a short wait" log "sleep 2"
check "reports podman ready" out "podman is ready!"
check "starts the stack from the repository" log "make start in ${__repo}"

bin="$(fresh_bin docker-bin)"
runtime_stub "${bin}" docker
echo 1 >"${__scratch}/count"
run "${bin}"
check "falls back to docker without podman" out "docker is ready!"
check "docker answered on the first poll" log "docker ps"
if grep --quiet "Waiting" "${__scratch}/out"; then
  echo "FAIL docker answered at once yet the script waited" >&2
  __failures=$((__failures + 1))
fi

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
