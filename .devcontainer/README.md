# The development container

What it is for, how to start it, and what deliberately does not run in it.

## What it is for

Working on this repository: the editor, the Claude Code and Codex CLIs, git,
`gh`, and the pre-commit hooks. It is built on the organization's shared base
image, the same one every other `ivan-pinatti-labs` repository uses.

**The stack does not run in here.** `make start`, the compose files and the
integration suite all run on the host, against the host's own podman. That is
why this container carries no compose provider and none of the run arguments
a nested compose network would need.

Until 2026-09-20 this was `mcr.microsoft.com/devcontainers/base:jammy` plus
devcontainer features. Those features were assembled only by the devcontainer
CLI, so the container could not be started from an ordinary terminal, and it
carried none of the organization's own tooling.

## Starting it

From a terminal, with no editor involved:

```shell
make shell
```

That builds the container and drops you into it with the working tree mounted
at its own path. Or open the repository in an editor that reads
`.devcontainer/devcontainer.json`.

## Why each run argument is there

- `--userns=keep-id:uid=1000,gid=1000` maps the `dev` account to your own
  host uid, so a bind mounted working tree is readable and writable.
- `--security-opt label=type:container_engine_t` and `--device /dev/fuse`
  are what let a nested container run under SELinux. Two pre-commit hooks
  here call `docker` by name, and the base image's `podman-docker` answers
  them. See `docs/IMAGES.md` in `ivan-pinatti-labs/devcontainer-images`,
  under "Running containers inside it".
- `--secret gh-devcontainer,type=env,target=GH_TOKEN` passes a GitHub token
  without putting it in the container's configuration, where
  `podman inspect` would show it. `make shell` uses the same secret when it
  exists and falls back to `GH_TOKEN` from the environment when it does not.

SELinux stays enforcing throughout. Nothing here reaches for
`label=disable`.

## Tools

`pre-commit` and `python3-venv` come from Ubuntu, `gh` from GitHub's own
signed repository. Everything else (git, make, python3, jq, curl,
openssh-client, nodejs, rootless podman, and the Claude Code and Codex CLIs)
comes with the base image.

Package versions are deliberately unpinned, so rebuilding can give you
different versions than it did last week, by design. The base image digest
pins what the container builds on, not what apt resolves on top. See that
image's `docs/TOOL_SOURCES.md` for where each tool comes from and what
vouches for it.
