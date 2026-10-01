#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for scripts/schedule-backup.sh. Every line of the script has to run in
# one of them: `make coverage` runs this file under kcov and fails below 100%.
#
# The script installs a cron entry. Here it runs through a symlink in a scratch
# repository, so the logs/ directory it creates and the paths it writes into
# the entry are the scratch ones, and crontab is a stub that keeps the table in
# a scratch file. The real crontab is never read or written. The prompts only
# appear on a terminal, so the interactive cases run under with-tty.py, which
# types their answers into a pseudo terminal.

set -o errexit
set -o pipefail
set -o nounset

__script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/schedule-backup.sh"
__bash="$(command -v bash)"
__python="$(command -v python3)"
__with_tty="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/with-tty.py"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0

mkdir "${__scratch}/scripts" "${__scratch}/bin"
ln -s "${__script}" "${__scratch}/scripts/schedule-backup.sh"
for tool in dirname mkdir grep; do
  ln -s "$(command -v "${tool}")" "${__scratch}/bin/${tool}"
done
# crontab -l prints the table, or fails when there is none; crontab - replaces it.
printf '#!%s\n%s\n' "${__bash}" "if [[ \"\$1\" == -l ]]; then
  [[ -f '${__scratch}/table' ]] || exit 1
  cat '${__scratch}/table'
else
  cat >'${__scratch}/table.new'
  mv '${__scratch}/table.new' '${__scratch}/table'
fi" >"${__scratch}/bin/crontab"
chmod +x "${__scratch}/bin/crontab"
ln -s "$(command -v cat)" "${__scratch}/bin/cat"
ln -s "$(command -v mv)" "${__scratch}/bin/mv"

# Runs the script without a terminal on standard input.
run() {
  __status=0
  PATH="${__scratch}/bin" "${__bash}" "${__scratch}/scripts/schedule-backup.sh" \
    </dev/null >"${__scratch}/out" 2>&1 || __status=$?
}

# Runs the script on a pseudo terminal, answering its prompts with $1.
run_tty() {
  __status=0
  local typed
  printf -v typed '%b' "${1}"
  PATH="${__scratch}/bin" "${__python}" "${__with_tty}" "${typed}" \
    "${__bash}" "${__scratch}/scripts/schedule-backup.sh" >"${__scratch}/out" 2>&1 ||
    __status=$?
}

check() {
  local name="${1}" file="${2}" want="${3}"
  if [[ "${__status}" -ne 0 ]]; then
    echo "FAIL ${name}: exit ${__status}" >&2
    cat "${__scratch}/out" >&2
    __failures=$((__failures + 1))
  elif ! grep --quiet --fixed-strings -- "${want}" "${__scratch}/${file}"; then
    echo "FAIL ${name}: '${want}' not in ${file}" >&2
    cat "${__scratch}/${file}" >&2
    __failures=$((__failures + 1))
  else
    echo "ok ${name}"
  fi
}

run
check "applies the default without a terminal" out "Scheduled: daily at 03:00"
check "installs a daily 03:00 entry" table "0 3 * * * cd ${__scratch} && make backup >> ${__scratch}/logs/backup.log 2>&1 # docker-torrent-box-with-vpn"
if [[ ! -d "${__scratch}/logs" ]]; then
  echo "FAIL the log directory was not created" >&2
  __failures=$((__failures + 1))
fi

printf '%s\n' "17 4 * * * someone-elses-job" >>"${__scratch}/table"
run_tty '2\n3\n04:30\n'
check "asks how often on a terminal" out "How often?"
check "reports a weekly schedule" out "Scheduled: weekly on Wednesday at 04:30"
check "installs the weekly entry" table "30 4 * * 3 cd ${__scratch}"
check "keeps other entries" table "someone-elses-job"
if [[ "$(grep --count "schedule-backup.sh" "${__scratch}/table")" -ne 1 ]]; then
  echo "FAIL re-running stacked a second entry" >&2
  cat "${__scratch}/table" >&2
  __failures=$((__failures + 1))
else
  echo "ok re-running replaces its own entry"
fi

run_tty '\n99:75\n'
check "falls back to 03:00 for an out of range time" out "Scheduled: daily at 03:00"

run_tty '2\n9\n\n'
check "falls back to Sunday for an out of range day" out "Scheduled: weekly on Sunday at 03:00"

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
