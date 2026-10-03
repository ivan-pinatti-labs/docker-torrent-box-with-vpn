#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# cspell:ignore cret frobnicate
#
# Tests for scripts/korsync-users.sh. Every line of the script has to run in
# one of them: `make coverage` runs this file under kcov and fails below 100%.
#
# The script runs bun inside the korsync container to edit its user database.
# Here it runs through a symlink in a scratch repository whose .env names a
# stub runtime, which records the command line and the variables handed to the
# container instead of running anything. The new password is typed on
# standard input.

set -o errexit
set -o pipefail
set -o nounset

__script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/korsync-users.sh"
__bash="$(command -v bash)"
__env="$(command -v env)"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0

repo="${__scratch}/repo"
bin="${__scratch}/bin"
mkdir -p "${repo}/scripts" "${bin}"
ln -s "${__script}" "${repo}/scripts/korsync-users.sh"
for tool in dirname awk cat; do
  ln -s "$(command -v "${tool}")" "${bin}/${tool}"
done
printf 'CONTAINER_RUNTIME=stub-runtime\n' >"${repo}/.env"
printf '#!%s\n%s\n' "${__bash}" "{
  echo \"args \${1} \${2} \${3} \${4} \${5}\"
  echo \"USERNAME=\${USERNAME:-} NEW_PASSWORD=\${NEW_PASSWORD:-} OLD_NAME=\${OLD_NAME:-} NEW_NAME=\${NEW_NAME:-}\"
  echo \"script \${*: -1}\"
} >'${__scratch}/log'" >"${bin}/stub-runtime"
chmod +x "${bin}/stub-runtime"

# Runs the script with the given arguments, standard input from ${__scratch}/in.
run() {
  rm -f "${__scratch}/log"
  touch "${__scratch}/log"
  __status=0
  "${__env}" -u CONTAINER_RUNTIME -u USERNAME -u NEW_PASSWORD PATH="${bin}" \
    "${__bash}" "${repo}/scripts/korsync-users.sh" "$@" \
    <"${__scratch}/in" >"${__scratch}/out" 2>&1 || __status=$?
}

check() {
  local name="${1}" want_status="${2}" file="${3}" want="${4}"
  if [[ "${__status}" -ne "${want_status}" ]]; then
    echo "FAIL ${name}: exit ${__status}, wanted ${want_status}" >&2
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

: >"${__scratch}/in"
run
check "prints usage without a command" 1 out "Usage:"
run frobnicate
check "prints usage for an unknown command" 1 out "change-password <username>"

run list
check "lists users read only" 0 log "args exec korsync bun -e"
check "opens the database read only to list" 0 log "readonly: true"

run remove
check "remove needs a username" 1 out "usage: remove <username>"
run remove alice
check "removes by username" 0 log "args exec -e USERNAME korsync bun"
check "hands the username over the environment" 0 log "USERNAME=alice"

run rename alice
check "rename needs two names" 1 out "usage: rename <old-username> <new-username>"
run rename alice bob
check "renames" 0 log "OLD_NAME=alice NEW_NAME=bob"

printf 's3cret\n' >"${__scratch}/in"
run change-password alice
check "changes a password read from standard input" 0 log "USERNAME=alice NEW_PASSWORD=s3cret"

printf '\n' >"${__scratch}/in"
run change-password alice
check "refuses an empty password" 1 out "password cannot be empty"

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
