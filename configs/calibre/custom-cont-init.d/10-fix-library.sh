#!/bin/sh
# The paths are overridable only so the unit tests can use scratch ones.
library="${CALIBRE_LIBRARY_DIR:-/data/media/calibre-library}"
database="${CALIBRE_DB_DIR:-/calibre-db}"
if [ ! -d "$library" ]; then
  echo "ERROR: $library not found — data volume not mounted?" >&2
  exit 1
fi
chown -R abc:abc "$library"
# metadata.db lives here rather than in the library (#402).
if [ -d "$database" ]; then
  chown -R abc:abc "$database"
fi
exit 0
