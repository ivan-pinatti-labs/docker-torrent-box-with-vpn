"""Unit tests for scripts/permissions.py.

The script's REPO_ROOT and MANIFEST are pointed at a temporary tree, and every
command it would run (podman unshare, chown, chmod, setfacl, stat, getfacl,
the hardlink smoke test) goes to a recorder that answers from the test instead
of the host. The mount table is a stand in too, so the result never depends on
how the machine running the tests is mounted.
"""

import io
import subprocess
from pathlib import Path

import pytest
import yaml

pytestmark = pytest.mark.unit


class Runner:
    """Records each command and answers it with `respond(cmd)`.

    `respond` returns (returncode, stdout, stderr); the default is success
    with no output.
    """

    def __init__(self):
        self.calls: list[list[str]] = []
        self.respond = lambda cmd: (0, "", "")

    def __call__(self, cmd, *, dry_run=False):
        self.calls.append(list(cmd))
        code, out, err = self.respond(cmd)
        return subprocess.CompletedProcess(cmd, code, out, err)


@pytest.fixture
def root(tmp_path):
    return tmp_path.resolve()


@pytest.fixture
def perms(load_script, root, monkeypatch):
    module = load_script("permissions.py")
    monkeypatch.setattr(module, "REPO_ROOT", root)
    monkeypatch.setattr(module, "MANIFEST", root / "permissions.yml")
    monkeypatch.setattr(module, "mount_table", lambda: ())
    return module


@pytest.fixture
def runner(perms, monkeypatch):
    fake = Runner()
    monkeypatch.setattr(perms, "run", fake)
    return fake


MANIFEST = {
    "identities": {
        "app": {"uid": 1000, "gid": 1001},
        "host": {"uid": 2000, "gid": 2000},
    },
}


# ---------------------------------------------------------------------------
# Mount table and filesystem types
# ---------------------------------------------------------------------------


def test_mount_table_parses_and_orders_longest_first(load_script, monkeypatch):
    module = load_script("permissions.py")
    text = "sysfs /sys sysfs rw 0 0\nshort\n//nas/share /mnt/my\\040share cifs rw 0 0\n"
    opened = []

    def fake_open(path, encoding):
        opened.append((path, encoding))
        return io.StringIO(text)

    monkeypatch.setattr(module, "open", fake_open, raising=False)
    assert module.mount_table() == (("/mnt/my share", "cifs"), ("/sys", "sysfs"))
    assert opened == [("/proc/self/mounts", "utf-8")]


def test_mount_table_is_empty_when_unreadable(load_script, monkeypatch):
    module = load_script("permissions.py")

    def fail(path, encoding):
        raise OSError("no /proc")

    monkeypatch.setattr(module, "open", fail, raising=False)
    assert module.mount_table() == ()


def test_path_fstype_and_unmanaged_fstype(perms, monkeypatch):
    table = (("/data/share", "cifs"), ("/data", "ext4"), ("/", "xfs"))
    monkeypatch.setattr(perms, "mount_table", lambda: table)
    assert perms.path_fstype(perms.Path("/data/share")) == "cifs"
    assert perms.path_fstype(perms.Path("/data/share/movies")) == "cifs"
    assert perms.path_fstype(perms.Path("/data/shared")) == "ext4"
    assert perms.path_fstype(perms.Path("/srv")) == "xfs"
    assert perms.unmanaged_fstype(perms.Path("/data/share/x")) == "cifs"
    assert perms.unmanaged_fstype(perms.Path("/data/x")) is None
    monkeypatch.setattr(perms, "mount_table", lambda: ())
    assert perms.path_fstype(perms.Path("/srv")) is None


def test_report_unmanaged(perms, capsys):
    perms.report_unmanaged({})
    assert capsys.readouterr().out == ""
    perms.report_unmanaged({"data/a": "cifs", "data/b": "cifs", "usb": "vfat"})
    out = capsys.readouterr().out.splitlines()
    assert (
        out[0] == "note: skipped ownership and ACLs for 2 path(s) on cifs: data/a ..."
    )
    assert out[2] == "note: skipped ownership and ACLs for 1 path(s) on vfat: usb"
    assert "vfat carries no per-file ownership" in out[3]


# ---------------------------------------------------------------------------
# Manifest, identities and path containment
# ---------------------------------------------------------------------------


def test_load_manifest(perms, root):
    (root / "permissions.yml").write_text(yaml.safe_dump(MANIFEST))
    assert perms.load_manifest() == MANIFEST
    (root / "permissions.yml").write_text("- a list\n")
    with pytest.raises(SystemExit, match="must contain a mapping"):
        perms.load_manifest()


def test_identity_id(perms):
    assert perms.identity_id(MANIFEST, None) == (0, 0)
    assert perms.identity_id(MANIFEST, "root") == (0, 0)
    assert perms.identity_id(MANIFEST, "app") == (1000, 1001)
    with pytest.raises(SystemExit, match="unknown identity in permissions.yml: ghost"):
        perms.identity_id(MANIFEST, "ghost")
    with pytest.raises(SystemExit, match="unknown identity"):
        perms.identity_id({}, "app")


def test_safe_path(perms, root):
    assert perms.safe_path("configs/app") == root / "configs/app"
    with pytest.raises(SystemExit, match="refusing path outside repository: ../x"):
        perms.safe_path("../x")


def test_safe_link_path_leaves_the_link_itself_unresolved(perms, root):
    (root / "configs").mkdir()
    (root / "configs/link").symlink_to("/mediacover")
    assert perms.safe_link_path("configs/link") == root / "configs/link"
    with pytest.raises(SystemExit, match="refusing path outside repository"):
        perms.safe_link_path("../elsewhere/link")


# ---------------------------------------------------------------------------
# Running commands
# ---------------------------------------------------------------------------


def test_run_prints_in_a_dry_run(perms, monkeypatch, capsys):
    def forbidden(*args, **kwargs):
        raise AssertionError("a dry run must not execute anything")

    monkeypatch.setattr(perms.subprocess, "run", forbidden)
    result = perms.run(["chown", "1:1", "a b"], dry_run=True)
    assert result.returncode == 0
    assert capsys.readouterr().out == "chown 1:1 'a b'\n"


def test_run_executes_otherwise(perms, monkeypatch):
    seen = {}

    def fake_run(cmd, **kwargs):
        seen.update(cmd=cmd, **kwargs)
        return subprocess.CompletedProcess(cmd, 3, "out", "err")

    monkeypatch.setattr(perms.subprocess, "run", fake_run)
    assert perms.run(["true"]).returncode == 3
    assert seen == {
        "cmd": ["true"],
        "text": True,
        "capture_output": True,
        "check": False,
    }


def test_runtime_prefix(perms):
    assert perms.runtime_prefix("podman") == ["podman", "unshare"]
    assert perms.runtime_prefix("docker") == []


def test_ensure_dir(perms, runner, root):
    perms.ensure_dir(root / "a", runtime="podman", dry_run=False)
    assert runner.calls == [["podman", "unshare", "mkdir", "-p", str(root / "a")]]
    runner.respond = lambda cmd: (1, "", "  denied  ")
    with pytest.raises(SystemExit, match="^denied$"):
        perms.ensure_dir(root / "a", runtime="docker", dry_run=False)
    runner.respond = lambda cmd: (1, "", "")
    with pytest.raises(SystemExit, match="failed to create"):
        perms.ensure_dir(root / "a", runtime="docker", dry_run=False)


# ---------------------------------------------------------------------------
# ensure_symlinks
# ---------------------------------------------------------------------------


def _links(*names):
    return {
        "symlinks": [
            {"path": f"configs/app/config/{name}", "target": f"/{name.lower()}"}
            for name in names
        ]
    }


def test_symlinks_created_kept_and_replaced(perms, root):
    config = root / "configs/app/config"
    config.mkdir(parents=True)
    (config / "Kept").symlink_to("/kept")
    (config / "Wrong").symlink_to("/old")
    (config / "Empty").mkdir()
    perms.ensure_symlinks(_links("Missing", "Kept", "Wrong", "Empty"), dry_run=False)
    for name in ("Missing", "Kept", "Wrong", "Empty"):
        link = config / name
        assert link.is_symlink(), name
        assert str(link.readlink()) == f"/{name.lower()}"


def test_symlinks_dry_run_changes_nothing(perms, root, capsys):
    config = root / "configs/app/config"
    config.mkdir(parents=True)
    (config / "Wrong").symlink_to("/old")
    (config / "Empty").mkdir()
    perms.ensure_symlinks(_links("Missing", "Wrong", "Empty"), dry_run=True)
    assert capsys.readouterr().out.splitlines() == [
        f"ln -s /missing {config / 'Missing'}",
        f"ln -sfn /wrong {config / 'Wrong'}",
        f"rmdir {config / 'Empty'} && ln -s /empty {config / 'Empty'}",
    ]
    assert not (config / "Missing").exists()
    assert str((config / "Wrong").readlink()) == "/old"
    assert (config / "Empty").is_dir() and not (config / "Empty").is_symlink()


def test_symlinks_refuse_a_file_in_the_way(perms, root):
    config = root / "configs/app/config"
    config.mkdir(parents=True)
    (config / "File").write_text("x")
    with pytest.raises(SystemExit, match="exists and is not a directory"):
        perms.ensure_symlinks(_links("File"), dry_run=False)


def test_symlinks_never_delete_a_populated_directory(perms, root):
    config = root / "configs/app/config"
    (config / "Full").mkdir(parents=True)
    (config / "Full/cover.jpg").write_text("art")
    with pytest.raises(SystemExit, match="non-empty directory"):
        perms.ensure_symlinks(_links("Full"), dry_run=False)
    assert (config / "Full/cover.jpg").exists()


# ---------------------------------------------------------------------------
# chmod_chown
# ---------------------------------------------------------------------------


def _entry(**extra):
    return {"path": "configs/app", "mode": "0750", "owner": "app", **extra}


@pytest.mark.parametrize(
    ("recursive", "chown_files", "chown"),
    [
        (True, True, ["chown", "-R", "1000:1001", "{path}"]),
        (
            True,
            False,
            ["find", "{path}", "-type", "d", "-exec", "chown", "1000:1001", "{}", "+"],
        ),
        (False, True, ["chown", "1000:1001", "{path}"]),
    ],
)
def test_chmod_chown_commands(perms, runner, root, recursive, chown_files, chown):
    path = str(root / "configs/app")
    entry = _entry(chown_files=chown_files)
    perms.chmod_chown(
        MANIFEST, entry, runtime="docker", recursive=recursive, dry_run=False
    )
    assert runner.calls == [
        ["mkdir", "-p", path],
        [path if part == "{path}" else part for part in chown],
        ["chmod", "0750", path],
    ]


def test_chmod_chown_failures(perms, runner):
    runner.respond = lambda cmd: (
        (1, "", "chown said no") if "chown" in cmd else (0, "", "")
    )
    with pytest.raises(SystemExit, match="chown said no"):
        perms.chmod_chown(
            MANIFEST, _entry(), runtime="docker", recursive=False, dry_run=False
        )
    runner.respond = lambda cmd: (1, "", "") if "chown" in cmd else (0, "", "")
    with pytest.raises(SystemExit, match="failed: "):
        perms.chmod_chown(
            MANIFEST, _entry(), runtime="docker", recursive=False, dry_run=False
        )
    runner.respond = lambda cmd: (
        (1, "", "chmod said no") if "chmod" in cmd else (0, "", "")
    )
    with pytest.raises(SystemExit, match="chmod said no"):
        perms.chmod_chown(
            MANIFEST, _entry(), runtime="docker", recursive=False, dry_run=False
        )
    runner.respond = lambda cmd: (1, "", "") if "chmod" in cmd else (0, "", "")
    with pytest.raises(SystemExit, match="failed: "):
        perms.chmod_chown(
            MANIFEST, _entry(), runtime="docker", recursive=False, dry_run=False
        )


# ---------------------------------------------------------------------------
# ACLs
# ---------------------------------------------------------------------------


HOST = {
    "enabled": True,
    "identity": "host",
    "perms": "rwx",
    "default_perms": "rwx",
}


def test_host_access_acl(perms):
    assert perms.host_access_acl({}, default=False) == []
    assert perms.host_access_acl({"host_access": None}, default=False) == []
    assert (
        perms.host_access_acl({"host_access": {"enabled": False}}, default=False) == []
    )
    assert perms.host_access_acl({"host_access": {"enabled": True}}, default=True) == []
    assert perms.host_access_acl({"host_access": HOST}, default=True) == [
        {"identity": "host", "perms": "rwx"}
    ]
    no_identity = {"enabled": True, "perms": "r-x"}
    assert perms.host_access_acl({"host_access": no_identity}, default=False) == [
        {"identity": "root", "perms": "r-x"}
    ]


def test_effective_acl_lets_host_access_override_the_entry(perms):
    manifest = {**MANIFEST, "host_access": HOST}
    entry = _entry(
        acl=[{"identity": "app", "perms": "r-x"}, {"identity": "host", "perms": "r--"}],
    )
    assert perms.effective_acl(manifest, entry, default=False) == [
        {"identity": "app", "perms": "r-x"},
        {"identity": "host", "perms": "rwx"},
    ]
    assert perms.effective_acl(MANIFEST, entry, default=True) == []


def test_acl_args(perms):
    acl = [{"identity": "app", "perms": "r-x"}, {"identity": "root", "perms": "rwx"}]
    assert perms.acl_args(MANIFEST, acl, False) == ["-m", "u:1000:r-x", "-m", "u:0:rwx"]
    assert perms.acl_args(MANIFEST, acl, True) == [
        "-m",
        "d:u:1000:r-x",
        "-m",
        "d:u:0:rwx",
    ]


def test_is_dir_namespace(perms, runner, root):
    assert perms.is_dir_namespace(root, "podman") is True
    assert runner.calls == [["podman", "unshare", "test", "-d", str(root)]]
    runner.respond = lambda cmd: (1, "", "")
    assert perms.is_dir_namespace(root, "docker") is False


def test_set_acl_without_any_acl_does_nothing(perms, runner):
    perms.set_acl(MANIFEST, _entry(), runtime="docker", recursive=True, dry_run=False)
    assert runner.calls == []


def test_set_acl_recursive(perms, runner, root):
    path = str(root / "configs/app")
    entry = _entry(
        acl=[{"identity": "app", "perms": "r-x"}],
        default_acl=[{"identity": "app", "perms": "rwx"}],
    )
    perms.set_acl(MANIFEST, entry, runtime="docker", recursive=True, dry_run=False)
    assert runner.calls == [
        ["setfacl", "-m", "u:1000:r-x", "-R", "-m", "m::r-x", path],
        [
            "find", path, "-type", "d", "-exec", "setfacl",
            "-m", "d:u:1000:rwx", "-m", "d:m::rwx", "{}", "+",
        ],
    ]  # fmt: skip


def test_set_acl_single_directory(perms, runner, root):
    path = str(root / "configs/app")
    entry = _entry(
        acl=[{"identity": "app", "perms": "rwx"}],
        default_acl=[{"identity": "app", "perms": "r-x"}],
    )
    perms.set_acl(MANIFEST, entry, runtime="docker", recursive=False, dry_run=False)
    assert runner.calls == [
        ["setfacl", "-m", "u:1000:rwx", "-m", "m::rwx", path],
        ["test", "-d", path],
        ["setfacl", "-m", "d:u:1000:r-x", "-m", "d:m::r-x", path],
    ]


def test_set_acl_dry_run_does_not_ask_whether_it_is_a_directory(perms, runner, root):
    entry = _entry(default_acl=[{"identity": "app", "perms": "r-x"}])
    perms.set_acl(MANIFEST, entry, runtime="docker", recursive=False, dry_run=True)
    assert runner.calls == [
        ["setfacl", "-m", "d:u:1000:r-x", "-m", "d:m::r-x", str(root / "configs/app")]
    ]


def test_set_acl_skips_the_default_acl_on_a_file(perms, runner):
    runner.respond = lambda cmd: (1, "", "") if cmd[0] == "test" else (0, "", "")
    entry = _entry(default_acl=[{"identity": "app", "perms": "r-x"}])
    perms.set_acl(MANIFEST, entry, runtime="docker", recursive=False, dry_run=False)
    assert [cmd[0] for cmd in runner.calls] == ["test"]


def test_set_acl_failures(perms, runner):
    entry = _entry(acl=[{"identity": "app", "perms": "r-x"}])
    runner.respond = lambda cmd: (1, "", "acl said no")
    with pytest.raises(SystemExit, match="acl said no"):
        perms.set_acl(MANIFEST, entry, runtime="docker", recursive=False, dry_run=False)
    runner.respond = lambda cmd: (1, "", "")
    with pytest.raises(SystemExit, match="failed: "):
        perms.set_acl(MANIFEST, entry, runtime="docker", recursive=False, dry_run=False)
    entry = _entry(default_acl=[{"identity": "app", "perms": "r-x"}])
    runner.respond = lambda cmd: (1, "", "default said no")
    with pytest.raises(SystemExit, match="default said no"):
        perms.set_acl(MANIFEST, entry, runtime="docker", recursive=True, dry_run=False)
    runner.respond = lambda cmd: (1, "", "")
    with pytest.raises(SystemExit, match="failed: "):
        perms.set_acl(MANIFEST, entry, runtime="docker", recursive=True, dry_run=False)


def test_expected_stat_mode(perms):
    assert perms.expected_stat_mode(MANIFEST, _entry()) == "0750"
    writable = _entry(default_acl=[{"identity": "app", "perms": "rwx"}])
    assert perms.expected_stat_mode(MANIFEST, writable) == "0770"


def test_path_mode(perms, root):
    target = root / "f"
    target.write_text("")
    target.chmod(0o640)
    assert perms.path_mode(target) == "0640"


def test_stat_namespace(perms, runner, root):
    runner.respond = lambda cmd: (0, "1000 1001 750\n", "")
    assert perms.stat_namespace(root, "podman") == (1000, 1001, "0750")
    assert runner.calls == [["podman", "unshare", "stat", "-c", "%u %g %a", str(root)]]
    runner.respond = lambda cmd: (1, "", "no such file\n")
    with pytest.raises(SystemExit, match="^no such file$"):
        perms.stat_namespace(root, "podman")


def test_getfacl_namespace(perms, runner, root):
    runner.respond = lambda cmd: (0, "user::rwx\n\n user:5:r-x \n", "")
    assert perms.getfacl_namespace(root, "docker") == {"user::rwx", "user:5:r-x"}
    assert runner.calls == [["getfacl", "-cpn", str(root)]]
    runner.respond = lambda cmd: (1, "", "unsupported")
    with pytest.raises(SystemExit, match="unsupported"):
        perms.getfacl_namespace(root, "docker")


def test_manifest_entry_for_path(perms, root):
    manifest = {"paths": [{"path": "a"}, {"path": "b"}]}
    assert perms.manifest_entry_for_path(manifest, root / "b") == {"path": "b"}
    assert perms.manifest_entry_for_path(manifest, root / "c") is None
    assert perms.manifest_entry_for_path({}, root / "a") is None


# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------


def _check_responder(root, *, stats, acls=None, dirs=(), acl_fail=()):
    """Answers stat, getfacl and test -d per relative path."""

    def respond(cmd):
        rel = str(Path(cmd[-1]).relative_to(root))
        if cmd[0] == "stat":
            if rel not in stats:
                return 1, "", f"cannot stat {rel}"
            return 0, stats[rel], ""
        if cmd[0] == "getfacl":
            if rel in acl_fail:
                return 1, "", "getfacl broke"
            return 0, "\n".join((acls or {}).get(rel, [])), ""
        if cmd[0] == "test":
            return (0 if rel in dirs else 1), "", ""
        raise AssertionError(cmd)

    return respond


def test_check_passes_on_a_tree_matching_the_manifest(perms, runner, root, capsys):
    manifest = {
        **MANIFEST,
        "paths": [{"path": "configs/app", "owner": "app", "mode": "0750"}],
    }
    runner.respond = _check_responder(root, stats={"configs/app": "1000 1001 750"})
    assert perms.check(manifest, runtime="docker") == 0
    assert capsys.readouterr().out == "permissions manifest check passed\n"


def test_check_reports_every_kind_of_drift(perms, runner, root, monkeypatch, capsys):
    monkeypatch.setattr(
        perms, "mount_table", lambda: ((str(root / "data/share"), "cifs"),)
    )
    config = root / "configs/app/config"
    config.mkdir(parents=True)
    (config / "Right").symlink_to("/right")
    (config / "Wrong").symlink_to("/old")
    (config / "Dir").mkdir()
    manifest = {
        **MANIFEST,
        "host_access": HOST,
        "paths": [
            {"path": "data/share", "owner": "app", "mode": "0750"},
            {"path": "gone", "owner": "app", "mode": "0750"},
            {"path": "owner", "owner": "app", "mode": "0750"},
            {"path": "bare", "owner": "app", "mode": "0770"},
            {"path": "nodefault", "owner": "app", "mode": "0770"},
            {"path": "file", "owner": "app", "mode": "0770"},
            {"path": "good", "owner": "app", "mode": "0770"},
        ],
        "symlinks": [
            {"path": "configs/app/config/Right", "target": "/right"},
            {"path": "configs/app/config/Wrong", "target": "/new"},
            {"path": "configs/app/config/Dir", "target": "/dir"},
            {"path": "configs/app/config/Missing", "target": "/missing"},
        ],
    }
    full = ["user:2000:rwx", "default:user:2000:rwx"]
    runner.respond = _check_responder(
        root,
        stats={
            "owner": "0 0 755",
            "bare": "1000 1001 770",
            "nodefault": "1000 1001 770",
            "file": "1000 1001 770",
            "good": "1000 1001 770",
        },
        acls={"nodefault": ["user:2000:rwx"], "file": full[:1], "good": full},
        dirs={"bare", "nodefault", "good"},
        acl_fail={"owner"},
    )
    assert perms.check(manifest, runtime="docker") == 1
    out = capsys.readouterr().out.splitlines()
    assert out == [
        "note: skipped ownership and ACLs for 1 path(s) on cifs: data/share",
        "      cifs carries no per-file ownership or POSIX ACLs; access there "
        "comes from the mount options instead.",
        "missing or inaccessible: gone: cannot stat gone",
        "owner: owner 0:0, expected 1000:1001",
        "owner: mode 0755, expected 0770",
        "owner: cannot inspect ACL: getfacl broke",
        "bare: missing host ACL user:2000:rwx",
        "bare: missing host default ACL default:user:2000:rwx",
        "nodefault: missing host default ACL default:user:2000:rwx",
        "configs/app/config/Wrong: points at /old, expected /new",
        "configs/app/config/Dir: expected a symlink to /dir, found a directory",
        "configs/app/config/Missing: expected a symlink to /missing, found missing",
    ]


def test_check_skips_acl_inspection_without_host_access(perms, runner, root):
    manifest = {**MANIFEST, "paths": [{"path": "a", "owner": "app", "mode": "0750"}]}
    runner.respond = _check_responder(root, stats={"a": "1000 1001 750"})
    assert perms.check(manifest, runtime="docker") == 0
    assert [cmd[0] for cmd in runner.calls] == ["stat"]


def test_check_with_only_a_default_host_acl(perms, runner, root):
    host = {"enabled": True, "identity": "host", "default_perms": "r-x"}
    manifest = {
        **MANIFEST,
        "host_access": host,
        "paths": [{"path": "a", "owner": "app", "mode": "0750"}],
    }
    runner.respond = _check_responder(
        root,
        stats={"a": "1000 1001 750"},
        acls={"a": ["default:user:2000:r-x"]},
        dirs={"a"},
    )
    assert perms.check(manifest, runtime="docker") == 0


# ---------------------------------------------------------------------------
# repair
# ---------------------------------------------------------------------------


def test_repair_needs_podman_for_the_podman_runtime(perms, monkeypatch):
    monkeypatch.setattr(perms.shutil, "which", lambda name: None)
    with pytest.raises(SystemExit, match="podman is required"):
        perms.repair(MANIFEST, runtime="podman", dry_run=False, recursive=False)


def test_repair_walks_the_manifest(perms, runner, root, monkeypatch, capsys):
    monkeypatch.setattr(perms.shutil, "which", lambda name: "/usr/bin/podman")
    monkeypatch.setattr(
        perms, "mount_table", lambda: ((str(root / "data/share"), "cifs"),)
    )
    manifest = {
        **MANIFEST,
        "paths": [
            {"path": "data/share", "owner": "app", "mode": "0750"},
            {
                "path": "configs/app",
                "owner": "app",
                "mode": "0750",
                "acl": [{"identity": "app", "perms": "r-x"}],
            },
        ],
        "symlinks": [{"path": "configs/app/config/Link", "target": "/link"}],
    }
    perms.repair(manifest, runtime="podman", dry_run=False, recursive=False)
    app = str(root / "configs/app")
    assert runner.calls == [
        ["podman", "unshare", "mkdir", "-p", str(root / "data/share")],
        ["podman", "unshare", "mkdir", "-p", app],
        ["podman", "unshare", "chown", "1000:1001", app],
        ["podman", "unshare", "chmod", "0750", app],
        ["podman", "unshare", "setfacl", "-m", "u:1000:r-x", "-m", "m::r-x", app],
    ]
    assert (root / "configs/app/config/Link").is_symlink()
    assert "on cifs: data/share" in capsys.readouterr().out


def test_repair_with_docker_does_not_look_for_podman(perms, runner, monkeypatch):
    monkeypatch.setattr(perms.shutil, "which", lambda name: pytest.fail("looked"))
    perms.repair(MANIFEST, runtime="docker", dry_run=True, recursive=True)
    assert runner.calls == []


# ---------------------------------------------------------------------------
# smoke and host_smoke
# ---------------------------------------------------------------------------


SMOKE_MANIFEST = {
    **MANIFEST,
    "paths": [{"path": "data/torrents", "owner": "app"}],
    "smoke_tests": {
        "hardlinks": [
            {
                "name": "import",
                "user": "host",
                "source_dir": "data/torrents",
                "target_dir": "data/media",
            },
            {
                "name": "undeclared",
                "user": "host",
                "source_dir": "data/elsewhere",
                "target_dir": "data/media",
            },
        ]
    },
}


def test_smoke_runs_the_hardlink_check(perms, runner, capsys):
    only_declared = {
        **SMOKE_MANIFEST,
        "smoke_tests": {"hardlinks": SMOKE_MANIFEST["smoke_tests"]["hardlinks"][:1]},
    }
    assert perms.smoke(only_declared, runtime="podman") == 0
    assert capsys.readouterr().out == "hardlink smoke tests passed\n"
    (cmd,) = runner.calls
    assert cmd[:4] == ["podman", "unshare", "sh", "-c"]
    assert cmd[4] == (
        "rm -f data/torrents/.permissions_source data/media/.permissions_target && "
        "setpriv --reuid 1000 --regid 1001 --clear-groups "
        "touch data/torrents/.permissions_source && "
        "setpriv --reuid 2000 --regid 2000 --clear-groups "
        "ln data/torrents/.permissions_source data/media/.permissions_target && "
        "rm -f data/torrents/.permissions_source data/media/.permissions_target"
    )


def test_smoke_reports_failures(perms, runner, capsys):
    runner.respond = lambda cmd: (1, "", "Operation not permitted\n")
    assert perms.smoke(SMOKE_MANIFEST, runtime="docker") == 1
    assert capsys.readouterr().out.splitlines() == [
        "import: Operation not permitted",
        "undeclared: source_dir is not declared in permissions.yml",
    ]
    runner.respond = lambda cmd: (1, "only stdout\n", "")
    assert perms.smoke(SMOKE_MANIFEST, runtime="docker") == 1
    assert capsys.readouterr().out.splitlines()[0] == "import: only stdout"


def test_smoke_with_no_tests_passes(perms, runner):
    assert perms.smoke(MANIFEST, runtime="docker") == 0
    assert runner.calls == []


def test_host_smoke_passes_and_cleans_up(perms, root, capsys):
    (root / "a/.host_access_smoke_dir_moved").mkdir(parents=True)
    manifest = {"paths": [{"path": "a"}, {"path": "not-a-dir"}]}
    assert perms.host_smoke(manifest) == 0
    assert capsys.readouterr().out == "host access smoke tests passed\n"
    assert list((root / "a").iterdir()) == []


def test_host_smoke_reports_and_cleans_up_after_a_failure(
    perms, root, monkeypatch, capsys
):
    (root / "a").mkdir()
    real_rename = perms.Path.rename

    def refuse_rename(self, target):
        raise PermissionError(13, "Permission denied")

    monkeypatch.setattr(perms.Path, "rename", refuse_rename)
    assert perms.host_smoke({"paths": [{"path": "a"}]}) == 1
    assert capsys.readouterr().out.startswith("a: [Errno 13] Permission denied")
    assert list((root / "a").iterdir()) == []
    monkeypatch.setattr(perms.Path, "rename", real_rename)


def test_host_smoke_cleanup_removes_a_leftover_file(perms, root, monkeypatch):
    (root / "a").mkdir()
    real_unlink = perms.Path.unlink
    attempts = []

    def flaky_unlink(self, missing_ok=False):
        attempts.append(self.name)
        if len(attempts) == 1:
            raise OSError("first unlink fails")
        real_unlink(self, missing_ok=missing_ok)

    monkeypatch.setattr(perms.Path, "unlink", flaky_unlink)
    assert perms.host_smoke({"paths": [{"path": "a"}]}) == 1
    assert attempts == [".host_access_smoke", ".host_access_smoke"]
    assert list((root / "a").iterdir()) == []


def test_host_smoke_cleanup_ignores_its_own_errors(perms, root, monkeypatch):
    (root / "a").mkdir()

    def broken_mkdir(self, *args, **kwargs):
        raise OSError("mkdir fails")

    def broken_rmdir(self):
        raise OSError("rmdir fails too")

    real_is_dir = perms.Path.is_dir

    def leftover_dir(self):
        return self.name == ".host_access_smoke_dir" or real_is_dir(self)

    monkeypatch.setattr(perms.Path, "mkdir", broken_mkdir)
    monkeypatch.setattr(perms.Path, "rmdir", broken_rmdir)
    monkeypatch.setattr(perms.Path, "is_dir", leftover_dir)
    assert perms.host_smoke({"paths": [{"path": "a"}]}) == 1


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------


@pytest.fixture
def manifest_file(root):
    (root / "permissions.yml").write_text(yaml.safe_dump(MANIFEST))


@pytest.mark.parametrize(
    ("argv", "called", "kwargs"),
    [
        (["check"], "check", {"runtime": "podman"}),
        (["smoke", "--runtime", "docker"], "smoke", {"runtime": "docker"}),
        (["host-smoke"], "host_smoke", {}),
        (
            ["repair", "--recursive"],
            "repair",
            {"runtime": "podman", "dry_run": False, "recursive": True},
        ),
        (
            ["dry-run"],
            "repair",
            {"runtime": "podman", "dry_run": True, "recursive": False},
        ),
    ],
)
def test_main_dispatches(perms, manifest_file, monkeypatch, argv, called, kwargs):
    seen = []
    monkeypatch.delenv("CONTAINER_RUNTIME", raising=False)
    for name in ("check", "smoke", "host_smoke", "repair"):
        monkeypatch.setattr(
            perms,
            name,
            lambda manifest, _name=name, **kw: seen.append((_name, manifest, kw)) or 7,
        )
    monkeypatch.setattr(perms.sys, "argv", ["permissions.py", *argv])
    expected = 0 if called == "repair" else 7
    assert perms.main() == expected
    assert seen == [(called, MANIFEST, kwargs)]


def test_main_reads_the_runtime_from_the_environment(perms, manifest_file, monkeypatch):
    seen = []
    monkeypatch.setenv("CONTAINER_RUNTIME", "docker")
    monkeypatch.setattr(perms, "check", lambda manifest, **kw: seen.append(kw) or 0)
    monkeypatch.setattr(perms.sys, "argv", ["permissions.py", "check"])
    assert perms.main() == 0
    assert seen == [{"runtime": "docker"}]
