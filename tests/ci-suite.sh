#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Usage: tests/ci-suite.sh MODE TARGET...
#
# The integration suite's steps, run inside the nested test runner (the
# podman-nested image the Makefile's test targets start; docs/TESTING.md,
# "Where the suite runs"). Never run on a host: it rewrites .env, enables the
# test profiles, seeds credentials and stands a whole stack up in whatever
# engine it finds. The Makefile refuses its tier targets outside the runner,
# and so does this.
#
# MODE is what stands before the tier targets:
#   none       nothing: the prerequisites tier reads files and asks the
#              runner's own tools, and needs no stack.
#   stack      the steps integration-tests.yml used to run one by one: seed,
#              certificate, pull, build, start, wait, wire.
#   bootstrap  `make bootstrap` from scratch instead (which also rotates every
#              credential), for `make bootstrap_tests`.
# TARGET is one or more of the Makefile's suite_* tier targets, run in order.
#
# Environment, passed in by the Makefile:
#   SUITE_PROJECT           COMPOSE_PROJECT_NAME for the nested stack.
#   SUITE_DISABLE_PROFILES  *_PROFILE variables to switch off after the test
#                           profiles are applied, space separated, for a
#                           reduced stack on a machine without the memory.
#   JELLYFIN_DRI_DEVICE     the GPU node Jellyfin gets (docs/CONTAINER_LIMITS.md).
#   REGISTRY_AUTH_FILE      registry credentials for the nested pulls, if any.
#   GITHUB_ACTIONS          set on a runner, for collapsible log groups.
#   PYTEST_ARGS, MARKER     read by the tier targets themselves.

set -euo pipefail

if [[ "${NESTED_RUNNER:-}" != 1 ]]; then
  echo "tests/ci-suite.sh runs inside the nested test runner only; use make test_nested." >&2
  exit 2
fi
if [[ $# -lt 2 ]]; then
  echo "usage: tests/ci-suite.sh none|stack|bootstrap TARGET..." >&2
  exit 2
fi
mode="$1"
shift
case "$mode" in
none | stack | bootstrap) ;;
*)
  echo "tests/ci-suite.sh: unknown mode '$mode'" >&2
  exit 2
  ;;
esac

started=$(date +%s)
group_open=false
step() {
  end_group
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::group::$1"
    group_open=true
  fi
  echo "##### $1 (+$(($(date +%s) - started))s)"
}
end_group() {
  if [[ "$group_open" == true ]]; then
    echo "::endgroup::"
    group_open=false
  fi
}
fail() {
  end_group
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::error::$1"
  else
    echo "ERROR: $1" >&2
  fi
  exit 1
}
set_env() {
  if grep -q "^$1=" .env; then
    sed -i "s|^$1=.*|$1=$2|" .env
  else
    printf '%s=%s\n' "$1" "$2" >>.env
  fi
}
show_stack() {
  echo "--- podman ps -a"
  podman ps -a --format '{{.Names}}\t{{.Status}}\t{{.Image}}' || true
}

step "Clear what an earlier run left in the nested storage"
# The storage volume is kept between runs for its images, but it holds the
# earlier run's containers, pods, networks and volumes as well, whose bind
# mount sources went with that run's container. compose would find a
# container by the same name and try to start it, which fails on the missing
# source. Images stay.
podman rm --all --force --time 0 >/dev/null
podman pod rm --all --force >/dev/null
podman network prune --force >/dev/null
podman volume prune --force >/dev/null

step "Create .env"
cp .env.example .env
# generate_certificate rejects the LAN_IP placeholder (OpenSSL needs a real
# address for the subjectAltName); any RFC 1918 address works, since nothing
# resolves it here.
set_env LAN_IP 192.168.1.100
# The runner's own account, which is what owns the nested socket three
# observability services mount from /run/user/${UID}/podman.
set_env UID "$(id -u)"
set_env GID "$(id -g)"
# Explicit rather than derived from the directory the tree was unpacked in,
# so the containers, networks and the suite's own label filter agree on one
# name whatever that directory is called.
set_env COMPOSE_PROJECT_NAME "${SUITE_PROJECT:-torrent-box-nested}"
if [[ -n "${JELLYFIN_DRI_DEVICE:-}" ]]; then
  set_env JELLYFIN_DRI_DEVICE "$JELLYFIN_DRI_DEVICE"
fi

if [[ "$mode" != none ]]; then
  step "Apply the test profile overrides"
  # .env.tests through its own make target, so the profile list has one
  # source of truth, and the credential free VPN mock in place of a real
  # provider, always: there is no VPN credential in CI and never will be.
  make enable_test_profiles
  for key in ${SUITE_DISABLE_PROFILES:-}; do
    [[ "$key" =~ ^[A-Z0-9_]+_PROFILE$ ]] || fail "SUITE_DISABLE_PROFILES holds '$key', not a *_PROFILE name"
    set_env "$key" disabled
    echo "[.env] $key=disabled"
  done
fi

step "Install the suite's Python dependencies"
# scripts/permissions.py runs with this interpreter during seeding, so its
# hash locked dependency goes in first; the suite's own pins follow.
python3 -m pip install --user --quiet --disable-pip-version-check --no-warn-script-location \
  --require-hashes --only-binary=:all: -r scripts/requirements.txt
python3 -m pip install --user --quiet --disable-pip-version-check --no-warn-script-location \
  -r tests/requirements.txt

profile_enabled() {
  grep -qx "$1=enabled" .env
}

# cadvisor reads /dev/kmsg, which the Makefile passes into the runner. On an
# SELinux host the runner's container_engine_t domain may not even stat it
# (devcontainer-airlock's policy module covers the FUSE and TUN devices, not
# this one), and the stack would then fail to start with cadvisor missing,
# naming nothing. Said here instead, before the stack is pulled.
if [[ "$mode" != none ]] && profile_enabled CADVISOR_PROFILE && ! stat /dev/kmsg >/dev/null 2>&1; then
  fail "cadvisor needs /dev/kmsg and the runner cannot read it (on an SELinux host, the container_engine_t label refuses it). Run with NESTED_LABEL=disable, or SUITE_DISABLE_PROFILES=CADVISOR_PROFILE to leave cadvisor out."
fi

case "$mode" in
stack)
  step "Seed every app's config and secrets"
  # make start alone never seeds, and every service whose compose block
  # names a seeded secrets file fails without it. Its chromedriver
  # prerequisite also runs the first registry pull, which is why it is
  # bounded like one.
  timeout 480 make seed_all || fail "make seed_all failed or took over 8 minutes."

  step "Generate the self signed certificate"
  timeout 180 make generate_certificate || fail "make generate_certificate failed."

  step "Pull container images"
  # Retried with a growing pause: an anonymous pull is the one that meets
  # Docker Hub's rate limit, which clears on its own, and the pull resumes
  # rather than starting over.
  pulled=false
  for attempt in 1 2 3; do
    if timeout 720 make pull_docker_images; then
      pulled=true
      break
    fi
    if [[ "$attempt" -lt 3 ]]; then
      echo "Pull attempt $attempt failed, retrying in $((attempt * 30))s"
      sleep $((attempt * 30))
    fi
  done
  [[ "$pulled" == true ]] || fail "Could not pull the images after 3 attempts."

  step "Build custom container images"
  # Before start, so assert-stack-started.sh's clock never counts a build.
  if profile_enabled LAZYLIBRARIAN_PROFILE || profile_enabled MYLAR_PROFILE; then
    timeout 600 make build_images || fail "make build_images failed or took over 10 minutes."
  else
    echo "LazyLibrarian and Mylar are both disabled, nothing to build."
  fi

  step "Start the stack"
  # Interrupted short of any outer limit, so a hang ends with the state
  # dumped below rather than a bare cancellation.
  rc=0
  timeout --signal=INT 420 make start || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    show_stack
    fail "make start did not finish (exit $rc)."
  fi

  step "Wait for containers to be ready"
  # 300s: calibre-web and lidarr have both needed more than 120s on a
  # runner. The nested image's health ticker runs every healthcheck, since
  # there is no systemd in here to schedule them.
  if ! timeout 300 bash -c 'until ! podman ps --format "{{.Status}}" | grep -q starting; do sleep 5; done'; then
    show_stack
    fail "Containers were still starting after 300s."
  fi
  show_stack

  step "Wire app to app connections"
  # Jellyfin and Audiobookshelf issue their API keys live, so Homepage's
  # widgets and Calibre-Web's library path have nothing real until this
  # runs; make bootstrap runs it straight after start for the same reason.
  timeout 600 make wire_connections || fail "make wire_connections failed or took over 10 minutes."
  ;;
bootstrap)
  step "Bootstrap the stack"
  make bootstrap || {
    show_stack
    fail "make bootstrap failed."
  }
  ;;
none) ;;
esac

for target in "$@"; do
  step "make $target"
  rc=0
  make "$target" || rc=$?
  [[ "$rc" -eq 0 ]] || fail "make $target failed (exit $rc)."
done
end_group
echo "##### done (+$(($(date +%s) - started))s)"
