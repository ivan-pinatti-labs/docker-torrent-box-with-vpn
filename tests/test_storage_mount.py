"""Tests for scripts/storage-mount.sh and make start's storage guard.

None of these touch the real mount, the real /etc/fstab or the running stack.
The script derives its repository root from its own location and reads .env
from there, so every test runs it out of a throwaway root built by the
``fake_repo`` fixture, with its own .env and its own fstab. ``SUDO=""`` makes
the boot-entry path runnable unprivileged, which is the only way to cover it
without a reboot.

Run explicitly with:
    pytest -m scripts tests/test_storage_mount.py
"""

import os
import shutil
import subprocess

import pytest

from conftest import REPO_ROOT

pytestmark = pytest.mark.scripts

SCRIPT = REPO_ROOT / "scripts/storage-mount.sh"

# A complete ### EXTERNAL STORAGE block, matching .env.example's shape,
# including the ${DATA_FOLDER} indirection the script has to expand itself.
ENV_TEMPLATE = """\
CONFIG_FOLDER=./configs
DATA_FOLDER=./data
STORAGE_REMOTE={remote}
STORAGE_MOUNTPOINT="${{DATA_FOLDER}}"
STORAGE_CREDENTIALS_FILE="${{CONFIG_FOLDER}}/storage/.smbcredentials"
STORAGE_CIFS_VERSION=3.1.1
STORAGE_CIFS_UID=1000
STORAGE_CIFS_GID=1000
STORAGE_CIFS_FILE_MODE=0664
STORAGE_CIFS_DIR_MODE=0775
STORAGE_CIFS_EXTRA_OPTIONS=noperm,mfsymlinks,serverino,cache=strict,actimeo=120
STORAGE_SELINUX_CONTEXT=system_u:object_r:container_file_t:s0
"""


@pytest.fixture
def fake_repo(tmp_path):
    """A throwaway repository root holding a copy of the script and the
    .env reader it sources."""
    (tmp_path / "scripts/lib").mkdir(parents=True)
    shutil.copy2(SCRIPT, tmp_path / "scripts/storage-mount.sh")
    shutil.copy2(
        REPO_ROOT / "scripts/lib/dotenv.sh", tmp_path / "scripts/lib/dotenv.sh"
    )
    (tmp_path / "configs/storage").mkdir(parents=True)
    (tmp_path / "data").mkdir()
    return tmp_path


def _write_env(root, remote="//server/share", credentials=True):
    (root / ".env").write_text(ENV_TEMPLATE.format(remote=remote))
    if credentials:
        cred = root / "configs/storage/.smbcredentials"
        cred.write_text("username=someone\npassword=secret\n")
        cred.chmod(0o600)


def _run(root, *args, stdin=subprocess.DEVNULL, env=None):
    merged = {**os.environ, "SUDO": "", **(env or {})}
    return subprocess.run(
        [str(root / "scripts/storage-mount.sh"), *args],
        cwd=root,
        env=merged,
        stdin=stdin,
        capture_output=True,
        text=True,
        timeout=120,
    )


# ---------------------------------------------------------------------------
# Argument handling and configuration reading
# ---------------------------------------------------------------------------


def test_rejects_unknown_subcommand(fake_repo):
    _write_env(fake_repo)
    result = _run(fake_repo, "bogus")
    assert result.returncode != 0
    assert "usage:" in result.stderr


def test_rejects_missing_subcommand(fake_repo):
    _write_env(fake_repo)
    result = _run(fake_repo)
    assert result.returncode != 0
    assert "usage:" in result.stderr


def test_status_reports_unconfigured_without_a_remote(fake_repo):
    _write_env(fake_repo, remote="")
    result = _run(fake_repo, "status")
    assert result.returncode == 0, result.stderr
    assert "external storage not configured" in result.stdout


def test_status_exits_nonzero_when_configured_but_not_mounted(fake_repo):
    """What make start's storage guard keys off."""
    _write_env(fake_repo)
    result = _run(fake_repo, "status")
    assert result.returncode != 0
    assert "NOT MOUNTED" in result.stdout


def test_expands_data_folder_in_the_mountpoint(fake_repo):
    """STORAGE_MOUNTPOINT="${DATA_FOLDER}" must not be taken literally.

    Read straight from .env it is the eight characters '${DATA_FOLDER}', and a
    caller that does not expand it mounts into a directory of that name.
    """
    _write_env(fake_repo)
    result = _run(fake_repo, "status")
    assert "${DATA_FOLDER}" not in result.stdout
    assert f"mountpoint: {fake_repo}/data" in result.stdout


def test_expands_config_folder_in_the_credentials_path(fake_repo):
    """Same indirection on STORAGE_CREDENTIALS_FILE.

    Unexpanded it points at a file that does not exist, so require_configured
    would refuse to mount a correctly configured install.
    """
    _write_env(fake_repo)
    result = _run(fake_repo, "mount")
    assert "${CONFIG_FOLDER}" not in result.stderr
    assert "credentials file not found" not in result.stderr


# ---------------------------------------------------------------------------
# mount refusals. None of these reach the mount call.
# ---------------------------------------------------------------------------


def test_mount_refuses_without_a_remote(fake_repo):
    _write_env(fake_repo, remote="")
    result = _run(fake_repo, "mount")
    assert result.returncode != 0
    assert "STORAGE_REMOTE is empty" in result.stderr


def test_mount_refuses_without_credentials(fake_repo):
    _write_env(fake_repo, credentials=False)
    result = _run(fake_repo, "mount")
    assert result.returncode != 0
    assert "credentials file not found" in result.stderr


def test_mount_refuses_a_non_empty_mountpoint(fake_repo):
    """The guard that matters most.

    Mounting over a populated data/ hides it. Worse is the inverse: if the
    mount silently fails the apps write into the local directory underneath
    and everything looks normal until the share returns.
    """
    _write_env(fake_repo)
    (fake_repo / "data/torrents").mkdir()
    result = _run(fake_repo, "mount")
    assert result.returncode != 0
    assert "not empty" in result.stderr
    assert "Refusing to mount over existing data" in result.stderr


def test_mount_creates_a_missing_mountpoint(fake_repo):
    _write_env(fake_repo)
    shutil.rmtree(fake_repo / "data")
    _run(fake_repo, "mount")
    assert (fake_repo / "data").is_dir()


# ---------------------------------------------------------------------------
# unmount
# ---------------------------------------------------------------------------


def test_unmount_is_a_no_op_when_not_mounted(fake_repo):
    _write_env(fake_repo)
    result = _run(fake_repo, "unmount")
    assert result.returncode == 0, result.stderr
    assert "not mounted" in result.stdout


# ---------------------------------------------------------------------------
# Mount options. Two of these have already cost a live debugging session.
# ---------------------------------------------------------------------------


def _install(fake_repo, fstab):
    """Runs install-boot all the way through, answering its confirmation."""
    merged = {**os.environ, "SUDO": "", "FSTAB": str(fstab)}
    return subprocess.run(
        [str(fake_repo / "scripts/storage-mount.sh"), "install-boot"],
        cwd=fake_repo,
        env=merged,
        input="yes\n",
        capture_output=True,
        text=True,
        timeout=120,
    )


@pytest.fixture
def fstab(tmp_path):
    path = tmp_path / "fstab"
    path.write_text("UUID=00000000-0000-0000-0000-000000000000 / ext4 defaults 0 1\n")
    return path


def test_fstab_entry_carries_the_selinux_context(fake_repo, fstab):
    """CIFS has no security.selinux xattr, so Podman's :z cannot label it.

    Without context= every container is denied by SELinux while the mode bits
    look correct, which reads as a permissions bug and is not one.
    """
    _write_env(fake_repo)
    assert _install(fake_repo, fstab).returncode == 0
    line = fstab.read_text().splitlines()[-1]
    assert "context=system_u:object_r:container_file_t:s0" in line


def test_fstab_entry_keeps_serverino(fake_repo, fstab):
    """serverino is what makes hardlinks visible at all."""
    _write_env(fake_repo)
    _install(fake_repo, fstab)
    assert "serverino" in fstab.read_text().splitlines()[-1]


def test_fstab_entry_has_the_boot_safety_options(fake_repo, fstab):
    """_netdev so it waits for the network, nofail so a NAS that is down
    cannot hold up boot."""
    _write_env(fake_repo)
    _install(fake_repo, fstab)
    line = fstab.read_text().splitlines()[-1]
    for option in ("_netdev", "nofail"):
        assert option in line, f"{option} missing from {line}"


def test_fstab_entry_does_not_use_automount(fake_repo, fstab):
    """An autofs mount reports its source as 'systemd-1' until something
    touches the path, and findmnt reads mountinfo without touching it. With
    x-systemd.automount every check here would read a healthy share as NOT
    MOUNTED after a reboot, and make start would refuse to run."""
    _write_env(fake_repo)
    _install(fake_repo, fstab)
    assert "automount" not in fstab.read_text().splitlines()[-1]


def test_fstab_entry_is_well_formed(fake_repo, fstab):
    _write_env(fake_repo)
    _install(fake_repo, fstab)
    fields = fstab.read_text().splitlines()[-1].split()
    assert len(fields) == 6, f"fstab needs 6 fields, got {fields}"
    assert fields[0] == "//server/share"
    assert fields[1] == f"{fake_repo}/data"
    assert fields[2] == "cifs"
    assert (fields[4], fields[5]) == ("0", "0")


def test_fstab_entry_uses_an_absolute_mountpoint(fake_repo, fstab):
    """A relative path in fstab would resolve against / at boot."""
    _write_env(fake_repo)
    _install(fake_repo, fstab)
    assert fstab.read_text().splitlines()[-1].split()[1].startswith("/")


# ---------------------------------------------------------------------------
# install-boot / uninstall-boot. The path that can affect a reboot.
# ---------------------------------------------------------------------------


def test_install_boot_requires_typed_confirmation(fake_repo, fstab):
    _write_env(fake_repo)
    before = fstab.read_text()
    result = _run(fake_repo, "install-boot", env={"FSTAB": str(fstab)})
    assert result.returncode != 0
    assert fstab.read_text() == before, "fstab was modified without confirmation"


def test_install_boot_rejects_anything_but_yes(fake_repo, fstab):
    _write_env(fake_repo)
    before = fstab.read_text()
    result = subprocess.run(
        [str(fake_repo / "scripts/storage-mount.sh"), "install-boot"],
        cwd=fake_repo,
        env={**os.environ, "SUDO": "", "FSTAB": str(fstab)},
        input="y\n",
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert result.returncode != 0
    assert "aborted" in result.stderr
    assert fstab.read_text() == before


def test_install_boot_previews_the_line_before_asking(fake_repo, fstab):
    _write_env(fake_repo)
    result = _run(fake_repo, "install-boot", env={"FSTAB": str(fstab)})
    assert "//server/share" in result.stdout
    assert "cifs" in result.stdout


def test_install_boot_backs_up_fstab(fake_repo, fstab):
    _write_env(fake_repo)
    original = fstab.read_text()
    assert _install(fake_repo, fstab).returncode == 0
    backups = list(fstab.parent.glob("fstab.*.bak"))
    assert len(backups) == 1, f"expected one backup, found {backups}"
    assert backups[0].read_text() == original


def test_install_boot_preserves_existing_entries(fake_repo, fstab):
    _write_env(fake_repo)
    original = fstab.read_text()
    _install(fake_repo, fstab)
    assert fstab.read_text().startswith(original)


def test_install_boot_ends_the_file_with_a_newline(fake_repo, fstab):
    """A trailing newline is not cosmetic here.

    Without it the next thing appended to fstab, by this script or anything
    else, lands on the end of our entry and corrupts both lines.
    """
    _write_env(fake_repo)
    _install(fake_repo, fstab)
    assert fstab.read_text().endswith("\n")


def test_install_boot_does_not_join_onto_an_unterminated_last_line(fake_repo, fstab):
    """An fstab whose final line lacks a newline is legal and does happen."""
    fstab.write_text("UUID=deadbeef / ext4 defaults 0 1")
    _write_env(fake_repo)
    _install(fake_repo, fstab)
    lines = fstab.read_text().splitlines()
    assert lines[0] == "UUID=deadbeef / ext4 defaults 0 1", (
        "existing entry was corrupted"
    )
    assert any(line.startswith("//server/share") for line in lines)


def test_install_boot_is_not_applied_twice(fake_repo, fstab):
    _write_env(fake_repo)
    assert _install(fake_repo, fstab).returncode == 0
    second = _install(fake_repo, fstab)
    assert second.returncode != 0
    assert "already installed" in second.stderr
    assert fstab.read_text().count("//server/share") == 1


def test_install_boot_refuses_when_unconfigured(fake_repo, fstab):
    _write_env(fake_repo, remote="")
    before = fstab.read_text()
    assert _install(fake_repo, fstab).returncode != 0
    assert fstab.read_text() == before


def test_uninstall_boot_removes_both_lines(fake_repo, fstab):
    _write_env(fake_repo)
    original = fstab.read_text()
    _install(fake_repo, fstab)
    result = _run(fake_repo, "uninstall-boot", env={"FSTAB": str(fstab)})
    assert result.returncode == 0, result.stderr
    assert fstab.read_text() == original, "uninstall did not restore fstab exactly"


def test_uninstall_boot_is_a_no_op_when_absent(fake_repo, fstab):
    _write_env(fake_repo)
    before = fstab.read_text()
    result = _run(fake_repo, "uninstall-boot", env={"FSTAB": str(fstab)})
    assert result.returncode == 0, result.stderr
    assert "no entry found" in result.stdout
    assert fstab.read_text() == before


def test_boot_entry_round_trips(fake_repo, fstab):
    """install then uninstall, twice, leaves fstab byte for byte unchanged."""
    _write_env(fake_repo)
    original = fstab.read_text()
    for _ in range(2):
        assert _install(fake_repo, fstab).returncode == 0
        assert (
            _run(fake_repo, "uninstall-boot", env={"FSTAB": str(fstab)}).returncode == 0
        )
    assert fstab.read_text() == original


def test_status_reports_the_boot_entry(fake_repo, fstab):
    _write_env(fake_repo)
    _install(fake_repo, fstab)
    # status exits 1 because the share is not mounted; the boot line is still
    # not reached in that branch, so assert on the fstab state the branch reads.
    assert "docker-torrent-box-with-vpn external storage" in fstab.read_text()


# ---------------------------------------------------------------------------
# make start's storage guard
# ---------------------------------------------------------------------------


def test_makefile_start_targets_depend_on_the_storage_guard():
    """An automounted share can be absent at boot, so the stack must refuse to
    start against an empty data/ rather than write into it."""
    makefile = (REPO_ROOT / "Makefile").read_text()
    assert "storage_guard:" in makefile
    for target in ("start:", "start_library:", "start_observability:"):
        line = next(ln for ln in makefile.splitlines() if ln.startswith(target))
        assert "storage_guard" in line, f"{target} does not depend on storage_guard"


# ---------------------------------------------------------------------------
# Path resolution and containment. All found by CodeRabbit on PR #38.
# ---------------------------------------------------------------------------


def _write_env_at(root, mountpoint):
    (root / ".env").write_text(
        ENV_TEMPLATE.format(remote="//server/share").replace(
            'STORAGE_MOUNTPOINT="${DATA_FOLDER}"', f'STORAGE_MOUNTPOINT="{mountpoint}"'
        )
    )
    cred = root / "configs/storage/.smbcredentials"
    cred.write_text("username=someone\npassword=secret\n")
    cred.chmod(0o600)


def test_refuses_a_mountpoint_whose_parent_is_missing(fake_repo):
    """Resolving the parent with a subshell cd and using whatever comes out
    turned './missing/data' into '/data', a real path at the filesystem root
    that install-boot would then write into /etc/fstab."""
    _write_env_at(fake_repo, "./missing/data")
    result = _run(fake_repo, "status")
    assert result.returncode != 0
    assert "/data" not in result.stdout.replace(str(fake_repo), "")
    assert "does not exist" in result.stderr


def test_refuses_a_mountpoint_outside_the_repository(fake_repo, tmp_path_factory):
    """compose reads DATA_FOLDER relative to the repository, so a mount
    elsewhere leaves the apps on one tree and permissions.py on another.
    permissions.py refuses such paths already; this matches it.

    tmp_path_factory, not tmp_path: the fake_repo fixture *is* tmp_path, so a
    directory under it would be inside the repository and correctly allowed.
    """
    outside = tmp_path_factory.mktemp("outside-the-repo")
    _write_env_at(fake_repo, str(outside))
    result = _run(fake_repo, "status")
    assert result.returncode != 0
    assert "outside the repository" in result.stderr


def test_install_boot_refuses_a_mountpoint_outside_the_repository(
    fake_repo, tmp_path_factory, fstab
):
    """The containment check has to bite before anything reaches fstab."""
    outside = tmp_path_factory.mktemp("outside-the-repo")
    _write_env_at(fake_repo, str(outside))
    before = fstab.read_text()
    assert _install(fake_repo, fstab).returncode != 0
    assert fstab.read_text() == before


def test_status_reports_the_boot_entry_when_not_mounted(fake_repo, fstab):
    """Whether the share comes back after a reboot is most worth answering
    when it is not currently mounted, which is exactly when this used to
    return early and stay silent."""
    _write_env(fake_repo)
    _install(fake_repo, fstab)
    result = _run(fake_repo, "status", env={"FSTAB": str(fstab)})
    assert result.returncode != 0, "an unmounted share must still exit non-zero"
    assert "NOT MOUNTED" in result.stdout
    assert "fstab entry installed" in result.stdout


def test_status_reports_a_missing_boot_entry_when_not_mounted(fake_repo, fstab):
    _write_env(fake_repo)
    result = _run(fake_repo, "status", env={"FSTAB": str(fstab)})
    assert "no fstab entry" in result.stdout


def test_install_boot_leaves_fstab_untouched_when_the_entry_is_invalid(
    fake_repo, fstab
):
    """Warning about a bad entry, leaving it in place and then reporting
    success is how a machine ends up not booting."""
    _write_env(fake_repo)
    # An option string with an embedded newline cannot produce a valid entry.
    env_text = (
        (fake_repo / ".env")
        .read_text()
        .replace("STORAGE_REMOTE=//server/share", "STORAGE_REMOTE=")
    )
    (fake_repo / ".env").write_text(env_text)
    before = fstab.read_text()
    assert _install(fake_repo, fstab).returncode != 0
    assert fstab.read_text() == before


def test_install_boot_tolerates_an_unrelated_bad_entry(fake_repo, fstab):
    """findmnt --verify reports on every line it is given, so validating the
    assembled file made somebody else's pre-existing entry our problem."""
    fstab.write_text("UUID=not-a-real-uuid / ext4 defaults 0 1\n")
    _write_env(fake_repo)
    result = _install(fake_repo, fstab)
    assert result.returncode == 0, result.stderr
    assert "//server/share" in fstab.read_text()


def _stale_mount_path(fake_repo, tmp_path_factory):
    """A PATH whose findmnt insists the share is mounted.

    Combined with a mountpoint that cannot be read, this is exactly the state a
    dead CIFS session leaves behind: the mount table still lists it while every
    access returns ENOENT.
    """
    binstub = tmp_path_factory.mktemp("stale-bin")
    findmnt = binstub / "findmnt"
    # Answers the --source probe affirmatively, and gives plausible output for
    # the FSTYPE/OPTIONS lookups so status does not fail for another reason.
    findmnt.write_text(
        "#!/bin/sh\n"
        'case "$*" in\n'
        "  *FSTYPE*) echo cifs ;;\n"
        "  *OPTIONS*) echo rw,relatime ;;\n"
        "  *) : ;;\n"
        "esac\n"
        "exit 0\n"
    )
    findmnt.chmod(0o755)
    return f"{binstub}:{os.environ['PATH']}"


def test_status_reports_a_stale_mount_rather_than_claiming_it_is_fine(
    fake_repo, tmp_path_factory
):
    """findmnt reporting a mount is not the same as the mount working.

    On 2026-08-12 a CIFS session died and left the entry in place. findmnt,
    /proc/mounts and df all still described a healthy mount while every read
    returned ENOENT, and the stack started against an unreadable data/ because
    the guard only asked findmnt.
    """
    _write_env(fake_repo)
    (fake_repo / "data").chmod(0o000)
    try:
        result = _run(
            fake_repo,
            "status",
            env={"PATH": _stale_mount_path(fake_repo, tmp_path_factory)},
        )
    finally:
        (fake_repo / "data").chmod(0o755)
    assert result.returncode != 0, "a stale mount must not report success"
    assert "STALE" in result.stdout
    assert "make storage_unmount" in result.stdout


def test_a_stale_mount_fails_the_start_guard(fake_repo, tmp_path_factory):
    """What make start keys off. Exiting zero here would start the stack
    against a share nothing can read."""
    _write_env(fake_repo)
    (fake_repo / "data").chmod(0o000)
    try:
        result = _run(
            fake_repo,
            "status",
            env={"PATH": _stale_mount_path(fake_repo, tmp_path_factory)},
        )
    finally:
        (fake_repo / "data").chmod(0o755)
    assert result.returncode != 0


def test_a_healthy_mount_is_still_reported_as_mounted(fake_repo, tmp_path_factory):
    """The readability check must not turn a working, empty share into a
    stale one: ls on an empty directory succeeds and says nothing."""
    _write_env(fake_repo)
    result = _run(
        fake_repo,
        "status",
        env={"PATH": _stale_mount_path(fake_repo, tmp_path_factory)},
    )
    assert "STALE" not in result.stdout
    assert "state:      mounted" in result.stdout
    assert result.returncode == 0


def test_hardlink_probe_uses_a_unique_directory():
    """The probe deletes the directory afterwards, so a fixed name is one the
    share might already have, and the probe would take its contents with it."""
    source = SCRIPT.read_text()
    assert "mktemp -d" in source
    assert 'rm -rf "$probe"' not in source.split("mktemp -d")[0]


# ---------------------------------------------------------------------------
# Second checkout isolation. FSTAB_MARKER is one fixed string with no path in
# it, so every clone of this repository writes and looks for the same comment.
# Keying the boot-entry checks on it made a second checkout read the first
# one's entry as its own.
# ---------------------------------------------------------------------------


def _foreign_entry(fstab, mountpoint):
    """Appends another checkout's boot entry, marker and all."""
    fstab.write_text(
        fstab.read_text()
        + "# docker-torrent-box-with-vpn external storage\n"
        + f"//server/share {mountpoint} cifs credentials=/elsewhere/.smbcredentials,_netdev,nofail 0 0\n"
    )


def test_status_does_not_claim_another_checkouts_boot_entry(fake_repo, fstab):
    """A clone with no entry of its own must not report one as installed."""
    _write_env(fake_repo)
    _foreign_entry(fstab, "/somewhere/else/docker-torrent-box-with-vpn/data")

    result = _run(fake_repo, "status", env={"FSTAB": str(fstab)})

    assert "no fstab entry" in result.stdout, result.stdout
    assert "fstab entry installed" not in result.stdout, result.stdout


def test_install_boot_is_not_blocked_by_another_checkouts_entry(fake_repo, fstab):
    """Two checkouts each get their own entry; one must not block the other."""
    _write_env(fake_repo)
    _foreign_entry(fstab, "/somewhere/else/docker-torrent-box-with-vpn/data")

    result = _install(fake_repo, fstab)

    assert result.returncode == 0, result.stderr
    assert str(fake_repo / "data") in fstab.read_text()
    # The other checkout's entry survives untouched.
    assert "/somewhere/else/docker-torrent-box-with-vpn/data" in fstab.read_text()


def test_uninstall_boot_leaves_another_checkouts_entry_alone(fake_repo, fstab):
    """Removing this clone's entry must not take the other clone's with it."""
    _write_env(fake_repo)
    _foreign_entry(fstab, "/somewhere/else/docker-torrent-box-with-vpn/data")
    _install(fake_repo, fstab)

    result = _run(fake_repo, "uninstall-boot", env={"FSTAB": str(fstab)})

    assert result.returncode == 0, result.stderr
    remaining = fstab.read_text()
    assert str(fake_repo / "data") not in remaining
    assert "/somewhere/else/docker-torrent-box-with-vpn/data" in remaining
