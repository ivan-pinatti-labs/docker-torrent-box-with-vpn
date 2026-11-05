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

# The script falls back to the environment for a setting .env does not have,
# and the Makefile exports the ones it fills in. `make coverage` would hand
# those to every case below, so start from none.
unset APPS_SUBNET SERVICES_SUBNET OBSERVABILITY_SUBNET MEDIA_SUBNET \
  SERVICES_DYNAMIC_IP_RANGE GLUETUN_SERVICES_IP NGINX_SERVICES_IP VPN_MOCK_IP READARR_SERVICES_IP READARR_PROFILE

__script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/check-network-subnets.sh"
__bash="$(command -v bash)"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0

tools="${__scratch}/tools"
mkdir -p "${tools}"
for tool in grep cut tr basename dirname awk cat; do
  ln -s "$(command -v "${tool}")" "${tools}/${tool}"
done

stub() {
  printf '#!%s\n%s\n' "${__bash}" "${3}" >"${1}/${2}"
  chmod +x "${1}/${2}"
}

# podman: proj_services is on the subnet .env asks for, proj_observability is
# not, proj_media answers no subnet at all, proj_apps is on the range podman
# picked for it before apps had a subnet of its own, and nothing else exists.
podman_bin="${__scratch}/podman-bin"
mkdir -p "${podman_bin}"
# shellcheck disable=SC2016 # expanded by the stub, not here
stub "${podman_bin}" podman 'name="$3"
case "$2:$name" in
exists:proj_services | exists:proj_observability | exists:proj_media | exists:proj_apps) exit 0 ;;
exists:*) exit 1 ;;
inspect:proj_services) echo 10.1.0.0/24 ;;
inspect:proj_observability) echo 10.9.0.0/24 ;;
inspect:proj_apps) echo 10.89.0.0/24 ;;
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
check "names only the mismatched networks to remove" 1 "podman network rm proj_observability"
if grep --quiet "ERROR: network proj_services" "${__scratch}/out"; then
  echo "FAIL flagged a network on the right subnet" >&2
  __failures=$((__failures + 1))
fi
if grep --quiet "proj_apps" "${__scratch}/out"; then
  echo "FAIL checked apps with no APPS_SUBNET anywhere" >&2
  __failures=$((__failures + 1))
fi

# A .env seeded before apps had a subnet: APPS_SUBNET comes from the
# environment, where the Makefile puts .env.example's value.
export APPS_SUBNET=10.6.0.0/24
run "${__scratch}/podman" "${podman_bin}"
unset APPS_SUBNET
check "checks apps against the subnet from the environment" 1 "ERROR: network proj_apps is on 10.89.0.0/24, but APPS_SUBNET in the environment (it is not in .env) asks for 10.6.0.0/24."
check "lists apps with the other networks to remove" 1 "podman network rm proj_apps proj_observability"

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

# READARR_SERVICES_IP, which qBittorrent lets in without a login. No network
# exists here (docker_bin still fails everything), so only the address is
# checked.
mkdir -p "${__scratch}/readarr"
readarr_env() {
  printf '%s\n' COMPOSE_PROJECT_NAME=other SERVICES_SUBNET=10.5.0.0/24 \
    SERVICES_DYNAMIC_IP_RANGE=10.5.0.128/25 GLUETUN_SERVICES_IP=10.5.0.10 \
    VPN_MOCK_IP=10.5.0.11 READARR_PROFILE=enabled "$@" >"${__scratch}/readarr/.env"
}

readarr_env READARR_SERVICES_IP=10.5.0.13
run "${__scratch}/readarr" "${docker_bin}"
if [[ "${__status}" -ne 0 || -s "${__scratch}/out" ]]; then
  echo "FAIL a free address inside the subnet: exit ${__status}" >&2
  cat "${__scratch}/out" >&2
  __failures=$((__failures + 1))
else
  echo "ok accepts a free fixed address inside the subnet"
fi

readarr_env READARR_SERVICES_IP=10.6.0.13
run "${__scratch}/readarr" "${docker_bin}"
check "refuses an address outside the subnet" 1 "ERROR: READARR_SERVICES_IP 10.6.0.13 is not an address inside SERVICES_SUBNET 10.5.0.0/24."
check "says what to set" 1 "Set READARR_SERVICES_IP in .env to a free address inside SERVICES_SUBNET, below SERVICES_DYNAMIC_IP_RANGE."

readarr_env READARR_SERVICES_IP=10.5.0.200
run "${__scratch}/readarr" "${docker_bin}"
check "refuses an address in the dynamic pool" 1 "ERROR: READARR_SERVICES_IP 10.5.0.200 is inside SERVICES_DYNAMIC_IP_RANGE 10.5.0.128/25, so another container can be handed it."

readarr_env READARR_SERVICES_IP=10.5.0.10
run "${__scratch}/readarr" "${docker_bin}"
check "refuses gluetun's address" 1 "ERROR: READARR_SERVICES_IP 10.5.0.10 is also GLUETUN_SERVICES_IP."

# Both from the environment, as the Makefile passes them for an older .env.
readarr_env
READARR_SERVICES_IP=10.5.0.12 NGINX_SERVICES_IP=10.5.0.12 run "${__scratch}/readarr" "${docker_bin}"
check "refuses nginx's address, both from the environment" 1 "ERROR: READARR_SERVICES_IP 10.5.0.12 is also NGINX_SERVICES_IP."

# Another fixed address set in the environment, as a make command line sets
# it, is the one compared, not .env's.
readarr_env READARR_SERVICES_IP=10.5.0.13 NGINX_SERVICES_IP=10.5.0.12
NGINX_SERVICES_IP=10.5.0.13 run "${__scratch}/readarr" "${docker_bin}"
check "compares with nginx's address from the environment over .env's" 1 "ERROR: READARR_SERVICES_IP 10.5.0.13 is also NGINX_SERVICES_IP."

for malformed in 10.5.0 10.5.0.13.1 10.5.0.256 10.5.0.x; do
  readarr_env "READARR_SERVICES_IP=${malformed}"
  run "${__scratch}/readarr" "${docker_bin}"
  check "refuses ${malformed}, which is no address" 1 "ERROR: READARR_SERVICES_IP ${malformed} is not an address inside SERVICES_SUBNET"
done

for subnet in 10.5.0/24 10.5.0.0/33 10.5.0.0; do
  readarr_env READARR_SERVICES_IP=10.5.0.13
  sed -i "s|^SERVICES_SUBNET=.*|SERVICES_SUBNET=${subnet}|" "${__scratch}/readarr/.env"
  run "${__scratch}/readarr" "${docker_bin}"
  check "refuses against ${subnet}, which is no subnet" 1 "ERROR: READARR_SERVICES_IP 10.5.0.13 is not an address inside SERVICES_SUBNET ${subnet}."
done

readarr_env READARR_SERVICES_IP=10.5.0.0
run "${__scratch}/readarr" "${docker_bin}"
check "refuses the network address" 1 "ERROR: READARR_SERVICES_IP 10.5.0.0 is the network or broadcast address of SERVICES_SUBNET 10.5.0.0/24."

readarr_env READARR_SERVICES_IP=10.5.0.127
sed -i "s|^SERVICES_SUBNET=.*|SERVICES_SUBNET=10.5.0.0/25|" "${__scratch}/readarr/.env"
run "${__scratch}/readarr" "${docker_bin}"
check "refuses the broadcast address" 1 "ERROR: READARR_SERVICES_IP 10.5.0.127 is the network or broadcast address of SERVICES_SUBNET 10.5.0.0/25."

# The environment comes first: make exports the address compose will use, a
# command line override included, so that is the one checked.
readarr_env READARR_SERVICES_IP=10.5.0.13
READARR_SERVICES_IP=10.6.0.13 run "${__scratch}/readarr" "${docker_bin}"
check "checks the address from the environment over .env's" 1 "ERROR: READARR_SERVICES_IP 10.6.0.13 is not an address inside SERVICES_SUBNET 10.5.0.0/24."

# So does the subnet, which make hands `network create` from its command line.
readarr_env READARR_SERVICES_IP=10.7.0.13
SERVICES_SUBNET=10.7.0.0/24 SERVICES_DYNAMIC_IP_RANGE=10.7.0.128/25 run "${__scratch}/readarr" "${docker_bin}"
if [[ "${__status}" -ne 0 ]]; then
  echo "FAIL the subnet from the environment was not the one checked: exit ${__status}" >&2
  cat "${__scratch}/out" >&2
  __failures=$((__failures + 1))
else
  echo "ok checks the address against the subnet from the environment"
fi
readarr_env READARR_SERVICES_IP=10.5.0.13
SERVICES_DYNAMIC_IP_RANGE=10.5.0.0/28 run "${__scratch}/readarr" "${docker_bin}"
check "and the dynamic range from the environment" 1 "ERROR: READARR_SERVICES_IP 10.5.0.13 is inside SERVICES_DYNAMIC_IP_RANGE 10.5.0.0/28"

# Readarr disabled: its address is not checked at all.
readarr_env READARR_SERVICES_IP=10.6.0.13
sed -i "s|^READARR_PROFILE=.*|READARR_PROFILE=disabled|" "${__scratch}/readarr/.env"
run "${__scratch}/readarr" "${docker_bin}"
if [[ "${__status}" -ne 0 || -s "${__scratch}/out" ]]; then
  echo "FAIL a disabled Readarr's address was checked: exit ${__status}" >&2
  cat "${__scratch}/out" >&2
  __failures=$((__failures + 1))
else
  echo "ok skips the address while Readarr is disabled"
fi
# The profile from the environment wins over .env's, as it does for compose.
READARR_PROFILE=enabled run "${__scratch}/readarr" "${docker_bin}"
check "checks the address when the environment enables Readarr" 1 "ERROR: READARR_SERVICES_IP 10.6.0.13 is not an address inside SERVICES_SUBNET 10.5.0.0/24."

# A /31 has no network or broadcast address to refuse.
readarr_env READARR_SERVICES_IP=10.5.0.12
sed -i "s|^SERVICES_SUBNET=.*|SERVICES_SUBNET=10.5.0.12/31|" "${__scratch}/readarr/.env"
run "${__scratch}/readarr" "${docker_bin}"
if [[ "${__status}" -ne 0 ]]; then
  echo "FAIL the low address of a /31: exit ${__status}" >&2
  cat "${__scratch}/out" >&2
  __failures=$((__failures + 1))
else
  echo "ok a /31 has no edge addresses"
fi

# A whole-range subnet holds every address.
readarr_env READARR_SERVICES_IP=10.5.0.13
sed -i "s|^SERVICES_SUBNET=.*|SERVICES_SUBNET=0.0.0.0/0|" "${__scratch}/readarr/.env"
run "${__scratch}/readarr" "${docker_bin}"
if [[ "${__status}" -ne 0 ]]; then
  echo "FAIL a /0 subnet holds the address: exit ${__status}" >&2
  cat "${__scratch}/out" >&2
  __failures=$((__failures + 1))
else
  echo "ok a /0 subnet holds every address"
fi

# A bad address and a mismatched network: both are named, then the network
# advice, and the run still fails.
podman_env="${__scratch}/podman/.env"
printf '%s\n' COMPOSE_PROJECT_NAME=proj SERVICES_SUBNET=10.1.0.0/24 OBSERVABILITY_SUBNET=10.3.0.0/24 \
  READARR_PROFILE=enabled READARR_SERVICES_IP=10.9.9.9 >"${podman_env}"
run "${__scratch}/podman" "${podman_bin}"
check "names a bad address alongside a bad network" 1 "ERROR: READARR_SERVICES_IP 10.9.9.9 is not an address inside SERVICES_SUBNET 10.1.0.0/24."
check "and still gives the network advice" 1 "podman network rm proj_observability"

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
