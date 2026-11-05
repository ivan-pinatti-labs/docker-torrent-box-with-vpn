#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
set -eu

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
cd "$repo_root"

# A value from .env, read the way compose reads it, failing when it is unset
# or empty so the caller's default applies. Inside the log_rotator container
# there is no .env: the container's environment carries every value, and the
# reader is mounted beside this script.
# shellcheck source=scripts/lib/dotenv.sh
. "${script_dir}/lib/dotenv.sh"
env_value() { dotenv_get -n "$1" .env; }

LOGS_FOLDER="${LOGS_FOLDER:-$(env_value LOGS_FOLDER || printf './logs')}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-$(env_value LOG_RETENTION_DAYS || printf '30')}"
LOG_ARCHIVE_RETENTION_DAYS="${LOG_ARCHIVE_RETENTION_DAYS:-$(env_value LOG_ARCHIVE_RETENTION_DAYS || printf '90')}"
NGINX_LOG_DIR="${LOGS_FOLDER}/nginx"
timestamp="$(date +%Y%m%d%H%M%S)"

if [ ! -d "$NGINX_LOG_DIR" ]; then
  echo "No nginx log directory found at ${NGINX_LOG_DIR}."
  exit 0
fi

rotate_one() {
  log_file="$1"
  [ -s "$log_file" ] || return 0

  rotated="${log_file}-${timestamp}"
  cp -p "$log_file" "$rotated"
  : >"$log_file"
  echo "Rotated ${log_file}"
}

find "$NGINX_LOG_DIR" -type f -name '*.log' | while IFS= read -r log_file; do
  rotate_one "$log_file"
done

find "$NGINX_LOG_DIR" -type f -name '*.log-*' ! -name '*.gz' -mtime "+${LOG_RETENTION_DAYS}" -exec gzip -f {} \;
find "$NGINX_LOG_DIR" -type f -name '*.log-*.gz' -mtime "+${LOG_ARCHIVE_RETENTION_DAYS}" -exec rm -f {} \;

echo "Nginx log rotation complete. Plain retention: ${LOG_RETENTION_DAYS} days. Compressed archive retention: ${LOG_ARCHIVE_RETENTION_DAYS} days."
