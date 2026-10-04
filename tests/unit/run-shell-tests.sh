#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# The shell half of the unit tier. Runs tests/unit/<name>.test.sh for every
# script named on the command line, which is the Makefile's
# COVERAGE_SHELL_SCRIPTS (every shell script the repository writes, found
# rather than listed): `make coverage` runs this file under kcov, which
# follows each test and each script it starts. A script with no test file is
# a failure, not a skip, so a new script cannot go unexercised.
#
# Usage: tests/unit/run-shell-tests.sh scripts/<name>.sh [...]

set -o errexit
set -o nounset
set -o pipefail

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 scripts/<name>.sh [...]" >&2
  exit 2
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=0
for script in "$@"; do
  test_file="${here}/$(basename "${script}" .sh).test.sh"
  if [[ ! -f "${test_file}" ]]; then
    echo "FAIL ${script}: no test file at tests/unit/$(basename "${test_file}")" >&2
    failed=1
    continue
  fi
  echo "# ${script}"
  bash "${test_file}" || failed=1
done
exit "${failed}"
