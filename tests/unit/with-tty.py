#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
"""Run a command with a terminal on its standard input, for the shell tests.

Usage: with-tty.py <input> <command> [<argument> ...]

Some scripts only prompt when standard input is a terminal (`[[ -t 0 ]]`),
and stay silent otherwise. A shell test drives those prompts through this:
the command's standard input is a pseudo terminal, <input> is typed into it
line by line followed by end of file, and its standard output and error are
this process's own, so the test still captures them separately. Every other
open file descriptor is passed through, which is how kcov keeps tracing the
command. Exits with the command's exit status.
"""

from __future__ import annotations

import os
import subprocess
import sys


def main(argv: list[str]) -> int:
    """Run argv[1:] with argv[0] typed into a pseudo terminal on its stdin."""
    typed, command = argv[0], argv[1:]
    master, slave = os.openpty()
    # \x04 is end of file at the start of a line, so a prompt that reads past
    # the given input sees end of file rather than waiting forever.
    os.write(master, typed.encode() + b"\x04")
    proc = subprocess.Popen(command, stdin=slave, close_fds=False)  # noqa: S603
    os.close(slave)
    status = proc.wait()
    os.close(master)
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
