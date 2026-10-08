#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
set -euo pipefail

# Usage: ./scripts/seed-vpn-mock.sh
# Brings up the local mock WireGuard endpoint (docker-compose-vpn.yml's
# vpn_mock service; see docs/VPN_MOCK.md) and points gluetun at it, but
# only when there's no real VPN key to protect: a real key already in
# place is never touched or overwritten. Only ever called from
# scripts/enable-test-profiles.sh (the nested test runner's suite), never
# from plain make bootstrap.

readonly ENV_FILE=".env"
readonly GLUETUN_SECRET="configs/gluetun/.secret" # pragma: allowlist secret
readonly GLUETUN_ENV="configs/gluetun/.env"
readonly PLACEHOLDER="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" # pragma: allowlist secret
readonly PEER_CONF="configs/vpn_mock/config/peer1/peer1.conf"

env_value() {
  grep -m1 "^$1=" "$ENV_FILE" | cut -d= -f2-
}

# The four shared networks are named ${COMPOSE_PROJECT_NAME}_<name>, so the
# ones seeded here have to carry the name compose will later look them up
# under, or `external: true` fails with "network not found".
#
# The precedence is .env, then an inherited value, then this checkout's own
# directory name, and it is in that order deliberately: it has to match the
# Makefile, which is what creates these same networks on every other path.
# The Makefile gets that order from `include .env`, since a makefile assignment
# beats the environment, so reading the environment first here would resolve to
# a different name than make did whenever a shell exports one value and .env
# carries another. The networks would then be created under one name while
# compose looked up the other.
#
# `|| true` is load bearing: env_value greps, grep exits 1 on no match, and
# under `set -euo pipefail` the failing substitution in an assignment takes the
# whole script with it. Most checkouts do not set this key at all, so the
# common case is exactly the one that would abort.
env_file_project_name="$(env_value COMPOSE_PROJECT_NAME || true)"
COMPOSE_PROJECT_NAME="${env_file_project_name:-${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}}"
unset env_file_project_name

# A real key alone isn't proof the job finished: this script also has to
# point gluetun's own config at the mock (VPN_SERVICE_PROVIDER=custom,
# below), and that step runs after the key is generated and saved. If a
# prior run died in between (confirmed live: an unrelated missing .env var
# made the later step fail), a rerun would see the already-saved key and
# skip everything, leaving gluetun permanently configured for its original
# real provider while holding mock key material, dialing real servers
# forever and never passing its own healthcheck. So both halves of the job
# have to check out before this counts as already done.
needs_setup() {
  [[ ! -s "$GLUETUN_SECRET" ]] && return 0
  grep -qx "$PLACEHOLDER" "$GLUETUN_SECRET" && return 0
  [[ ! -f "$GLUETUN_ENV" ]] && return 0
  ! grep -q "^VPN_SERVICE_PROVIDER=custom" "$GLUETUN_ENV"
}

if [[ "$(env_value VPN_MOCK_PROFILE)" != "enabled" ]]; then
  exit 0
fi

if ! needs_setup; then
  # The key is already seeded, so the peer handshake below is skipped. The
  # endpoint address is refreshed anyway, because it is the one value here that
  # comes from .env rather than from the mock's generated peer config, and it
  # moves whenever VPN_MOCK_IP does. Applying .env.tests to an already-seeded
  # clone does exactly that, and gating this on the key meant gluetun kept
  # dialling the previous address: it goes unhealthy with nothing in the log but
  # WireGuard's own "Connecting to <old ip>" and a later i/o timeout, and
  # `make start` fails on the health wait having said nothing about why.
  # Confirmed live, moving VPN_MOCK_IP from 172.28.0.11 to 172.25.0.11.
  #
  # Only this one line is rewritten. The keys are what the guard exists to
  # protect and they are left exactly as they are.
  echo "[vpn_mock] ${GLUETUN_SECRET} already has a real key; leaving it alone."
  if [[ -f "$GLUETUN_ENV" ]]; then
    vpn_mock_ip="$(env_value VPN_MOCK_IP || true)"
    # Empty means the variable is absent from .env, not that the endpoint should
    # be cleared: writing an empty value would leave gluetun with no endpoint at
    # all, which fails later and further away than saying so here.
    if [[ -z "$vpn_mock_ip" ]]; then
      echo "ERROR: VPN_MOCK_IP is not set in .env, so gluetun's endpoint" >&2
      echo "cannot be refreshed. Restore it from .env.example." >&2
      exit 1
    fi
    if grep -q "^WIREGUARD_ENDPOINT_IP=" "$GLUETUN_ENV"; then
      current="$(awk -F= '/^WIREGUARD_ENDPOINT_IP=/ {print $2; exit}' "$GLUETUN_ENV")"
      if [[ "$current" != "$vpn_mock_ip" ]]; then
        sed -i "s|^WIREGUARD_ENDPOINT_IP=.*|WIREGUARD_ENDPOINT_IP=${vpn_mock_ip}|" "$GLUETUN_ENV"
        echo "[${GLUETUN_ENV}] Endpoint moved from ${current} to ${vpn_mock_ip}."
      fi
    fi
  fi
  exit 0
fi

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

echo "[vpn_mock] No real VPN key found; starting the local mock WireGuard endpoint..."
# gluetun's own .env is normally seeded later, inside bootstrap's own
# recipe; this runs before that, so it must exist first (same ordering
# fix seed-gluetun-secret.sh already applies to itself, for the same
# reason: both edit it before bootstrap otherwise would).
./scripts/seed-configs.sh "$GLUETUN_ENV" >/dev/null

# docker-compose.yml's apps/services/media/observability networks are
# external (make start creates them itself, see its own network create
# calls): this runs before that, same ordering issue as above, so vpn_mock
# (which attaches to services) needs them pre-created too, confirmed live.
"$RUNTIME" network exists ${COMPOSE_PROJECT_NAME}_apps || "$RUNTIME" network create --subnet "$(env_value APPS_SUBNET)" --ip-range "$(env_value APPS_DYNAMIC_IP_RANGE)" ${COMPOSE_PROJECT_NAME}_apps
"$RUNTIME" network exists ${COMPOSE_PROJECT_NAME}_services || "$RUNTIME" network create --internal --subnet "$(env_value SERVICES_SUBNET)" --ip-range "$(env_value SERVICES_DYNAMIC_IP_RANGE)" ${COMPOSE_PROJECT_NAME}_services
"$RUNTIME" network exists ${COMPOSE_PROJECT_NAME}_media || "$RUNTIME" network create --subnet "$(env_value MEDIA_SUBNET)" --ip-range "$(env_value MEDIA_DYNAMIC_IP_RANGE)" ${COMPOSE_PROJECT_NAME}_media
"$RUNTIME" network exists ${COMPOSE_PROJECT_NAME}_observability || "$RUNTIME" network create --internal --subnet "$(env_value OBSERVABILITY_SUBNET)" ${COMPOSE_PROJECT_NAME}_observability

"${COMPOSE[@]}" --file docker-compose.yml --profile enabled up -d vpn_mock >/dev/null

echo "[vpn_mock] Waiting for peer keys to generate..."
elapsed=0
until [[ -s "$PEER_CONF" ]]; do
  sleep 2
  elapsed=$((elapsed + 2))
  if [[ $elapsed -ge 60 ]]; then
    echo "ERROR: ${PEER_CONF} was not generated after 60s." >&2
    echo "Check 'podman logs $(env_value CONTAINER_PREFIX)vpn_mock' for details." >&2
    exit 1
  fi
done

private_key=$(awk -F' = ' '/^PrivateKey/ {print $2; exit}' "$PEER_CONF")
address=$(awk -F' = ' '/^Address/ {print $2; exit}' "$PEER_CONF")
public_key=$(awk -F' = ' '/^PublicKey/ {print $2; exit}' "$PEER_CONF")
preshared_key=$(awk -F' = ' '/^PresharedKey/ {print $2; exit}' "$PEER_CONF")

if [[ -z "$private_key" || -z "$address" || -z "$public_key" || -z "$preshared_key" ]]; then
  echo "ERROR: Could not parse ${PEER_CONF}." >&2
  exit 1
fi

printf '%s' "$private_key" >"$GLUETUN_SECRET"
echo "[${GLUETUN_SECRET}] Saved the mock's peer private key."

vpn_mock_ip="$(env_value VPN_MOCK_IP)"
sed -i \
  -e "s|^VPN_SERVICE_PROVIDER=.*|VPN_SERVICE_PROVIDER=custom|" \
  -e "s|^VPN_TYPE=.*|VPN_TYPE=wireguard|" \
  -e "s|^VPN_PORT_FORWARDING=.*|VPN_PORT_FORWARDING=off|" \
  -e "s|^SERVER_COUNTRIES=.*|SERVER_COUNTRIES=|" \
  "$GLUETUN_ENV"

# SERVER_COUNTRIES is blanked, not removed, above: gluetun's "custom"
# provider has no server list to validate a country against and hard
# rejects the config outright if it's still set to protonvpn's default
# ("the country specified is not valid: one or more values is set but
# there is no possible value available"), confirmed live. Also using
# WIREGUARD_ENDPOINT_IP/_PORT here, not the generic VPN_ENDPOINT_IP/_PORT:
# gluetun accepts the latter only as a deprecated alias (it logs a WARN
# pointing at the same rename).
for var_line in \
  "WIREGUARD_ENDPOINT_IP=${vpn_mock_ip}" \
  "WIREGUARD_ENDPOINT_PORT=51820" \
  "WIREGUARD_PUBLIC_KEY=${public_key}" \
  "WIREGUARD_PRESHARED_KEY=${preshared_key}" \
  "WIREGUARD_ADDRESSES=${address}"; do
  key="${var_line%%=*}"
  if grep -q "^${key}=" "$GLUETUN_ENV"; then
    sed -i "s|^${key}=.*|${var_line}|" "$GLUETUN_ENV"
  else
    printf '%s\n' "$var_line" >>"$GLUETUN_ENV"
  fi
done

echo "[${GLUETUN_ENV}] Pointed gluetun at the local mock (custom WireGuard provider)."
