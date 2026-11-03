#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
set -euo pipefail

# Usage: ./scripts/seed-calibre-library.sh
#
# Makes sure the Calibre library has its metadata.db in DB_DIR, on local
# storage, with the books in LIBRARY_DIR under data/. Calibre and Calibre-Web
# find it there through CALIBRE_OVERRIDE_DATABASE_PATH and Calibre-Web's split
# library settings. data/ can be a CIFS share, and SMB refuses the lock
# upgrade SQLite needs for every commit, so a metadata.db there could be read
# but never written again (#402).
#
# Three cases, run before any calibre container starts (`make seed_all` and
# `make start`):
#
# - DB_DIR/metadata.db exists: nothing to do, on every run after the first.
# - Only LIBRARY_DIR/metadata.db exists, an install from before #402: copy it
#   into DB_DIR, check the copy, and rename the original aside rather than
#   delete it. Refuses while calibre or calibre-web runs, since either may be
#   writing it, and never overwrites a database already in DB_DIR.
# - Neither exists: pre-create an empty library with calibredb, in the same
#   image the stack runs. Calibre's GUI opens its library the moment the
#   container boots, and creating metadata.db for the first time in-process,
#   while the container's own startup scripts are still running, was a real
#   "library database appears to be corrupted" on first login. With the
#   database already there, its first open is a normal one.

# One key from .env, else from versions.env (the pin .env holds back on
# purpose, if there is one; see the header of versions.env), read the way
# compose reads it: whitespace (a CRLF file's carriage return too) around the
# key and the value dropped, the quotes around a quoted value dropped, a
# " # comment" after an unquoted one dropped, and the last assignment in each
# file winning, as it does for compose and make. The program is a here
# document because kcov counts each line of a multi line quoted argument as
# a command that never runs.
env_value() {
  # Only the files that are there: some awk builds stop at a missing one before END.
  local files=() file
  for file in .env versions.env; do
    [[ -f "$file" ]] && files+=("$file")
  done
  [[ ${#files[@]} -gt 0 ]] || return 0
  awk -F= -v key="$1" -f /dev/stdin "${files[@]}" <<'AWK'
{
  name = $1
  gsub(/^[ \t\r]+|[ \t\r]+$/, "", name)
}
name == key {
  sub(/^[^=]*=/, "")
  gsub(/^[ \t\r]+|[ \t\r]+$/, "")
  if (/^"/) {
    sub(/^"/, ""); sub(/".*$/, "")
  } else if (/^'/) {
    sub(/^'/, ""); sub(/'.*$/, "")
  } else {
    sub(/[ \t]+#.*$/, "")
  }
  if (FILENAME == ".env") {
    from_env = $0; in_env = 1
  } else {
    from_versions = $0; in_versions = 1
  }
}
END {
  if (in_env) print from_env
  else if (in_versions) print from_versions
}
AWK
}

# The folders compose mounts, read the way compose reads them: the
# environment first, then .env. A moved DATA_FOLDER moves the library this
# looks at too. A value holding a $ reference compose would expand, braced or
# not, or a backslash escape, is refused rather than taken literally, which
# would seed a folder nothing mounts. Make passes RUNTIME.
data_folder="${DATA_FOLDER:-$(env_value DATA_FOLDER)}"
config_folder="${CONFIG_FOLDER:-$(env_value CONFIG_FOLDER)}"
data_folder="${data_folder:-./data}"
config_folder="${config_folder:-./configs}"
for folder in "$data_folder" "$config_folder"; do
  if [[ "$folder" == *'$'* || "$folder" == *\\* ]]; then
    echo "ERROR: ${folder} holds a \$ reference or a backslash escape; set DATA_FOLDER and CONFIG_FOLDER to plain paths." >&2
    exit 1
  fi
done
readonly LIBRARY_DIR="${data_folder#./}/media/calibre-library"
readonly DB_DIR="${config_folder#./}/calibre/library-db"
readonly RUNTIME="${RUNTIME:-podman}"

# An absolute path for a bind mount.
absolute() {
  case "$1" in
  /*) printf '%s' "$1" ;;
  *) printf '%s/%s' "$(pwd)" "$1" ;;
  esac
}

# Prints true or false for a container that exists, missing for one that does
# not, and the runtime's own error otherwise: a check that failed is not a
# container that stopped. The name takes CONTAINER_PREFIX from the
# environment before .env, as compose does.
container_state() {
  local out
  if out="$("$RUNTIME" container inspect -f '{{.State.Running}}' "${CONTAINER_PREFIX-$(env_value CONTAINER_PREFIX)}$1" 2>&1)"; then
    printf '%s' "$out"
  elif [[ "$out" == *[Nn]"o such container"* ]]; then
    printf missing
  else
    printf '%s' "${out:-no output}"
  fi
}

integrity() {
  python3 -I -c 'import sqlite3, sys; print(sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True).execute("PRAGMA integrity_check").fetchone()[0])' "$1"
}

if [[ -f "${DB_DIR}/metadata.db" ]]; then
  exit 0
fi
mkdir -p "$LIBRARY_DIR" "$DB_DIR"

if [[ -f "${LIBRARY_DIR}/metadata.db" ]]; then
  for app in calibre calibre-web; do
    state="$(container_state "$app")"
    case "$state" in
    false | missing) : ;;
    true)
      echo "ERROR: ${app} is running, so ${LIBRARY_DIR}/metadata.db cannot be moved to ${DB_DIR}." >&2
      echo "Run 'make down', then 'make start' again." >&2
      exit 1
      ;;
    *)
      echo "ERROR: could not tell whether ${app} is running (${state}), so ${LIBRARY_DIR}/metadata.db was not moved." >&2
      exit 1
      ;;
    esac
  done
  for sidecar in "${LIBRARY_DIR}/metadata.db-journal" "${LIBRARY_DIR}/metadata.db-wal"; do
    if [[ -e "$sidecar" ]]; then
      echo "ERROR: ${sidecar} exists, so the database may hold an unfinished write. Move it aside by hand once Calibre has been closed cleanly." >&2
      exit 1
    fi
  done
  echo "Moving the Calibre library's metadata.db to ${DB_DIR}..."
  cp -p "${LIBRARY_DIR}/metadata.db" "${DB_DIR}/metadata.db.partial"
  if ! cmp -s "${LIBRARY_DIR}/metadata.db" "${DB_DIR}/metadata.db.partial" ||
    [[ "$(integrity "${DB_DIR}/metadata.db.partial")" != ok ]]; then
    rm -f "${DB_DIR}/metadata.db.partial"
    echo "ERROR: the copy of ${LIBRARY_DIR}/metadata.db did not check out; nothing was changed." >&2
    exit 1
  fi
  mv "${DB_DIR}/metadata.db.partial" "${DB_DIR}/metadata.db"
  aside="${LIBRARY_DIR}/metadata.db.on-share-$(date +%Y%m%d%H%M%S)"
  mv "${LIBRARY_DIR}/metadata.db" "$aside"
  echo "Moved. The original is kept as ${aside}; delete it once the library looks right."
  echo "Run 'make wire_connections' once the stack is up, so Calibre-Web looks for the database there too."
  exit 0
fi

CALIBRE_VERSION="$(env_value CALIBRE_VERSION)"
readonly CALIBRE_VERSION

echo "Pre-creating the Calibre library at ${LIBRARY_DIR}, with its database in ${DB_DIR}..."
# The same reference docker-compose-media-library.yml runs, so the image this
# pulls is the one the stack starts later, and no second registry is involved.
# It came from lscr.io before; a pull from there that hung for 15 minutes
# ended a CI run (#305).
"$RUNTIME" run --rm -v "$(absolute "$LIBRARY_DIR"):/library:z" -v "$(absolute "$DB_DIR"):/calibre-db:z" \
  -e CALIBRE_OVERRIDE_DATABASE_PATH=/calibre-db/metadata.db --entrypoint calibredb \
  "docker.io/linuxserver/calibre:${CALIBRE_VERSION}" list --library-path /library >/dev/null
echo "Calibre library pre-created."
