#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for scripts/seed-gluetun-secret.sh. Every line of the script has to
# run in one of them: `make coverage` runs this file under kcov and fails
# below 100%.
#
# The guided setup only runs when standard input is a terminal, and it reads
# the key one masked character at a time from /dev/tty. So the interactive
# cases run the script on a pseudo terminal of its own, through a small
# Python driver that answers each prompt the way a person would type it. Each
# case runs in a scratch directory whose scripts/seed-configs.sh is a stub, and
# PATH holds only grep and sed, so nothing outside the scratch directory is
# read or written.

# cspell:ignore termios execv tcgetattr ICANON waitpid waitstatus

set -o errexit
set -o pipefail
set -o nounset

__script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/seed-gluetun-secret.sh"
__bash="$(command -v bash)"
__python="$(command -v python3)"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0
__work="${__scratch}/work"
__secret="${__work}/configs/gluetun/.secret"
__placeholder="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" # pragma: allowlist secret

# Runs `bash <script>` on a new pseudo terminal, which is also its controlling
# terminal (/dev/tty). Arguments after the script come in pairs: a prompt to
# wait for, then what to type. A line answer is sent once the prompt shows. A
# masked answer (prefixed `masked:`) is sent in one write once the first
# `read -rsn1` has taken the terminal out of canonical mode, so the line editor
# never sees it: typed earlier, a DEL byte would be eaten as an erase and every
# character echoed. Writes everything the terminal showed to <out> and exits
# with the script's status.
cat >"${__scratch}/pty-driver.py" <<'PY'
import os
import pty
import select
import sys
import termios
import time

out_path, bash, script, *steps = sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    os.execv(bash, [bash, script])
seen = b""
closed = False


def pump():
    global seen, closed
    if closed:
        return
    ready, _, _ = select.select([fd], [], [], 0.02)
    if ready:
        try:
            data = os.read(fd, 4096)
        except OSError:
            data = b""
        if data:
            seen += data
        else:
            closed = True


def until(condition, what):
    deadline = time.time() + 20
    while not condition():
        if closed or time.time() > deadline:
            sys.exit(f"pty-driver: gave up waiting for {what!r}; saw {seen!r}")
        pump()


def canonical():
    return bool(termios.tcgetattr(fd)[3] & termios.ICANON)


for prompt, answer in zip(steps[0::2], steps[1::2]):
    until(lambda: prompt.encode() in seen, prompt)
    if answer.startswith("masked:"):
        until(lambda: not canonical(), "a masked read")
        os.write(fd, answer[len("masked:"):].encode())
    else:
        os.write(fd, answer.encode() + b"\n")
while not closed:
    pump()
_, status = os.waitpid(pid, 0)
with open(out_path, "wb") as out:
    out.write(seen)
sys.exit(os.waitstatus_to_exitcode(status))
PY

bin="${__scratch}/bin"
mkdir -p "${bin}"
for tool in grep sed; do
  ln -s "$(command -v "${tool}")" "${bin}/${tool}"
done

fresh_work() {
  rm -rf "${__work}"
  mkdir -p "${__work}/scripts" "${__work}/configs/gluetun"
  printf '#!%s\n%s\n' "${__bash}" "echo \"seed-configs \$*\" >>'${__scratch}/log'
printf '%s\n' VPN_SERVICE_PROVIDER=protonvpn SERVER_COUNTRIES=Netherlands >\"\${1}\"" \
    >"${__work}/scripts/seed-configs.sh"
  chmod +x "${__work}/scripts/seed-configs.sh"
  : >"${__scratch}/log"
}

# Runs the script without a terminal, standard input from /dev/null.
run() {
  __status=0
  (cd "${__work}" && PATH="${bin}" "${__bash}" "${__script}") </dev/null \
    >"${__scratch}/out" 2>"${__scratch}/err" || __status=$?
}

# Runs the script on a terminal, answering the prompts given as pairs.
run_tty() {
  __status=0
  (cd "${__work}" && PATH="${bin}" "${__python}" "${__scratch}/pty-driver.py" \
    "${__scratch}/out" "${__bash}" "${__script}" "$@") 2>"${__scratch}/err" || __status=$?
}

check() {
  local name="${1}" status="${2}" file="${3}" want="${4}"
  if [[ "${__status}" -ne "${status}" ]]; then
    echo "FAIL ${name}: exit ${__status}, wanted ${status}" >&2
    cat "${__scratch}/err" "${__scratch}/out" >&2
    __failures=$((__failures + 1))
  elif ! grep --quiet --fixed-strings -- "${want}" "${file}"; then
    echo "FAIL ${name}: '${want}' not in ${file}" >&2
    cat "${file}" >&2
    __failures=$((__failures + 1))
  else
    echo "ok ${name}"
  fi
}

fresh_work
printf 'real-key' >"${__secret}"
run
check "leaves a real key alone" 0 "${__secret}" "real-key"
if [[ -s "${__scratch}/log" ]]; then
  echo "FAIL seeded configs although the key was real" >&2
  __failures=$((__failures + 1))
fi

fresh_work
echo "${__placeholder}" >"${__secret}"
run
check "fails fast without a terminal" 1 "${__scratch}/err" "configs/gluetun/.secret is missing or empty."
check "points at the docs" 1 "${__scratch}/err" "docs/VPN_PROVIDERS.md"

fresh_work
run_tty "Choice [1/2] [1]: " "" \
  "PrivateKey: " $'masked:\x7fab\x7fcd\n' \
  "SERVER_COUNTRIES [" ""
check "seeds gluetun's .env first" 0 "${__scratch}/log" "seed-configs configs/gluetun/.env"
check "masks the key as it is typed" 0 "${__scratch}/out" $'PrivateKey: **\b \b**'
check "saves the key with backspaces applied" 0 "${__secret}" "acd"
check "defaults to the suggested country" 0 "${__scratch}/out" "Set SERVER_COUNTRIES="
suggested="$(sed -n 's/.*SERVER_COUNTRIES \[\([A-Za-z]*\)\].*/\1/p' "${__scratch}/out")"
check "writes the suggested country" 0 "${__work}/configs/gluetun/.env" "SERVER_COUNTRIES=${suggested}"
if [[ "$(<"${__secret}")" != acd ]]; then
  echo "FAIL the key file holds more than the key" >&2
  __failures=$((__failures + 1))
fi

fresh_work
run_tty "Choice [1/2] [1]: " "1" \
  "PrivateKey: " $'masked:key\n' \
  "SERVER_COUNTRIES [" "Japan"
check "writes the country typed" 0 "${__work}/configs/gluetun/.env" "SERVER_COUNTRIES=Japan"

fresh_work
run_tty "Choice [1/2] [1]: " "1" "PrivateKey: " $'masked:\n'
check "refuses an empty key" 1 "${__scratch}/out" "ERROR: No key entered."

fresh_work
run_tty "Choice [1/2] [1]: " "2"
check "sends other providers to the docs" 1 "${__scratch}/out" "Only Proton VPN can be configured interactively"

fresh_work
run_tty "Choice [1/2] [1]: " "9"
check "rejects an unknown choice" 1 "${__scratch}/out" "ERROR: Invalid choice."

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
