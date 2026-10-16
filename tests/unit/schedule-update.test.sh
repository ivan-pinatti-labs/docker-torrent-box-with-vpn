#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for scripts/schedule-update.sh. Every line of the script has to run in
# one of them: `make coverage` runs this file under kcov and fails below 100%.
#
# Built the way tests/unit/schedule-backup.test.sh is: the script runs through
# a symlink in a scratch repository, crontab is a stub keeping the table in a
# scratch file, and the prompts are answered on a pseudo terminal by
# with-tty.py. The real crontab is never read or written.

set -o errexit
set -o pipefail
set -o nounset

__script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/schedule-update.sh"
__bash="$(command -v bash)"
__python="$(command -v python3)"
__with_tty="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/with-tty.py"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0

mkdir "${__scratch}/scripts" "${__scratch}/bin"
ln -s "${__script}" "${__scratch}/scripts/schedule-update.sh"
for tool in dirname mkdir grep cat mv; do
  ln -s "$(command -v "${tool}")" "${__scratch}/bin/${tool}"
done
# crontab -l fails the way cron does when there is no table, and with another
# error while ${__scratch}/broken exists, whether or not there is a table.
printf '#!%s\n%s\n' "${__bash}" "if [[ \"\$1\" == -l ]]; then
  [[ ! -f '${__scratch}/broken' ]] || { echo 'crontab: permission denied' >&2; exit 1; }
  [[ -f '${__scratch}/table' ]] || { echo 'no crontab for user' >&2; exit 1; }
  cat '${__scratch}/table'
else
  cat >'${__scratch}/table.new'
  mv '${__scratch}/table.new' '${__scratch}/table'
fi" >"${__scratch}/bin/crontab"
chmod +x "${__scratch}/bin/crontab"

run() {
  __status=0
  PATH="${__scratch}/bin" "${__bash}" "${__scratch}/scripts/schedule-update.sh" "$@" \
    </dev/null >"${__scratch}/out" 2>&1 || __status=$?
}

run_tty() {
  __status=0
  local typed
  printf -v typed '%b' "${1}"
  PATH="${__scratch}/bin" "${__python}" "${__with_tty}" "${typed}" \
    "${__bash}" "${__scratch}/scripts/schedule-update.sh" >"${__scratch}/out" 2>&1 ||
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
check "applies the default without a terminal" out "Scheduled: weekly on Sunday at 04:00, logging to logs/update.log."
check "installs a Sunday 04:00 entry" table "0 4 * * 0 cd ${__scratch} && make update >> ${__scratch}/logs/update.log 2>&1 # docker-torrent-box-with-vpn: scheduled update"
if [[ ! -d "${__scratch}/logs" ]]; then
  echo "FAIL the log directory was not created" >&2
  __failures=$((__failures + 1))
fi

printf '%s\n' "17 4 * * * someone-elses-job" >>"${__scratch}/table"
run_tty '3\n05:30\n'
check "warns about one way migrations on a terminal" out "Some image updates migrate their database one way"
check "reports the chosen day and time" out "Scheduled: weekly on Wednesday at 05:30"
check "installs the chosen entry" table "30 5 * * 3 cd ${__scratch} && make update"
check "keeps other entries" table "someone-elses-job"
if [[ "$(grep --count "schedule-update.sh" "${__scratch}/table")" -ne 1 ]]; then
  echo "FAIL re-running stacked a second entry" >&2
  cat "${__scratch}/table" >&2
  __failures=$((__failures + 1))
else
  echo "ok re-running replaces its own entry"
fi

run_tty '9\n99:75\n'
check "falls back to the defaults for out of range answers" out "Scheduled: weekly on Sunday at 04:00"

run --remove
check "removes the entry" out "Removed the scheduled update"
check "keeps other entries on removal" table "someone-elses-job"
if grep --quiet "schedule-update.sh" "${__scratch}/table"; then
  echo "FAIL --remove left the entry in place" >&2
  __failures=$((__failures + 1))
else
  echo "ok --remove takes the entry out"
fi

# A table that cannot be read is never written over, by either path.
cp "${__scratch}/table" "${__scratch}/table.kept"
touch "${__scratch}/broken"
for args in "" "--remove"; do
  # shellcheck disable=SC2086 # empty on purpose, so the first round passes no argument
  run ${args}
  if [[ "${__status}" -ne 1 ]] || ! grep --quiet "could not read the crontab (crontab: permission denied)" "${__scratch}/out"; then
    echo "FAIL a read error ${args:-on install} did not stop the script" >&2
    cat "${__scratch}/out" >&2
    __failures=$((__failures + 1))
  elif ! cmp -s "${__scratch}/table" "${__scratch}/table.kept"; then
    echo "FAIL a read error ${args:-on install} changed the table" >&2
    __failures=$((__failures + 1))
  else
    echo "ok a read error ${args:-on install} leaves the table alone"
  fi
done
rm "${__scratch}/broken"

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
