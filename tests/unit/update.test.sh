#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for scripts/update.sh. Every line of the script has to run in one of
# them: `make coverage` runs this file under kcov and fails below 100%.
#
# The script runs through a symlink in a scratch repository, so the backup it
# finds is the scratch one. git, make and podman are stubs first on PATH,
# driven by files in a state directory: git answers from them and fails a
# subcommand when told to, make logs every target it is asked for and fails
# the ones it is told to, and podman lists the containers the state says
# exist, which the make stub swaps for the new ones when `start` runs. No
# repository is fetched, no stack is touched.

set -o errexit
set -o pipefail
set -o nounset

__script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/update.sh"
__bash="$(command -v bash)"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0
__repo="${__scratch}/repo"
__state="${__scratch}/state"
__bin="${__scratch}/bin"

stub() {
  printf '#!%s\nstate=%q\n%s\n' "${__bash}" "${__state}" "${2}" >"${__bin}/${1}"
  chmod +x "${__bin}/${1}"
}

mkdir -p "${__bin}"
stub git '
case "$1 ${2:-}" in
  "status --porcelain") cat "$state/dirty" 2>/dev/null || true ;;
  "rev-parse --abbrev-ref") [[ ! -f "$state/no-upstream" ]] && echo origin/main ;;
  "rev-parse HEAD") cat "$state/head" ;;
  "rev-parse origin/main") cat "$state/upstream" ;;
  "rev-parse --short") cut -c1-7 <<<"$3" ;;
  "fetch --quiet") [[ ! -f "$state/fetch-fails" ]] ;;
  "merge-base --is-ancestor") [[ ! -f "$state/diverged" ]] ;;
  "merge --ff-only") echo "git merge $4" >>"$state/log"; [[ ! -f "$state/merge-fails" ]] ;;
  "log -1") echo "${4:0:7} subject of ${4:0:7}" ;;
  *) echo "unexpected git $*" >&2; exit 99 ;;
esac'
stub make '
target="${2}"
echo "make ${target}" >>"$state/log"
[[ ! -f "$state/fail-${target}" ]] || exit 2
case "${target}" in
  backup-full)
    if [[ ! -f "$state/no-archive" ]]; then
      mkdir -p backup && echo archive >backup/full-1.tar.gz
    fi
    echo "Done: backup/full-1.tar.gz (4.0K)" ;;
  migrate_versions) sed -i "/^SONARR_VERSION=/d" .env ;;
  start) cp "$state/images-after" "$state/images" ;;
esac'
stub podman '
[[ "$*" == "ps --all --filter label=com.docker.compose.project=box --format {{.Names}} {{.Image}}" ]] || exit 99
cat "$state/images"'

fresh() {
  rm -rf "${__repo}" "${__state}"
  mkdir -p "${__repo}/scripts" "${__state}"
  ln -s "${__script}" "${__repo}/scripts/update.sh"
  echo aaaaaaaaaa >"${__state}/head"
  echo bbbbbbbbbb >"${__state}/upstream"
  # The old .env pins sonarr; migrate_versions clears it, so versions.env's
  # pin applies. A container reports a digest only, which the summary names
  # by tag from either file; one with no pin keeps its digest.
  printf '%s\n' "LAN_IP=192.0.2.10" "SONARR_VERSION=4.0.19@sha256:1111" >"${__repo}/.env"
  printf '%s\n' "SONARR_VERSION=4.0.20@sha256:2222" "NGINX_VERSION=stable-alpine" >"${__repo}/versions.env"
  printf '%s\n' "dev-sonarr sonarr@sha256:1111" "dev-bazarr bazarr:1.5.6" "dev-flare flare@sha256:9999" >"${__state}/images"
  printf '%s\n' "dev-sonarr sonarr@sha256:2222" "dev-bazarr bazarr:1.5.6" "dev-flare flare@sha256:8888" \
    "dev-radarr radarr:6.3.0" >"${__state}/images-after"
  : >"${__state}/log"
}

run() {
  __status=0
  PATH="${__bin}:${PATH}" RUNTIME=podman COMPOSE_PROJECT_NAME=box MAKE=make \
    "${__bash}" "${__repo}/scripts/update.sh" >"${__scratch}/out" 2>&1 || __status=$?
}

check() {
  local name="${1}" status="${2}" file="${3}" want="${4}"
  if [[ "${__status}" -ne "${status}" ]]; then
    echo "FAIL ${name}: exit ${__status}, wanted ${status}" >&2
    cat "${__scratch}/out" >&2
    __failures=$((__failures + 1))
  elif ! grep --quiet --fixed-strings -- "${want}" "${file}"; then
    echo "FAIL ${name}: '${want}' not in ${file}" >&2
    cat "${file}" >&2
    __failures=$((__failures + 1))
  else
    echo "ok ${name}"
  fi
}

refute() {
  local name="${1}" file="${2}" unwanted="${3}"
  if grep --quiet --fixed-strings -- "${unwanted}" "${file}"; then
    echo "FAIL ${name}: '${unwanted}' in ${file}" >&2
    __failures=$((__failures + 1))
  else
    echo "ok ${name}"
  fi
}

# The whole file, exactly.
same() {
  local name="${1}" file="${2}" want="${3}"
  if [[ "$(<"${file}")" != "${want}" ]]; then
    echo "FAIL ${name}: ${file} is not what was wanted" >&2
    diff <(printf '%s\n' "${want}") "${file}" >&2 || true
    __failures=$((__failures + 1))
  else
    echo "ok ${name}"
  fi
}

out="${__scratch}/out"
log="${__state}/log"

fresh
run
check "updates from one commit to the next" 0 "${out}" "Updating aaaaaaa to bbbbbbb (origin/main)."
same "runs every step in order" "${log}" "make down
make backup-full
git merge bbbbbbbbbb
make migrate_versions
make pull_docker_images
make start
make wire_connections"
check "names the old commit" 0 "${out}" "Commit: aaaaaaa subject of aaaaaaa"
check "names the new commit" 0 "${out}" "    to: bbbbbbb subject of bbbbbbb"
check "names a moved image by the tags its digests were pinned with" 0 "${out}" "  dev-sonarr: sonarr:4.0.19 -> sonarr:4.0.20"
check "keeps a digest no pin names" 0 "${out}" "  dev-flare: flare@sha256:9999 -> flare@sha256:8888"
check "lists a new container" 0 "${out}" "  dev-radarr: (new) -> radarr:6.3.0"
refute "leaves out an image that stayed" "${out}" "dev-bazarr"
check "names the backup" 0 "${out}" "Backup: backup/full-1.tar.gz"
check "prints the rollback checkout" 0 "${out}" "  git checkout --detach aaaaaaaaaa"
check "prints the rollback restore" 0 "${out}" "  make restore-configs BACKUP=backup/full-1.tar.gz"

fresh
cp "${__state}/head" "${__state}/upstream"
cp "${__state}/images" "${__state}/images-after"
run
check "runs on a commit that is already current" 0 "${out}" "(already current)"
check "says when no image moved" 0 "${out}" "Images changed: none"

fresh
echo " M Makefile" >"${__state}/dirty"
run
check "refuses local changes" 1 "${out}" "the working tree has local changes"
check "lists them" 1 "${out}" " M Makefile"
same "touches nothing on a dirty tree" "${log}" ""

fresh
touch "${__state}/no-upstream"
run
check "refuses a branch with no upstream" 1 "${out}" "follows no upstream branch"

fresh
touch "${__state}/fetch-fails"
run
check "stops when fetch fails" 1 "${out}" "git fetch failed."

fresh
touch "${__state}/diverged"
run
check "refuses a tree that cannot fast forward" 1 "${out}" "does not fast forward from here"
refute "stops before make down" "${log}" "make down"

fresh
touch "${__state}/fail-down"
run
check "stops when make down fails" 1 "${out}" "make down failed."
refute "offers no rollback before a backup exists" "${out}" "restore-configs"

fresh
touch "${__state}/fail-backup-full"
run
check "stops when the backup fails" 1 "${out}" "the backup failed, so nothing was updated"
refute "does not pull after a failed backup" "${log}" "git merge"

fresh
touch "${__state}/no-archive"
run
check "stops when the backup names no archive" 1 "${out}" "make backup-full reported no archive"

fresh
touch "${__state}/merge-fails"
run
check "stops when git cannot fast forward" 1 "${out}" "git could not fast forward to origin/main."
check "offers the rollback once a backup exists" 1 "${out}" "make restore-configs BACKUP=backup/full-1.tar.gz"

fresh
touch "${__state}/fail-migrate_versions"
run
check "stops when the migration fails" 1 "${out}" "make migrate_versions failed."

fresh
touch "${__state}/fail-pull_docker_images"
run
check "stops when the image pull fails" 1 "${out}" "make pull_docker_images failed."

fresh
touch "${__state}/fail-start"
run
check "stops when the start fails" 1 "${out}" "make start failed."
check "says the update stopped partway" 1 "${out}" "The update stopped partway."
check "rolls back to the commit it started on" 1 "${out}" "git checkout --detach aaaaaaaaaa"
refute "does not wire after a failed start" "${log}" "make wire_connections"

fresh
touch "${__state}/fail-wire_connections"
run
check "stops when wiring fails" 1 "${out}" "make wire_connections failed."

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
