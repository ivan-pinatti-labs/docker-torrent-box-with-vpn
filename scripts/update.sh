#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
set -euo pipefail

# Usage: ./scripts/update.sh (through `make update`)
# Brings a deployment up to the latest commit of the branch it follows, and
# the images that commit pins, and stops at the first step that fails:
#
#   1. refuse a tree with local changes, or one that cannot fast forward
#   2. make down
#   3. make backup-full, which refuses an incomplete archive
#   4. fast forward to the upstream branch
#   5. make migrate_versions, so pins an older .env still carries stop
#      overriding versions.env (holds stay, see versions.env)
#   6. make pull_docker_images
#   7. make start
#   8. make wire_connections
#
# and then prints the old and new commit, the images that changed, the backup
# and the commands that roll all of it back. Every make step is a new make,
# so from step 5 on it reads the Makefile, versions.env and .env the pull just
# brought, not the ones this run started with.
#
# RUNTIME and COMPOSE_PROJECT_NAME come from the Makefile, and only list the
# stack's containers for the summary.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
readonly RUNTIME="${RUNTIME:-podman}"
readonly PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$repo_root")}"
readonly MAKE_CMD="${MAKE:-make}"

backup=""
old=""

fail() {
  echo "" >&2
  echo "ERROR: $*" >&2
  if [[ -n "$backup" ]]; then
    echo "The update stopped partway. Fix the cause and run 'make update' again, or roll back:" >&2
    rollback >&2
  fi
  exit 1
}

rollback() {
  echo "  make down"
  echo "  git checkout --detach ${old}"
  echo "  make restore-configs BACKUP=${backup}"
  echo "  make start"
  echo "(then 'git checkout <branch>' to follow the branch again)"
}

step() {
  echo ""
  echo "==> $*"
}

# One "<container> <image>" line per container of this stack.
stack_images() {
  "$RUNTIME" ps --all --filter "label=com.docker.compose.project=${PROJECT}" \
    --format '{{.Names}} {{.Image}}' 2>/dev/null || true
}

# Every pin with a digest, as it stands in .env and versions.env right now.
# A container started from `<image>:<tag>@sha256:<digest>` reports only the
# digest, so the summary looks each one up here to name its tag again.
pins_with_digests() {
  cat .env versions.env 2>/dev/null | grep -E '^[A-Z0-9_]+_VERSION=[^@]+@sha256:' || true
}

step "Checking the working tree"
changes="$(git status --porcelain --untracked-files=no)"
[[ -z "$changes" ]] || {
  echo "$changes" >&2
  fail "the working tree has local changes to tracked files; commit or discard them first."
}
upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)" ||
  fail "the current branch follows no upstream branch, so there is nothing to update to."
git fetch --quiet || fail "git fetch failed."
old="$(git rev-parse HEAD)"
new="$(git rev-parse "$upstream")"
git merge-base --is-ancestor "$old" "$new" ||
  fail "${upstream} does not fast forward from here (local commits, or a rewritten branch)."
echo "Updating $(git rev-parse --short "$old") to $(git rev-parse --short "$new") (${upstream})."

images_before="$(stack_images)"
pins_before="$(pins_with_digests)"

step "make down"
"$MAKE_CMD" --no-print-directory down || fail "make down failed."

step "make backup-full"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
"$MAKE_CMD" --no-print-directory backup-full | tee "$log" || fail "the backup failed, so nothing was updated. The stack is down; 'make start' brings it back as it was."
backup="$(sed -n 's/^Done: \(.*\) ([^)]*)$/\1/p' "$log")"
[[ -n "$backup" && -s "$backup" ]] ||
  fail "make backup-full reported no archive, so nothing was updated. The stack is down; 'make start' brings it back as it was."

step "Fast forwarding to ${upstream}"
git merge --ff-only --quiet "$new" || {
  # Nothing moved yet but the stack going down, so no rollback to offer.
  backup=""
  fail "git could not fast forward to ${upstream}, so nothing was updated. The stack is down; 'make start' brings it back as it was."
}

step "make migrate_versions"
"$MAKE_CMD" --no-print-directory migrate_versions || fail "make migrate_versions failed."

step "make pull_docker_images"
"$MAKE_CMD" --no-print-directory pull_docker_images || fail "make pull_docker_images failed."

step "make start"
"$MAKE_CMD" --no-print-directory start || fail "make start failed."

step "make wire_connections"
"$MAKE_CMD" --no-print-directory wire_connections || fail "make wire_connections failed."

images_after="$(stack_images)"

step "Updated"
if [[ "$old" == "$new" ]]; then
  echo "Commit: $(git log -1 --format='%h %s' "$new") (already current)"
else
  echo "Commit: $(git log -1 --format='%h %s' "$old")"
  echo "    to: $(git log -1 --format='%h %s' "$new")"
fi
changed="$(awk '
  function named(ref) {
    if (match(ref, /@sha256:[0-9a-f]+$/) && substr(ref, RSTART + 8) in tag) {
      return substr(ref, 1, RSTART - 1) ":" tag[substr(ref, RSTART + 8)]
    }
    return ref
  }
  FILENAME == ARGV[1] { split($0, pin, /[=@]/); tag[substr(pin[3], 8)] = pin[2]; next }
  FILENAME == ARGV[2] { before[$1] = $2; next }
  { was = ($1 in before) ? named(before[$1]) : "(new)"; if (before[$1] != $2) print "  " $1 ": " was " -> " named($2) }' \
  <(printf '%s\n%s' "$pins_before" "$(pins_with_digests)") \
  <(printf '%s' "$images_before") <(printf '%s' "$images_after"))"
if [[ -n "$changed" ]]; then
  echo "Images changed:"
  echo "$changed"
else
  echo "Images changed: none"
fi
echo "Backup: ${backup}"
echo "To roll back to where this run started:"
rollback
