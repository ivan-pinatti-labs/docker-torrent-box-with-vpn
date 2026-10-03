#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for scripts/rotate-all.sh. Every line of the script has to run in one
# of them: `make coverage` runs this file under kcov and fails below 100%.
#
# The script runs its two siblings, rotate-api-keys.sh and rotate-passwords.sh,
# from its own directory. Here it runs through a symlink in a scratch scripts/
# directory whose siblings are stubs that only record how they were called, so
# no credential is ever rotated and no container is touched.

set -o errexit
set -o pipefail
set -o nounset

__script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/rotate-all.sh"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0

mkdir "${__scratch}/scripts"
ln -s "${__script}" "${__scratch}/scripts/rotate-all.sh"
for sibling in rotate-api-keys rotate-passwords; do
  printf '#!/usr/bin/env bash\necho "%s $* in $PWD" >>"%s/log"\n' \
    "${sibling}" "${__scratch}" >"${__scratch}/scripts/${sibling}.sh"
  chmod +x "${__scratch}/scripts/${sibling}.sh"
done

run() {
  rm -f "${__scratch}/log"
  __status=0
  bash "${__scratch}/scripts/rotate-all.sh" "$@" >"${__scratch}/out" 2>"${__scratch}/err" ||
    __status=$?
}

# The siblings that ran, in order, one argument per expected log line.
check() {
  local name="${1}"
  shift
  printf '%s\n' "$@" >"${__scratch}/want"
  if [[ "${__status}" -ne 0 ]]; then
    echo "FAIL ${name}: exit ${__status}" >&2
    cat "${__scratch}/err" >&2
    __failures=$((__failures + 1))
  elif ! diff -u "${__scratch}/want" "${__scratch}/log" >&2; then
    echo "FAIL ${name}: the siblings above ran, not the ones wanted" >&2
    __failures=$((__failures + 1))
  elif ! grep --quiet --fixed-strings "All rotations complete." "${__scratch}/out"; then
    echo "FAIL ${name}: no completion message" >&2
    __failures=$((__failures + 1))
  else
    echo "ok ${name}"
  fi
}

run
check "defaults to every service, API keys first" \
  "rotate-api-keys all in ${__scratch}" \
  "rotate-passwords all in ${__scratch}"

run sonarr
check "passes one service to both" \
  "rotate-api-keys sonarr in ${__scratch}" \
  "rotate-passwords sonarr in ${__scratch}"

run qbittorrent
check "qbittorrent gets password rotation only" \
  "rotate-passwords qbittorrent in ${__scratch}"

run sabnzbd
check "sabnzbd gets password rotation only" \
  "rotate-passwords sabnzbd in ${__scratch}"

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
