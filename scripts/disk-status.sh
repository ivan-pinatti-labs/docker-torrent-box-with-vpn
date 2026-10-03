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

DATA_FOLDER="${DATA_FOLDER:-$(env_value DATA_FOLDER || printf './data')}"
TORRENTS_FOLDER="${TORRENTS_FOLDER:-$(env_value TORRENTS_FOLDER || printf '%s/torrents' "$DATA_FOLDER")}"
USENET_FOLDER="${USENET_FOLDER:-$(env_value USENET_FOLDER || printf '%s/usenet' "$DATA_FOLDER")}"
TORRENTS_FOLDER="${TORRENTS_FOLDER//\$\{DATA_FOLDER\}/$DATA_FOLDER}"
USENET_FOLDER="${USENET_FOLDER//\$\{DATA_FOLDER\}/$DATA_FOLDER}"
LOGS_FOLDER="${LOGS_FOLDER:-$(env_value LOGS_FOLDER || printf './logs')}"
CACHE_FOLDER="${CACHE_FOLDER:-$(env_value CACHE_FOLDER || printf './cache')}"
STORAGE_FOLDER="${STORAGE_FOLDER:-$(env_value STORAGE_FOLDER || printf './storage')}"
DOWNLOADS_WARN_GB="${DOWNLOADS_WARN_GB:-$(env_value DOWNLOADS_WARN_GB || printf '500')}"
DOWNLOADS_CRIT_GB="${DOWNLOADS_CRIT_GB:-$(env_value DOWNLOADS_CRIT_GB || printf '750')}"

# Validated rather than trusted. The threshold tests below cannot compare a
# value that is not a whole number, and with `[ ]` such a value read as false,
# so a typo in either one fell through to the OK line whatever the downloads
# weighed.
for threshold in DOWNLOADS_WARN_GB DOWNLOADS_CRIT_GB; do
  case "${!threshold}" in
  '' | *[!0-9]*)
    echo "ERROR: ${threshold} must be a whole number of gigabytes, got '${!threshold}'." >&2
    exit 1
    ;;
  esac
done

bytes_for() {
  local path="$1"
  local output
  if [[ ! -e "$path" ]]; then
    printf '0'
    return
  fi
  output="$(du -sb "$path" 2>/dev/null | awk '{print $1}')" || true
  printf '%s' "${output:-0}"
}

human_for() {
  local path="$1"
  local output
  if [[ ! -e "$path" ]]; then
    printf 'missing'
    return
  fi
  output="$(du -sh "$path" 2>/dev/null | awk 'NR == 1 {print $1}')" || true
  if [[ -n "$output" ]]; then
    printf '%s' "$output"
  else
    printf 'permission-denied'
  fi
}

print_path() {
  local label="$1"
  local path="$2"
  printf '%-18s %10s  %s\n' "$label" "$(human_for "$path")" "$path"
}

print_largest_children() {
  local path="$1"
  local limit="${2:-10}"
  [[ -d "$path" ]] || return 0

  find "$path" -mindepth 1 -maxdepth 1 -exec du -sh {} + 2>/dev/null | sort -hr | head -n "$limit" || true
}

echo "Disk growth status"
echo
print_path "Torrents" "$TORRENTS_FOLDER"
print_path "Usenet" "$USENET_FOLDER"
print_path "Logs" "$LOGS_FOLDER"
print_path "Cache" "$CACHE_FOLDER"
print_path "Storage" "$STORAGE_FOLDER"
echo

torrent_bytes="$(bytes_for "$TORRENTS_FOLDER")"
usenet_bytes="$(bytes_for "$USENET_FOLDER")"
download_bytes=$((torrent_bytes + usenet_bytes))
download_gb=$((download_bytes / 1024 / 1024 / 1024))

# 10# because [[ ]] reads its operands as arithmetic, where a leading zero
# means octal: a threshold of 0500 would be 320 rather than the 500 it means.
if [[ "$download_gb" -ge "10#$DOWNLOADS_CRIT_GB" ]]; then
  echo "CRITICAL: downloads are ${download_gb}G, at or above ${DOWNLOADS_CRIT_GB}G."
elif [[ "$download_gb" -ge "10#$DOWNLOADS_WARN_GB" ]]; then
  echo "WARNING: downloads are ${download_gb}G, at or above ${DOWNLOADS_WARN_GB}G."
else
  echo "OK: downloads are ${download_gb}G, below ${DOWNLOADS_WARN_GB}G warning threshold."
fi

echo
echo "Largest torrent folders:"
print_largest_children "$TORRENTS_FOLDER" 10

echo
echo "Largest usenet folders:"
print_largest_children "$USENET_FOLDER" 10

echo
echo "Largest log folders:"
print_largest_children "$LOGS_FOLDER" 10
