#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

env_value() {
  local key="$1"
  local value
  [[ -f .env ]] || return 1
  value="$(
    awk -v key="$key" '
      index($0, key "=") == 1 {
        sub("^[^=]*=", "")
        sub(/^"/, "")
        sub(/"$/, "")
        sub(/^'\''/, "")
        sub(/'\''$/, "")
        print
        exit
      }
    ' .env
  )"
  [[ -n "$value" ]] || return 1
  printf '%s' "$value"
}

CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-$(env_value CONTAINER_RUNTIME || printf 'podman')}"
CACHE_FOLDER="${CACHE_FOLDER:-$(env_value CACHE_FOLDER || printf './cache')}"
NGINX_CACHE_DIR="${CACHE_FOLDER}/nginx"

if ! command -v "$CONTAINER_RUNTIME" >/dev/null 2>&1; then
  echo "Container runtime '${CONTAINER_RUNTIME}' was not found."
  exit 1
fi

if [[ ! -d "$NGINX_CACHE_DIR" ]]; then
  echo "No nginx cache directory found at ${NGINX_CACHE_DIR}."
  exit 0
fi

nginx_was_running=false
if "$CONTAINER_RUNTIME" ps --format '{{.Names}}' 2>/dev/null | grep -qx nginx; then
  nginx_was_running=true
fi

cat <<EOF
This will prune the nginx proxy cache at:
  ${NGINX_CACHE_DIR}

The command will:
  1. stop the nginx container if it is running
  2. delete cached nginx proxy files
  3. start nginx again if it was running before

It will not delete torrent, usenet, media, config, or observability data.
EOF

printf 'Continue? [y/N] '
read -r answer
# `:` rather than an empty branch, which kcov counts as a line that never runs.
case "$answer" in
y | Y | yes | YES) : ;;
*)
  echo "Aborted."
  exit 0
  ;;
esac

if [[ "$nginx_was_running" = true ]]; then
  echo "Stopping nginx..."
  "$CONTAINER_RUNTIME" stop nginx
fi

find "$NGINX_CACHE_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
mkdir -p "$NGINX_CACHE_DIR"
echo "Pruned nginx cache under ${NGINX_CACHE_DIR}."

if [[ "$nginx_was_running" = true ]]; then
  echo "Starting nginx..."
  "$CONTAINER_RUNTIME" start nginx
fi
