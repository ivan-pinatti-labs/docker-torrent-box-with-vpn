import os
import subprocess
import tarfile
from pathlib import Path

REPO_ROOT = Path(__file__).parent.parent
MAKEFILE = REPO_ROOT / "Makefile"


def _write(path: Path, content: str = "x") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def _fixture(root: Path) -> None:
    # The Makefile's `include .env certs/cert.conf` (see its own comment)
    # makes GNU Make check both files' .example prerequisites on *every*
    # invocation, even though both are already written below: an existing
    # target still needs its prerequisite present to confirm freshness, or
    # Make fails immediately with "No rule to make target '.env.example'"
    # before backup-configs/restore-configs ever runs.
    _write(root / ".env.example", "APP_ENV=fixture\n")
    # Included ahead of .env, and committed, so it has no rule to make it.
    _write(root / "versions.env", "FIXTURE_VERSION=1.0\n")
    _write(root / "certs/cert.conf.example", "CERT_FQDN=fixture.local\n")
    _write(root / ".env", "APP_ENV=fixture\n")
    _write(root / "certs/cert.conf", "CERT_FQDN=fixture.local\n")
    _write(root / "certs/server.crt", "certificate\n")
    _write(root / "certs/server.key", "private-key\n")

    _write(root / "configs/lidarr/config/config.xml", "<Config />\n")
    _write(root / "configs/lidarr/config/lidarr.db", "primary database\n")
    _write(root / "configs/lidarr/config/lidarr.db-wal", "wal\n")
    _write(root / "configs/lidarr/config/lidarr.db-shm", "shm\n")
    _write(root / "configs/lidarr/config/logs.db", "log database\n")
    _write(root / "configs/lidarr/config/logs/lidarr.log", "log\n")
    _write(root / "configs/lidarr/config/asp/key.xml", "data protection key\n")
    # Legacy in-configs locations. Cover art and scheduled backups now live
    # under data/ (MEDIA_COVERS_FOLDER, APP_BACKUPS_FOLDER), but the Makefile
    # keeps these excludes for setups predating that move, so they stay covered.
    _write(root / "configs/lidarr/config/MediaCover/1/poster.jpg", "artwork\n")
    _write(root / "configs/lidarr/config/Backups/scheduled/backup.zip", "zip\n")
    # Current locations. Neither backup mode may ever archive these: the
    # scheduled backups in particular can run to hundreds of MiB.
    _write(root / "data/media/covers/lidarr/1/poster.jpg", "artwork\n")
    _write(root / "data/backups/lidarr/scheduled/backup.zip", "zip\n")
    _write(root / "configs/lidarr/config/Sentry/event.json", "{}\n")
    _write(root / "configs/whisparr/config.bak/asp/key.xml", "legacy key\n")
    _write(root / "configs/whisparr/config.v2.bak/asp/key.xml", "legacy key\n")

    _write(root / "configs/jellyfin/config/network.xml", "<NetworkConfiguration />\n")
    _write(
        root / "configs/jellyfin/config/.aspnet/DataProtection-Keys/key.xml", "key\n"
    )
    _write(root / "configs/jellyfin/config/metadata/People/A/person.jpg", "person\n")
    _write(root / "configs/jellyfin/config/cache/transcodes/file", "cache\n")
    _write(root / "configs/audiobookshelf/metadata/backups/abs.zip", "backup\n")
    _write(root / "configs/recyclarr/config/recyclarr.yml", "sonarr: {}\n")
    _write(
        root / "configs/recyclarr/config/resources/trash-guides/git/official/.git/HEAD",
        "ref\n",
    )

    _write(root / ".git/config", "[core]\n")
    _write(root / "tests/test_placeholder.py", "def test_placeholder(): pass\n")
    _write(root / "data/torrents/file", "download\n")


def _make(root: Path, target: str, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["make", "--no-print-directory", "-f", str(MAKEFILE), target, *args],
        cwd=root,
        check=True,
        text=True,
        capture_output=True,
    )


def _archive_names(archive: Path) -> set[str]:
    with tarfile.open(archive, "r:gz") as tar:
        return set(tar.getnames())


def test_backup_configs_creates_lean_archive(tmp_path):
    _fixture(tmp_path)

    result = _make(tmp_path, "backup-configs", "BACKUP_TIMESTAMP=2026-04-27-101112")

    assert "For everything the lean backup strips, run: make backup-full" in (
        result.stdout
    )
    archive = tmp_path / "backup/configs-2026-04-27-101112.tar.gz"
    names = _archive_names(archive)

    assert ".env" in names
    assert "certs/cert.conf" in names
    assert "configs/lidarr/config/config.xml" in names
    assert "configs/lidarr/config/lidarr.db" in names
    assert "configs/jellyfin/config/network.xml" in names
    assert "configs/audiobookshelf/metadata/backups/abs.zip" in names
    assert "configs/recyclarr/config/recyclarr.yml" in names

    assert "configs/lidarr/config/MediaCover/1/poster.jpg" not in names
    assert "configs/lidarr/config/Backups/scheduled/backup.zip" not in names
    assert "data/media/covers/lidarr/1/poster.jpg" not in names
    assert "data/backups/lidarr/scheduled/backup.zip" not in names
    assert "configs/lidarr/config/Sentry/event.json" not in names
    assert "configs/lidarr/config/logs/lidarr.log" not in names
    assert "configs/lidarr/config/asp/key.xml" not in names
    assert "configs/lidarr/config/logs.db" not in names
    assert "configs/lidarr/config/lidarr.db-wal" not in names
    assert "configs/lidarr/config/lidarr.db-shm" not in names
    assert "configs/whisparr/config.bak/asp/key.xml" not in names
    assert "configs/whisparr/config.v2.bak/asp/key.xml" not in names
    assert "configs/jellyfin/config/metadata/People/A/person.jpg" not in names
    assert "configs/jellyfin/config/cache/transcodes/file" not in names
    assert "configs/jellyfin/config/.aspnet/DataProtection-Keys/key.xml" not in names
    assert (
        "configs/recyclarr/config/resources/trash-guides/git/official/.git/HEAD"
        not in names
    )


def test_backup_full_keeps_app_artwork_but_not_repo_or_media_state(tmp_path):
    _fixture(tmp_path)

    _make(tmp_path, "backup-full", "BACKUP_TIMESTAMP=2026-04-27-121314")

    names = _archive_names(tmp_path / "backup/full-2026-04-27-121314.tar.gz")

    assert ".env" in names
    assert "certs/server.key" in names
    assert "configs/lidarr/config/MediaCover/1/poster.jpg" in names
    assert "configs/jellyfin/config/metadata/People/A/person.jpg" in names
    assert "configs/audiobookshelf/metadata/backups/abs.zip" in names

    assert "data/media/covers/lidarr/1/poster.jpg" not in names
    assert "data/backups/lidarr/scheduled/backup.zip" not in names
    # --exclude=cache is unanchored and lives in COMMON_BACKUP_EXCLUDES, so the
    # full mode drops caches too. Deliberate: the big ones are transcodes.
    assert "configs/jellyfin/config/cache/transcodes/file" not in names
    assert "configs/lidarr/config/asp/key.xml" not in names
    assert "configs/jellyfin/config/.aspnet/DataProtection-Keys/key.xml" not in names
    assert ".git/config" not in names
    assert "tests/test_placeholder.py" not in names
    assert "data/torrents/file" not in names


def test_backup_fails_when_a_required_file_is_unreadable(tmp_path):
    """--ignore-failed-read must not turn a dropped database into a success."""
    if os.geteuid() == 0:
        import pytest

        pytest.skip("root ignores the permission bits this test relies on")
    _fixture(tmp_path)
    unreadable = tmp_path / "configs/sonarr/config/sonarr.db"
    _write(unreadable, "critical\n")
    unreadable.chmod(0o000)

    result = subprocess.run(
        [
            "make",
            "--no-print-directory",
            "-f",
            str(MAKEFILE),
            "backup-configs",
            "BACKUP_TIMESTAMP=unreadable",
        ],
        cwd=tmp_path,
        check=False,
        text=True,
        capture_output=True,
    )

    assert result.returncode != 0
    assert "not known-skippable" in result.stdout


def test_backup_tolerates_known_container_owned_files(tmp_path):
    """The pulse runtime directory is unreadable by design and must be skippable."""
    if os.geteuid() == 0:
        import pytest

        pytest.skip("root ignores the permission bits this test relies on")
    _fixture(tmp_path)
    pulse = tmp_path / "configs/calibre/config/.config/pulse/runtime"
    _write(pulse, "socket\n")
    pulse.chmod(0o000)

    _make(tmp_path, "backup-configs", "BACKUP_TIMESTAMP=skippable")

    assert (tmp_path / "backup/configs-skippable.tar.gz").exists()


def test_restore_requires_explicit_existing_backup(tmp_path):
    _fixture(tmp_path)

    missing = subprocess.run(
        ["make", "--no-print-directory", "-f", str(MAKEFILE), "restore-configs"],
        cwd=tmp_path,
        check=False,
        text=True,
        capture_output=True,
    )
    assert missing.returncode != 0
    assert "BACKUP=/path/to/archive.tar.gz is required" in missing.stdout

    missing_file = subprocess.run(
        [
            "make",
            "--no-print-directory",
            "-f",
            str(MAKEFILE),
            "restore-configs",
            "BACKUP=backup/missing.tar.gz",
        ],
        cwd=tmp_path,
        check=False,
        text=True,
        capture_output=True,
    )
    assert missing_file.returncode != 0
    assert "backup archive not found" in missing_file.stdout


def test_restore_replaces_state_and_creates_safety_archive(tmp_path):
    _fixture(tmp_path)
    _make(tmp_path, "backup-configs", "BACKUP_TIMESTAMP=2026-04-27-151617")
    archive = tmp_path / "backup/configs-2026-04-27-151617.tar.gz"

    _write(tmp_path / ".env", "APP_ENV=changed\n")
    _write(tmp_path / "certs/cert.conf", "CERT_FQDN=changed.local\n")
    _write(tmp_path / "configs/lidarr/config/config.xml", "<Changed />\n")
    _write(tmp_path / "configs/lidarr/config/stale.txt", "must be removed\n")

    _make(
        tmp_path,
        "restore-configs",
        f"BACKUP={archive}",
        "BACKUP_TIMESTAMP=2026-04-27-181920",
    )

    assert (tmp_path / ".env").read_text(encoding="utf-8") == "APP_ENV=fixture\n"
    assert (tmp_path / "certs/cert.conf").read_text(
        encoding="utf-8"
    ) == "CERT_FQDN=fixture.local\n"
    assert (tmp_path / "configs/lidarr/config/config.xml").read_text(
        encoding="utf-8"
    ) == "<Config />\n"
    assert not (tmp_path / "configs/lidarr/config/stale.txt").exists()
    assert (tmp_path / "backup/pre-restore-2026-04-27-181920.tar.gz").is_file()
