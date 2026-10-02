#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for scripts/assert-stack-started.sh. Every line of the script has to
# run in one of them: `make coverage` runs this file under kcov and fails
# below 100%.
#
# The script asks compose which services are enabled and the runtime which
# are running, then polls until the two lists match. Here podman,
# podman-compose, docker and sleep are stubs that read their answers from the
# scratch directory, and PATH holds nothing else but the handful of text tools
# the script needs, so no real runtime is asked anything and nothing sleeps.

set -o errexit
set -o pipefail
set -o nounset

__script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/assert-stack-started.sh"
__bash="$(command -v bash)"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0

stub() {
  local dir="${1}" name="${2}" body="${3}"
  printf '#!%s\n%s\n' "${__bash}" "${body}" >"${dir}/${name}"
  chmod +x "${dir}/${name}"
}

# A bin directory with the text tools and the given runtime stubs. The compose
# stubs print the services in `expected`; the runtime's `ps` prints those in
# `running`, and sleep moves `later` into `running`, so a service can come up
# while the script waits.
fresh_bin() {
  local bin="${__scratch}/bin"
  rm -rf "${bin}"
  mkdir -p "${bin}"
  for tool in sed head tr basename sort wc comm grep cat mv; do
    ln -s "$(command -v "${tool}")" "${bin}/${tool}"
  done
  for name in "$@"; do
    stub "${bin}" "${name}" "echo \"${name} \$*\" >>'${__scratch}/log'
case \"\$*\" in
*config*) cat '${__scratch}/expected' ;;
ps*) cat '${__scratch}/running' ;;
esac"
  done
  stub "${bin}" sleep "echo \"sleep \$*\" >>'${__scratch}/log'
[[ -f '${__scratch}/later' ]] && mv '${__scratch}/later' '${__scratch}/running'
true"
  echo "${bin}"
}

run() {
  local bin="${1}"
  shift
  rm -f "${__scratch}/log"
  touch "${__scratch}/log"
  __status=0
  (cd "${__scratch}/work" && PATH="${bin}" "${__bash}" "${__script}" "$@") \
    >"${__scratch}/out" 2>"${__scratch}/err" || __status=$?
}

check() {
  local name="${1}" status="${2}" file="${3}" want="${4}"
  if [[ "${__status}" -ne "${status}" ]]; then
    echo "FAIL ${name}: exit ${__status}, wanted ${status}" >&2
    cat "${__scratch}/err" >&2
    __failures=$((__failures + 1))
  elif ! grep --quiet --fixed-strings -- "${want}" "${__scratch}/${file}"; then
    echo "FAIL ${name}: '${want}' not in ${file}" >&2
    cat "${__scratch}/${file}" >&2
    __failures=$((__failures + 1))
  else
    echo "ok ${name}"
  fi
}

mkdir -p "${__scratch}/work"
printf 'sonarr\nradarr\n' >"${__scratch}/expected"
printf 'radarr\nsonarr\n\n' >"${__scratch}/running"

bin="$(fresh_bin podman podman-compose)"
STACK_START_TIMEOUT=soon run "${bin}"
check "rejects a timeout that is not a number" 1 err "must be a whole number of seconds, got 'soon'"

printf 'COMPOSE_PROJECT_NAME="from-env"\n' >"${__scratch}/work/.env"
run "${bin}" --file a.yml
check "passes the compose files to podman-compose" 0 log "podman-compose --file a.yml --profile enabled config --services"
check "reads the project from .env" 0 log "label=com.docker.compose.project=from-env"
check "reports every service running" 0 out "All 2 enabled services are running."
rm "${__scratch}/work/.env"

bin="$(fresh_bin podman)"
COMPOSE_PROJECT_NAME=inherited run "${bin}"
check "uses podman compose without podman-compose" 0 log "podman compose --profile enabled config --services"
check "an inherited project name wins over the directory" 0 log "label=com.docker.compose.project=inherited"

bin="$(fresh_bin docker)"
printf 'radarr\n' >"${__scratch}/running"
printf 'radarr\nsonarr\n' >"${__scratch}/later"
run "${bin}"
check "falls back to docker compose" 0 log "docker compose --profile enabled config --services"
check "falls back to the directory name" 0 log "label=com.docker.compose.project=work"
check "waits while a service is still coming up" 0 log "sleep 5"
check "reports once it is up" 0 out "All 2 enabled services are running."

printf 'radarr\n' >"${__scratch}/running"
STACK_START_TIMEOUT=5 run "${bin}"
check "gives up at the timeout" 1 err "1 of 2 enabled services are not running after 5s:"
check "names the missing service" 1 err "  sonarr"

# A leading zero is decimal, as it always was. Read as octal, 012 would be
# ten seconds and the run would give up after 10s, not 15s.
STACK_START_TIMEOUT=012 run "${bin}"
check "reads a timeout with a leading zero as decimal" 1 err "after 15s:"

true &
dead=$!
wait "${dead}"
COMPOSE_UP_PID="${dead}" run "${bin}"
check "stops one poll after compose up exits" 1 err "after 5s:"

COMPOSE_UP_PID="$$" STACK_START_TIMEOUT=0 run "${bin}"
check "a live compose up still honors the timeout" 1 err "after 0s:"

: >"${__scratch}/expected"
run "${bin}"
check "refuses when compose lists no services" 1 err "could not determine which services should be running"

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
