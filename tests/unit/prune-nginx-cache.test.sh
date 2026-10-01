#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for scripts/prune-nginx-cache.sh. Every line of the script has to run
# in one of them: `make coverage` runs this file under kcov and fails below
# 100%.
#
# The script reads .env from its repository and empties the nginx cache
# directory, stopping and starting the nginx container around it. Here it runs
# through a symlink in a scratch repository with its own .env and cache, the
# container runtime is a stub that only records its calls, and the
# confirmation prompt is answered on standard input. The two variables it
# reads before .env are unset for each run, so the caller's shell cannot leak in.

set -o errexit
set -o pipefail
set -o nounset

__script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/prune-nginx-cache.sh"
__bash="$(command -v bash)"
__env="$(command -v env)"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0

repo="${__scratch}/repo"
bin="${__scratch}/bin"
mkdir -p "${repo}/scripts" "${bin}"
ln -s "${__script}" "${repo}/scripts/prune-nginx-cache.sh"
for tool in dirname awk grep find rm mkdir cat; do
  ln -s "$(command -v "${tool}")" "${bin}/${tool}"
done
# The runtime stub lists nginx as running when ${__scratch}/running exists.
printf '#!%s\n%s\n' "${__bash}" "echo \"stub \$*\" >>'${__scratch}/log'
if [[ \"\$1\" == ps && -f '${__scratch}/running' ]]; then echo other; echo nginx; fi
exit 0" >"${bin}/stub-runtime"
chmod +x "${bin}/stub-runtime"

# Runs the script with $1 on standard input.
run() {
  rm -f "${__scratch}/log"
  touch "${__scratch}/log"
  __status=0
  printf '%s\n' "${1}" | "${__env}" -u CONTAINER_RUNTIME -u CACHE_FOLDER PATH="${bin}" "${__bash}" "${repo}/scripts/prune-nginx-cache.sh" \
    >"${__scratch}/out" 2>&1 || __status=$?
}

check() {
  local name="${1}" want_status="${2}" file="${3}" want="${4}"
  if [[ "${__status}" -ne "${want_status}" ]]; then
    echo "FAIL ${name}: exit ${__status}, wanted ${want_status}" >&2
    cat "${__scratch}/out" >&2
    __failures=$((__failures + 1))
  elif ! grep --quiet --fixed-strings -- "${want}" "${__scratch}/${file}"; then
    echo "FAIL ${name}: '${want}' not in ${file}" >&2
    cat "${__scratch}/${file}" >&2
    __failures=$((__failures + 1))
  else
    echo "ok ${name}"
  fi
}

refute() {
  local name="${1}" file="${2}" unwanted="${3}"
  if grep --quiet --fixed-strings -- "${unwanted}" "${__scratch}/${file}"; then
    echo "FAIL ${name}: '${unwanted}' in ${file}" >&2
    __failures=$((__failures + 1))
  else
    echo "ok ${name}"
  fi
}

printf 'CONTAINER_RUNTIME=missing-runtime\n' >"${repo}/.env"
run y
check "refuses a runtime that is not installed" 1 out "Container runtime 'missing-runtime' was not found."

printf '%s\n' 'CONTAINER_RUNTIME="stub-runtime"' "CACHE_FOLDER='./cache'" >"${repo}/.env"
run y
check "does nothing without a cache directory" 0 out "No nginx cache directory found at ./cache/nginx."

mkdir -p "${repo}/cache/nginx/aa/bb"
touch "${repo}/cache/nginx/aa/bb/entry" "${repo}/cache/keep"
run n
check "aborts unless confirmed" 0 out "Aborted."
if [[ ! -f "${repo}/cache/nginx/aa/bb/entry" ]]; then
  echo "FAIL an aborted run deleted the cache" >&2
  __failures=$((__failures + 1))
fi

touch "${__scratch}/running"
run y
check "stops a running nginx first" 0 log "stub stop nginx"
check "starts nginx again" 0 log "stub start nginx"
check "reports the prune" 0 out "Pruned nginx cache under ./cache/nginx."
if [[ -e "${repo}/cache/nginx/aa" || ! -d "${repo}/cache/nginx" || ! -f "${repo}/cache/keep" ]]; then
  echo "FAIL the prune removed the wrong things" >&2
  __failures=$((__failures + 1))
fi

rm "${__scratch}/running" "${repo}/.env"
mkdir -p "${repo}/cache/nginx/cc"
ln -s stub-runtime "${bin}/podman"
run yes
check "defaults to podman without a .env" 0 log "stub ps"
refute "leaves a stopped nginx stopped" log "start nginx"
if [[ -e "${repo}/cache/nginx/cc" ]]; then
  echo "FAIL the default cache folder was not pruned" >&2
  __failures=$((__failures + 1))
fi

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
