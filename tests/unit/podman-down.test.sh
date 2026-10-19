#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for scripts/podman-down.sh. Every line of the script has to run in one
# of them: `make coverage` runs this file under kcov and fails below 100%.
#
# podman and sleep are stubs. podman keeps a small model of the containers in
# the scratch directory, one file per container under c/, holding its compose
# project, its compose service, whether it runs, and the container whose
# network namespace it shares, and the networks that exist in a file of their
# own. Like the real one, `rm` refuses a container that another existing
# container depends on, and `network rm` refuses a network while a container
# of its project exists. A container listed under stuck/ cannot be removed at
# all, and when the file ps-ok exists, podman ps fails once it has answered
# that many calls. sleep only logs.

set -o errexit
set -o pipefail
set -o nounset

__script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/podman-down.sh"
__bash="$(command -v bash)"
__rm="$(command -v rm)"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0
__bin="${__scratch}/bin"
__work="${__scratch}/work"
__state="${__scratch}/state"
# The Makefile exports the project name, and `make coverage` runs this file.
unset COMPOSE_PROJECT_NAME PODMAN_DOWN_TIMEOUT

mkdir -p "${__bin}"
for tool in basename cat grep xargs; do
  ln -s "$(command -v "${tool}")" "${__bin}/${tool}"
done
printf '#!%s\necho "sleep $*" >>"%s/log"\n' "${__bash}" "${__state}" >"${__bin}/sleep"
chmod +x "${__bin}/sleep"
cat >"${__bin}/podman" <<EOF
#!${__bash}
state='${__state}'
echo "podman \$*" >>"\${state}/log"
# Fields of a container: project service running|exited namespace|-.
field() { read -r -a f <"\${state}/c/\${1}"; echo "\${f[\${2}]}"; }
set_running() { read -r -a f <"\${state}/c/\${1}"; f[2]="\${2}"; echo "\${f[*]}" >"\${state}/c/\${1}"; }
case "\${1}" in
ps)
  shift
  if [[ -f "\${state}/ps-ok" ]]; then
    left_ok="\$(<"\${state}/ps-ok")"
    if [[ "\${left_ok}" -le 0 ]]; then
      echo "Error: unable to connect to Podman socket" >&2
      exit 125
    fi
    echo "\$((left_ok - 1))" >"\${state}/ps-ok"
  fi
  all=0 labels=()
  while [[ \$# -gt 0 ]]; do
    case "\${1}" in
    --all) all=1 ;;
    --filter) labels+=("\${2#label=}"); shift ;;
    --format) shift ;;
    esac
    shift
  done
  for file in "\${state}"/c/*; do
    [[ -e "\${file}" ]] || continue
    name="\${file##*/}"
    [[ "\${all}" -eq 1 || "\$(field "\${name}" 2)" == running ]] || continue
    keep=1
    for label in "\${labels[@]}"; do
      case "\${label}" in
      com.docker.compose.project=*) [[ "\$(field "\${name}" 0)" == "\${label#*=}" ]] || keep=0 ;;
      com.docker.compose.service=*) [[ "\$(field "\${name}" 1)" == "\${label#*=}" ]] || keep=0 ;;
      esac
    done
    [[ "\${keep}" -eq 0 ]] || echo "\${name}"
  done
  ;;
kill)
  shift
  signal=KILL
  if [[ "\${1}" == --signal ]]; then signal="\${2}"; shift 2; fi
  for name in "\$@"; do
    [[ "\${signal}" == TERM && -e "\${state}/stubborn/\${name}" ]] && continue
    set_running "\${name}" exited
  done
  ;;
rm)
  shift 4
  status=0
  for name in "\$@"; do
    if [[ -e "\${state}/stuck/\${name}" ]]; then
      echo "Error: cannot remove container \${name}: device or resource busy" >&2
      status=125
      continue
    fi
    for other in "\${state}"/c/*; do
      if [[ -e "\${other}" && "\$(field "\${other##*/}" 3)" == "\${name}" ]]; then
        echo "Error: container \${name} has dependent containers which must be removed before it: \${other##*/}" >&2
        status=125
        continue 2
      fi
    done
    ${__rm} "\${state}/c/\${name}"
  done
  exit "\${status}"
  ;;
network)
  exists=1 others=()
  while read -r network; do
    if [[ "\${network}" == "\${3}" ]]; then exists=0; else others+=("\${network}"); fi
  done <"\${state}/networks"
  [[ "\${2}" == exists ]] && exit "\${exists}"
  for file in "\${state}"/c/*; do
    if [[ -e "\${file}" && "\${3}" == "\$(field "\${file##*/}" 0)_"* ]]; then
      echo "Error: network \${3} is in use" >&2
      exit 2
    fi
  done
  printf '%s\n' "\${others[@]}" >"\${state}/networks"
  echo "\${3}" >>"\${state}/networks-removed"
  ;;
esac
EOF
chmod +x "${__bin}/podman"

# Resets the model. Each argument is one container as
# name:project:service:running|exited:namespace|-.
fresh() {
  rm -rf "${__state}" "${__work}"
  mkdir -p "${__state}/c" "${__state}/stubborn" "${__state}/stuck" "${__work}"
  : >"${__state}/log"
  : >"${__state}/networks"
  : >"${__state}/networks-removed"
  local spec
  for spec in "$@"; do
    IFS=: read -r -a f <<<"${spec}"
    echo "${f[1]} ${f[2]} ${f[3]} ${f[4]}" >"${__state}/c/${f[0]}"
  done
}

# The six networks of a project exist.
networks() {
  local network
  for network in edge wan apps services media observability; do
    echo "${1}_${network}"
  done >"${__state}/networks"
}

run() {
  __status=0
  (cd "${__work}" && PATH="${__bin}" "${__bash}" "${__script}") \
    >"${__scratch}/out" 2>"${__scratch}/err" || __status=$?
}

fail() {
  echo "FAIL ${1}: ${2}" >&2
  __failures=$((__failures + 1))
}

# check <name> <status> <file> <text>: the run exited with <status> and
# <file> (out, err, or a file under the state directory) holds <text>.
check() {
  local name="${1}" status="${2}" file="${3}" want="${4}" path
  path="${__scratch}/${file}"
  [[ -f "${path}" ]] || path="${__state}/${file}"
  if [[ "${__status}" -ne "${status}" ]]; then
    fail "${name}" "exit ${__status}, wanted ${status}"
    cat "${__scratch}/err" >&2
  elif ! grep --quiet --fixed-strings -- "${want}" "${path}"; then
    fail "${name}" "'${want}' not in ${file}"
    cat "${path}" >&2
  else
    echo "ok ${name}"
  fi
}

# check_absent <name> <file> <text>: <file> does not hold <text>.
check_absent() {
  local name="${1}" file="${2}" want="${3}" path
  path="${__scratch}/${file}"
  [[ -f "${path}" ]] || path="${__state}/${file}"
  if grep --quiet --fixed-strings -- "${want}" "${path}"; then
    fail "${name}" "'${want}' in ${file}"
  else
    echo "ok ${name}"
  fi
}

# check_left <name> <container> ...: exactly these containers still exist.
check_left() {
  local name="${1}" left
  shift
  left="$(ls "${__state}/c" | xargs)"
  if [[ "${left}" != "$*" ]]; then
    fail "${name}" "left '${left}', wanted '$*'"
  else
    echo "ok ${name}"
  fi
}

fresh
PODMAN_DOWN_TIMEOUT=soon run
check "rejects a timeout that is not a number" 1 err "must be a whole number of seconds, got 'soon'"

fresh gluetun:box:gluetun:running:-
networks box
echo 0 >"${__state}/ps-ok"
COMPOSE_PROJECT_NAME=box run
check "fails when podman cannot list the containers" 1 err "podman could not list the containers of project box."
check_absent "touches nothing then" log "podman rm"
check_absent "not even the networks" log "podman network"

fresh other-gluetun:other:gluetun:running:-
echo box_wan >"${__state}/networks"
COMPOSE_PROJECT_NAME=box run
check "says when the project has no containers" 0 out "No stack containers found."
check_absent "removes no container then" log "podman rm"
check_left "leaves other projects alone" other-gluetun
check "still removes a network an earlier run left" 0 networks-removed "box_wan"
check_absent "and skips the ones that do not exist" log "podman network rm box_edge"

# The case of issue #301: the containers were created with no prefix, and the
# current .env sets one. The VPN container is found by its service label, so
# it waits for the containers sharing its namespace whatever it is named.
fresh \
  gluetun:box:gluetun:running:- \
  radarr:box:radarr:running:gluetun \
  sonarr:box:sonarr:running:gluetun \
  nginx:box:nginx:running:- \
  other-gluetun:other:gluetun:running:-
networks box
COMPOSE_PROJECT_NAME=box CONTAINER_PREFIX=live- run
check "stops the running containers" 0 log "podman kill --signal TERM gluetun nginx radarr sonarr"
check "removes the dependents before the VPN container" 0 log "podman rm --force --time 0 nginx radarr sonarr"
check "then removes the VPN container" 0 log "podman rm --force --time 0 gluetun"
check_absent "never asks podman to remove the VPN container early" err "has dependent containers"
check_absent "does not wait once everything stopped" log "sleep"
check_left "removes every container of the project" other-gluetun
for network in edge wan apps services media observability; do
  check "removes the ${network} network" 0 networks-removed "box_${network}"
done

# A container that shares the namespace of one the labels do not single out
# makes the first pass fail on that one. The second pass removes it.
fresh \
  app:box:app:exited:- \
  sidecar:box:sidecar:exited:app
networks box
COMPOSE_PROJECT_NAME=box run
check_absent "the first pass fails quietly on the shared one" err "has dependent containers"
check_left "the second pass removes it"
check "and the networks go too" 0 networks-removed "box_wan"
check_absent "kills nothing when nothing runs" log "podman kill"

fresh gluetun:box:gluetun:exited:-
touch "${__state}/stuck/gluetun"
networks box
COMPOSE_PROJECT_NAME=box run
check "fails when a container cannot be removed" 1 err "these containers of project box could not be removed:"
check "and names it" 1 err "  gluetun"
check "shows the error podman gave" 1 err "cannot remove container gluetun"
check "fails when a network is still in use" 1 err "could not remove network box_wan."

# Listing works until the check of what is left, the sixth podman ps here.
fresh gluetun:box:gluetun:exited:-
echo 5 >"${__state}/ps-ok"
COMPOSE_PROJECT_NAME=box run
check "fails when podman cannot list what is left" 1 err "podman could not list what is left of project box."

fresh \
  gluetun:work:gluetun:running:- \
  slow:work:slow:running:gluetun
touch "${__state}/stubborn/slow"
PODMAN_DOWN_TIMEOUT=3 run
check "falls back to the directory name" 0 log "label=com.docker.compose.project=work"
check "waits for the containers to stop" 0 log "sleep 1"
check "force-kills what is still running at the timeout" 0 out "Force-killing containers still running after 3s..."
check "only what is still running" 0 log "podman kill slow"
check_left "and removes it all"

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
