#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
set -euo pipefail

# Usage: ./scripts/schedule-update.sh [--remove]
# Installs (or replaces) a cron entry that runs `make update` on a schedule,
# the way scripts/schedule-backup.sh does for `make backup`. Nothing schedules
# updates unless this is run: an image update can run a one way database
# migration (a Jellyfin minor release, for one), and when an unattended run
# fails partway, putting the backup it took back is a job for a person. The
# summary and the rollback commands of every run land in logs/update.log.
#
# Prompts for the day and time in a real terminal; without one it applies the
# default, weekly on Sunday at 04:00, an hour after the default backup.
# --remove takes the entry out again. Re-running replaces the entry rather
# than stacking a second one, identified by MARKER below.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly MARKER="# docker-torrent-box-with-vpn: scheduled update, managed by scripts/schedule-update.sh, do not edit this line by hand"

existing="$(crontab -l 2>/dev/null | grep -vF "$MARKER" || true)"

if [[ "${1:-}" == "--remove" ]]; then
  printf '%s\n' "$existing" | crontab -
  echo "Removed the scheduled update, if there was one."
  exit 0
fi

day_of_week="0"
hour="04"
minute="00"

if [[ -t 0 ]]; then
  echo "Schedule automatic updates (runs 'make update': backup, git pull, new images, restart)."
  echo "Some image updates migrate their database one way; read docs/MAKE_COMMANDS.md first."
  echo ""
  echo "Which day? 0=Sunday 1=Monday 2=Tuesday 3=Wednesday 4=Thursday 5=Friday 6=Saturday"
  read -r -p "Day of week [0]: " day_input
  day_of_week="${day_input:-0}"
  read -r -p "What time, 24h HH:MM [04:00]: " time_input
  time_input="${time_input:-04:00}"
  hour="${time_input%%:*}"
  minute="${time_input##*:}"
fi

# Fall back to the default for anything that is not a plain, in-range number,
# as schedule-backup.sh does.
[[ "$day_of_week" =~ ^[0-6]$ ]] || day_of_week="0"
[[ "$hour" =~ ^[0-9]{1,2}$ ]] && ((10#$hour <= 23)) || hour="04"
[[ "$minute" =~ ^[0-9]{1,2}$ ]] && ((10#$minute <= 59)) || minute="00"
hour="$((10#$hour))"
minute="$((10#$minute))"

days=(Sunday Monday Tuesday Wednesday Thursday Friday Saturday)
mkdir -p "${repo_root}/logs"
cron_line="${minute} ${hour} * * ${day_of_week} cd ${repo_root} && make update >> ${repo_root}/logs/update.log 2>&1 ${MARKER}"
{
  [[ -n "$existing" ]] && printf '%s\n' "$existing"
  printf '%s\n' "$cron_line"
} | crontab -

echo ""
echo "Scheduled: weekly on ${days[$day_of_week]} at $(printf '%02d:%02d' "$hour" "$minute"), logging to logs/update.log."
echo "A failed run leaves the stack as that log says and does not retry; check it after each run."
echo "Remove it with: make update-schedule ARGS=--remove"
