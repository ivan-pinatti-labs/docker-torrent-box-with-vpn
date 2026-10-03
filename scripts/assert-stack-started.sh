#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
set -uo pipefail

# Usage: ./scripts/assert-stack-started.sh --file a.yml --file b.yml ...
#
# Decides whether the stack came up by looking at what is running, rather than
# by trusting `compose up --detach` to return. Two separate problems make that
# necessary, and this is the one check that answers both.
#
# `podman-compose up --detach` intermittently never returns even though every
# container is created and running. CI bounded it at 420s and treated the
# interrupt as failure, so a stack that was demonstrably up reported a failed
# build: three consecutive runs across two unrelated branches stalled at
# "Starting all containers..." with 27, 33 and 33 containers already running.
# It became consistent rather than occasional when CI started applying
# .env.tests, which took the service count from 22 to 36.
#
# The opposite failure is just as quiet. podman-compose returns 0 even when
# every individual container fails to create, so `make start` could report
# success having created nothing at all: 33 "the container name is already in
# use" errors, an empty pod, exit code 0. Nothing downstream noticed either,
# because the readiness wait greps for containers reporting "starting" and an
# empty stack matches none, after which every test skips itself and the suite
# passes having tested nothing.
#
# Comparing the enabled service list against the services actually running
# replaces both a command's exit status and a grep for absence with the
# question that was meant all along.
#
# Services are matched through the compose project and service labels, not
# through container names, so this is unaffected by anything that renames a
# container.

readonly TIMEOUT="${STACK_START_TIMEOUT:-300}"
readonly INTERVAL=5

# Validated rather than trusted, because a non-numeric value fails quietly in
# the worst direction. This script runs under `set -uo pipefail` and
# deliberately not `set -e`, so the timeout comparison below, given a
# non-number, prints an error and returns non-zero, the bound never triggers,
# and the loop runs until `compose up` happens to exit. A typo in the variable
# would therefore remove the timeout instead of reporting itself. Zero stays
# valid: it means check once and report what is already running.
case "$TIMEOUT" in
'' | *[!0-9]*)
  echo "ERROR: STACK_START_TIMEOUT must be a whole number of seconds, got '${TIMEOUT}'." >&2
  exit 1
  ;;
esac

if command -v podman >/dev/null 2>&1; then
  RUNTIME=podman
  if command -v podman-compose >/dev/null 2>&1; then
    COMPOSE=(podman-compose)
  else
    COMPOSE=(podman compose)
  fi
else
  RUNTIME=docker
  COMPOSE=(docker compose)
fi

project="${COMPOSE_PROJECT_NAME:-}"
if [[ -z "$project" ]] && [[ -f .env ]]; then
  project="$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' .env | head -1 | tr -d '"')"
fi
[[ -n "$project" ]] || project="$(basename "$PWD")"

expected="$("${COMPOSE[@]}" "$@" --profile enabled config --services 2>/dev/null | sort -u)"
if [[ -z "$expected" ]]; then
  echo "ERROR: could not determine which services should be running." >&2
  echo "'${COMPOSE[*]} ... --profile enabled config --services' returned nothing," >&2
  echo "so there is no list to check the stack against. Refusing to report success." >&2
  exit 1
fi
expected_count="$(printf '%s\n' "$expected" | wc -l)"

running_services() {
  "$RUNTIME" ps --filter "label=com.docker.compose.project=${project}" \
    --format '{{index .Labels "com.docker.compose.service"}}' 2>/dev/null |
    grep -v '^$' | sort -u
}

# COMPOSE_UP_PID, when the caller passes one, is a `compose up` still running in
# the background. Polling alongside it rather than after it is what keeps the
# known hang from costing the full bound on every start: the loop stops the
# moment every service is up, whether or not the command has returned.
#
# It also gives a fast exit on a genuine failure. Once that process is gone,
# nothing more is going to appear, so one further poll settles it instead of
# waiting out the timeout for containers that are never coming.
up_pid="${COMPOSE_UP_PID:-}"
elapsed=0
grace=0
while :; do
  missing="$(comm -23 <(printf '%s\n' "$expected") <(running_services))"
  [[ -z "$missing" ]] && break
  if [[ -n "$up_pid" ]] && ! kill -0 "$up_pid" 2>/dev/null; then
    [[ "$grace" -ge 1 ]] && break
    grace=$((grace + 1))
  fi
  # 10# because [[ ]] reads its operands as arithmetic, where a leading zero
  # means octal: 012 would be ten seconds rather than the twelve it means.
  [[ "$elapsed" -ge "10#$TIMEOUT" ]] && break
  sleep "$INTERVAL"
  elapsed=$((elapsed + INTERVAL))
done

if [[ -n "$missing" ]]; then
  echo "ERROR: $(printf '%s\n' "$missing" | wc -l) of ${expected_count} enabled services are not running after ${elapsed}s:" >&2
  printf '  %s\n' $missing >&2
  echo >&2
  echo "Their absence is the failure, whatever 'compose up' reported. Check" >&2
  echo "'$RUNTIME logs <name>' for one of them, and '$RUNTIME ps --all' for" >&2
  echo "containers that were created and then exited." >&2
  exit 1
fi

echo "All ${expected_count} enabled services are running."
