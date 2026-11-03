# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
"""Read an app's live SQLite database through a private copy.

Opening the live file from the host, even read only, lets SQLite create the
-wal and -shm sidecars whenever the app has just removed them, owned by the
host user rather than the app's. The app then cannot open its own database:
Readarr (#305), Radarr and Lidarr (#334) answered "unable to open database
file" in the middle of CI runs exactly that way. A plain sqlite3.connect() on
a path that does not exist yet does worse, creating an empty file there,
which an app that seeds its database only when the file is missing then
never seeds. Reading a copy of the database and its write ahead log from a
temporary directory leaves the live one untouched.

The test suite (tests/conftest.py) and the scripts in this directory that
read a database while its app may be running both use it. A script's Python
runs from the repository root, so it imports this with:

    sys.path.insert(0, "scripts")
    from live_db import live_db

Writes are not for this: those stop the app first, see AGENTS.md, "Editing
runtime app state".
"""

import contextlib
import shutil
import sqlite3
import tempfile
import time
from pathlib import Path


class StillChanging(RuntimeError):
    """The database kept changing on every attempt to copy it."""


def _stamp(file):
    try:
        stat = file.stat()
    except FileNotFoundError:
        return None
    return stat.st_size, stat.st_mtime_ns


@contextlib.contextmanager
def live_db(path, attempts=20, pause=0.25):
    """A connection to a private copy of the SQLite database at `path`.

    Raises FileNotFoundError when there is no database there, rather than
    creating one.

    The rollback -journal comes along too: one an app left behind when it was
    killed mid-write holds what SQLite needs to undo that write, and without
    it the copy would show rows that were never committed.

    The files are copied one after the other, so a checkpoint in between
    would pair a database from before it with a log from after it, or with
    none. The copy is kept only when no file changed while it was taken, and
    taken again otherwise, up to `attempts` times.
    """
    path = Path(path)
    sidecars = [Path(f"{path}-wal"), Path(f"{path}-journal")]

    with tempfile.TemporaryDirectory() as tmp:
        copy = Path(tmp) / path.name
        for _ in range(attempts):
            before = [_stamp(path), *map(_stamp, sidecars)]
            shutil.copyfile(path, copy)
            for sidecar in sidecars:
                copy_sidecar = Path(tmp) / sidecar.name
                copy_sidecar.unlink(missing_ok=True)
                try:
                    shutil.copyfile(sidecar, copy_sidecar)
                except FileNotFoundError:
                    pass
            if [_stamp(path), *map(_stamp, sidecars)] == before:
                break
            time.sleep(pause)
        else:
            raise StillChanging(f"{path} kept changing while it was being copied")
        conn = sqlite3.connect(copy)
        try:
            yield conn
        finally:
            conn.close()
