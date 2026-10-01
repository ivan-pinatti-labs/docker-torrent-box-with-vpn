#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
set -euo pipefail

# Usage: ./scripts/detect-system-values.sh <env-file>
# Fills in UID, GID, TIMEZONE, and LAN_IP with values detected from the
# host, but only while they still match .env.example's own placeholder
# defaults (UID=1000, GID=1000, TIMEZONE=America/Toronto,
# LAN_IP=192.168.1.x). That makes it safe to call on every `make` invocation
# without ever touching a value the user has already customized.

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <env-file>" >&2
  exit 1
fi

readonly ENV_FILE="$1"
# Where the host's time zone is read from when timedatectl has no answer.
# Overridable only so the unit tests can point them at a scratch directory.
readonly TIMEZONE_FILE="${DETECT_TIMEZONE_FILE:-/etc/timezone}"
readonly LOCALTIME_LINK="${DETECT_LOCALTIME_LINK:-/etc/localtime}"

[[ -f "$ENV_FILE" ]] || exit 0

detected_uid="$(id -u)"
detected_gid="$(id -g)"
detected_timezone="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
if [[ -z "$detected_timezone" && -f "$TIMEZONE_FILE" ]]; then
  detected_timezone="$(cat "$TIMEZONE_FILE")"
fi
if [[ -z "$detected_timezone" && -L "$LOCALTIME_LINK" ]]; then
  detected_timezone="$(readlink "$LOCALTIME_LINK" | sed 's#.*/zoneinfo/##')"
fi
# `|| true` on both lookups: under pipefail a failing ip or hostname (no route,
# no network yet) fails the assignment, and errexit then ended the script
# before the hostname -I fallback or any of the other values were written.
detected_lan_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' || true)"
if [[ -z "$detected_lan_ip" ]]; then
  detected_lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
fi

if [[ "$detected_uid" != "1000" ]] && grep -qx "UID=1000" "$ENV_FILE"; then
  sed -i "s/^UID=1000\$/UID=${detected_uid}/" "$ENV_FILE"
  echo "[$ENV_FILE] Set UID=${detected_uid} (detected via 'id -u')."
fi

if [[ "$detected_gid" != "1000" ]] && grep -qx "GID=1000" "$ENV_FILE"; then
  sed -i "s/^GID=1000\$/GID=${detected_gid}/" "$ENV_FILE"
  echo "[$ENV_FILE] Set GID=${detected_gid} (detected via 'id -g')."
fi

if [[ -n "$detected_timezone" && "$detected_timezone" != "America/Toronto" ]] &&
  grep -qx "TIMEZONE=America/Toronto" "$ENV_FILE"; then
  sed -i "s#^TIMEZONE=America/Toronto\$#TIMEZONE=${detected_timezone}#" "$ENV_FILE"
  echo "[$ENV_FILE] Set TIMEZONE=${detected_timezone} (detected from the host)."
fi

if [[ -n "$detected_lan_ip" ]] && grep -qx "LAN_IP=192.168.1.x" "$ENV_FILE"; then
  sed -i "s/^LAN_IP=192.168.1.x\$/LAN_IP=${detected_lan_ip}/" "$ENV_FILE"
  echo "[$ENV_FILE] Set LAN_IP=${detected_lan_ip} (detected via 'ip route')."
fi
