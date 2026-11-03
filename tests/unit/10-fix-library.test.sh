#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for configs/calibre/custom-cont-init.d/10-fix-library.sh, the init
# script the calibre container runs at start. Every line of it has to run in
# one of them: `make coverage` runs this file under kcov and fails below 100%.
#
# The library and the database folder are scratch directories
# (CALIBRE_LIBRARY_DIR, CALIBRE_DB_DIR) and chown is a
# stub on PATH that only records its arguments. The script's shebang is
# /bin/sh; it runs under bash here because kcov traces bash.

set -o errexit
set -o pipefail
set -o nounset

__script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/configs/calibre/custom-cont-init.d/10-fix-library.sh"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0
mkdir "${__scratch}/bin"
printf '#!%s\necho "chown $*" >>"%s/log"\n' "$(command -v bash)" "${__scratch}" >"${__scratch}/bin/chown"
chmod +x "${__scratch}/bin/chown"

run() {
  __status=0
  rm -f "${__scratch}/log"
  PATH="${__scratch}/bin:${PATH}" CALIBRE_LIBRARY_DIR="${1}" CALIBRE_DB_DIR="${2:-${__scratch}/no-db}" \
    bash "${__script}" \
    >"${__scratch}/out" 2>"${__scratch}/err" || __status=$?
}

# check <name> <status> <file> <text>
check() {
  if [[ "${__status}" -eq "${2}" ]] && grep --quiet --fixed-strings -- "${4}" "${__scratch}/${3}"; then
    echo "ok ${1}"
  else
    echo "FAIL ${1}: exit ${__status}, '${4}' wanted in ${3}" >&2
    __failures=$((__failures + 1))
  fi
}

run "${__scratch}/missing"
check "fails when the library is not mounted" 1 err "ERROR: ${__scratch}/missing not found"

mkdir "${__scratch}/library"
run "${__scratch}/library"
check "hands the library to the app user" 0 log "chown -R abc:abc ${__scratch}/library"
if grep --quiet "no-db" "${__scratch}/log"; then
  echo "FAIL a missing database folder is left alone" >&2
  __failures=$((__failures + 1))
else
  echo "ok a missing database folder is left alone"
fi

mkdir "${__scratch}/db"
run "${__scratch}/library" "${__scratch}/db"
check "hands the database folder to the app user" 0 log "chown -R abc:abc ${__scratch}/db"

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
