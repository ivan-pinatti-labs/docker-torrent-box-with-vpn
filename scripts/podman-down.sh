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

# An empty list from a podman that failed would read as a stack already gone,
# and make down would go on to forget which VPN routes it ran with.
if ! existing="$(containers --all)"; then
  echo "ERROR: podman could not list the containers of project ${PROJECT}." >&2
  exit 1
fi

if [[ -z "$existing" ]]; then
  echo "No stack containers found."
else
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

  # The first pass may fail on a container something still depends on; the
  # second one is the pass whose errors count.
  vpn="$(containers --all --filter "label=com.docker.compose.service=${VPN_SERVICE}")"
  containers --all | grep -vxF -f <(printf '%s\n' "$vpn") |
    xargs -r podman rm --force --time 0 >/dev/null 2>&1 || true
  containers --all | xargs -r podman rm --force --time 0 >/dev/null || true
fi

status=0
if ! left="$(containers --all)"; then
  echo "ERROR: podman could not list what is left of project ${PROJECT}." >&2
  status=1
elif [[ -n "$left" ]]; then
  echo "ERROR: these containers of project ${PROJECT} could not be removed:" >&2
  printf '  %s\n' $left >&2
  status=1
fi

# Even with no containers left, so a network an earlier run could not remove
# goes now. One that does not exist is not an error; one still in use is, and
# so is a podman that cannot tell (exists answers 1 for absent, 125 on error).
for network in "${NETWORKS[@]}"; do
  name="${PROJECT}_${network}"
  exists=0
  podman network exists "$name" || exists=$?
  [[ "$exists" -eq 1 ]] && continue
  if [[ "$exists" -ne 0 ]]; then
    echo "ERROR: podman could not tell whether network ${name} exists." >&2
    status=1
    continue
  fi
  if ! podman network rm "$name" >/dev/null; then
    echo "ERROR: could not remove network ${name}." >&2
    status=1
  fi
done
exit "$status"
