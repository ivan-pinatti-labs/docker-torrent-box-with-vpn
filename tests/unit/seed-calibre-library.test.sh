#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for scripts/seed-calibre-library.sh. Every line of the script has to
# run in one of them: `make coverage` runs this file under kcov and fails
# below 100%.
#
# The script works in the current directory, so each case runs in a scratch
# directory holding its own .env and data/. podman is a stub on PATH that only
# records how it was called, so no image is pulled and no container runs.

set -o errexit
set -o pipefail
set -o nounset

__script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/seed-calibre-library.sh"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0

mkdir "${__scratch}/bin" "${__scratch}/work"
printf '#!%s\necho "podman $*" >>"%s/log"\n' "$(command -v bash)" "${__scratch}" >"${__scratch}/bin/podman"
chmod +x "${__scratch}/bin/podman"
echo "CALIBRE_VERSION=v8.1.0" >"${__scratch}/work/.env"

run() {
  rm -f "${__scratch}/log"
  touch "${__scratch}/log"
  __status=0
  (cd "${__scratch}/work" && PATH="${__scratch}/bin:${PATH}" bash "${__script}") \
    >"${__scratch}/out" 2>"${__scratch}/err" || __status=$?
}

check() {
  local name="${1}" file="${2}" want="${3}"
  if [[ "${__status}" -ne 0 ]]; then
    echo "FAIL ${name}: exit ${__status}" >&2
    cat "${__scratch}/err" >&2
    __failures=$((__failures + 1))
  elif ! grep --quiet --fixed-strings -- "${want}" "${__scratch}/${file}"; then
    echo "FAIL ${name}: '${want}' not in ${file}" >&2
    __failures=$((__failures + 1))
  else
    echo "ok ${name}"
  fi
}

run
check "announces the new library" out "Pre-creating the Calibre library at data/media/calibre-library..."
check "creates it with calibredb in the pinned image" log \
  "podman run --rm -v ${__scratch}/work/data/media/calibre-library:/library:z --entrypoint calibredb lscr.io/linuxserver/calibre:v8.1.0 list --library-path /library"
check "reports the library created" out "Calibre library pre-created."

mkdir -p "${__scratch}/work/data/media/calibre-library"
touch "${__scratch}/work/data/media/calibre-library/metadata.db"
run
if [[ "${__status}" -ne 0 || -s "${__scratch}/log" || -s "${__scratch}/out" ]]; then
  echo "FAIL an existing library is left alone: exit ${__status}" >&2
  __failures=$((__failures + 1))
else
  echo "ok an existing library is left alone"
fi

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
