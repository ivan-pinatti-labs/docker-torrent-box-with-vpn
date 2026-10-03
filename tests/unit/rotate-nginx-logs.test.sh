#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# cspell:ignore mylogs
#
# Tests for scripts/rotate-nginx-logs.sh. Every line of the script has to run
# in one of them: `make coverage` runs this file under kcov and fails below
# 100%.
#
# The script works from the repository it lives in, so it runs here through a
# symlink in a scratch scripts/ directory, next to a scratch .env and logs/.
# It only drives find, cp, gzip and rm on those files, so nothing needs a
# stub. Its shebang is /bin/sh; it runs under bash here because kcov traces
# bash, and it uses nothing bash treats differently.

set -o errexit
set -o pipefail
set -o nounset

__script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/rotate-nginx-logs.sh"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0

mkdir "${__scratch}/scripts"
ln -s "${__script}" "${__scratch}/scripts/rotate-nginx-logs.sh"

run() {
  __status=0
  env "$@" bash "${__scratch}/scripts/rotate-nginx-logs.sh" >"${__scratch}/out" 2>"${__scratch}/err" ||
    __status=$?
}

result() {
  if [[ "${2}" == yes ]]; then
    echo "ok ${1}"
  else
    echo "FAIL ${1}" >&2
    cat "${__scratch}/err" >&2
    __failures=$((__failures + 1))
  fi
}

ran_with() {
  [[ "${__status}" -eq 0 ]] && grep --quiet --fixed-strings -- "${1}" "${__scratch}/out" && echo yes || echo no
}

run
result "without .env or logs says there is nothing to rotate" \
  "$(ran_with "No nginx log directory found at ./logs/nginx.")"

# Quoted values in .env are unquoted, and a key .env lacks falls back.
printf '%s\n' 'LOGS_FOLDER="./mylogs"' "LOG_RETENTION_DAYS='5'" >"${__scratch}/.env"
logs="${__scratch}/mylogs/nginx"
mkdir -p "${logs}"
echo "GET /" >"${logs}/access.log"
: >"${logs}/error.log"
echo old >"${logs}/access.log-20200101000000"
touch -d "10 days ago" "${logs}/access.log-20200101000000"
echo older >"${logs}/access.log-20190101000000.gz"
touch -d "100 days ago" "${logs}/access.log-20190101000000.gz"
echo recent >"${logs}/access.log-20260101000000.gz"
run
result "reads .env, unquoting values, and defaults the rest" \
  "$(ran_with "Plain retention: 5 days. Compressed archive retention: 90 days.")"
result "rotates a log with content" "$(ran_with "Rotated ./mylogs/nginx/access.log")"
rotated=("${logs}"/access.log-2?????????????)
[[ ! -s "${logs}/access.log" && "$(cat "${rotated[@]}")" == *"GET /"* ]] && ok=yes || ok=no
result "the rotated copy holds the content and the log is emptied" "${ok}"
[[ -f "${logs}/error.log" && ! -e "$(ls "${logs}"/error.log-* 2>/dev/null)" ]] && ok=yes || ok=no
result "an empty log is not rotated" "${ok}"
[[ -f "${logs}/access.log-20200101000000.gz" ]] && ok=yes || ok=no
result "compresses rotated logs past plain retention" "${ok}"
[[ ! -e "${logs}/access.log-20190101000000.gz" && -f "${logs}/access.log-20260101000000.gz" ]] && ok=yes || ok=no
result "deletes archives past archive retention, keeps newer ones" "${ok}"

run LOGS_FOLDER=./elsewhere LOG_RETENTION_DAYS=1 LOG_ARCHIVE_RETENTION_DAYS=2
result "the environment wins over .env" "$(ran_with "No nginx log directory found at ./elsewhere/nginx.")"

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
