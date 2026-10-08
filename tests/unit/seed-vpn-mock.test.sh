#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for scripts/seed-vpn-mock.sh. Every line of the script has to run in
# one of them: `make coverage` runs this file under kcov and fails below 100%.
#
# The script works on paths relative to where it runs, so each case runs in a
# scratch directory with its own .env, gluetun config and a stub
# scripts/seed-configs.sh. podman, podman-compose, docker and sleep are stubs
# that only record their calls; `compose up` (or, when `slow` is set, the
# first sleep) writes the mock's peer config from `peer`, the way the real
# vpn_mock container would. PATH holds nothing else but the text tools the
# script needs, so no network or container is ever created.

set -o errexit
set -o pipefail
set -o nounset

__script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/seed-vpn-mock.sh"
__bash="$(command -v bash)"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0
__work="${__scratch}/work"
__peer="configs/vpn_mock/config/peer1/peer1.conf"
__real_key="cmVhbGtleXJlYWxrZXlyZWFsa2V5cmVhbGtleXJlYWw="    # pragma: allowlist secret gitleaks:allow
__placeholder="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" # pragma: allowlist secret

stub() {
  local dir="${1}" name="${2}" body="${3}"
  printf '#!%s\n%s\n' "${__bash}" "${body}" >"${dir}/${name}"
  chmod +x "${dir}/${name}"
}

# Writes the peer config into the work directory, unless it is already there.
write_peer="mkdir -p '${__work}/$(dirname "${__peer}")'; [[ -s '${__work}/${__peer}' ]] || cp '${__scratch}/peer' '${__work}/${__peer}'"

fresh_bin() {
  local bin="${__scratch}/bin"
  rm -rf "${bin}"
  mkdir -p "${bin}"
  for tool in grep cut basename awk sed cat cp mkdir; do
    ln -s "$(command -v "${tool}")" "${bin}/${tool}"
  done
  for name in "$@"; do
    stub "${bin}" "${name}" "echo \"${name} \$*\" >>'${__scratch}/log'
[[ \"\$*\" == *' up '* && ! -f '${__scratch}/slow' ]] && { ${write_peer}; }
[[ \"\$*\" != *'network exists'* ]]"
  done
  stub "${bin}" sleep "echo \"sleep \$*\" >>'${__scratch}/log'
[[ -f '${__scratch}/slow' && -f '${__scratch}/peer' ]] && { ${write_peer}; }
true"
  echo "${bin}"
}

# A scratch checkout with the mock profile on and the gluetun config the
# real seed-configs.sh would have produced from configs/gluetun/.env.example.
fresh_work() {
  rm -rf "${__work}" "${__scratch}/log" "${__scratch}/slow"
  mkdir -p "${__work}/scripts" "${__work}/configs/gluetun"
  printf '%s\n' VPN_MOCK_PROFILE=enabled VPN_MOCK_IP=172.25.0.11 CONTAINER_PREFIX=dev_ \
    SERVICES_SUBNET=172.25.0.0/24 SERVICES_DYNAMIC_IP_RANGE=172.25.0.128/25 \
    MEDIA_SUBNET=172.26.0.0/24 MEDIA_DYNAMIC_IP_RANGE=172.26.0.128/25 \
    OBSERVABILITY_SUBNET=172.27.0.0/24 \
    APPS_SUBNET=172.24.0.0/24 APPS_DYNAMIC_IP_RANGE=172.24.0.128/25 >"${__work}/.env"
  stub "${__work}/scripts" seed-configs.sh "echo \"seed-configs \$*\" >>'${__scratch}/log'
printf '%s\n' VPN_SERVICE_PROVIDER=protonvpn VPN_TYPE=openvpn VPN_PORT_FORWARDING=on SERVER_COUNTRIES=Netherlands WIREGUARD_ENDPOINT_PORT=1 >\"\${1}\""
  printf '%s\n' '[Interface]' 'Address = 10.13.13.2' 'PrivateKey = private-key' \
    '[Peer]' 'PublicKey = public-key' 'PresharedKey = preshared-key' >"${__scratch}/peer"
}

run() {
  touch "${__scratch}/log"
  __status=0
  (cd "${__work}" && PATH="${1}" "${__bash}" "${__script}") \
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

refute() {
  local name="${1}" file="${2}" unwanted="${3}"
  if grep --quiet --fixed-strings -- "${unwanted}" "${__scratch}/${file}"; then
    echo "FAIL ${name}: '${unwanted}' in ${file}" >&2
    __failures=$((__failures + 1))
  else
    echo "ok ${name}"
  fi
}

gluetun_env=work/configs/gluetun/.env

bin="$(fresh_bin podman podman-compose)"
fresh_work
sed -i 's/^VPN_MOCK_PROFILE=.*/VPN_MOCK_PROFILE=disabled/' "${__work}/.env"
run "${bin}"
if [[ "${__status}" -ne 0 || -s "${__scratch}/out" ]]; then
  echo "FAIL does nothing with the mock profile off: exit ${__status}" >&2
  __failures=$((__failures + 1))
fi
refute "starts nothing with the mock profile off" log "podman"

fresh_work
echo COMPOSE_PROJECT_NAME=from-env >>"${__work}/.env"
COMPOSE_PROJECT_NAME=inherited run "${bin}"
check "seeds gluetun's .env first" 0 log "seed-configs configs/gluetun/.env"
check ".env's project name wins" 0 log "podman network create --subnet 172.24.0.0/24 --ip-range 172.24.0.128/25 from-env_apps"
check "creates the services network" 0 log "podman network create --internal --subnet 172.25.0.0/24 --ip-range 172.25.0.128/25 from-env_services"
check "creates the media network" 0 log "podman network create --subnet 172.26.0.0/24 --ip-range 172.26.0.128/25 from-env_media"
check "creates the observability network" 0 log "podman network create --internal --subnet 172.27.0.0/24 from-env_observability"
check "starts vpn_mock with podman-compose" 0 log "podman-compose --file docker-compose.yml --profile enabled up -d vpn_mock"
check "saves the peer's private key" 0 work/configs/gluetun/.secret "private-key"
check "switches gluetun to the custom provider" 0 "${gluetun_env}" "VPN_SERVICE_PROVIDER=custom"
check "uses WireGuard" 0 "${gluetun_env}" "VPN_TYPE=wireguard"
check "turns port forwarding off" 0 "${gluetun_env}" "VPN_PORT_FORWARDING=off"
check "blanks the server country" 0 "${gluetun_env}" "SERVER_COUNTRIES="
check "replaces an existing endpoint port" 0 "${gluetun_env}" "WIREGUARD_ENDPOINT_PORT=51820"
check "appends the endpoint address" 0 "${gluetun_env}" "WIREGUARD_ENDPOINT_IP=172.25.0.11"
check "appends the public key" 0 "${gluetun_env}" "WIREGUARD_PUBLIC_KEY=public-key" # pragma: allowlist secret
check "appends the preshared key" 0 "${gluetun_env}" "WIREGUARD_PRESHARED_KEY=preshared-key"
check "appends the address" 0 "${gluetun_env}" "WIREGUARD_ADDRESSES=10.13.13.2"
check "reports it" 0 out "Pointed gluetun at the local mock"

bin="$(fresh_bin podman)"
fresh_work
echo "${__placeholder}" >"${__work}/configs/gluetun/.secret"
touch "${__scratch}/slow"
COMPOSE_PROJECT_NAME=inherited run "${bin}"
check "replaces the placeholder key" 0 work/configs/gluetun/.secret "private-key"
check "uses podman compose without podman-compose" 0 log "podman compose --file docker-compose.yml"
check "an inherited project name beats the directory" 0 log "inherited_apps"
check "waits for the peer config" 0 log "sleep 2"

bin="$(fresh_bin docker)"
fresh_work
printf '%s' "${__real_key}" >"${__work}/configs/gluetun/.secret"
touch "${__scratch}/slow"
rm "${__scratch}/peer"
run "${bin}"
check "redoes a run that never reached gluetun's .env" 1 log "docker compose --file docker-compose.yml"
check "falls back to the directory name" 1 log "docker network create --subnet 172.24.0.0/24 --ip-range 172.24.0.128/25 work_apps"
check "gives up when the peer config never appears" 1 err "was not generated after 60s"
check "points at the container's logs" 1 err "podman logs dev_vpn_mock"

fresh_work
printf '%s\n' '[Interface]' 'Address = 10.13.13.2' >"${__scratch}/peer"
run "${bin}"
check "refuses a peer config it cannot parse" 1 err "Could not parse configs/vpn_mock/config/peer1/peer1.conf"

# Already seeded: a real key and gluetun on the custom provider.
seeded() {
  fresh_work
  printf '%s' "${__real_key}" >"${__work}/configs/gluetun/.secret"
  printf '%s\n' VPN_SERVICE_PROVIDER=custom "WIREGUARD_ENDPOINT_IP=${1}" >"${__work}/configs/gluetun/.env"
}

seeded 172.28.0.11
run "${bin}"
check "leaves a real key alone" 0 out "already has a real key; leaving it alone."
check "moves the endpoint to the current VPN_MOCK_IP" 0 "${gluetun_env}" "WIREGUARD_ENDPOINT_IP=172.25.0.11"
check "says where it moved from" 0 out "Endpoint moved from 172.28.0.11 to 172.25.0.11."
check "keeps the real key" 0 work/configs/gluetun/.secret "${__real_key}"
refute "starts nothing once seeded" log "docker"

seeded 172.25.0.11
run "${bin}"
refute "leaves an endpoint that is already right" out "Endpoint moved"

seeded 172.25.0.11
sed -i '/^WIREGUARD_ENDPOINT_IP=/d' "${__work}/configs/gluetun/.env"
run "${bin}"
refute "adds no endpoint where there was none" "${gluetun_env}" "WIREGUARD_ENDPOINT_IP"

seeded 172.25.0.11
sed -i '/^VPN_MOCK_IP=/d' "${__work}/.env"
run "${bin}"
check "refuses to clear the endpoint when VPN_MOCK_IP is missing" 1 err "VPN_MOCK_IP is not set in .env"

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
