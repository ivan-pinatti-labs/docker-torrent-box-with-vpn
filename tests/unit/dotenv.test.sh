#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for scripts/lib/dotenv.sh, the .env reader every shell script sources.
# Every line of it has to run in one of them: `make coverage` runs this file
# under kcov and fails below 100%. Each case reads a scratch file the way
# compose would and compares the value; the scripts' own tests cover how each
# of them uses it.

set -o errexit
set -o pipefail
set -o nounset

__lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/dotenv.sh"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0
cd "${__scratch}"

# shellcheck source=scripts/lib/dotenv.sh
. "${__lib}"

# check NAME EXPECTED_STATUS EXPECTED_OUTPUT COMMAND...
check() {
  local name="$1" want_status="$2" want="$3" got status=0
  shift 3
  got="$("$@" 2>"${__scratch}/err")" || status=$?
  if [[ "${status}" == "${want_status}" && "${got}" == "${want}" ]]; then
    echo "ok ${name}"
  else
    echo "FAIL ${name}: status ${status}, got [${got}], want [${want}]" >&2
    cat "${__scratch}/err" >&2
    __failures=$((__failures + 1))
  fi
}

{
  printf '%s\n' \
    '# PLAIN=commented out' \
    '# ONLY_COMMENTED=commented out' \
    'not an assignment' \
    'PLAIN=value' \
    'PLAIN_LONGER=not this one' \
    'COMMENT=live- # local stack' \
    'TAB=tabbed	# comment' \
    'HASH=x#y' \
    'BARE= # only a comment' \
    'EMPTY=' \
    'DOUBLE="a # b" # comment' \
    'ESCAPED="./media \"archive\" \\ end\n" # comment' \
    "SINGLE='a \"b\" c' # comment" \
    'UNCLOSED="no end' \
    '  SPACED  =  padded value  ' \
    'export EXPORTED=yes' \
    'REF=${DATA_FOLDER}/x' \
    'TWICE=first' \
    'TWICE=second'
  printf 'CRLF=windows\r\n'
} >.env

check "an unquoted value" 0 value dotenv_get PLAIN .env
check "a trailing comment after whitespace is dropped" 0 live- dotenv_get COMMENT .env
check "a tab before the comment counts as whitespace" 0 tabbed dotenv_get TAB .env
check "a # with no whitespace before it stays" 0 'x#y' dotenv_get HASH .env
check "a value that is only a comment is empty" 0 '' dotenv_get BARE .env
check "an empty value is set" 0 '' dotenv_get EMPTY .env
check "a double quoted value keeps its #, the comment after it goes" 0 'a # b' dotenv_get DOUBLE .env
check "a double quoted value unescapes \\\" and \\\\, and keeps other escapes" 0 './media "archive" \ end\n' dotenv_get ESCAPED .env
check "a single quoted value keeps double quotes inside it" 0 'a "b" c' dotenv_get SINGLE .env
check "an unclosed quote runs to the end of the line" 0 'no end' dotenv_get UNCLOSED .env
check "whitespace around the key and the value is dropped" 0 'padded value' dotenv_get SPACED .env
check "export before the key is ignored" 0 yes dotenv_get EXPORTED .env
check "a reference is not expanded" 0 "\${DATA_FOLDER}/x" dotenv_get REF .env
check "the last assignment in a file wins" 0 second dotenv_get TWICE .env
check "a CRLF line loses its carriage return" 0 windows dotenv_get CRLF .env
check "a key no line sets fails" 1 '' dotenv_get MISSING .env
check "a commented out line does not override a real one" 0 value dotenv_get PLAIN .env
check "a key set only on a commented out line is unset" 1 '' dotenv_get ONLY_COMMENTED .env

printf '%s\n' 'PIN=from-versions' 'ONLY=versions' >versions.env
printf '%s\n' 'PIN=from-env' >held.env
check "the first file that sets the key wins" 0 from-env dotenv_get PIN held.env versions.env
check "a later file answers what the first lacks" 0 versions dotenv_get ONLY held.env versions.env
check "a missing file is skipped" 0 versions dotenv_get ONLY absent.env versions.env
check "a key no file sets fails" 1 '' dotenv_get MISSING absent.env versions.env

check "-n returns a value that is there" 0 value dotenv_get -n PLAIN .env
check "-n fails on an empty value" 1 '' dotenv_get -n EMPTY .env

printf '%s\n' 'FROM_FILE=file' 'BOTH=file' >conf
printf '%s\n' 'FROM_EXAMPLE=example # default' 'BOTH=example' 'IN_ENV=example' 'BAD-NAME=example' >conf.example
check "lookup reads the file first" 0 file dotenv_lookup BOTH conf
check "lookup takes the environment for a key the file lacks" 0 environment \
  env IN_ENV=environment bash -c '. "$1"; dotenv_lookup IN_ENV conf' sh "${__lib}"
IN_SHELL=shell
check "lookup sees a shell variable as well as an exported one" 0 shell dotenv_lookup IN_SHELL conf
unset IN_SHELL
EMPTY_VAR=
check "lookup takes a set but empty variable" 0 '' dotenv_lookup EMPTY_VAR conf
unset EMPTY_VAR
check "lookup falls back to the example" 0 example dotenv_lookup FROM_EXAMPLE conf
check "a key that is no variable name skips the environment" 0 example dotenv_lookup BAD-NAME conf
check "lookup names a key found nowhere" 1 '' dotenv_lookup NOWHERE conf
if grep --quiet --fixed-strings "ERROR: NOWHERE is set in neither conf nor conf.example, nor in the environment." err; then
  echo "ok the error names the key and both files"
else
  echo "FAIL the error names the key and both files" >&2
  __failures=$((__failures + 1))
fi

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
