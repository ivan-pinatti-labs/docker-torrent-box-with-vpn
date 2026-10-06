#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for scripts/nested-cgroups-report.sh, the line tests/ci-suite.sh
# prints about the nested runner's cgroups. Every line of it has to run in one
# of them: `make coverage` runs this file under kcov and fails below 100%.
#
# HOME is a scratch directory, so the drop in the image's init writes is a
# file the test creates or leaves out. podman is a stub on PATH that answers
# `podman info` with PODMAN_INFO (the joined controller list, possibly
# empty), or fails when PODMAN_INFO is unset.

set -o errexit
set -o pipefail
set -o nounset

__script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/nested-cgroups-report.sh"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0
mkdir "${__scratch}/bin" "${__scratch}/home"
printf '#!%s\n[ -n "${PODMAN_INFO+set}" ] || exit 125\nprintf "%%s\\n" "${PODMAN_INFO}"\n' "$(command -v bash)" >"${__scratch}/bin/podman"
chmod +x "${__scratch}/bin/podman"
conf="${__scratch}/home/.config/containers/containers.conf.d/50-cgroups.conf"

# run [ENV=VALUE...]: the script with a clean runner environment plus these.
run() {
  __status=0
  env -u GITHUB_ACTIONS PATH="${__scratch}/bin:${PATH}" HOME="${__scratch}/home" "$@" \
    bash "${__script}" >"${__scratch}/out" 2>"${__scratch}/err" || __status=$?
}

# check <name> <file> <text>: the last run succeeded and printed text.
check() {
  if [[ "${__status}" -eq 0 ]] && grep --quiet --fixed-strings -- "${3}" "${__scratch}/${2}"; then
    echo "ok ${1}"
  else
    echo "FAIL ${1}: exit ${__status}, '${3}' wanted in ${2}" >&2
    __failures=$((__failures + 1))
  fi
}

# refute <name> <file> <text>: the last run did not print text.
refute() {
  if ! grep --quiet --fixed-strings -- "${3}" "${__scratch}/${2}"; then
    echo "ok ${1}"
  else
    echo "FAIL ${1}: '${3}' unwanted in ${2}" >&2
    __failures=$((__failures + 1))
  fi
}

run PODMAN_INFO="cpu memory"
check "without the drop in, cgroups are off" out "nested cgroups off (the runner was given no delegated cgroup v2 tree, or started with --user)"
refute "and nothing else is printed" out "::notice"

mkdir -p "$(dirname "${conf}")"
: >"${conf}"
run PODMAN_INFO="cpu io memory pids"
check "with the drop in, cgroups are on, with the engine's controllers" out "nested cgroups on (engine controllers: cpu io memory pids)"

run PODMAN_INFO=""
check "an engine reporting no controllers says none" out "nested cgroups on (engine controllers: none)"

run
check "an engine that does not answer still gets a report" out "nested cgroups on (engine controllers: none)"

run GITHUB_ACTIONS=true PODMAN_INFO="cpu memory"
check "on a runner the state is also a notice" out "::notice title=Nested cgroups::on (engine controllers: cpu memory)"

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
