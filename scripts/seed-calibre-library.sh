#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
set -euo pipefail

# Usage: ./scripts/seed-calibre-library.sh
#
# Pre-creates a valid, empty Calibre library at data/media/calibre-library
# before any container ever starts, using a throwaway container running
# calibredb (the same image the real calibre/calibre-web containers use).
#
# Calibre's desktop GUI auto-opens its configured library immediately on
# container boot; on a fresh bootstrap, that means it's the one creating
# metadata.db for the very first time, in-process, at the same moment the
# container's own startup scripts are still running. That's a real reported
# failure mode ("library database appears to be corrupted" on first login),
# not reproduced via any headless check afterward (calibredb, SQLite
# integrity, Calibre-Web's own dbconfig page all show a healthy library
# once things settle), consistent with a narrow first-open race rather than
# lasting damage. Pre-creating the library here removes that race entirely:
# by the time the real container starts, metadata.db already exists and is
# already valid, so its own first open is just a normal, existing-library
# open, not a first-ever creation.
#
# Skips entirely if metadata.db already exists, so this is a no-op on every
# run after the first.

readonly LIBRARY_DIR="data/media/calibre-library"

if [[ -f "${LIBRARY_DIR}/metadata.db" ]]; then
  exit 0
fi

# The pin .env holds back on purpose if there is one, else the committed one
# in versions.env (see its header).
CALIBRE_VERSION="$(awk -F= '$1 == "CALIBRE_VERSION" { sub(/^[^=]*=/, ""); print; exit }' .env versions.env)"
readonly CALIBRE_VERSION

echo "Pre-creating the Calibre library at ${LIBRARY_DIR}..."
# The same reference docker-compose-media-library.yml runs, so the image this
# pulls is the one the stack starts later, and no second registry is involved.
# It came from lscr.io before; a pull from there that hung for 15 minutes
# ended a CI run (#305).
podman run --rm -v "$(pwd)/${LIBRARY_DIR}:/library:z" --entrypoint calibredb \
  "docker.io/linuxserver/calibre:${CALIBRE_VERSION}" list --library-path /library >/dev/null
echo "Calibre library pre-created."
