#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Says whether the nested test runner gave the nested engine cgroups, for
# tests/ci-suite.sh. The podman-nested image's init turns them on through the
# drop in below and removes it when it leaves them off (devcontainer-airlock's
# docs/IMAGES.md, "Cgroups for the nested containers"). The line repeats what
# the init printed, from what the engine itself reports, and on a runner it is
# also a notice on the run's summary, so a run says whether the stack's CPU and
# memory limits were enforced and whether the podman_exporter CPU and memory
# tests had anything to read.

set -o errexit
set -o pipefail
set -o nounset

conf="${HOME}/.config/containers/containers.conf.d/50-cgroups.conf"
if controllers="$(podman info --format '{{join .Host.CgroupControllers " "}}' 2>/dev/null)"; then
  controllers="${controllers:-none}"
else
  controllers="unknown, podman info failed"
fi
if [[ -f "${conf}" ]]; then
  state="on (engine controllers: ${controllers})"
else
  state="off (the runner was given no delegated cgroup v2 tree, or started with --user), so no container stats or resource limits"
fi
echo "nested cgroups ${state}"
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  echo "::notice title=Nested cgroups::${state}"
fi
