#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
set -euo pipefail

# Usage: ./scripts/check-network-subnets.sh
#
# Also refuses a READARR_SERVICES_IP that another container could hold; see
# check_readarr_address below.
#
# Refuses to start when a network already exists on a different subnet than .env
# now asks for. `make start`'s own "ensure required networks exist" step is
# `network exists X || network create --subnet ...`, so an existing network is
# reused whatever subnet it carries, and a podman network outlives the stack it
# belongs to: stopping does not remove it. Change SERVICES_SUBNET and the network
# keeps the old range, while the compose files hand containers an
# `ipv4_address:` from the new one. The container then fails to attach, or
# attaches somewhere nothing can reach it, and neither message mentions the
# subnet.
#
# Removing the network automatically is deliberately not what happens here. It
# would disconnect whatever else is attached, including another checkout's
# running stack, which is precisely the situation these variables exist to keep
# apart. Naming the mismatch and stopping is the useful behavior.

readonly ENV_FILE=".env"

[[ -f "$ENV_FILE" ]] || exit 0

if command -v podman >/dev/null 2>&1; then
  RUNTIME=podman
else
  RUNTIME=docker
fi

# podman and docker disagree on both of these. `network exists` is podman only,
# and the inspect format differs: podman puts subnets in `.Subnets`, docker in
# `.IPAM.Config`. Handing docker the podman template does not return empty, it
# raises "map has no entry for key \"Subnets\"", which a swallowed error would
# turn into an empty answer and a guard that passes whatever the subnet is.
# Confirmed against docker 29.0.4 and podman 5.8.4. Both shapes are tried rather
# than branching on the runtime name, so this keeps working if either changes
# which one it reports.
network_exists() {
  if [[ "$RUNTIME" == "podman" ]]; then
    podman network exists "$1" 2>/dev/null
  else
    docker network inspect "$1" >/dev/null 2>&1
  fi
}

network_subnet() {
  local out
  for template in '{{range .Subnets}}{{.Subnet}}{{end}}' '{{range .IPAM.Config}}{{.Subnet}}{{end}}'; do
    out="$("$RUNTIME" network inspect "$1" --format "$template" 2>/dev/null || true)"
    if [[ -n "$out" ]]; then
      printf '%s' "$out"
      return 0
    fi
  done
}

env_value() {
  grep -m1 "^${1}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' || true
}

project="$(env_value COMPOSE_PROJECT_NAME)"
[[ -n "$project" ]] || project="$(basename "$PWD")"

problems=()
address_problem=0

# A setting from .env, else from the environment, where the Makefile puts
# .env.example's value for one an older .env lacks.
setting() {
  local value
  value="$(env_value "$1")"
  [[ -n "$value" ]] || value="${!1:-}"
  printf '%s' "$value"
}

# An IPv4 address as a number, failing for anything that is not one.
ipv4_number() {
  local a b c d extra octet
  IFS=. read -r a b c d extra <<<"$1"
  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ && "$octet" -le 255 ]] || return 1
  done
  [[ -z "$extra" ]] || return 1
  printf '%s' "$(((10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d))"
}

# in_subnet <address> <subnet>: whether an IPv4 address is inside a CIDR
# subnet. Fails, as not inside, when either is malformed.
in_subnet() {
  local address network bits mask
  address="$(ipv4_number "$1")" || return 1
  network="$(ipv4_number "${2%/*}")" || return 1
  bits="${2#*/}"
  [[ "$bits" =~ ^[0-9]{1,2}$ && "$bits" -le 32 ]] || return 1
  mask=$(((0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF))
  (((address & mask) == (network & mask)))
}

# subnet_edge <address> <subnet>: whether the address is the subnet's network
# or broadcast address, which no container can hold. A /31 or /32 has neither.
# Expects both to be valid, as in_subnet has already checked.
subnet_edge() {
  local address network bits mask
  address="$(ipv4_number "$1")"
  network="$(ipv4_number "${2%/*}")"
  bits="${2#*/}"
  ((bits <= 30)) || return 1
  mask=$(((0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF))
  ((address == (network & mask) || address == ((network & mask) | (~mask & 0xFFFFFFFF))))
}

# The four that declare a subnet. wan and edge are created without one, so
# podman picks a free range and there is nothing to disagree about.
#
# apps joined them later, so most existing deployments have an apps network
# podman numbered itself, and a .env seeded before then has no APPS_SUBNET.
# The Makefile fills that in from .env.example and exports it, which is why a
# variable missing from .env falls back to the environment: otherwise the
# check would skip exactly the network it now has to catch.
check() {
  local suffix="$1" var="$2"
  local name="${project}_${suffix}"
  local want source="${ENV_FILE}" actual
  want="$(env_value "$var")"
  if [[ -z "$want" ]]; then
    want="${!var:-}"
    source="the environment (it is not in ${ENV_FILE})"
  fi
  [[ -n "$want" ]] || return 0
  network_exists "$name" || return 0
  actual="$(network_subnet "$name")"
  if [[ -z "$actual" ]]; then
    # Neither shape answered for a network that exists. Warn rather than fail:
    # the point of this script is to stop a container attaching silently to the
    # wrong network, and turning an unreadable inspect into a hard stop would
    # trade that for a different way of refusing to start. Saying so is enough
    # for someone to look.
    echo "WARNING: could not read ${name}'s subnet, so it was not checked against ${var}." >&2
    return 0
  fi
  if [[ "$actual" != "$want" ]]; then
    echo "ERROR: network ${name} is on ${actual}, but ${var} in ${source} asks for ${want}." >&2
    problems+=("$name")
  fi
}

# qBittorrent lets READARR_SERVICES_IP in without a login (wire-connections.sh
# sets that up), so the address has to be Readarr's alone. Outside
# SERVICES_SUBNET Readarr cannot attach at all. Inside the dynamic pool, or on
# another fixed address, a different container can hold it, and would skip
# qBittorrent's login in Readarr's place.
#
# Skipped while Readarr is disabled, so an older .env that never set the
# address cannot stop the rest of the stack over .env.example's. The address
# comes from the environment before .env: the Makefile exports the one compose
# will hand Readarr, a command line override included.
check_readarr_address() {
  local want subnet pool other
  [[ "$(setting READARR_PROFILE)" == enabled ]] || return 0
  want="${READARR_SERVICES_IP-$(env_value READARR_SERVICES_IP)}"
  [[ -n "$want" ]] || return 0
  subnet="$(setting SERVICES_SUBNET)"
  if [[ -n "$subnet" ]] && ! in_subnet "$want" "$subnet"; then
    echo "ERROR: READARR_SERVICES_IP ${want} is not an address inside SERVICES_SUBNET ${subnet}." >&2
    address_problem=1
  elif [[ -n "$subnet" ]] && subnet_edge "$want" "$subnet"; then
    echo "ERROR: READARR_SERVICES_IP ${want} is the network or broadcast address of SERVICES_SUBNET ${subnet}." >&2
    address_problem=1
  fi
  pool="$(setting SERVICES_DYNAMIC_IP_RANGE)"
  if [[ -n "$pool" ]] && in_subnet "$want" "$pool"; then
    echo "ERROR: READARR_SERVICES_IP ${want} is inside SERVICES_DYNAMIC_IP_RANGE ${pool}, so another container can be handed it." >&2
    address_problem=1
  fi
  for other in GLUETUN_SERVICES_IP NGINX_SERVICES_IP VPN_MOCK_IP; do
    if [[ "$want" == "$(setting "$other")" ]]; then
      echo "ERROR: READARR_SERVICES_IP ${want} is also ${other}." >&2
      address_problem=1
    fi
  done
}

check apps APPS_SUBNET
check services SERVICES_SUBNET
check observability OBSERVABILITY_SUBNET
check media MEDIA_SUBNET
check_readarr_address

if [[ "$address_problem" -eq 1 ]]; then
  echo "Set READARR_SERVICES_IP in .env to a free address inside SERVICES_SUBNET, below SERVICES_DYNAMIC_IP_RANGE." >&2
fi

if [[ "${#problems[@]}" -gt 0 ]]; then
  cat >&2 <<EOF

Containers would be given an ipv4_address outside the network they attach to.
Remove this stack's containers, then the networks above, so they are recreated
on the subnets now declared:

  make down
  ${RUNTIME} network rm ${problems[*]}

Under podman \`make down\` already removes the networks, so the second line is
only needed for any it left behind. A stopped container still holds its
network, which is why \`make stop_all\` alone is not enough. Check nothing else is attached first: another checkout sharing these subnets is
why they are worth changing in the first place.
EOF
  exit 1
fi

[[ "$address_problem" -eq 0 ]] || exit 1
