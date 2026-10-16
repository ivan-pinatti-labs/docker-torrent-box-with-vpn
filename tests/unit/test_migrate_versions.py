"""Unit tests for scripts/migrate-versions.py.

The script's .env and versions.env are pointed at tmp_path, so the checkout's
own files are never read or written.
"""

import os
import stat

import pytest

pytestmark = pytest.mark.unit

VERSIONS = """\
# renovate: depName=docker.io/linuxserver/sonarr
SONARR_VERSION=4.0.20@sha256:aaaa
# renovate: depName=docker.io/linuxserver/bazarr
BAZARR_VERSION=1.6.1@sha256:bbbb
NGINX_VERSION=stable-alpine
"""

# An .env seeded from the old .env.example: settings, then the pins block.
OLD_ENV = """\
LAN_IP=192.168.1.20
PYTHON_VERSION=3.14
### VERSIONS
# renovate: depName=docker.io/linuxserver/sonarr
SONARR_VERSION=4.0.19@sha256:cccc
# hold: waiting on a plugin
BAZARR_VERSION=1.5.6@sha256:dddd
NGINX_VERSION=stable-alpine
RETIRED_VERSION=1.0
"""


@pytest.fixture
def migrate(load_script, tmp_path, monkeypatch):
    module = load_script("migrate-versions.py")
    monkeypatch.setattr(module, "ENV_FILE", tmp_path / ".env")
    monkeypatch.setattr(module, "VERSIONS_FILE", tmp_path / "versions.env")
    (tmp_path / "versions.env").write_text(VERSIONS)
    return module


def test_clears_stale_and_unchanged_pins_and_keeps_holds(migrate, tmp_path, capsys):
    env = tmp_path / ".env"
    env.write_text(OLD_ENV)
    env.chmod(0o600)

    assert migrate.main([]) == 0

    assert env.read_text() == (
        "LAN_IP=192.168.1.20\n"
        "PYTHON_VERSION=3.14\n"
        "### VERSIONS\n"
        "# hold: waiting on a plugin\n"
        "BAZARR_VERSION=1.5.6@sha256:dddd\n"
        "RETIRED_VERSION=1.0\n"
    )
    assert stat.S_IMODE(env.stat().st_mode) == 0o600
    backups = list(tmp_path.glob(".env.backup.*"))
    assert len(backups) == 1
    assert backups[0].read_text() == OLD_ENV
    out = capsys.readouterr().out
    assert "Cleared 2 image pin(s) from .env" in out
    assert "SONARR_VERSION: 4.0.19, removed, versions.env has 4.0.20" in out
    assert "BAZARR_VERSION: 1.5.6, held (versions.env has 1.6.1)" in out
    assert "NGINX_VERSION: stable-alpine, removed, same as versions.env" in out
    assert f"The previous .env is at {backups[0].name}." in out


def test_a_second_run_finds_only_the_hold(migrate, tmp_path, capsys):
    (tmp_path / ".env").write_text(OLD_ENV)
    migrate.main([])
    capsys.readouterr()

    assert migrate.main([]) == 0

    out = capsys.readouterr().out
    assert ".env holds 1 image pin(s) back on purpose:" in out
    assert len(list(tmp_path.glob(".env.backup.*"))) == 1


def test_check_reports_and_changes_nothing(migrate, tmp_path, capsys):
    env = tmp_path / ".env"
    env.write_text(OLD_ENV)

    assert migrate.main(["--check"]) == 0

    assert env.read_text() == OLD_ENV
    assert not list(tmp_path.glob(".env.backup.*"))
    out = capsys.readouterr().out
    assert "NOTICE: .env still pins 2 image(s), which override versions.env:" in out
    assert "SONARR_VERSION: 4.0.19, would remove, versions.env has 4.0.20" in out
    assert "Run 'make migrate_versions'" in out


def test_check_is_silent_without_pins(migrate, tmp_path, capsys):
    (tmp_path / ".env").write_text("LAN_IP=192.168.1.20\n")

    assert migrate.main(["--check"]) == 0

    assert capsys.readouterr().out == ""


def test_says_so_when_there_is_nothing_to_migrate(migrate, tmp_path, capsys):
    env = tmp_path / ".env"
    env.write_text("LAN_IP=192.168.1.20")

    assert migrate.main([]) == 0

    assert env.read_text() == "LAN_IP=192.168.1.20"
    assert "carries no image pins" in capsys.readouterr().out


def test_keeps_a_missing_final_newline_missing(migrate, tmp_path):
    env = tmp_path / ".env"
    env.write_text("SONARR_VERSION=4.0.19\nLAN_IP=192.168.1.20")

    migrate.main([])

    assert env.read_text() == "LAN_IP=192.168.1.20"


def test_a_pin_on_the_first_line_has_nothing_above_it(migrate, tmp_path):
    env = tmp_path / ".env"
    env.write_text("SONARR_VERSION=4.0.19\n")

    migrate.main([])

    assert env.read_text() == ""


def test_an_empty_pin_reads_as_empty(migrate, tmp_path, capsys):
    (tmp_path / ".env").write_text("SONARR_VERSION=\n")

    migrate.main([])

    assert "SONARR_VERSION: (empty), removed" in capsys.readouterr().out


def test_names_a_digest_only_change(migrate, tmp_path, capsys):
    (tmp_path / ".env").write_text("SONARR_VERSION=4.0.20@sha256:eeee\n")

    migrate.main([])

    assert (
        "SONARR_VERSION: 4.0.20, removed, versions.env pins that tag to another digest"
        in capsys.readouterr().out
    )


def test_no_env_yet(migrate, capsys):
    assert migrate.main([]) == 0

    assert "No .env yet" in capsys.readouterr().out


def test_refuses_without_versions_env(migrate, tmp_path, capsys):
    (tmp_path / "versions.env").unlink()

    assert migrate.main([]) == 1

    assert "versions.env not found" in capsys.readouterr().err


def test_a_failed_write_leaves_env_and_no_temporary_file(
    migrate, tmp_path, monkeypatch
):
    env = tmp_path / ".env"
    env.write_text(OLD_ENV)

    def refuse(*_):
        raise OSError("disk full")

    monkeypatch.setattr(migrate.os, "replace", refuse)
    with pytest.raises(OSError, match="disk full"):
        migrate.main([])

    assert env.read_text() == OLD_ENV
    leftovers = [name for name in os.listdir(tmp_path) if name.startswith(".env.")]
    assert [name for name in leftovers if not name.startswith(".env.backup.")] == []
