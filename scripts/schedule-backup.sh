#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
set -euo pipefail

# Usage: ./scripts/schedule-backup.sh
# Installs (or replaces) a cron entry that runs `make backup` (the lean
# config backup) on a schedule. Prompts for frequency and time in a real
# terminal; in a non-interactive run it applies the default (daily at
# 03:00) without prompting, since scheduling a backup is a safe, reversible
# action, unlike Gluetun's VPN credentials where guessing would be actively
# wrong. Re-running this script replaces the previously scheduled entry
# rather than stacking a second one, identified by MARKER below.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly MARKER="# docker-torrent-box-with-vpn: scheduled backup, managed by scripts/schedule-backup.sh, do not edit this line by hand"

frequency="daily"
day_of_week="0"
hour="03"
minute="00"

if [[ -t 0 ]]; then
  echo "Schedule automatic backups (runs 'make backup', the lean config backup)."
  echo ""
  echo "How often?"
  echo "  1) Daily (default)"
  echo "  2) Weekly"
  read -r -p "Choice [1/2] [1]: " freq_choice
  freq_choice="${freq_choice:-1}"

  if [[ "$freq_choice" == "2" ]]; then
    frequency="weekly"
    echo ""
    echo "Which day? 0=Sunday 1=Monday 2=Tuesday 3=Wednesday 4=Thursday 5=Friday 6=Saturday"
    read -r -p "Day of week [0]: " day_input
    day_of_week="${day_input:-0}"
  fi

  echo ""
  read -r -p "What time, 24h HH:MM [03:00]: " time_input
  time_input="${time_input:-03:00}"
  hour="${time_input%%:*}"
  minute="${time_input##*:}"
fi

# Fall back to the default for anything that isn't a plain, in-range number,
# rather than installing a cron entry that silently never fires (or fires
# constantly on a malformed schedule).
[[ "$day_of_week" =~ ^[0-6]$ ]] || day_of_week="0"
[[ "$hour" =~ ^[0-9]{1,2}$ ]] && ((10#$hour <= 23)) || hour="03"
[[ "$minute" =~ ^[0-9]{1,2}$ ]] && ((10#$minute <= 59)) || minute="00"
hour="$((10#$hour))"
minute="$((10#$minute))"

if [[ "$frequency" == "daily" ]]; then
  cron_schedule="${minute} ${hour} * * *"
  human_schedule="daily at $(printf '%02d:%02d' "$hour" "$minute")"
else
  days=(Sunday Monday Tuesday Wednesday Thursday Friday Saturday)
  cron_schedule="${minute} ${hour} * * ${day_of_week}"
  human_schedule="weekly on ${days[$day_of_week]} at $(printf '%02d:%02d' "$hour" "$minute")"
fi

mkdir -p "${repo_root}/logs"
cron_line="${cron_schedule} cd ${repo_root} && make backup >> ${repo_root}/logs/backup.log 2>&1 ${MARKER}"

# Drop any previously scheduled entry from this script before adding the
# new one, so re-running replaces rather than stacks.
# Only a missing table reads as empty. Any other failure to read it stops here,
# before writing back what little was read could replace the whole table.
if ! current="$(crontab -l 2>/dev/null)"; then
  reason="$(LC_ALL=C crontab -l 2>&1 >/dev/null || true)"
  if [[ "$reason" != *"no crontab"* ]]; then
    echo "ERROR: could not read the crontab (${reason:-no reason given}), so it was left as it is." >&2
    exit 1
  fi
  current=""
fi
existing="$(printf '%s\n' "$current" | grep -vF "$MARKER" || true)"
{
  [[ -n "$existing" ]] && printf '%s\n' "$existing"
  printf '%s\n' "$cron_line"
} | crontab -

echo ""
echo "Scheduled: ${human_schedule}, logging to logs/backup.log."
echo "View it any time with: crontab -l"
echo "Remove it with: crontab -l | grep -v 'schedule-backup.sh' | crontab -"
