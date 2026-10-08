#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
set -euo pipefail

# Usage: ./scripts/check-network-subnets.sh
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

check apps APPS_SUBNET
check services SERVICES_SUBNET
check observability OBSERVABILITY_SUBNET
check media MEDIA_SUBNET

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
