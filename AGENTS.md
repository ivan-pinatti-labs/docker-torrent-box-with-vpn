# docker-torrent-box-with-vpn agent instructions

Instructions for AI coding agents working in this repository. Claude Code
reads them through `CLAUDE.md`; Codex and CodeRabbit read this file
directly.

## Organization conventions

Shared by every `ivan-pinatti-labs` repository and kept identical across
them, so change it everywhere at once. Where this repository's own sections
are more specific, follow them.

### Everything here is public

- Nothing sensitive, controversial or borderline goes into a commit, pull
  request, issue, comment or committed agent file. That includes secrets,
  tokens, personal paths, email addresses other than a GitHub noreply one,
  host names, LAN addresses and details of anyone's own deployment.
- Personal or machine specific material stays in gitignored files:
  `CLAUDE.local.md` for notes, `.claude/settings.local.json` for settings,
  `.claude/agents/local/` for agents.
- Sensitive content found already committed is reported to a maintainer.
  Never rewrite history or force push to remove it.

### Run binaries in containers, not on the host

A binary that did not come from the operating system's package manager (a
release download, an installer script, a new version under evaluation, a
scanner, a debugging tool) runs inside a rootless Podman container, never
directly on the host. That holds when validating,
testing, checking a new version and debugging.

It holds one level further in as well. In a
[devcontainer-airlock](https://github.com/ivan-pinatti-labs/devcontainer-airlock)
workbench, where the coding agents and their logins live, project code does
not run in the workbench itself: hooks, tests, package installs and
unreviewed binaries run through `l2`, in an L2 container that gets the
working tree and nothing else (no network, no credentials). `l2 --net` adds
network through the workspace's egress proxy, and `l2 --engine` gives a run
the L2 engine, for tests that build or start containers of their own.

```bash
podman run --rm --network=none \
  -v "<only what it needs>:/work:ro,Z" -w /work \
  <image> <binary> [args]
```

- The container gets what the process needs and nothing else. Mount only the
  specific files and folders required, read only. Add network access or
  `:rw` only when the task requires it, and say so.
- Prefer the tool's official image, pinned to a version. For a bare release
  binary use `debian:13-slim` rather than Alpine: glibc builds fail on musl
  with a misleading "No such file or directory".
- On SELinux hosts a bind mount needs a label (`Z`). Do not relabel a large
  tree that other containers also use; copy what is needed into a scratch
  directory and mount that.
- Podman is the default container runtime: rootless, with no daemon.
- Exceptions: the hook environments pre-commit builds, and the containers
  this repository's own `Makefile` or hooks start. In a workbench both run in
  L2 too.

### Parallel work uses worktrees

More than one agent may work in a repository at the same time. Give each task
its own worktree under `.claude/worktrees/<branch>` (gitignored), and never
switch branches in a checkout someone else may be using.

### Unattended work runs on a bounded tick

Work left running while nobody is watching is driven by a bounded pass, never
by a wait for the outcome you want.

A background wait whose only exit is success does not fail, it disappears. A
pull request sitting in a merge queue is the worked example: a flaky check
ejects it, which is neither merged nor closed, so a loop waiting for "merged"
runs forever, nothing notifies, and the session stops. That cost roughly
sixteen unattended hours here on 2026-09-22, and the giveaway is that silence
and progress look identical from outside.

So:

- **Cap every pass**, around fifty minutes, and report on exit whether or not
  anything moved. Time always advances, so no condition can trap it. Say
  plainly when a pass did nothing, because a quiet pass and a dead session
  have to look different.
- **Re-derive state from the API every pass.** Draft status, review verdict,
  unresolved threads, approval, queue membership. Never carry a belief from
  the previous pass.
- **Handle every outcome, not only the good one.** Released from draft,
  review declined, approval job timed out, ejected from the queue, merged,
  closed. Only the last two are final; the rest are recoverable, and that is
  exactly why they have to be handled rather than waited through. A pass that
  only knows how to recognize success cannot recover anything, and treating a
  recoverable outcome as an ending is the failure this whole section is about.
- **Before arming a wait, ask what would wake you if this failed right now.**
  If the answer is nothing, widen the condition.
- **A pass that ends with nothing moved and no reason is a signal to
  inspect**, not to re-arm the same watch.
- **Never finish a turn** without either a bounded wait armed or an explicit
  statement that work has stopped.

### Writing style

Do not use a hyphen, em dash or en dash as punctuation in prose, code
comments, commit messages or pull request text. Use commas, parentheses or
separate sentences. Hyphens inside compound words and in code, paths, flags
and identifiers are fine.

### Commits and pull requests

- Conventional Commits with an imperative subject. Branch names are lowercase
  slugs such as `fix/flaky-test`. Never commit directly to `main`.
- Open a pull request as a draft and mark it ready once the checks are green;
  marking it ready is what starts CodeRabbit. `docs/MERGE_PIPELINE.md` is the
  authority on required checks and how a pull request merges.
- Answer every CodeRabbit comment on its thread, and say plainly when
  declining one and why.
- Never force push.
- Never add AI attribution: no AI `Co-Authored-By` trailer and no "Generated
  with" line, in commits, pull requests, comments, issues or docs.

## Docker compose files

- Service blocks in `docker-compose-*.yml` files must follow the key order
  documented in docs/COMPOSE_CONVENTIONS.md.
- For a service whose `.env` needs real secrets, follow the secrets override
  pattern in docs/COMPOSE_CONVENTIONS.md (committed `.env` template plus
  gitignored `.env.secrets`, see `configs/grafana/` for a working example).

## Pull requests in this repository

Follow this order. Each step waits on the one before it. The full path,
every required check, and what each one proves are in
docs/MERGE_PIPELINE.md; do not restate that reasoning here.

1. Open as a draft (`gh pr create --draft`). `Code Check` (pre-commit),
   `Prerequisite Checks` and `Security Reports` all start at once, none of them
   gated on another, and `Renovate Config` follows `Detect Changed Paths`.
   CodeRabbit skips drafts. There is no `MegaLinter` step: #50 replaced it with
   pre-commit hooks on 2026-08-15, so `Code Check` is where that coverage lives
   now.
2. Mark ready (`gh pr ready <n>`) once they are green. That is what starts
   CodeRabbit, so it reviews an already-clean diff once.
3. Address every CodeRabbit comment. Reply on the thread, and say plainly when
   declining one and why. Read the reason beside the `CodeRabbit` check, not
   whether it is green: "Review skipped", "Review rate limited" and "Review
   completed" all report green, and only the last means a review happened.
   The required check that actually enforces this is `Review Verified`, not
   `CodeRabbit`: wait for `Review Verified` to read `success`, not merely for
   `CodeRabbit` to stop being `pending`.
4. Comment `/run-tests` last. That is a comment `integration-tests.yml`
   reacts to directly (no label involved), and it is the only thing that
   starts the integration suite.

- The required `Integration Tests` check is a separate gate job from
  `Integration Suite`, and is red until the suite passes on the current head
  commit. A job skipped by its own `if` is reported to branch protection as
  successful, so gating the suite alone would have made an unlabelled PR
  mergeable with no tests at all.
- "Every check green" does not mean merged. `main` uses a merge queue instead
  of requiring a pull request to be rebased onto the latest `main` (`strict`
  required status checks came off for this): once every required check passes,
  GitHub adds the pull request to the queue on its own, and it merges only
  after the queue's own run of that same check set passes on the commit the
  queue actually builds, not on your pull request's own head commit.

## Running the dev stack

- Bring the dev stack up to test or develop against, and bring it down as
  soon as that work is finished. Do not leave it running while idle.
  `make start` to raise it, `make stop_all` to lower it.
- Leaving it up is not free. It holds every container name, so
  `make stop_all` alone does not release them and a second checkout is still
  blocked (only `make down` removes them). It also blocks every working tree
  git operation, since `.claude/hooks/git-guard.sh` refuses those while
  containers labelled with this project are running, which means an idle dev
  stack turns an ordinary commit into stop, commit, start.

## Editing runtime app state (configs and databases)

- Never edit a running container's config file or SQLite database directly.
  Most apps read config only at startup and persist their in-memory state on
  shutdown, which silently overwrites file edits made while they run
  (LazyLibrarian, Mylar, SABnzbd, NZBHydra2, qBittorrent, Calibre-Web at
  minimum).
- The safe pattern is stop the container, edit the file or database, start
  the container. The exception is changes made through the app's own live
  API, which need no restart.
- After host side SQLite writes, run `scripts/permissions.py repair` so
  `-wal`/`-shm` sidecar files are not left owned by the host user, which the
  app user cannot open after a restart.
- Never run `git commit` (or anything that stashes the working tree) while
  the stack is running: pre-commit's stash cycle rewrote tracked runtime files
  mid-flight on 2026-07-07 and corrupted live SQLite databases.
- Run `pre-commit install` in every new clone before the first commit.
  `git clone` does not install the hooks, so commits made in a fresh checkout
  run no secret scanning at all and still report success (two of them reached
  a PR on 2026-08-12 that way). `.claude/hooks/git-guard.sh` refuses a commit
  when the hook is missing.
