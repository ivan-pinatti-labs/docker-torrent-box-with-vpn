"""Smoke tests for the standalone maintenance scripts in scripts/.

These tests never mutate live stack state. Filesystem scenarios run against
temporary directories, permissions.py runs in dry-run mode, the Readarr
profile script runs against a throwaway copy of the database, and the
korsync/exporter checks are read-only probes that skip when the container is
not running.

Run explicitly with:
    pytest -m scripts tests/test_scripts.py
"""

import os
import sqlite3
import subprocess

import pytest

from conftest import REPO_ROOT

pytestmark = pytest.mark.scripts

SCRIPTS = REPO_ROOT / "scripts"
READARR_DB = REPO_ROOT / "configs/readarr/config/readarr.db"


def _skip_unless_running(container: str) -> None:
    result = subprocess.run(
        ["podman", "ps", "--format", "{{.Names}}"],
        capture_output=True,
        text=True,
        timeout=30,
    )
    if result.returncode != 0 or container not in result.stdout.split():
        pytest.skip(f"container '{container}' is not running")


def _run(cmd, *, env=None, cwd=REPO_ROOT, stdin=subprocess.DEVNULL):
    merged_env = {**os.environ, **(env or {})}
    return subprocess.run(
        cmd,
        cwd=cwd,
        env=merged_env,
        stdin=stdin,
        capture_output=True,
        text=True,
        timeout=300,
    )


# ---------------------------------------------------------------------------
# disk-status.sh
# ---------------------------------------------------------------------------


def _disk_status(tmp_path, warn_gb: str, crit_gb: str) -> subprocess.CompletedProcess:
    for name in ("torrents", "usenet", "logs", "cache", "storage"):
        (tmp_path / name).mkdir(exist_ok=True)
    env = {
        "TORRENTS_FOLDER": str(tmp_path / "torrents"),
        "USENET_FOLDER": str(tmp_path / "usenet"),
        "LOGS_FOLDER": str(tmp_path / "logs"),
        "CACHE_FOLDER": str(tmp_path / "cache"),
        "STORAGE_FOLDER": str(tmp_path / "storage"),
        "DOWNLOADS_WARN_GB": warn_gb,
        "DOWNLOADS_CRIT_GB": crit_gb,
    }
    return _run([str(SCRIPTS / "disk-status.sh")], env=env)


def test_disk_status_ok(tmp_path):
    result = _disk_status(tmp_path, warn_gb="1", crit_gb="2")
    assert result.returncode == 0, result.stderr
    assert "OK: downloads are 0G" in result.stdout


def test_disk_status_warning(tmp_path):
    result = _disk_status(tmp_path, warn_gb="0", crit_gb="9999")
    assert result.returncode == 0, result.stderr
    assert "WARNING: downloads are 0G" in result.stdout


def test_disk_status_critical(tmp_path):
    result = _disk_status(tmp_path, warn_gb="0", crit_gb="0")
    assert result.returncode == 0, result.stderr
    assert "CRITICAL: downloads are 0G" in result.stdout


def test_disk_status_reports_missing_paths(tmp_path):
    env = {
        "TORRENTS_FOLDER": str(tmp_path / "does-not-exist"),
        "USENET_FOLDER": str(tmp_path / "also-missing"),
        "LOGS_FOLDER": str(tmp_path / "missing-too"),
        "CACHE_FOLDER": str(tmp_path / "nope"),
        "STORAGE_FOLDER": str(tmp_path / "still-nope"),
        "DOWNLOADS_WARN_GB": "1",
        "DOWNLOADS_CRIT_GB": "2",
    }
    result = _run([str(SCRIPTS / "disk-status.sh")], env=env)
    assert result.returncode == 0, result.stderr
    assert "missing" in result.stdout


# ---------------------------------------------------------------------------
# seed-secrets.sh
# ---------------------------------------------------------------------------


def test_seed_secrets_requires_config_dir_argument():
    result = _run([str(SCRIPTS / "seed-secrets.sh")])
    assert result.returncode == 1
    assert "Usage" in result.stderr


def test_seed_secrets_noop_without_example(tmp_path):
    result = _run([str(SCRIPTS / "seed-secrets.sh"), str(tmp_path)])
    assert result.returncode == 0, result.stderr
    assert not (tmp_path / ".env.secrets").exists()


def test_seed_secrets_seeds_from_example(tmp_path):
    (tmp_path / ".env.secrets.example").write_text("TOKEN=changeme\n")
    result = _run([str(SCRIPTS / "seed-secrets.sh"), str(tmp_path)])
    assert result.returncode == 0, result.stderr
    assert (tmp_path / ".env.secrets").read_text() == "TOKEN=changeme\n"
    assert "Seeded" in result.stdout


def test_seed_secrets_keeps_existing_when_not_a_tty(tmp_path):
    (tmp_path / ".env.secrets.example").write_text("TOKEN=changeme\n")
    (tmp_path / ".env.secrets").write_text("TOKEN=real-value\n")
    result = _run([str(SCRIPTS / "seed-secrets.sh"), str(tmp_path)])
    assert result.returncode == 0, result.stderr
    assert (tmp_path / ".env.secrets").read_text() == "TOKEN=real-value\n"


# ---------------------------------------------------------------------------
# permissions.py
# ---------------------------------------------------------------------------


def test_permissions_dry_run_prints_commands_only(tmp_path):
    marker = tmp_path / "untouched"
    marker.write_text("before\n")
    result = _run([str(SCRIPTS / "permissions.py"), "dry-run", "--recursive"])
    assert result.returncode == 0, result.stderr
    assert "chown" in result.stdout
    assert "chmod" in result.stdout
    assert "setfacl" in result.stdout
    assert marker.read_text() == "before\n"


# ---------------------------------------------------------------------------
# readarr-add-comic-profile.py
# ---------------------------------------------------------------------------


def test_readarr_comic_profile_is_idempotent(tmp_path):
    if not READARR_DB.exists():
        pytest.skip("readarr database not present")
    db_copy = tmp_path / "readarr.db"
    source = sqlite3.connect(f"file:{READARR_DB}?mode=ro", uri=True)
    try:
        target = sqlite3.connect(db_copy)
        with target:
            source.backup(target)
        target.close()
    finally:
        source.close()

    env = {"READARR_DB": str(db_copy)}
    script = str(SCRIPTS / "readarr-add-comic-profile.py")

    first = _run(["python3", script], env=env)
    assert first.returncode == 0, first.stderr

    second = _run(["python3", script], env=env)
    assert second.returncode == 0, second.stderr
    assert "already exists" in second.stdout

    con = sqlite3.connect(db_copy)
    try:
        profiles = con.execute(
            "SELECT COUNT(*) FROM QualityProfiles WHERE Name = 'Comic'"
        ).fetchone()[0]
        formats = con.execute(
            "SELECT COUNT(*) FROM CustomFormats WHERE Name IN ('CBZ', 'CBR')"
        ).fetchone()[0]
    finally:
        con.close()
    assert profiles == 1
    assert formats == 2


def test_readarr_comic_profile_fails_cleanly_without_db(tmp_path):
    env = {"READARR_DB": str(tmp_path / "missing.db")}
    result = _run(["python3", str(SCRIPTS / "readarr-add-comic-profile.py")], env=env)
    assert result.returncode != 0
    assert "Database not found" in result.stderr


# ---------------------------------------------------------------------------
# korsync-users.sh (read-only against the live container)
# ---------------------------------------------------------------------------


def test_korsync_users_usage_without_arguments():
    result = _run([str(SCRIPTS / "korsync-users.sh")])
    assert result.returncode == 1
    assert "Usage" in result.stdout


def test_korsync_users_list():
    _skip_unless_running("korsync")
    result = _run([str(SCRIPTS / "korsync-users.sh"), "list"])
    assert result.returncode == 0, result.stderr
    assert "Username" in result.stdout or "no users" in result.stdout


# ---------------------------------------------------------------------------
# podman-limits-exporter.py (read-only probe of the live container)
# ---------------------------------------------------------------------------


def test_podman_limits_exporter_metrics():
    _skip_unless_running("podman_limits_exporter")
    result = _run(
        [
            "podman",
            "exec",
            "podman_limits_exporter",
            "wget",
            "-q",
            "-O",
            "-",
            "http://127.0.0.1:9889/metrics",
        ]
    )
    assert result.returncode == 0, result.stderr
    assert "podman_container_cpu_limit_vcpus" in result.stdout
    assert "podman_container_pids_limit" in result.stdout


# ---------------------------------------------------------------------------
# prune-nginx-cache.sh (abort path only; never deletes anything)
# ---------------------------------------------------------------------------


def test_prune_nginx_cache_aborts_without_confirmation(tmp_path):
    cache_dir = tmp_path / "nginx"
    cache_dir.mkdir()
    sentinel = cache_dir / "cached-object"
    sentinel.write_text("cached\n")
    env = {"CACHE_FOLDER": str(tmp_path)}
    result = subprocess.run(
        [str(SCRIPTS / "prune-nginx-cache.sh")],
        cwd=REPO_ROOT,
        env={**os.environ, **env},
        input="n\n",
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert result.returncode == 0, result.stderr
    assert "Aborted" in result.stdout
    assert sentinel.exists()


def test_prune_nginx_cache_noop_without_cache_dir(tmp_path):
    env = {"CACHE_FOLDER": str(tmp_path / "empty")}
    result = _run([str(SCRIPTS / "prune-nginx-cache.sh")], env=env)
    assert result.returncode == 0, result.stderr
    assert "No nginx cache directory" in result.stdout


# ---------------------------------------------------------------------------
# generate-homepage-services.py
# ---------------------------------------------------------------------------


def _load_generate_homepage_services():
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "generate_homepage_services", SCRIPTS / "generate-homepage-services.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_generate_homepage_services_tolerates_unowned_output_file(
    tmp_path, monkeypatch
):
    """A PermissionError from chmod on the freshly-written file must not be fatal.

    `make start` runs permissions_repair before this script, and
    permissions.yml's configs/homepage/config entry (chown_files: true)
    already recursively chowns this file to Homepage's own mapped UID,
    what actually lets the container read it, regardless of the file's mode
    bits. The host user's own access to write it comes from that same
    manifest's ACL grant, not ownership, so an unconditional chmod (owner/
    root only) used to crash `make start` on every run after the first,
    confirmed live on a plain `make down && make start`.
    """
    module = _load_generate_homepage_services()

    env_file = tmp_path / ".env"
    env_file.write_text("SONARR_PROFILE=enabled\n")
    template_file = tmp_path / "services.yaml.template"
    template_file.write_text("- Group:\n    - Sonarr:\n        href: /sonarr/\n")
    output_file = tmp_path / "services.yaml"
    output_file.write_text("stale")

    monkeypatch.setattr(module, "ENV_FILE", env_file)
    monkeypatch.setattr(module, "TEMPLATE_FILE", template_file)
    monkeypatch.setattr(module, "OUTPUT_FILE", output_file)

    def _raise_permission_error(self, mode):
        raise PermissionError("not the owner")

    monkeypatch.setattr(module.Path, "chmod", _raise_permission_error)

    assert module.main() is None
    assert "Sonarr" in output_file.read_text()


def test_assert_stack_started_refuses_an_empty_service_list(tmp_path):
    """No service list means nothing was checked, which must not read as success.

    The script decides whether a start worked by comparing the enabled services
    against the running ones. If the compose invocation yields no services at
    all, the comparison is vacuous and every service trivially "present", which
    is the shape of bug this script exists to end rather than to repeat. It has
    to refuse instead.
    """
    empty = tmp_path / "empty-compose.yml"
    empty.write_text("services: {}\n")
    result = subprocess.run(
        [str(SCRIPTS / "assert-stack-started.sh"), "--file", str(empty)],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert result.returncode != 0, (
        f"an empty service list was accepted: {result.stdout}{result.stderr}"
    )
    assert "could not determine which services should be running" in result.stderr


def test_assert_stack_started_reports_the_services_it_cannot_find(tmp_path):
    """A failure names the missing services rather than only a count.

    The message is the whole value of this check when a start goes wrong: the
    step it replaced reported an exit status and nothing about which containers
    were absent.
    """
    compose = tmp_path / "compose.yml"
    compose.write_text(
        "services:\n"
        "  nothing-of-this-name-is-running:\n"
        "    image: docker.io/library/alpine:3\n"
    )
    result = subprocess.run(
        [str(SCRIPTS / "assert-stack-started.sh"), "--file", str(compose)],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=120,
        env={**os.environ, "STACK_START_TIMEOUT": "0"},
    )
    assert result.returncode != 0
    assert "nothing-of-this-name-is-running" in result.stderr, result.stderr


@pytest.mark.parametrize("value", ["abc", "5s", "-1", "3.5", " "])
def test_assert_stack_started_rejects_a_non_numeric_timeout(value):
    """A bad timeout must be reported, not silently remove the bound.

    The script runs under `set -uo pipefail` and deliberately not `set -e`, so an
    non-number that is never checked makes the `-ge` comparison print "integer expression
    expected" and return non-zero. The bound would then never trigger and the
    loop would run until `compose up` happened to exit, which is a typo quietly
    disabling the timeout rather than announcing itself.
    """
    result = subprocess.run(
        [str(SCRIPTS / "assert-stack-started.sh"), "--file", "docker-compose.yml"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=120,
        env={**os.environ, "STACK_START_TIMEOUT": value},
    )
    assert result.returncode == 1, result.stdout + result.stderr
    assert "must be a whole number of seconds" in result.stderr, result.stderr
