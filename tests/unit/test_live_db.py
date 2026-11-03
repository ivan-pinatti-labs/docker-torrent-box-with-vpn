"""Unit tests for scripts/live_db.py.

Every database here is a throwaway one in the test's temporary directory,
made the way the apps make theirs: in write ahead log mode, sometimes with a
writer still holding it open.
"""

# cspell:ignore autocheckpoint

import os
import shutil
import sqlite3

import pytest

pytestmark = pytest.mark.unit


@pytest.fixture
def module(load_script):
    return load_script("live_db.py")


def wal_database(path, rows):
    """A WAL mode database holding `rows`, its writer closed."""
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("CREATE TABLE t (v TEXT)")
    conn.executemany("INSERT INTO t VALUES (?)", [(r,) for r in rows])
    conn.commit()
    conn.close()


def test_reads_a_closed_wal_database_without_leaving_sidecars(module, tmp_path):
    # The case behind #305 and #334: the app has just closed its database and
    # SQLite removed -wal and -shm. Opening the live file here, even read
    # only, would make them again, owned by whoever opened it.
    db = tmp_path / "radarr.db"
    wal_database(db, ["a"])
    assert sorted(p.name for p in tmp_path.iterdir()) == ["radarr.db"]

    with module.live_db(db) as conn:
        assert conn.execute("SELECT v FROM t").fetchall() == [("a",)]
        assert sorted(p.name for p in tmp_path.iterdir()) == ["radarr.db"]
    assert sorted(p.name for p in tmp_path.iterdir()) == ["radarr.db"]


def test_reads_what_is_only_in_the_write_ahead_log(module, tmp_path):
    db = tmp_path / "sonarr.db"
    wal_database(db, ["a"])
    writer = sqlite3.connect(db)
    try:
        writer.execute("PRAGMA wal_autocheckpoint = 0")
        writer.execute("INSERT INTO t VALUES ('b')")
        writer.commit()
        assert (tmp_path / "sonarr.db-wal").stat().st_size > 0

        with module.live_db(db) as conn:
            assert conn.execute("SELECT v FROM t ORDER BY v").fetchall() == [
                ("a",),
                ("b",),
            ]
    finally:
        writer.close()


def test_a_missing_database_is_not_created(module, tmp_path):
    db = tmp_path / "app.db"
    with pytest.raises(FileNotFoundError), module.live_db(db):
        pass
    assert not db.exists()


def test_a_copy_taken_while_the_file_changed_is_taken_again(
    module, tmp_path, monkeypatch
):
    db = tmp_path / "mylar.db"
    wal_database(db, ["a"])
    copy = shutil.copyfile
    calls = []

    def copy_then_touch(src, dst):
        calls.append(src)
        result = copy(src, dst)
        if len(calls) == 1:
            # A write landing between the database and its log.
            stat = db.stat()
            os.utime(db, ns=(stat.st_atime_ns, stat.st_mtime_ns + 1_000_000))
        return result

    pauses = []
    monkeypatch.setattr(module.shutil, "copyfile", copy_then_touch)
    monkeypatch.setattr(module.time, "sleep", pauses.append)
    with module.live_db(db, pause=0.5) as conn:
        assert conn.execute("SELECT v FROM t").fetchall() == [("a",)]
    assert pauses == [0.5]
    assert calls.count(db) == 2


def test_a_database_that_never_holds_still_is_an_error(module, tmp_path, monkeypatch):
    db = tmp_path / "lidarr.db"
    wal_database(db, ["a"])
    copy = shutil.copyfile

    def copy_then_touch(src, dst):
        result = copy(src, dst)
        stat = db.stat()
        os.utime(db, ns=(stat.st_atime_ns, stat.st_mtime_ns + 1_000_000))
        return result

    pauses = []
    monkeypatch.setattr(module.shutil, "copyfile", copy_then_touch)
    monkeypatch.setattr(module.time, "sleep", pauses.append)
    with (
        pytest.raises(module.StillChanging, match="kept changing"),
        module.live_db(db, attempts=3),
    ):
        pass
    assert pauses == [0.25] * 3
