# Developing in containers

This repository is developed with
[devcontainer-airlock](https://github.com/ivan-pinatti-labs/devcontainer-airlock):
you and the coding agents work in a workbench that holds no GitHub token and
no ssh key, and the pre-commit hooks run in an L2 container that gets the
working tree and nothing else. Its
[docs/LAYERS.md](https://github.com/ivan-pinatti-labs/devcontainer-airlock/blob/main/docs/LAYERS.md)
explains the layers and the one time setup on the host.

**The stack does not run in there.** `make start`, the compose files and the
integration suite run on the host, against the host's own podman, as they
always have. A workbench is for the editor, the agents, git and the hooks.

## Worktrees only

The main clone holds the stack's data, which the stack's own containers use.
A workbench mounts its workspace with a private SELinux label, which would
take that data away from them, so this repository carries
`workbench-worktree-only`: work happens in a worktree, and devcontainer-airlock
refuses to use the main clone as a workspace.

```shell
git worktree add .claude/worktrees/<name> -b <branch> origin/main
cd .claude/worktrees/<name>
make unlock          # the ssh key, for eight hours
make claude          # Claude Code in this worktree's workbench (or: make codex)
make claude-shell    # a terminal in it (or: codex-shell)
```

The workbench targets come from a devcontainer-airlock clone next to this
repository's main clone (or wherever `WORKBENCH_HOME` points). The first time
in a clone, inside a workbench, route the git hooks through L2:

```shell
l2-hooks-install
```

## What is in here

| File | What |
| --- | --- |
| `l2/Dockerfile` | This repository's L2 image, on the shared one pinned by digest, plus `shfmt`, which the local hooks call by name. |
| `egress-sets` | What the hooks reach through the egress proxy: Docker Hub for the images they run, trivy's database for the pre-push scan. |
| `workbench-profile` | `hooks-engine`: the hooks that start containers of their own (trivy, lychee) get the L2 engine. |
| `workbench-worktree-only` | The marker above. |

Package versions are deliberately unpinned, so rebuilding can give you
different versions than it did last week, by design. The image digest pins
what the L2 image builds on, not what apt resolves on top.
