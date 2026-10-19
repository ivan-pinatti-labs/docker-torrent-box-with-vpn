#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
set -uo pipefail

# Usage: COMPOSE_PROJECT_NAME=<project> ./scripts/podman-down.sh
#
# `make down` on podman: stops and removes every container of the compose
# project, then the project's networks.
#
# Containers are found by the compose project label, so this removes what
# exists rather than what the current .env would create. That matters when
# CONTAINER_PREFIX changed while the stack's containers still existed: they
# carry the old prefix, and matching them by name would miss them.
#
# The VPN container goes last, because the containers routed through it share
# its network namespace (`network_mode: container:...`) and podman refuses to
# remove it while they exist. It is picked out by its compose service label,
# not by its name, for the same reason. Anything the first pass leaves behind
# is removed in the second, so a container the labels did not account for
# cannot keep a network attached and make its removal fail.

readonly PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}"
readonly TIMEOUT="${PODMAN_DOWN_TIMEOUT:-60}"
readonly VPN_SERVICE=gluetun
readonly NETWORKS=(edge wan apps services media observability)
readonly PROJECT_FILTER="label=com.docker.compose.project=${PROJECT}"

case "$TIMEOUT" in
'' | *[!0-9]*)
  echo "ERROR: PODMAN_DOWN_TIMEOUT must be a whole number of seconds, got '${TIMEOUT}'." >&2
  exit 1
  ;;
esac

# The project's containers, one name per line. Arguments are extra podman ps
# options: --all for stopped ones too, another --filter to narrow it.
containers() {
  podman ps --filter "$PROJECT_FILTER" --format '{{.Names}}' "$@"
}

remove() {
  xargs -r podman rm --force --time 0 >/dev/null || true
}

if [[ -z "$(containers --all)" ]]; then
  echo "No stack containers found."
  exit 0
fi

running="$(containers)"
if [[ -n "$running" ]]; then
  echo "$running" | xargs -r podman kill --signal TERM >/dev/null || true
  elapsed=0
  while [[ "$elapsed" -lt "10#$TIMEOUT" ]] && [[ -n "$(containers)" ]]; do
    sleep 1
    elapsed=$((elapsed + 1))
  done
  remaining="$(containers)"
  if [[ -n "$remaining" ]]; then
    echo "Force-killing containers still running after ${TIMEOUT}s..."
    echo "$remaining" | xargs -r podman kill >/dev/null || true
  fi
fi

vpn="$(containers --all --filter "label=com.docker.compose.service=${VPN_SERVICE}")"
containers --all | grep -vxF -f <(printf '%s\n' "$vpn") | remove
containers --all | remove

for network in "${NETWORKS[@]}"; do
  podman network rm "${PROJECT}_${network}" >/dev/null 2>&1 || true
done
