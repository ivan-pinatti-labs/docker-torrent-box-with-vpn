#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for scripts/seed-secrets.sh. Every line of the script has to run in
# one of them: `make coverage` runs this file under kcov and fails below 100%.
#
# The script seeds a config directory's secrets/<name> and .env.secrets from
# their .example files, and prompts only when .env.secrets already exists and
# standard input is a terminal. The prompt is driven through
# tests/unit/with-tty.py, which types the answers into a pseudo terminal. The
# config directory is a scratch one.

set -o errexit
set -o pipefail
set -o nounset

__here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__script="${__here}/../../scripts/seed-secrets.sh"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0
dir="${__scratch}/app"

run() {
  __status=0
  bash "${__script}" "$@" >"${__scratch}/out" 2>"${__scratch}/err" </dev/null || __status=$?
}

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

mkdir -p "${dir}/secrets"
printf 'token\n\n' >"${dir}/secrets/api_key.example"
echo "example" >"${dir}/secrets/kept.example"
echo "live" >"${dir}/secrets/kept"
run "${dir}"
expect "seeds a missing secret file" 0 out "[${dir}] Seeded secrets/api_key from secrets/api_key.example."
if [[ "$(od -An -c "${dir}/secrets/api_key" | tr -d ' ')" == "token" ]]; then
  pass "drops trailing newlines"
else
  fail "trailing newlines were copied"
fi
if [[ "$(stat -c %a "${dir}/secrets/api_key")" == 644 ]]; then
  pass "the secret file is mode 644"
else
  fail "the secret file is not mode 644"
fi
if [[ "$(<"${dir}/secrets/kept")" == live ]]; then
  pass "an existing secret file is kept"
else
  fail "an existing secret file was overwritten"
fi
if [[ ! -e "${dir}/.env.secrets" ]]; then
  pass "no .env.secrets without an example"
else
  fail ".env.secrets appeared without an example"
fi

echo "NEW=1" >"${dir}/.env.secrets.example"
run "${dir}"
expect "seeds a missing .env.secrets" 0 out "[${dir}] Seeded .env.secrets from .env.secrets.example."

echo "OLD=1" >"${dir}/.env.secrets"
run "${dir}"
if [[ "${__status}" -eq 0 && "$(<"${dir}/.env.secrets")" == "OLD=1" && ! -s "${__scratch}/out" ]]; then
  pass "a non interactive run leaves existing secrets alone"
else
  fail "a non interactive run touched existing secrets"
fi

run_tty $'9\n2\n1\n' "${dir}"
expect "rejects an unknown choice" 0 out "Invalid choice."
expect "shows the diff on request" 0 out "+NEW=1"
if [[ "$(<"${dir}/.env.secrets")" == "OLD=1" ]]; then
  pass "skip keeps the existing secrets"
else
  fail "skip changed the secrets"
fi

run_tty $'3\n' "${dir}"
expect "replaces on request" 0 out "[${dir}] Replaced .env.secrets."
if [[ "$(<"${dir}/.env.secrets")" == "NEW=1" ]]; then
  pass "the replacement is the example"
else
  fail "the secrets were not replaced"
fi

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
