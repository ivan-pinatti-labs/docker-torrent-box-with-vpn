#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
set -euo pipefail

# Usage: ./scripts/seed-nginx-ports.sh
# Prompts once during bootstrap to use the standard ports 80/443 instead of
# this project's rootless-safe defaults (8080/8443). Rootless Podman/Docker
# run as the invoking user rather than root, and the kernel blocks
# unprivileged binds below net.ipv4.ip_unprivileged_port_start (1024 by
# default), so 80/443 need that boundary lowered first; this offers to do
# it here with sudo instead of pointing at README instructions to run by
# hand later. Skips entirely, keeping the rootless-safe defaults, once
# .env's ports no longer match the placeholder defaults (already
# customized) or when not running interactively.

readonly ENV_FILE=".env"
readonly DEFAULT_HTTP_PORT="8080"
readonly DEFAULT_HTTPS_PORT="8443"
# Overridable only so the unit tests can stand in for the kernel's value.
readonly PORT_START_FILE="${UNPRIVILEGED_PORT_START_FILE:-/proc/sys/net/ipv4/ip_unprivileged_port_start}"

[[ -f "$ENV_FILE" ]] || exit 0

if ! grep -qx "NGINX_HTTP_PORT=${DEFAULT_HTTP_PORT}" "$ENV_FILE" ||
  ! grep -qx "NGINX_HTTPS_PORT=${DEFAULT_HTTPS_PORT}" "$ENV_FILE"; then
  exit 0
fi

[[ -t 0 ]] || exit 0

echo ""
echo "Nginx defaults to ports 8080/8443, since rootless Podman/Docker cannot"
echo "bind ports below 1024 without help from the kernel (see README.md's"
echo "rootless-ports note). Switch to the standard 80/443 instead? This"
echo "needs sudo once, to raise the kernel's unprivileged port boundary."
read -r -p "Use standard ports 80/443? [y/N]: " choice

# The `:` gives the yes branch a command, so kcov sees it run.
case "$choice" in
y | Y | yes | Yes | YES) : ;;
*)
  echo "Keeping the rootless-safe defaults (8080/8443)."
  exit 0
  ;;
esac

boundary="$(cat "$PORT_START_FILE" 2>/dev/null || echo 1024)"
if [[ "$boundary" -gt 80 ]]; then
  echo "Lowering the kernel's unprivileged port boundary (needs sudo)..."
  if ! sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80; then
    echo "WARNING: Could not lower the port boundary; keeping 8080/8443." >&2
    exit 0
  fi
  echo "This only lasts until the next reboot. To make it permanent, add"
  echo "'net.ipv4.ip_unprivileged_port_start=80' to /etc/sysctl.conf (see"
  echo "README.md's rootless-ports note for the exact line)."
  read -r -p "Press Enter once you've read that: " _
else
  # Already lowered (e.g. a previous bootstrap run on this same host already
  # did it, and it hasn't rebooted since), so there's nothing for sudo to do
  # this time. Say so explicitly instead of silently skipping straight to
  # the .env update, which otherwise looks like the sudo/disclaimer step
  # never ran at all.
  echo "The kernel's unprivileged port boundary is already ${boundary} (<=80),"
  echo "so no sudo is needed this time."
fi

sed -i "s/^NGINX_HTTP_PORT=${DEFAULT_HTTP_PORT}\$/NGINX_HTTP_PORT=80/" "$ENV_FILE"
sed -i "s/^NGINX_HTTPS_PORT=${DEFAULT_HTTPS_PORT}\$/NGINX_HTTPS_PORT=443/" "$ENV_FILE"
echo "[$ENV_FILE] Set NGINX_HTTP_PORT=80 and NGINX_HTTPS_PORT=443."
