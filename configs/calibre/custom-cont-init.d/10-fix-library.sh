#!/bin/sh
# The library path is overridable only so the unit tests can use a scratch one.
library="${CALIBRE_LIBRARY_DIR:-/data/media/calibre-library}"
if [ ! -d "$library" ]; then
  echo "ERROR: $library not found — data volume not mounted?" >&2
  exit 1
fi
chown -R abc:abc "$library"
exit 0
