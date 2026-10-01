#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# cspell:ignore abshooks fromdotenv fromenv nogit nojq nopodman notrepo sharedhooks
#
# Tests for .claude/hooks/git-guard.sh. Every line of the hook has to run in
# one of them: `make coverage` runs this file under kcov and fails below 100%.
#
# tests/test_git_guard.py holds the hook's full matrix of commands against
# real git repositories. This file is the line coverage half, and it needs
# none of git, jq or podman: the coverage container has none of them, and
# the hook must never ask the real ones anything here. jq, git and podman are
# stubs in a scratch directory, and PATH holds only those plus the text tools
# the hook pipes through, so no repository is read and no container listed.
#
# The git stub treats a directory as a repository when it holds a .git
# directory, and answers `rev-parse --git-path hooks` with .git/hooks, or with
# the contents of .git/hookspath when that file exists.

set -o errexit
set -o pipefail
set -o nounset

__repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
__hook="${__repo}/.claude/hooks/git-guard.sh"
__bash="$(command -v bash)"
__python="$(command -v python3)"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0
unset COMPOSE_PROJECT_NAME

# Writes an executable stub with the given interpreter.
stub() {
  local dir="${1}" name="${2}" interpreter="${3}" body="${4}"
  mkdir -p "${dir}"
  printf '#!%s\n%s\n' "${interpreter}" "${body}" >"${dir}/${name}"
  chmod +x "${dir}/${name}"
}

# A bin directory with the text tools the hook needs and the named stubs.
make_bin() {
  local bin="${__scratch}/bin-${1}"
  shift
  mkdir -p "${bin}"
  for tool in cat awk sed grep tr head basename; do
    ln -sf "$(command -v "${tool}")" "${bin}/${tool}"
  done
  for name in "$@"; do
    cp "${__scratch}/stubs/${name}" "${bin}/${name}"
  done
  echo "${bin}"
}

# Only the three jq programs the hook runs.
stub "${__scratch}/stubs" jq "${__python}" '
import json, sys
args = sys.argv[1:]
if args[0] == "-cn":
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
        "permissionDecision": "deny", "permissionDecisionReason": args[3]}}))
    sys.exit(0)
try:
    payload = json.loads(sys.stdin.read())
except ValueError:
    sys.exit(5)
if args[0] == "-er":
    print(payload.get("tool_input", {}).get("command") or "")
elif payload.get("cwd"):
    print(payload["cwd"])'

# shellcheck disable=SC2016 # expanded by the stub, not here
stub "${__scratch}/stubs" git "${__bash}" '[[ "${1}" == -C && -d "${2}/.git" ]] || exit 128
case "${*:3}" in
"rev-parse --git-dir") echo .git ;;
"rev-parse --show-toplevel") echo "${2}" ;;
"rev-parse --git-path hooks") if [[ -f "${2}/.git/hookspath" ]]; then cat "${2}/.git/hookspath"; else echo .git/hooks; fi ;;
esac'

stub "${__scratch}/stubs" podman "${__bash}" "echo \"podman \$*\" >>'${__scratch}/podman.log'
[[ -f '${__scratch}/running' ]] && cat '${__scratch}/running'
exit 0"

# A repository in the requested state, under the scratch directory.
repo() {
  local path="${__scratch}/${1}" state="${2}"
  mkdir -p "${path}/.git/hooks"
  [[ "${state}" == plain ]] && return 0
  touch "${path}/.pre-commit-config.yaml"
  if [[ "${state}" == hooked ]]; then
    printf '#!/bin/sh\n' >"${path}/.git/hooks/pre-commit"
    chmod +x "${path}/.git/hooks/pre-commit"
  fi
  return 0
}

repo hooked hooked
repo unhooked unhooked
repo plain plain
mkdir -p "${__scratch}/notrepo" "${__scratch}/elsewhere"
repo hooked/sub hooked
repo abshooks unhooked
mkdir -p "${__scratch}/sharedhooks"
printf '#!/bin/sh\n' >"${__scratch}/sharedhooks/pre-commit"
chmod +x "${__scratch}/sharedhooks/pre-commit"
echo "${__scratch}/sharedhooks" >"${__scratch}/abshooks/.git/hookspath"

full="$(make_bin full jq git podman)"
nojq="$(make_bin nojq)"
nogit="$(make_bin nogit jq podman)"
nopodman="$(make_bin nopodman jq git)"

# Runs the hook. Arguments: bin dir, project dir, raw payload.
run() {
  __status=0
  rm -f "${__scratch}/podman.log"
  PATH="${1}" CLAUDE_PROJECT_DIR="${2}" "${__bash}" "${__hook}" <<<"${3}" \
    >"${__scratch}/out" 2>"${__scratch}/err" || __status=$?
}

# A payload for a command, run with cwd set to a scratch directory.
payload() {
  "${__python}" -c 'import json, sys; d = {"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}
if sys.argv[2]: d["cwd"] = sys.argv[2]
print(json.dumps(d))' "${1}" "${2:-}"
}

decide() {
  local bin="${1}" cmd="${2}" cwd="${3-${__scratch}/hooked}"
  run "${bin}" "${__scratch}/hooked" "$(payload "${cmd}" "${cwd}")"
}

fail() {
  echo "FAIL ${1}: ${2}" >&2
  __failures=$((__failures + 1))
}

# Expects a refusal whose reason contains the given text.
denied() {
  local name="${1}" want="${2}"
  if [[ "${__status}" -ne 0 ]]; then
    fail "${name}" "exit ${__status}"
  elif ! grep --quiet '"permissionDecision": *"deny"' "${__scratch}/out"; then
    fail "${name}" "not refused: $(cat "${__scratch}/out" "${__scratch}/err")"
  elif ! grep --quiet --fixed-strings -- "${want}" "${__scratch}/out"; then
    fail "${name}" "'${want}' not in $(cat "${__scratch}/out")"
  else
    echo "ok ${name}"
  fi
}

allowed() {
  local name="${1}"
  if [[ "${__status}" -ne 0 ]]; then
    fail "${name}" "exit ${__status}"
  elif [[ -s "${__scratch}/out" ]]; then
    fail "${name}" "refused: $(cat "${__scratch}/out")"
  else
    echo "ok ${name}"
  fi
}

# Fail closed when the payload cannot be read.
run "${nojq}" "${__scratch}/hooked" '{}'
denied "refuses without jq" "jq is not installed"
run "${full}" "${__scratch}/hooked" 'not json'
denied "refuses a payload it cannot parse" "could not parse the hook payload"
run "${full}" "${__scratch}/hooked" '{"tool_input": {}}'
allowed "allows an empty command"
decide "${full}" "ls -la"
allowed "allows a command that is not git"

# Rule 1.
decide "${full}" "git commit --no-verify -m x"
denied "refuses commit --no-verify" "git commit --no-verify is not allowed"
decide "${full}" "git push origin main --no-verify"
denied "refuses push --no-verify" "git push --no-verify is not allowed"

# Rule 3.
decide "${nogit}" "git commit -m x"
allowed "allows a commit when git itself is missing"
decide "${full}" "git commit -m x"
allowed "allows a commit in a hooked repository"
if ! grep --quiet "label=com.docker.compose.project=hooked" "${__scratch}/podman.log"; then
  fail "names the project after the directory" "$(cat "${__scratch}/podman.log")"
else
  echo "ok names the project after the directory"
fi
run "${full}" "${__scratch}/unhooked" "$(payload "git commit -m x")"
denied "falls back to the project directory without a cwd" "unhooked/.git/hooks/pre-commit does not exist"
decide "${full}" "git commit -m x" "${__scratch}/unhooked"
denied "refuses a commit in an unhooked repository" "Run 'pre-commit install' in ${__scratch}/unhooked"
decide "${full}" "git commit -m x" "${__scratch}/plain"
allowed "ignores a repository without pre-commit"
decide "${full}" "git commit -m x" "${__scratch}/notrepo"
allowed "leaves a directory that is not a repository to git"
decide "${full}" "cd ../unhooked && git commit -m x"
denied "follows a relative cd before the commit" "Run 'pre-commit install' in ${__scratch}/hooked/../unhooked"
decide "${full}" "cd -P sub && git commit -m x" "${__scratch}/unhooked"
allowed "leaves the session directory once the command cds away"
decide "${full}" "(cd sub && true) && git commit -m x" "${__scratch}/unhooked"
denied "keeps the session directory after a subshell cd" "in ${__scratch}/unhooked"
decide "${full}" "git -C ${__scratch}/hooked commit -m x"
denied "refuses -C" "git -C, --git-dir and --work-tree"
decide "${full}" "git -c core.hooksPath=/x commit -m a; git commit -m b"
denied "refuses a hooksPath override with two commits" "more than one git commit"
decide "${full}" "git -c core.hooksPath=${__scratch}/sharedhooks commit -m x" "${__scratch}/unhooked"
allowed "honors an absolute hooksPath override"
decide "${full}" "git -c core.hookspath=.git/hooks commit -m x" "${__scratch}/unhooked"
denied "resolves a relative hooksPath override against the top level" "${__scratch}/unhooked/.git/hooks/pre-commit"
decide "${full}" "git commit -m x" "${__scratch}/abshooks"
allowed "uses the absolute hooks path git reports"

# Rule 2.
decide "${nopodman}" "git stash"
allowed "allows a working tree command without podman"
decide "${full}" "git stash list"
allowed "allows a read only stash command"
echo qbittorrent >"${__scratch}/running"
decide "${full}" "git stash"
denied "refuses a working tree command while the stack runs" "The stack is running"
rm -f "${__scratch}/running"
COMPOSE_PROJECT_NAME=fromenv decide "${full}" "git reset --hard"
allowed "allows a working tree command while the stack is down"
if ! grep --quiet "project=fromenv" "${__scratch}/podman.log"; then
  fail "takes the project name from the environment" "$(cat "${__scratch}/podman.log")"
else
  echo "ok takes the project name from the environment"
fi
printf 'OTHER=1\nCOMPOSE_PROJECT_NAME="fromdotenv"\n' >"${__scratch}/hooked/.env"
decide "${full}" "git stash"
if ! grep --quiet "project=fromdotenv " "${__scratch}/podman.log"; then
  fail "takes the project name from .env" "$(cat "${__scratch}/podman.log")"
else
  echo "ok takes the project name from .env"
fi

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
