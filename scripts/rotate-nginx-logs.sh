#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
set -eu

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
cd "$repo_root"

env_value() {
  key="$1"
  [ -f .env ] || return 1
  # One line on purpose: kcov reads each line of a multi line awk program as
  # a shell line that never ran. The program takes the first KEY= line,
  # drops the key and a leading and a trailing double or single quote.
  value="$(awk -v key="$key" 'index($0, key "=") == 1 { sub("^[^=]*=", ""); sub(/^"/, ""); sub(/"$/, ""); sub(/^'\''/, ""); sub(/'\''$/, ""); print; exit }' .env)"
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

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
