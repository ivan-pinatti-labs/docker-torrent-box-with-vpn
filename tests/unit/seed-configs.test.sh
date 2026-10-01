#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for scripts/seed-configs.sh. Every line of the script has to run in
# one of them: `make coverage` runs this file under kcov and fails below 100%.
#
# The script copies <file>.example to <file>, and prompts only when <file>
# already exists and standard input is a terminal. The prompt is driven
# through tests/unit/with-tty.py, which types the answers into a pseudo
# terminal. Every file lives in a scratch directory.

set -o errexit
set -o pipefail
set -o nounset

__here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__script="${__here}/../../scripts/seed-configs.sh"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0
live="${__scratch}/sub/dir/app.conf"

run() {
  __status=0
  bash "${__script}" "$@" >"${__scratch}/out" 2>"${__scratch}/err" </dev/null || __status=$?
}

# Runs the script with the given answers typed at its prompt.
run_tty() {
  local typed="${1}"
  shift
  __status=0
  python3 "${__here}/with-tty.py" "${typed}" bash "${__script}" "$@" \
    >"${__scratch}/out" 2>"${__scratch}/err" || __status=$?
}

pass() { echo "ok ${1}"; }
fail() {
  echo "FAIL ${1}" >&2
  cat "${__scratch}/err" >&2
  __failures=$((__failures + 1))
}

# expect <name> <status> <file> <text>
expect() {
  if [[ "${__status}" -eq "${2}" ]] && grep --quiet --fixed-strings -- "${4}" "${__scratch}/${3}"; then
    pass "${1}"
  else
    fail "${1}: exit ${__status}, '${4}' wanted in ${3}"
  fi
}

run
expect "no argument is a usage error" 1 err "Usage:"

run "${live}"
expect "a missing example is an error" 1 err "Missing ${live}.example"

mkdir -p "${__scratch}/sub/dir"
echo "new=1" >"${live}.example"
rm -rf "${__scratch}/sub/dir/app.conf"
run "${live}"
expect "seeds a missing live file" 0 out "[${live}] Seeded from app.conf.example."
if cmp --quiet "${live}" "${live}.example"; then
  pass "the seed is a copy"
else
  fail "the seed is not a copy"
fi

echo "old=1" >"${live}"
run "${live}"
if [[ "${__status}" -eq 0 && "$(<"${live}")" == "old=1" && ! -s "${__scratch}/out" ]]; then
  pass "a non interactive run leaves an existing file alone"
else
  fail "a non interactive run touched the existing file"
fi

run_tty $'9\n2\n1\n' "${live}"
expect "rejects an unknown choice" 0 out "Invalid choice."
expect "shows the diff on request" 0 out "+new=1"
if [[ "$(<"${live}")" == "old=1" ]]; then
  pass "skip keeps the existing file"
else
  fail "skip changed the file"
fi

run_tty $'3\n' "${live}"
expect "replaces on request" 0 out "[${live}] Replaced."
if [[ "$(<"${live}")" == "new=1" ]]; then
  pass "the replacement is the example"
else
  fail "the file was not replaced"
fi

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
