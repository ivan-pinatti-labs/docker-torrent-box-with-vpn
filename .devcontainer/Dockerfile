# Development container for docker-torrent-box-with-vpn, on the
# organization's shared base image. See .devcontainer/README.md for how to
# start it and why each run argument is there.
#
# This repository used mcr.microsoft.com/devcontainers/base:jammy with
# devcontainer features until 2026-09-20. That image was assembled only by
# the devcontainer CLI, so the container could not be started from an
# ordinary terminal, and it carried none of the organization's own tooling.
#
# The base image is pinned by digest. BASE_IMAGE is a build argument only so
# a change to the base image can be tested against this repository before it
# is published.
ARG BASE_IMAGE=ghcr.io/ivan-pinatti-labs/devcontainer-base@sha256:32c98c5e822a95028b08a6d388374f2a342bd72be33969f04e73aa1efe988044
FROM ${BASE_IMAGE}

USER 0:0

# What the shared base image does not already carry.
#
# This container is for working on the repository: the editor, the agent
# CLIs, git, gh and the pre-commit hooks. It is **not** where the stack runs.
# `make start`, the compose files and the integration suite all run on the
# host, against the host's own podman, and nothing here needs a compose
# provider or the VPN's TUN device.
#
# gh comes from GitHub's own signed repository, whose key the base image
# checks against a fingerprint and installs without enabling, so the source
# entry below is what opts in. The rest come from Ubuntu.
#
#   pre-commit    the hook runner, previously a devcontainer feature
#   python3-venv  `make bootstrap_tests` builds tests/.venv, and Ubuntu marks
#                 its own Python externally managed so pip will not install
#                 into it
#   shfmt         the jumanjihouse shfmt hook is a script hook that needs the
#                 binary on PATH and reports "This check needs shfmt from
#                 https://github.com/mvdan/sh/releases" without it
#
# The base image already provides git, make, python3, jq, curl,
# openssh-client, nodejs, the Claude Code and Codex CLIs, and rootless podman
# with a `docker` shim for the two hooks here that call `docker` by name.
#
# Versions are deliberately unpinned, which makes this layer rolling rather
# than reproducible: the digest above fixes what this builds on and says
# nothing about what apt resolves on top. See the base image's
# docs/TOOL_SOURCES.md.
# hadolint ignore=DL3008
RUN printf '%s\n' \
      'deb [arch=amd64 signed-by=/usr/share/keyrings/github-cli.gpg] https://cli.github.com/packages stable main' \
      > /etc/apt/sources.list.d/github-cli.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends \
    gh \
    pre-commit \
    python3-venv \
    shfmt \
  && rm -rf /var/lib/apt/lists/*

USER 1000:1000

WORKDIR /workspace
