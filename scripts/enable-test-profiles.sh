#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
set -euo pipefail

# Usage: ./scripts/enable-test-profiles.sh
# Applies .env.tests' profile overrides onto .env, then seeds the local
# mock VPN endpoint if one is needed (scripts/seed-vpn-mock.sh decides
# that for itself). Called by tests/ci-suite.sh inside the nested test
# runner (every stack test target, `make bootstrap_tests` included), never by
# plain `make bootstrap` or `make start`. Never run this against a real
# deployment: it changes which profiles are enabled in .env, the same way
# bootstrap's own credential rotation permanently changes every password.

readonly ENV_FILE=".env"
readonly OVERRIDES_FILE=".env.tests"

[[ -f "$ENV_FILE" ]] || {
  echo "ERROR: ${ENV_FILE} does not exist. Run 'make bootstrap' at least" >&2
  echo "once first, or 'cp .env.example ${ENV_FILE}'." >&2
  exit 1
}

# Read through a descriptor opened here rather than `done <file`, a line kcov
# never sees run.
exec 3<"$OVERRIDES_FILE"
while IFS= read -r -u 3 line; do
  # Skip blank lines and comments, same idiom .env itself uses.
  [[ -z "$line" || "$line" == \#* ]] && continue
  key="${line%%=*}"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${line}|" "$ENV_FILE"
  else
    printf '%s\n' "$line" >>"$ENV_FILE"
  fi
  echo "[${ENV_FILE}] ${line}"
done
exec 3<&-

# UID and GID ship as 1000 in .env.example, which is right on a typical bench and
# wrong anywhere else. Three observability services mount the rootless podman
# socket from /run/user/${UID}/podman, so a value that is not the invoking user's
# makes that path not exist and podman refuses the container outright: "statfs
# /run/user/1000/podman/podman.sock: no such file or directory". Seen on a runner
# whose user is 1001, where cadvisor, podman_exporter and podman_limits_exporter
# all failed to be created and `make start` reported 3 of 36 services missing.
#
# Derived rather than asked for, because there is no case where a test run wants
# a UID other than the one invoking it.
for var_line in "UID=$(id -u)" "GID=$(id -g)"; do
  key="${var_line%%=*}"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${var_line}|" "$ENV_FILE"
  else
    printf '%s\n' "$var_line" >>"$ENV_FILE"
  fi
  echo "[${ENV_FILE}] ${var_line}"
done

# podman_exporter and podman_limits_exporter both set userns_mode, podman-compose
# puts every service in a pod, and podman refuses that combination before version
# 5 with "--userns and --pod cannot be set together". Disabled on those runtimes
# rather than left to fail, since a service that cannot be created is not a test
# result. Both are verified working on podman 5.8.4, so a bench keeps the
# coverage and `make bootstrap_tests` remains the release gate.
#
# Gated on the runtime rather than on a CI environment variable: the limitation
# belongs to podman's version, and anyone on a 4.x runtime hits it identically.
#
# `|| true` because under pipefail a host without podman (a Docker runtime)
# failed this assignment, and errexit ended the script before seed-vpn-mock.sh.
podman_major="$(podman version --format '{{.Client.Version}}' 2>/dev/null | cut -d. -f1 || true)"
if [[ -n "$podman_major" ]] && ((podman_major < 5)); then
  for key in PODMAN_EXPORTER_PROFILE PODMAN_LIMITS_EXPORTER_PROFILE; do
    sed -i "s|^${key}=.*|${key}=disabled|" "$ENV_FILE"
    echo "[${ENV_FILE}] ${key}=disabled (podman ${podman_major}.x cannot set --userns inside a pod)"
  done
fi

./scripts/seed-vpn-mock.sh
