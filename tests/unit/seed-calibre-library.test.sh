#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for scripts/seed-calibre-library.sh. Every line of the script has to
# run in one of them: `make coverage` runs this file under kcov and fails
# below 100%.
#
# The script works in the current directory, so each case runs in a scratch
# directory holding its own .env, data/ and configs/. podman is a stub on PATH
# that records how it was called and reports the container named in
# STUB_RUNNING as running, so no image is pulled and no container runs.

set -o errexit
set -o pipefail
set -o nounset

__script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/seed-calibre-library.sh"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0
readonly LIBRARY="data/media/calibre-library"
readonly DB_DIR="configs/calibre/library-db"

mkdir "${__scratch}/bin" "${__scratch}/work"
cat >"${__scratch}/bin/podman" <<EOF
#!$(command -v bash)
echo "podman \$*" >>"${__scratch}/log"
if [[ "\$1 \$2" == "container inspect" && -n "\${STUB_RUNNING:-}" && "\${*: -1}" == "\${STUB_RUNNING}" ]]; then
  echo true
fi
EOF
chmod +x "${__scratch}/bin/podman"
sed 's/^echo "podman /echo "docker /' "${__scratch}/bin/podman" >"${__scratch}/bin/docker"
chmod +x "${__scratch}/bin/docker"
echo "CALIBRE_VERSION=v8.1.0" >"${__scratch}/work/.env"

run() {
  rm -f "${__scratch}/log"
  touch "${__scratch}/log"
  __status=0
  (cd "${__scratch}/work" && PATH="${__scratch}/bin:${PATH}" bash "${__script}") \
    >"${__scratch}/out" 2>"${__scratch}/err" || __status=$?
}

fail() {
  echo "FAIL ${1}" >&2
  __failures=$((__failures + 1))
}

# check <name> <status> <file> <text>
check() {
  local name="${1}" want_status="${2}" file="${3}" want="${4}"
  if [[ "${__status}" -ne "${want_status}" ]]; then
    fail "${name}: exit ${__status}, wanted ${want_status}"
    cat "${__scratch}/err" >&2
  elif ! grep --quiet --fixed-strings -- "${want}" "${__scratch}/${file}"; then
    fail "${name}: '${want}' not in ${file}"
  else
    echo "ok ${name}"
  fi
}

# A library from before #402: a real, empty SQLite metadata.db among the books.
old_library() {
  rm -rf "${__scratch}/work/data" "${__scratch}/work/configs"
  mkdir -p "${__scratch}/work/${LIBRARY}/Author/Book (1)"
  python3 -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute("CREATE TABLE books (id INTEGER)"); c.commit()' \
    "${__scratch}/work/${LIBRARY}/metadata.db"
}

run
check "announces the new library" 0 out \
  "Pre-creating the Calibre library at ${LIBRARY}, with its database in ${DB_DIR}..."
check "creates it with calibredb in the pinned image, the database apart" 0 log \
  "podman run --rm -v ${__scratch}/work/${LIBRARY}:/library:z -v ${__scratch}/work/${DB_DIR}:/calibre-db:z -e CALIBRE_OVERRIDE_DATABASE_PATH=/calibre-db/metadata.db --entrypoint calibredb docker.io/linuxserver/calibre:v8.1.0 list --library-path /library"
check "reports the library created" 0 out "Calibre library pre-created."
[[ -d "${__scratch}/work/${DB_DIR}" ]] || fail "makes the database folder"

# A .env with no pin of its own takes the committed one, and a hold in .env
# wins over it.
echo "CALIBRE_VERSION=v9.0.0" >"${__scratch}/work/versions.env"
echo "LAN_IP=192.168.1.20" >"${__scratch}/work/.env"
run
check "takes the pin from versions.env" 0 log "docker.io/linuxserver/calibre:v9.0.0 list"
printf '%s\n' "# hold: testing" "CALIBRE_VERSION=v8.1.0" >"${__scratch}/work/.env"
run
check "lets a pin in .env override versions.env" 0 log "docker.io/linuxserver/calibre:v8.1.0 list"

# The database already where it belongs: nothing to do, whatever else is there.
old_library
mkdir -p "${__scratch}/work/${DB_DIR}"
echo local >"${__scratch}/work/${DB_DIR}/metadata.db"
run
if [[ "${__status}" -ne 0 || -s "${__scratch}/log" || -s "${__scratch}/out" ]]; then
  fail "an existing database is left alone: exit ${__status}"
elif [[ "$(cat "${__scratch}/work/${DB_DIR}/metadata.db")" != local || ! -f "${__scratch}/work/${LIBRARY}/metadata.db" ]]; then
  fail "an existing database is never overwritten"
else
  echo "ok an existing database is left alone"
fi

# An install from before #402 has its database moved, and the original kept.
old_library
touch -d "2020-01-02 03:04:05" "${__scratch}/work/${LIBRARY}/metadata.db"
cp "${__scratch}/work/${LIBRARY}/metadata.db" "${__scratch}/expected.db"
run
check "moves an old library's database" 0 out "Moving the Calibre library's metadata.db to ${DB_DIR}..."
check "says where the original went" 0 out "The original is kept as ${LIBRARY}/metadata.db.on-share-"
check "asks whether the containers run" 0 log "podman container inspect -f {{.State.Running}} calibre-web"
cmp -s "${__scratch}/expected.db" "${__scratch}/work/${DB_DIR}/metadata.db" || fail "the moved database is the original"
[[ "$(stat -c %Y "${__scratch}/work/${DB_DIR}/metadata.db")" == "$(date -d "2020-01-02 03:04:05" +%s)" ]] ||
  fail "the move keeps the timestamps"
[[ ! -e "${__scratch}/work/${LIBRARY}/metadata.db" ]] || fail "the original is renamed aside"
compgen -G "${__scratch}/work/${LIBRARY}/metadata.db.on-share-*" >/dev/null || fail "the original is kept"
[[ ! -e "${__scratch}/work/${DB_DIR}/metadata.db.partial" ]] || fail "no partial copy is left"

# Not while either app may be writing it, under the configured prefix.
old_library
printf '%s\n' "CALIBRE_VERSION=v8.1.0" "CONTAINER_PREFIX=dev-" >"${__scratch}/work/.env"
STUB_RUNNING=dev-calibre run
check "refuses while calibre runs" 1 err "ERROR: calibre is running, so ${LIBRARY}/metadata.db cannot be moved to ${DB_DIR}."
check "says how to get past it" 1 err "Run 'make down', then 'make start' again."
[[ -f "${__scratch}/work/${LIBRARY}/metadata.db" && ! -e "${__scratch}/work/${DB_DIR}/metadata.db" ]] ||
  fail "a refused move changes nothing"
echo "CALIBRE_VERSION=v8.1.0" >"${__scratch}/work/.env"

# Nor with a journal or log beside it, which may hold an unfinished write.
for sidecar in journal wal; do
  old_library
  touch "${__scratch}/work/${LIBRARY}/metadata.db-${sidecar}"
  run
  check "refuses beside a -${sidecar}" 1 err "ERROR: ${LIBRARY}/metadata.db-${sidecar} exists"
done

# A copy that does not check out is thrown away, and the original stays.
old_library
echo "not a database" >"${__scratch}/work/${LIBRARY}/metadata.db"
run
check "refuses a database that fails its integrity check" 1 err \
  "ERROR: the copy of ${LIBRARY}/metadata.db did not check out; nothing was changed."
[[ -f "${__scratch}/work/${LIBRARY}/metadata.db" && ! -e "${__scratch}/work/${DB_DIR}/metadata.db" &&
  ! -e "${__scratch}/work/${DB_DIR}/metadata.db.partial" ]] || fail "a failed check changes nothing"

# The folders come from .env, as compose reads them: a library under another
# DATA_FOLDER is the one moved, into the database folder under CONFIG_FOLDER.
old_library
mkdir -p "${__scratch}/work/elsewhere/media"
mv "${__scratch}/work/data/media/calibre-library" "${__scratch}/work/elsewhere/media/"
printf '%s\n' "CALIBRE_VERSION=v8.1.0" "DATA_FOLDER=./elsewhere" "CONFIG_FOLDER=./cfg" >"${__scratch}/work/.env"
run
check "moves the library under DATA_FOLDER" 0 out \
  "Moving the Calibre library's metadata.db to cfg/calibre/library-db..."
[[ -f "${__scratch}/work/cfg/calibre/library-db/metadata.db" ]] || fail "the database lands under CONFIG_FOLDER"
rm -rf "${__scratch}/work/elsewhere" "${__scratch}/work/cfg"

# The runtime make passes, and an absolute DATA_FOLDER mounted as it is.
printf '%s\n' "CALIBRE_VERSION=v8.1.0" "DATA_FOLDER=${__scratch}/abs" >"${__scratch}/work/.env"
rm -f "${__scratch}/log"
touch "${__scratch}/log"
__status=0
(cd "${__scratch}/work" && PATH="${__scratch}/bin:${PATH}" RUNTIME=docker bash "${__script}") \
  >"${__scratch}/out" 2>"${__scratch}/err" || __status=$?
check "creates the library with the runtime make passes" 0 log \
  "docker run --rm -v ${__scratch}/abs/media/calibre-library:/library:z -v ${__scratch}/work/configs/calibre/library-db:/calibre-db:z"
echo "CALIBRE_VERSION=v8.1.0" >"${__scratch}/work/.env"

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
