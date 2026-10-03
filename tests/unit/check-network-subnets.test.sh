#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for scripts/check-network-subnets.sh. Every line of the script has to
# run in one of them: `make coverage` runs this file under kcov and fails below
# 100%.
#
# The script compares the subnets of the stack's existing networks with the
# ones .env asks for. It reads .env from the directory it runs in, so each case
# runs in a scratch directory with its own .env, and podman or docker is a stub
# that answers for a fixed set of networks. PATH holds the stubs and the few
# tools the script needs, so no real runtime is ever asked anything.

set -o errexit
set -o pipefail
set -o nounset

__script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/check-network-subnets.sh"
__bash="$(command -v bash)"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0

tools="${__scratch}/tools"
mkdir -p "${tools}"
for tool in grep cut tr basename cat; do
  ln -s "$(command -v "${tool}")" "${tools}/${tool}"
done

stub() {
  printf '#!%s\n%s\n' "${__bash}" "${3}" >"${1}/${2}"
  chmod +x "${1}/${2}"
}

# podman: proj_services is on the subnet .env asks for, proj_observability is
# not, proj_media answers no subnet at all, and nothing else exists.
podman_bin="${__scratch}/podman-bin"
mkdir -p "${podman_bin}"
# shellcheck disable=SC2016 # expanded by the stub, not here
stub "${podman_bin}" podman 'name="$3"
case "$2:$name" in
exists:proj_services | exists:proj_observability | exists:proj_media) exit 0 ;;
exists:*) exit 1 ;;
inspect:proj_services) echo 10.1.0.0/24 ;;
inspect:proj_observability) echo 10.9.0.0/24 ;;
esac
exit 0'

# docker: only answers the .IPAM.Config template, and rejects the podman one
# the way docker really does, so the script has to try both.
docker_bin="${__scratch}/docker-bin"
mkdir -p "${docker_bin}"
# shellcheck disable=SC2016 # expanded by the stub, not here
stub "${docker_bin}" docker 'if [[ "$#" -eq 2 ]]; then exit 0; fi
case "$5" in
*Subnets*) echo "map has no entry for key \"Subnets\"" >&2; exit 1 ;;
*) echo 10.2.0.0/24 ;;
esac'

run() {
  local dir="${1}" bin="${2}"
  __status=0
  (cd "${dir}" && PATH="${bin}:${tools}" "${__bash}" "${__script}") \
    >"${__scratch}/out" 2>&1 || __status=$?
}

check() {
  local name="${1}" want_status="${2}" want="${3}"
  if [[ "${__status}" -ne "${want_status}" ]]; then
    echo "FAIL ${name}: exit ${__status}, wanted ${want_status}" >&2
    cat "${__scratch}/out" >&2
    __failures=$((__failures + 1))
  elif ! grep --quiet --fixed-strings -- "${want}" "${__scratch}/out"; then
    echo "FAIL ${name}: '${want}' not in the output" >&2
    cat "${__scratch}/out" >&2
    __failures=$((__failures + 1))
  else
    echo "ok ${name}"
  fi
}

mkdir -p "${__scratch}/no-env"
run "${__scratch}/no-env" "${podman_bin}"
if [[ "${__status}" -ne 0 || -s "${__scratch}/out" ]]; then
  echo "FAIL no .env: exit ${__status}" >&2
  __failures=$((__failures + 1))
else
  echo "ok passes silently without a .env"
fi

mkdir -p "${__scratch}/podman"
printf '%s\n' COMPOSE_PROJECT_NAME=proj 'SERVICES_SUBNET="10.1.0.0/24"' \
  OBSERVABILITY_SUBNET=10.3.0.0/24 MEDIA_SUBNET=10.4.0.0/24 >"${__scratch}/podman/.env"
run "${__scratch}/podman" "${podman_bin}"
check "names a network on the wrong subnet" 1 "ERROR: network proj_observability is on 10.9.0.0/24, but OBSERVABILITY_SUBNET in .env asks for 10.3.0.0/24."
check "warns about a subnet it cannot read" 1 "WARNING: could not read proj_media's subnet"
check "says how to recreate the networks" 1 "podman network rm proj_services proj_observability proj_media"
if grep --quiet "ERROR: network proj_services" "${__scratch}/out"; then
  echo "FAIL flagged a network on the right subnet" >&2
  __failures=$((__failures + 1))
fi

mkdir -p "${__scratch}/checkout"
printf '%s\n' SERVICES_SUBNET=10.2.0.0/24 OBSERVABILITY_SUBNET= >"${__scratch}/checkout/.env"
run "${__scratch}/checkout" "${docker_bin}"
if [[ "${__status}" -ne 0 ]]; then
  echo "FAIL docker with matching subnets: exit ${__status}" >&2
  cat "${__scratch}/out" >&2
  __failures=$((__failures + 1))
else
  echo "ok falls back to docker and its inspect format"
fi

# A network that does not exist is not checked: docker_bin answers only for
# the inspect without a format, so make it fail for this run.
stub "${docker_bin}" docker 'exit 1'
printf '%s\n' COMPOSE_PROJECT_NAME=other SERVICES_SUBNET=10.5.0.0/24 >"${__scratch}/checkout/.env"
run "${__scratch}/checkout" "${docker_bin}"
if [[ "${__status}" -ne 0 ]]; then
  echo "FAIL a missing network failed the check" >&2
  __failures=$((__failures + 1))
else
  echo "ok skips a network that does not exist"
fi

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
