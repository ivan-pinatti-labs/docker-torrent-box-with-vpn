# shellcheck shell=bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Shared by the tests of the scripts that drive the running stack:
# rotate-api-keys.sh, rotate-passwords.sh and wire-connections.sh. Sourced,
# not run. The test sets __script_name to the script's file name first.
#
# The script runs through a symlink in a scratch repository, so the .env,
# configs/ and databases it reads and writes are the test's own, and so is
# scripts/permissions.py, a stub. podman, podman-compose, jq, yq, xmlstarlet,
# openssl and timeout are tests/unit/stack-stub.py, first on PATH; see its
# docstring for how it answers. sleep is a shell function exported into the
# script, which advances $SECONDS instead of waiting, so every retry loop
# runs to its end at once and the one loop that counts wall clock time sees
# it pass. No container, network or real credential is touched.

__here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__script="$(cd "${__here}/../.." && pwd)/scripts/${__script_name}"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0
__repo="${__scratch}/repo"
__state="${__scratch}/state"
__bin="${__scratch}/bin"
export STUB_STATE="${__state}"

mkdir -p "${__bin}"
for tool in podman podman-compose jq yq xmlstarlet openssl timeout; do
  ln -s "${__here}/stack-stub.py" "${__bin}/${tool}"
done

sleep() {
  SECONDS=$((SECONDS + ${1:-0}))
}
export -f sleep

# Resets the scratch repository and the stubs' state. Reads the .env lines
# from standard input.
fresh_repo() {
  rm -rf "${__repo}" "${__state}"
  mkdir -p "${__repo}/scripts" "${__state}/rules" "${__state}/health"
  ln -s "${__script}" "${__repo}/scripts/${__script_name}"
  printf '#!/usr/bin/env bash\necho "permissions.py $*" >>"%s/log"\n' "${__state}" >"${__repo}/scripts/permissions.py"
  chmod +x "${__repo}/scripts/permissions.py"
  cat >"${__repo}/.env"
  : >"${__state}/log"
  __rules=0
}

# Writes a file under the scratch repository, making its directory. The
# content is the second argument, or standard input when there is none.
put() {
  mkdir -p "$(dirname "${__repo}/${1}")"
  if [[ $# -gt 1 ]]; then
    printf '%s' "${2}" >"${__repo}/${1}"
  else
    cat >"${__repo}/${1}"
  fi
}

# rule <regex> <exit status> <output> [<times>]: see stack-stub.py.
rule() {
  __rules=$((__rules + 1))
  printf '%s\n%s\n%s\n%s' "${1}" "${2}" "${4:--}" "${3}" >"${__state}/rules/$(printf '%04d' "${__rules}")"
}

# The containers that exist, all running.
containers() {
  printf '%s\n' "$@" >"${__state}/containers"
}

# The ones of those that are stopped.
stopped() {
  printf '%s\n' "$@" >"${__state}/stopped"
}

run() {
  __status=0
  PATH="${__bin}:${PATH}" bash "${__repo}/scripts/${__script_name}" "$@" \
    </dev/null >"${__scratch}/out" 2>"${__scratch}/err" || __status=$?
}

# Where check and refute look: out, err, log (the stubs' calls) or a file
# under the scratch repository.
where() {
  case "${1}" in
  out | err) echo "${__scratch}/${1}" ;;
  log) echo "${__state}/log" ;;
  *) echo "${__repo}/${1}" ;;
  esac
}

fail() {
  echo "FAIL ${1}" >&2
  echo "--- out" >&2
  cat "${__scratch}/out" >&2
  echo "--- err" >&2
  cat "${__scratch}/err" >&2
  __failures=$((__failures + 1))
}

# check <name> <expected exit> <where> <text>...: the run exited as expected
# and every text is in that file.
check() {
  local name="${1}" want_status="${2}" path text
  path="$(where "${3}")"
  shift 3
  if [[ "${__status}" -ne "${want_status}" ]]; then
    fail "${name}: exit ${__status}, wanted ${want_status}"
    return
  fi
  for text in "$@"; do
    if ! grep --quiet --fixed-strings -- "${text}" "${path}" 2>/dev/null; then
      fail "${name}: '${text}' not in ${path#"${__scratch}"/}"
      return
    fi
  done
  echo "ok ${name}"
}

# refute <name> <where> <text>: the text is not in that file.
refute() {
  local path
  path="$(where "${2}")"
  if grep --quiet --fixed-strings -- "${3}" "${path}" 2>/dev/null; then
    fail "${1}: '${3}' found in ${path#"${__scratch}"/}"
  else
    echo "ok ${1}"
  fi
}

finish() {
  if [[ "${__failures}" -gt 0 ]]; then
    echo "${__failures} failed" >&2
    exit 1
  fi
}
