"""Tests for .claude/hooks/git-guard.sh, the PreToolUse hook on the Bash tool.

The hook enforces three rules that were prose in AGENTS.md and got broken
anyway: no skipping the pre-commit hooks, no working-tree git operations while
the stack is running, and no committing into a clone where the hooks were never
installed.

Nothing here touches the real stack; podman is stubbed on PATH so both stack
states are deterministic. Rule 3 does need real repositories, so those cases
build throwaway ones under tmp_path rather than asking about this checkout,
whose answer depends on whether anyone has run `pre-commit install` in it (CI
never has, a developer's clone usually has).

Run explicitly with:
    pytest -m scripts tests/test_git_guard.py
"""

import json
import os
import shutil
import subprocess

import pytest

from conftest import REPO_ROOT

pytestmark = pytest.mark.scripts

GIT_GUARD = REPO_ROOT / ".claude/hooks/git-guard.sh"
SETTINGS = REPO_ROOT / ".claude/settings.json"


def _hook_command():
    settings = json.loads(SETTINGS.read_text())
    entries = [e for e in settings["hooks"]["PreToolUse"] if e["matcher"] == "Bash"]
    assert entries, "no PreToolUse hook on the Bash matcher"
    return entries[0]["hooks"][0]["command"]


@pytest.fixture
def stub_bin(tmp_path):
    """Builds a PATH whose podman reports whichever stack state is asked for."""

    def _build(*, containers_running, with_jq=True):
        binstub = tmp_path / f"bin-{containers_running}-{with_jq}"
        binstub.mkdir(exist_ok=True)
        podman = binstub / "podman"
        podman.write_text(
            "#!/bin/sh\n" + ("echo qbittorrent\n" if containers_running else "exit 0\n")
        )
        podman.chmod(0o755)
        path = f"{binstub}:{os.environ['PATH']}"
        if not with_jq:
            # An isolated PATH with no jq on it at all, rather than a stub that
            # fails: the hook checks availability before it checks parsing. It
            # still needs enough to reach that check and print the refusal.
            for tool in ("bash", "cat"):
                target = shutil.which(tool)
                assert target, f"{tool} not found, cannot build the no-jq PATH"
                link = binstub / tool
                if not link.exists():
                    link.symlink_to(target)
            path = str(binstub)
        return path

    return _build


def _init_repo(path, *, uses_pre_commit=True, hook_installed=True, executable=True):
    """A throwaway git repository in whichever rule 3 state is asked for."""
    path.mkdir(parents=True, exist_ok=True)
    subprocess.run(  # noqa: S603 - fixed argv, path is pytest's tmp_path
        ["git", "init", "-q", str(path)], check=True, capture_output=True, timeout=60
    )
    if uses_pre_commit:
        (path / ".pre-commit-config.yaml").touch()
    if hook_installed:
        hook = path / ".git" / "hooks" / "pre-commit"
        hook.write_text("#!/bin/sh\n")
        hook.chmod(0o755 if executable else 0o644)
    return path


_DEFAULT_CWD = None


@pytest.fixture(scope="session", autouse=True)
def default_cwd(tmp_path_factory):
    """The directory every case that is not about rule 3 reports as its cwd.

    Without this they inherit this checkout, where rule 3's answer depends on
    whether `pre-commit install` has been run: locally it usually has, in CI it
    never has, so `git commit -m x` would be allowed on one and refused on the
    other. Pointing them at a repository that is unambiguously installed keeps
    every rule 1 and rule 2 expectation about the same thing it was before.
    """
    global _DEFAULT_CWD
    repo = _init_repo(tmp_path_factory.mktemp("hooks-installed"))
    _DEFAULT_CWD = str(repo)
    return repo


def _decision(tool_command, path, cwd=None):
    """Returns "allow" or "deny" for a command, plus the refusal reason."""
    payload = json.dumps(
        {
            "tool_name": "Bash",
            "cwd": str(cwd) if cwd is not None else _DEFAULT_CWD,
            "tool_input": {"command": tool_command},
        }
    )
    result = subprocess.run(  # noqa: S603 - GIT_GUARD is a path inside this repo
        ["bash", str(GIT_GUARD)],
        input=payload,
        capture_output=True,
        text=True,
        timeout=60,
        env={**os.environ, "PATH": path, "CLAUDE_PROJECT_DIR": str(REPO_ROOT)},
    )
    assert result.returncode == 0, "the hook must never fail the tool call"
    if not result.stdout.strip():
        return "allow", ""
    payload = json.loads(result.stdout)["hookSpecificOutput"]
    return payload["permissionDecision"], payload["permissionDecisionReason"]


# ---------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------


def test_settings_json_is_valid():
    """A malformed settings.json silently disables every setting in it."""
    json.loads(SETTINGS.read_text())


def test_settings_json_keeps_its_permission_rules():
    """The hook was merged into a file that already carried allow rules."""
    allow = json.loads(SETTINGS.read_text())["permissions"]["allow"]
    assert "Bash(podman ps *)" in allow
    assert "Bash(podman logs *)" in allow


def test_settings_json_allows_only_read_only_commands():
    """An allow rule skips the permission prompt, so every one stays read only.

    Any other checkout of this project running on the same host can share its
    Compose project label, so an allowed `podman stop *` could stop those
    containers without anyone being asked. `cat *` would read any file on the
    host, credentials included, with no prompt either.
    """
    allow = json.loads(SETTINGS.read_text())["permissions"]["allow"]
    changing = {"stop", "kill", "rm", "rmi", "restart", "pause", "down", "compose"}
    container_changes = [
        rule
        for rule in allow
        if rule.startswith(("Bash(podman ", "Bash(docker "))
        and rule.split()[1] in changing
    ]
    assert not container_changes
    assert "Bash(cat *)" not in allow


def test_hook_script_exists_and_is_executable():
    """settings.json refers to it by path, so a missing or non-executable file
    means the hook silently never fires."""
    assert GIT_GUARD.is_file(), f"{GIT_GUARD} does not exist"
    assert os.access(GIT_GUARD, os.X_OK), f"{GIT_GUARD} is not executable"
    assert "git-guard.sh" in _hook_command()


def test_hook_derives_the_project_name_rather_than_hardcoding_it():
    """A clone under a different directory name has a different Compose
    project label, and a hardcoded one would find no containers and allow
    everything. storage-mount.sh derives it the same way."""
    source = GIT_GUARD.read_text()
    assert "CLAUDE_PROJECT_DIR" in source
    assert "docker-torrent-box-with-vpn" not in source


# ---------------------------------------------------------------------------
# Rule 1: never skip the pre-commit hooks
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "bypass",
    [
        "git commit --no-verify -m x",
        "git commit -n -m x",
        "git commit -m x --no-verify",
        "git push --no-verify",
        "git push origin main --no-verify",
        "cd /tmp && git commit --no-verify -m x",
        "true; git push --no-verify",
        # Global options before the subcommand.
        "git -C . commit --no-verify",
        "git -C /repo push --no-verify",
        "git -c user.email=x commit --no-verify -m y",
        # Quoting the flag still passes it to git.
        'git commit "--no-verify" -m x',
        "git commit '--no-verify' -m x",
        # Scoping the flag to the command's own arguments must not open a way
        # through by parking a heredoc after it.
        "git commit --no-verify -F - <<MSG\nbody\nMSG",
    ],
)
def test_blocks_skipping_the_pre_commit_hooks(bypass, stub_bin):
    """The secret scanners run as pre-commit hooks.

    A bypassed commit is an unscanned commit, and this repository is public, so
    that is how a credential gets published. Refused whether or not the stack
    is running: the risk is the missing scan, not the stash.
    """
    decision, _ = _decision(bypass, stub_bin(containers_running=False))
    assert decision == "deny", f"{bypass!r} was not blocked"


def test_bypass_refusal_explains_the_supported_path(stub_bin):
    """A refusal that does not say what to do instead invites working around
    it, which is how --no-verify got used in the first place."""
    _, reason = _decision(
        "git commit --no-verify -m x", stub_bin(containers_running=False)
    )
    assert "make stop_all" in reason
    assert "secret" in reason.lower()


@pytest.mark.parametrize(
    "allowed",
    [
        "git commit -m x",
        "git push",
        "git push -n",  # -n on push is --dry-run, which is harmless
        "git push --dry-run",
        "git status",
        "git log --oneline -5",
        "git diff",
        "git log -n 5",
        # Quoted spans naming the flag are data. This hook refused the very
        # commit that introduced it, because the message explained the rule.
        'git commit -m "do not use --no-verify here"',
        "git commit -m 'refuse -n and --no-verify'",
        "echo 'git commit --no-verify'",
        'echo "--no-verify"',
        # A heredoc body is data too, and is not a quoted span, so the flag had
        # to be scoped to that git command's own arguments. This refused the
        # introducing commit a second time, via its message.
        "git commit -F - <<MSG\nA bare -n on push is allowed\nabout --no-verify\nMSG",
        # -n here belongs to grep, on the far side of a pipe.
        "git commit -F - | grep -n foo",
    ],
)
def test_allows_verified_git_with_the_stack_stopped(allowed, stub_bin):
    decision, _ = _decision(allowed, stub_bin(containers_running=False))
    assert decision == "allow", f"{allowed!r} was blocked"


# ---------------------------------------------------------------------------
# Rule 2: no working-tree rewrites against a running stack
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "subcommand",
    [
        "stash -u",
        "commit -m x",
        "checkout main",
        "switch -c topic",
        # Everything below rewrites tracked files at least as thoroughly as the
        # stash that caused the original corruption, and all of it was allowed
        # until CodeRabbit pointed it out on PR #38.
        "restore .",
        "reset --hard",
        "revert abc123",
        "merge main",
        "rebase main",
        "cherry-pick abc123",
        "am patch.mbox",
        "apply patch.diff",
        "clean -fdx",
        "mv a b",
        "rm -r x",
        "pull",
    ],
)
def test_blocks_working_tree_rewrites_while_the_stack_runs(subcommand, stub_bin):
    """pre-commit's stash cycle rewrote tracked runtime files mid-flight and
    corrupted live SQLite databases. AGENTS.md warned about it and the warning
    was not enough, so this is enforced."""
    decision, _ = _decision(f"git {subcommand}", stub_bin(containers_running=True))
    assert decision == "deny", f"git {subcommand} was not blocked"


@pytest.mark.parametrize(
    "invocation",
    [
        "git -C . stash",
        "git -C /repo restore .",
        "git --no-pager reset --hard",
        "git -c core.editor=true commit -m x",
        "cd /tmp && git -C . checkout main",
    ],
)
def test_global_options_do_not_bypass_the_stack_guard(invocation, stub_bin):
    """git accepts its own options before the subcommand, so `git -C /repo
    stash` is a stash and has to be caught as one."""
    decision, _ = _decision(invocation, stub_bin(containers_running=True))
    assert decision == "deny", f"{invocation!r} was not blocked"


@pytest.mark.parametrize(
    "readonly",
    ["git status", "git log --oneline -5", "git diff", "git show HEAD", "git push"],
)
def test_allows_read_only_git_while_the_stack_runs(readonly, stub_bin):
    """Reading history mutates nothing and must stay available."""
    decision, _ = _decision(readonly, stub_bin(containers_running=True))
    assert decision == "allow", f"{readonly!r} was blocked"


@pytest.mark.parametrize(
    "benign",
    [
        "echo 'git commit'",
        "grep -r 'git stash' docs/",
        # The unquoted cases are the ones that exercise the anchoring. A
        # mention ending in a quote is rejected by the trailing
        # ([[:space:]]|$) whatever the anchor does, so quoted cases alone pass
        # even with the anchor removed. Mutation testing surfaced that.
        "echo git commit -n",
        "echo git stash here",
        "printf '%s' git checkout main",
        "ls -la",
        "cat README.md",
    ],
)
def test_ignores_commands_that_merely_mention_git(benign, stub_bin):
    """The first version of this hook matched substrings and blocked its own
    test command."""
    decision, _ = _decision(benign, stub_bin(containers_running=True))
    assert decision == "allow", f"{benign!r} was blocked"


def test_allows_working_tree_rewrites_once_the_stack_is_stopped(stub_bin):
    """The rule is about live containers, not about the commands themselves."""
    path = stub_bin(containers_running=False)
    for subcommand in ("stash -u", "restore .", "reset --hard", "commit -m x"):
        decision, _ = _decision(f"git {subcommand}", path)
        assert decision == "allow", f"git {subcommand} was blocked with no stack"


# ---------------------------------------------------------------------------
# Failure modes
# ---------------------------------------------------------------------------


def test_fails_closed_when_the_payload_cannot_be_parsed():
    """A hook that allows everything the moment something goes wrong is worse
    than no hook, because it still reads as protection."""
    result = subprocess.run(  # noqa: S603 - GIT_GUARD is a path inside this repo
        ["bash", str(GIT_GUARD)],
        input="not-json",
        capture_output=True,
        text=True,
        timeout=60,
        env={**os.environ, "CLAUDE_PROJECT_DIR": str(REPO_ROOT)},
    )
    assert result.returncode == 0
    assert json.loads(result.stdout)["hookSpecificOutput"]["permissionDecision"] == (
        "deny"
    )


def test_fails_closed_when_jq_is_unavailable(stub_bin):
    """Without jq the hook cannot read the command at all."""
    decision, reason = _decision(
        "ls -la", stub_bin(containers_running=False, with_jq=False)
    )
    assert decision == "deny"
    assert "jq" in reason


def test_consults_podman_only_after_the_command_matches(stub_bin):
    """A command that is not a git working-tree operation must not depend on
    podman at all, so the common case costs nothing and cannot misfire."""
    decision, _ = _decision("ls -la", stub_bin(containers_running=True))
    assert decision == "allow"


def test_never_fails_the_tool_call(stub_bin):
    """Any non-zero exit from a PreToolUse hook is itself disruptive."""
    path = stub_bin(containers_running=True)
    for command in ("git stash", "ls -la", "git commit --no-verify -m x"):
        decision, _ = _decision(command, path)
        assert decision in ("allow", "deny")


# ---------------------------------------------------------------------------
# Telling commands apart from text that reads like one
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "readonly_stash",
    ["git stash list", "git stash show", "git stash show -p", "git -C . stash list"],
)
def test_allows_read_only_stash_subcommands(readonly_stash, stub_bin):
    """These only read. Blocking them was a live false positive: inspecting
    the stash list while the stack ran got refused."""
    decision, _ = _decision(readonly_stash, stub_bin(containers_running=True))
    assert decision == "allow", f"{readonly_stash!r} was blocked"


def test_read_only_stash_does_not_exempt_the_rest_of_the_line(stub_bin):
    """Written as "unless the command mentions stash list", this exemption
    would have let the reset through with it."""
    decision, _ = _decision(
        "git stash list; git reset --hard", stub_bin(containers_running=True)
    )
    assert decision == "deny"


@pytest.mark.parametrize(
    "quoted",
    [
        "echo 'git stash list; git reset --hard'",
        'echo "git reset --hard"',
        "grep -r 'git clean -fdx' docs/",
    ],
)
def test_quoted_text_that_reads_like_a_command_is_not_one(quoted, stub_bin):
    """Rule 2 removes whole quoted spans rather than just the quote
    characters. Sharing rule 1's normalization here, which strips the
    characters so that git commit "--no-verify" is still caught, made these
    test-case strings look like real commands."""
    decision, _ = _decision(quoted, stub_bin(containers_running=True))
    assert decision == "allow", f"{quoted!r} was blocked"


@pytest.mark.parametrize(
    "wrapped",
    [
        "command git commit -m x",
        "env CI=1 git reset --hard",
        "env A=1 B=2 git stash",
        "/usr/bin/git push --no-verify",
        "sudo git clean -fdx",
        "\\git stash",
        "exec git rebase main",
        "time git merge main",
    ],
)
def test_wrapped_git_invocations_are_still_git(wrapped, stub_bin):
    """git is not always spelled "git" at the start of the command, and every
    one of these ran it while walking straight past the matchers."""
    decision, _ = _decision(wrapped, stub_bin(containers_running=True))
    assert decision == "deny", f"{wrapped!r} was not blocked"


@pytest.mark.parametrize(
    "not_git", ["mygit stash", "digit reset", "./scripts/gitless.sh", "legit commit"]
)
def test_wrapper_matching_does_not_over_reach(not_git, stub_bin):
    """Allowing a path prefix must not turn any word ending in git into git."""
    decision, _ = _decision(not_git, stub_bin(containers_running=True))
    assert decision == "allow", f"{not_git!r} was blocked"


def test_honours_an_overridden_compose_project_name(tmp_path):
    """The Makefile takes COMPOSE_PROJECT_NAME from the environment before
    falling back to the directory name. Deriving it from the directory alone
    means an install that overrides it finds no containers, and the guard
    quietly passes everything."""
    binstub = tmp_path / "bin"
    binstub.mkdir()
    podman = binstub / "podman"
    podman.write_text(
        '#!/bin/sh\ncase "$*" in *custom-project*) echo qbittorrent;; esac\n'
    )
    podman.chmod(0o755)
    path = f"{binstub}:{os.environ['PATH']}"

    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": "git stash"}})

    def decide(project):
        env = {**os.environ, "PATH": path, "CLAUDE_PROJECT_DIR": str(REPO_ROOT)}
        env["COMPOSE_PROJECT_NAME"] = project
        result = subprocess.run(  # noqa: S603 - GIT_GUARD is a path inside this repo
            ["bash", str(GIT_GUARD)],
            input=payload,
            capture_output=True,
            text=True,
            timeout=60,
            env=env,
        )
        return "deny" if result.stdout.strip() else "allow"

    assert decide("custom-project") == "deny", "the override was ignored"
    assert decide("") == "allow", "the stub reports no containers for the default name"


def test_heredoc_bodies_are_data(stub_bin):
    """A heredoc body runs across lines and each line can look exactly like a
    command, so writing a test case or a commit message in one was reading as
    the command it described."""
    decision, _ = _decision(
        "cat > f <<PYEOF\ngit stash list; git reset --hard\nPYEOF",
        stub_bin(containers_running=True),
    )
    assert decision == "allow"


def test_a_command_after_a_heredoc_still_counts(stub_bin):
    """Skipping to the terminator, not to the end of the command."""
    decision, _ = _decision(
        "cat > f <<PYEOF\nharmless\nPYEOF\ngit reset --hard",
        stub_bin(containers_running=True),
    )
    assert decision == "deny"


# ---------------------------------------------------------------------------
# Rule 3: no committing where the hooks were never installed
#
# `git clone` does not install them, so a fresh clone runs nothing on commit and
# still reports success. On 2026-08-12 that put two commits into a test bench
# and failed CI on findings the hooks catch locally. Rule 1 only ever sees an
# explicit --no-verify, so it cannot help here.
# ---------------------------------------------------------------------------


def test_blocks_a_commit_where_the_hook_is_not_installed(tmp_path, stub_bin):
    repo = _init_repo(tmp_path / "fresh-clone", hook_installed=False)
    decision, reason = _decision(
        "git commit -m x", stub_bin(containers_running=False), cwd=repo
    )
    assert decision == "deny"
    assert "pre-commit install" in reason, "the refusal must say how to fix it"


def test_allows_a_commit_where_the_hook_is_installed(tmp_path, stub_bin):
    repo = _init_repo(tmp_path / "installed")
    decision, _ = _decision(
        "git commit -m x", stub_bin(containers_running=False), cwd=repo
    )
    assert decision == "allow"


def test_repos_that_do_not_configure_pre_commit_are_left_alone(tmp_path, stub_bin):
    """Otherwise every unrelated repository would be refused for missing a hook
    it never asked for."""
    repo = _init_repo(
        tmp_path / "no-pre-commit", uses_pre_commit=False, hook_installed=False
    )
    decision, _ = _decision(
        "git commit -m x", stub_bin(containers_running=False), cwd=repo
    )
    assert decision == "allow"


def test_a_directory_that_is_not_a_repo_is_left_alone(tmp_path, stub_bin):
    """git itself gives a clear error; refusing here would replace it with a
    confusing one."""
    plain = tmp_path / "not-a-repo"
    plain.mkdir()
    decision, _ = _decision(
        "git commit -m x", stub_bin(containers_running=False), cwd=plain
    )
    assert decision == "allow"


def test_a_present_but_non_executable_hook_does_not_count(tmp_path, stub_bin):
    """git skips a hook it cannot execute, silently, which is the whole problem
    this rule exists for."""
    repo = _init_repo(tmp_path / "chmod-644", executable=False)
    decision, _ = _decision(
        "git commit -m x", stub_bin(containers_running=False), cwd=repo
    )
    assert decision == "deny"


def test_core_hooks_path_counts_as_installed(tmp_path, stub_bin):
    """Hooks do not have to live in .git/hooks, so the lookup asks git where
    they are rather than assuming."""
    repo = _init_repo(tmp_path / "hooks-path", hook_installed=False)
    elsewhere = tmp_path / "shared-hooks"
    elsewhere.mkdir()
    hook = elsewhere / "pre-commit"
    hook.write_text("#!/bin/sh\n")
    hook.chmod(0o755)
    subprocess.run(  # noqa: S603 - fixed argv, paths are pytest's tmp_path
        ["git", "-C", str(repo), "config", "core.hooksPath", str(elsewhere)],
        check=True,
        capture_output=True,
        timeout=60,
    )
    decision, _ = _decision(
        "git commit -m x", stub_bin(containers_running=False), cwd=repo
    )
    assert decision == "allow"


@pytest.mark.parametrize("hook_installed", [True, False])
def test_a_worktree_answers_for_the_repo_it_belongs_to(
    hook_installed, tmp_path, stub_bin
):
    """A worktree has no .git/hooks of its own; it shares the parent's. Asking
    for .git/hooks relative to the worktree would refuse every commit made in
    one, however well installed the parent is."""
    repo = _init_repo(
        tmp_path / f"parent-{hook_installed}", hook_installed=hook_installed
    )
    for argv in (
        ["git", "-C", str(repo), "add", "-A"],
        [
            "git",
            "-C",
            str(repo),
            "-c",
            "user.email=t@e",
            "-c",
            "user.name=t",
            "commit",
            "-q",
            "--no-verify",
            "-m",
            "init",
        ],
        [
            "git",
            "-C",
            str(repo),
            "worktree",
            "add",
            "-q",
            "--detach",
            str(tmp_path / f"wt-{hook_installed}"),
            "HEAD",
        ],
    ):
        subprocess.run(argv, check=True, capture_output=True, timeout=60)  # noqa: S603
    decision, _ = _decision(
        "git commit -m x",
        stub_bin(containers_running=False),
        cwd=tmp_path / f"wt-{hook_installed}",
    )
    assert decision == ("allow" if hook_installed else "deny")


def test_a_leading_cd_decides_which_repo_is_checked(tmp_path, stub_bin):
    """Commands against another checkout are written `cd <dir> && git ...`, so
    the session directory is the wrong thing to ask about."""
    installed = _init_repo(tmp_path / "cd-installed")
    fresh = _init_repo(tmp_path / "cd-fresh", hook_installed=False)

    denied, _ = _decision(
        f"cd {fresh} && git add -A && git commit -m x",
        stub_bin(containers_running=False),
        cwd=installed,
    )
    allowed, _ = _decision(
        f"cd {installed} && git commit -m x",
        stub_bin(containers_running=False),
        cwd=fresh,
    )
    assert denied == "deny", "the cd target was ignored"
    assert allowed == "allow", "the session directory overrode the cd target"


@pytest.mark.parametrize(
    "read_only",
    ["git status", "git log --oneline -5", "git diff", "git push", "git stash list"],
)
def test_rule_three_only_looks_at_commits(read_only, tmp_path, stub_bin):
    repo = _init_repo(tmp_path / "reads", hook_installed=False)
    decision, _ = _decision(read_only, stub_bin(containers_running=False), cwd=repo)
    assert decision == "allow", f"{read_only!r} was blocked"


@pytest.mark.parametrize(
    "invocation",
    [
        "sudo git commit -m x",
        "\\git commit -m x",
        "/usr/bin/git commit -m x",
        "env CI=1 git commit -m x",
        "git -c user.name=x commit -m y",
        "make lint && git commit -m x",
    ],
)
def test_rule_three_sees_the_same_spellings_the_other_rules_do(
    invocation, tmp_path, stub_bin
):
    repo = _init_repo(tmp_path / "spellings", hook_installed=False)
    decision, _ = _decision(invocation, stub_bin(containers_running=False), cwd=repo)
    assert decision == "deny", f"{invocation!r} slipped past rule 3"


def test_a_commit_message_naming_the_rule_is_not_a_commit_elsewhere(tmp_path, stub_bin):
    """The quoted span is data. Rule 1 was refused by its own commit message
    twice over for exactly this reason."""
    repo = _init_repo(tmp_path / "message", hook_installed=False)
    decision, _ = _decision(
        "echo 'git commit needs pre-commit install'",
        stub_bin(containers_running=False),
        cwd=repo,
    )
    assert decision == "allow"


def test_a_cd_after_the_commit_does_not_decide_anything(tmp_path, stub_bin):
    """`git commit && cd /elsewhere` runs the commit where it already was.

    Taking the first cd anywhere in the string read the trailing one as the
    target and turned a refusal into a pass (CodeRabbit, PR #40).
    """
    installed = _init_repo(tmp_path / "after-installed")
    fresh = _init_repo(tmp_path / "after-fresh", hook_installed=False)
    decision, _ = _decision(
        f"git commit -m x && cd {installed}",
        stub_bin(containers_running=False),
        cwd=fresh,
    )
    assert decision == "deny"


def test_a_cd_on_a_later_line_does_not_decide_anything(tmp_path, stub_bin):
    """Newlines separate commands exactly as `;` does, so a cd below the commit
    is still after it."""
    installed = _init_repo(tmp_path / "line-installed")
    fresh = _init_repo(tmp_path / "line-fresh", hook_installed=False)
    decision, _ = _decision(
        f"git commit -m x\ncd {installed}",
        stub_bin(containers_running=False),
        cwd=fresh,
    )
    assert decision == "deny"


def test_a_cd_inside_a_subshell_does_not_move_the_commit(tmp_path, stub_bin):
    """Its effect ends with the subshell, so the session directory is still a
    candidate and an unhooked one there is still refused."""
    installed = _init_repo(tmp_path / "sub-installed")
    fresh = _init_repo(tmp_path / "sub-fresh", hook_installed=False)
    decision, _ = _decision(
        f"(cd {installed} && ls); git commit -m x",
        stub_bin(containers_running=False),
        cwd=fresh,
    )
    assert decision == "deny"


def test_any_unhooked_candidate_in_a_cd_chain_refuses(tmp_path, stub_bin):
    """Deliberately the conservative reading, not "the last cd wins".

    Only the final directory is the one git actually uses, so this refuses a
    commit that would have been fine. Resolving it properly means tracking shell
    state through the command; until then a wrong refusal costs one
    `pre-commit install`, while a wrong pass costs an unscanned commit in a
    public repository.
    """
    installed = _init_repo(tmp_path / "chain-installed")
    fresh = _init_repo(tmp_path / "chain-fresh", hook_installed=False)
    decision, _ = _decision(
        f"cd {installed} && cd {fresh} && git commit -m x",
        stub_bin(containers_running=False),
        cwd=installed,
    )
    assert decision == "deny"


def test_a_command_scoped_hooks_path_is_the_one_git_will_use(tmp_path, stub_bin):
    """`git -c core.hooksPath=<dir> commit` applies to that one command, so
    asking the repository where its hooks live answers about the wrong
    directory (CodeRabbit, PR #40)."""
    repo = _init_repo(tmp_path / "scoped")
    empty = tmp_path / "no-hooks-here"
    empty.mkdir()
    decision, _ = _decision(
        f"git -c core.hooksPath={empty} commit -m x",
        stub_bin(containers_running=False),
        cwd=repo,
    )
    assert decision == "deny", "the command-scoped hooks path was ignored"


def test_a_command_scoped_hooks_path_that_is_installed_is_allowed(tmp_path, stub_bin):
    """The override is honoured in both directions, not treated as suspicious
    in itself."""
    repo = _init_repo(tmp_path / "scoped-ok", hook_installed=False)
    elsewhere = tmp_path / "real-hooks"
    elsewhere.mkdir()
    hook = elsewhere / "pre-commit"
    hook.write_text("#!/bin/sh\n")
    hook.chmod(0o755)
    decision, _ = _decision(
        f"git -c core.hooksPath={elsewhere} commit -m x",
        stub_bin(containers_running=False),
        cwd=repo,
    )
    assert decision == "allow"


def test_every_commit_in_a_compound_command_is_checked(tmp_path, stub_bin):
    """Truncating at the first `git commit` hid a second one's directory.

    From a hooked session, `git commit -m a; cd /unhooked && git commit -m b`
    left nothing before the first commit, so only the session directory was
    checked and the second commit ran unhooked (CodeRabbit, PR #40).
    """
    installed = _init_repo(tmp_path / "multi-installed")
    fresh = _init_repo(tmp_path / "multi-fresh", hook_installed=False)
    decision, _ = _decision(
        f"git commit -m first; cd {fresh} && git commit -m second",
        stub_bin(containers_running=False),
        cwd=installed,
    )
    assert decision == "deny"


def test_the_hooks_path_key_is_matched_without_regard_to_case(tmp_path, stub_bin):
    """git config keys are case-insensitive, so `-c core.hookspath=<dir>` sets
    it just as well as the camel-cased spelling (CodeRabbit, PR #40)."""
    repo = _init_repo(tmp_path / "lowercase-key")
    empty = tmp_path / "lowercase-empty"
    empty.mkdir()
    decision, _ = _decision(
        f"git -c core.hookspath={empty} commit -m x",
        stub_bin(containers_running=False),
        cwd=repo,
    )
    assert decision == "deny"


def test_the_hooks_path_value_keeps_its_case(tmp_path, stub_bin):
    """Matching the key case-insensitively must not lowercase the path, which
    would stop resolving to a real directory."""
    repo = _init_repo(tmp_path / "MixedCase-repo", hook_installed=False)
    elsewhere = tmp_path / "MixedCase-Hooks"
    elsewhere.mkdir()
    hook = elsewhere / "pre-commit"
    hook.write_text("#!/bin/sh\n")
    hook.chmod(0o755)
    decision, _ = _decision(
        f"git -c core.hooksPath={elsewhere} commit -m x",
        stub_bin(containers_running=False),
        cwd=repo,
    )
    assert decision == "allow", "the path was probably case-folded"


@pytest.mark.parametrize("option", ["-L", "-P", "--"])
def test_cd_options_do_not_hide_the_directory(option, tmp_path, stub_bin):
    """`cd -P /repo` recorded `-P` as the directory, which is not a repository,
    so the real one went unchecked (CodeRabbit, PR #40)."""
    installed = _init_repo(tmp_path / f"opt-installed{option.strip('-') or 'dd'}")
    fresh = _init_repo(
        tmp_path / f"opt-fresh{option.strip('-') or 'dd'}", hook_installed=False
    )
    decision, _ = _decision(
        f"cd {option} {fresh} && git commit -m x",
        stub_bin(containers_running=False),
        cwd=installed,
    )
    assert decision == "deny"


@pytest.mark.parametrize(
    "selector",
    [
        "-C {fresh}",
        "--git-dir={fresh}/.git --work-tree={fresh}",
        "--git-dir {fresh}/.git",
        "--work-tree={fresh}",
    ],
)
def test_repository_selectors_are_refused_rather_than_guessed(
    selector, tmp_path, stub_bin
):
    """-C, --git-dir and --work-tree all point the commit at a repository other
    than the one the command appears to run in. None resolves from the text with
    any confidence, and guessing wrong means an unscanned commit rather than a
    refused one, so all three are refused with the rewrite named.

    Verified against git 2.55.0 that --git-dir/--work-tree really do relocate
    the commit (CodeRabbit, PR #40).
    """
    installed = _init_repo(tmp_path / f"sel-installed{abs(hash(selector))}")
    fresh = _init_repo(
        tmp_path / f"sel-fresh{abs(hash(selector))}", hook_installed=False
    )
    decision, reason = _decision(
        f"git {selector.format(fresh=fresh)} commit -m x",
        stub_bin(containers_running=False),
        cwd=installed,
    )
    assert decision == "deny"
    assert "cd <dir> && git commit" in reason, "the refusal must name the rewrite"


def test_a_selector_named_in_a_commit_message_is_data(tmp_path, stub_bin):
    """Quoted spans are data. Rule 1 was refused by its own commit message
    twice for exactly this reason."""
    repo = _init_repo(tmp_path / "selector-in-message")
    decision, _ = _decision(
        "git add -A && git commit -q -m 'stop guessing --work-tree targets'",
        stub_bin(containers_running=False),
        cwd=repo,
    )
    assert decision == "allow"


def test_a_scoped_hooks_path_with_two_commits_is_refused(tmp_path, stub_bin):
    """The override belongs to one git command. With two commits on the line
    there is no way to say which, and applying it to both let the second inherit
    an override it never had (CodeRabbit, PR #40)."""
    repo = _init_repo(tmp_path / "two-commit-override")
    fresh = _init_repo(tmp_path / "two-commit-fresh", hook_installed=False)
    elsewhere = tmp_path / "two-commit-hooks"
    elsewhere.mkdir()
    hook = elsewhere / "pre-commit"
    hook.write_text("#!/bin/sh\n")
    hook.chmod(0o755)
    decision, _ = _decision(
        f"git -c core.hooksPath={elsewhere} commit -m a; cd {fresh} && git commit -m b",
        stub_bin(containers_running=False),
        cwd=repo,
    )
    assert decision == "deny"


def test_a_scoped_hooks_path_with_one_commit_is_still_honoured(tmp_path, stub_bin):
    """The refusal above is about ambiguity, not about the option itself."""
    repo = _init_repo(tmp_path / "one-commit-override", hook_installed=False)
    elsewhere = tmp_path / "one-commit-hooks"
    elsewhere.mkdir()
    hook = elsewhere / "pre-commit"
    hook.write_text("#!/bin/sh\n")
    hook.chmod(0o755)
    decision, _ = _decision(
        f"git -c core.hooksPath={elsewhere} commit -m x",
        stub_bin(containers_running=False),
        cwd=repo,
    )
    assert decision == "allow"


def test_a_selector_inside_an_unrelated_quoted_argument_is_data(tmp_path, stub_bin):
    """The selector check reads the form with quoted spans removed, not the one
    with only quote characters removed.

    `-m` values are stripped from the flags form anyway, so a commit message
    naming a selector cannot tell the two apart. A quoted argument to a
    different command can: here `--work-tree=` belongs to echo, and reading the
    flags form would refuse the commit for it.
    """
    repo = _init_repo(tmp_path / "selector-in-argument")
    decision, _ = _decision(
        "echo '--work-tree=/tmp/nowhere' && git commit -m x",
        stub_bin(containers_running=False),
        cwd=repo,
    )
    assert decision == "allow"
