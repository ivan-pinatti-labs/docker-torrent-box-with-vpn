"""Unit tests for scripts/readarr-add-comic-profile.py.

Each test builds a throwaway SQLite database holding only the three tables the
script touches, with the columns it names, and points the script at it.
Readarr's own database is never opened.
"""

import json
import sqlite3

import pytest

pytestmark = pytest.mark.unit

SCHEMA = """
CREATE TABLE QualityProfiles (
    Id INTEGER PRIMARY KEY, Name TEXT, Cutoff INTEGER, Items TEXT,
    UpgradeAllowed INTEGER, FormatItems TEXT, MinFormatScore INTEGER,
    CutoffFormatScore INTEGER
);
CREATE TABLE CustomFormats (
    Id INTEGER PRIMARY KEY, Name TEXT, Specifications TEXT,
    IncludeCustomFormatWhenRenaming INTEGER
);
CREATE TABLE RootFolders (
    Id INTEGER PRIMARY KEY, Path TEXT, DefaultQualityProfileId INTEGER
);
"""


@pytest.fixture
def database(tmp_path):
    path = tmp_path / "readarr.db"
    con = sqlite3.connect(path)
    con.executescript(SCHEMA)
    con.commit()
    con.close()
    return path


@pytest.fixture
def readarr(load_script, database, monkeypatch):
    module = load_script("readarr-add-comic-profile.py")
    monkeypatch.setattr(module, "DB", database)
    return module


def _query(database, sql):
    con = sqlite3.connect(database)
    try:
        return con.execute(sql).fetchall()
    finally:
        con.close()


def _seed(database, sql):
    con = sqlite3.connect(database)
    con.execute(sql)
    con.commit()
    con.close()


def test_reads_the_database_path_from_the_environment(load_script, monkeypatch):
    monkeypatch.setenv("READARR_DB", "/elsewhere/readarr.db")
    assert (
        str(load_script("readarr-add-comic-profile.py").DB) == "/elsewhere/readarr.db"
    )


def test_refuses_a_missing_database(readarr, tmp_path, monkeypatch):
    monkeypatch.setattr(readarr, "DB", tmp_path / "absent.db")
    with pytest.raises(SystemExit) as exit_info:
        readarr.main()
    assert "Database not found" in str(exit_info.value)


def test_skips_when_the_profile_already_exists(readarr, database, capsys):
    _seed(database, "INSERT INTO QualityProfiles (Id, Name) VALUES (7, 'Comic')")
    readarr.main()
    assert "already exists (id=7), skipping" in capsys.readouterr().out
    assert _query(database, "SELECT COUNT(*) FROM CustomFormats") == [(0,)]


def test_adds_the_profile_formats_and_root_folder(readarr, database, capsys):
    _seed(database, "INSERT INTO CustomFormats (Id, Name) VALUES (3, 'CBZ')")
    _seed(
        database,
        "INSERT INTO RootFolders (Path, DefaultQualityProfileId) "
        "VALUES ('/data/media/comics/', 1)",
    )
    readarr.main()
    out = capsys.readouterr().out
    assert "Inserted quality profile 'Comic'" in out
    assert "Custom format 'CBZ' already exists (id=3), skipping." in out
    assert "Inserted custom format 'CBR'" in out
    assert "Updated comics root folder" in out
    assert out.rstrip().endswith("Done.")

    ((profile_id, items),) = _query(
        database, "SELECT Id, Items FROM QualityProfiles WHERE Name = 'Comic'"
    )
    assert json.loads(items)[0] == {"quality": 0, "items": [], "allowed": True}
    assert _query(database, "SELECT Name FROM CustomFormats ORDER BY Id") == [
        ("CBZ",),
        ("CBR",),
    ]
    assert _query(database, "SELECT DefaultQualityProfileId FROM RootFolders") == [
        (profile_id,)
    ]


def test_warns_when_the_comics_root_folder_is_missing(readarr, database, capsys):
    readarr.main()
    out = capsys.readouterr().out
    assert "Inserted custom format 'CBZ'" in out
    assert "root folder '/data/media/comics/' not found" in out
    assert _query(database, "SELECT COUNT(*) FROM QualityProfiles") == [(1,)]
