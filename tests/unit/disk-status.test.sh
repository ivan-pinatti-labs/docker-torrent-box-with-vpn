#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for scripts/disk-status.sh. Every line of the script has to run in one
# of them: `make coverage` runs this file under kcov and fails below 100%.
#
# The script sizes the download, log, cache and storage folders .env names.
# Here it runs through a symlink in a scratch repository with its own .env and
# small folders, so the real data/ is never walked. du is the real one, behind
# a wrapper that answers nothing for a folder named `denied`, the way du does
# for a folder it cannot read. The variables the script reads before .env are
# unset for each run, so the caller's shell cannot leak in.

set -o errexit
set -o pipefail
set -o nounset

__script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/disk-status.sh"
__bash="$(command -v bash)"
__env="$(command -v env)"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0

repo="${__scratch}/repo"
bin="${__scratch}/bin"
mkdir -p "${repo}/scripts" "${bin}"
ln -s "${__script}" "${repo}/scripts/disk-status.sh"
for tool in dirname awk find sort head; do
  ln -s "$(command -v "${tool}")" "${bin}/${tool}"
done
printf '#!%s\n%s\n' "${__bash}" "[[ \"\${*: -1}\" == *denied ]] && exit 1
exec '$(command -v du)' \"\$@\"" >"${bin}/du"
chmod +x "${bin}/du"

run() {
  __status=0
  "${__env}" -u DATA_FOLDER -u TORRENTS_FOLDER -u USENET_FOLDER -u LOGS_FOLDER \
    -u CACHE_FOLDER -u STORAGE_FOLDER -u DOWNLOADS_WARN_GB -u DOWNLOADS_CRIT_GB \
    PATH="${bin}" "${__bash}" "${repo}/scripts/disk-status.sh" >"${__scratch}/out" 2>&1 ||
    __status=$?
}

check() {
  local name="${1}" want="${2}"
  if [[ "${__status}" -ne 0 ]]; then
    echo "FAIL ${name}: exit ${__status}" >&2
    cat "${__scratch}/out" >&2
    __failures=$((__failures + 1))
  elif ! grep --quiet -- "${want}" "${__scratch}/out"; then
    echo "FAIL ${name}: '${want}' not in the output" >&2
    cat "${__scratch}/out" >&2
    __failures=$((__failures + 1))
  else
    echo "ok ${name}"
  fi
}

run
check "reports a folder that does not exist" "^Torrents  *missing  ./data/torrents$"
check "is fine with nothing downloaded" "^OK: downloads are 0G, below 500G warning threshold.$"

mkdir -p "${repo}/media/torrents/big" "${repo}/media/torrents/small" "${repo}/logs/app" "${repo}/denied"
head -c 20000 /dev/zero >"${repo}/media/torrents/big/file"
printf '%s\n' 'DATA_FOLDER="./media"' "TORRENTS_FOLDER='\${DATA_FOLDER}/torrents'" \
  STORAGE_FOLDER=./denied DOWNLOADS_WARN_GB=0 DOWNLOADS_CRIT_GB=1 >"${repo}/.env"
run
check "expands \${DATA_FOLDER} in a folder path" "  ./media/torrents$"
check "falls back to DATA_FOLDER for usenet" "  ./media/usenet$"
check "reports a folder du cannot read" "^Storage  *permission-denied  ./denied$"
check "warns at the warning threshold" "^WARNING: downloads are 0G, at or above 0G.$"
check "lists the largest torrent folders" "./media/torrents/big$"
check "lists the largest log folders" "./logs/app$"

printf 'DOWNLOADS_CRIT_GB=0\n' >"${repo}/.env"
run
check "is critical at the critical threshold" "^CRITICAL: downloads are 0G, at or above 0G.$"

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
