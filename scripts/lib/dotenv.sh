# shellcheck shell=sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# The one reader of KEY=value files (.env, versions.env, certs/cert.conf) for
# the shell scripts, sourced rather than run. None of them can `source .env`,
# since .env defines UID, which is a readonly bash builtin. It reads a value
# the way compose does, so a script and the stack it drives agree on what a
# line says:
#   - whitespace around the key and the value is dropped, a CRLF file's
#     carriage return too, and an `export ` before the key is ignored;
#   - a value in double or single quotes is what is inside the first pair, and
#     anything after the closing quote is dropped. Inside double quotes \" is
#     a quote and \\ a backslash; single quotes take everything literally;
#   - an unquoted value ends where whitespace followed by # starts a comment.
#     A # with nothing but the value before it stays part of the value;
#   - within one file the last assignment wins, as it does for compose and
#     make.
# Nothing is expanded: a ${VAR} inside a value comes back as written.
#
# Two deliberate differences, both on lines compose would not use as they
# are. Other backslash escapes inside double quotes (\n, \t) come back as
# written rather than as the character. A quote that is never closed runs to
# the end of the line rather than being an error: compose refuses such a
# .env outright, so the stack is not running on a value a script could
# disagree with, and the script still gets the most likely meaning.
#
# POSIX sh rather than bash, because scripts/rotate-nginx-logs.sh sources it
# too, inside the log_rotator container. The awk program is a here document
# because kcov counts each line of a multi line quoted argument as a command
# that never runs. tests/unit/dotenv.test.sh covers every rule above.

# dotenv_get [-n] KEY FILE...
# Prints KEY's value from the first FILE that sets it, skipping a FILE that
# does not exist. Fails when none sets it, and with -n also when the value it
# found is empty, for a caller that falls back to a default either way.
dotenv_get() {
  _dotenv_nonempty=false
  if [ "$1" = -n ]; then
    _dotenv_nonempty=true
    shift
  fi
  _dotenv_key="$1"
  shift
  for _dotenv_file in "$@"; do
    [ -f "$_dotenv_file" ] || continue
    _dotenv_value="$(_dotenv_read "$_dotenv_key" "$_dotenv_file")" || continue
    [ "$_dotenv_nonempty" = false ] || [ -n "$_dotenv_value" ] || return 1
    printf '%s\n' "$_dotenv_value"
    return 0
  done
  return 1
}

# dotenv_lookup KEY FILE
# FILE, else the environment (the value make passed down for a key an older
# FILE lacks), else FILE.example (the default make and compose would apply).
# A key found nowhere is named before the caller stops: a bare miss under
# pipefail used to end a script silently (#299).
dotenv_lookup() {
  dotenv_get "$1" "$2" && return 0
  # Only a variable name can be in the environment, and only one is safe to
  # hand to eval.
  case "$1" in
  "" | [0-9]* | *[!A-Za-z0-9_]*) _dotenv_in_env= ;;
  *) eval "_dotenv_in_env=\${$1+set}" ;;
  esac
  if [ -n "$_dotenv_in_env" ]; then
    eval "printf '%s\n' \"\${$1}\""
    return 0
  fi
  dotenv_get "$1" "$2.example" && return 0
  echo "ERROR: $1 is set in neither $2 nor $2.example, nor in the environment." >&2
  return 1
}

# The value of KEY's last assignment in FILE, failing when FILE has none.
_dotenv_read() {
  awk -v key="$1" -f /dev/stdin "$2" <<'AWK'
{
  sub(/\r$/, "")
  eq = index($0, "=")
  if (eq == 0) next
  name = substr($0, 1, eq - 1)
  sub(/^[ \t]*(export[ \t]+)?/, "", name)
  sub(/[ \t]+$/, "", name)
  if (name != key) next
  value = substr($0, eq + 1)
  quote = value
  sub(/^[ \t]+/, "", quote)
  quote = substr(quote, 1, 1)
  if (quote == "\"") {
    sub(/^[ \t]+/, "", value)
    out = ""
    for (i = 2; i <= length(value); i++) {
      c = substr(value, i, 1)
      if (c == "\\") {
        next_c = substr(value, i + 1, 1)
        if (next_c == "\"" || next_c == "\\") {
          out = out next_c
          i++
          continue
        }
      }
      if (c == "\"") break
      out = out c
    }
    value = out
  } else if (quote == "'") {
    sub(/^[ \t]+/, "", value)
    value = substr(value, 2)
    end = index(value, quote)
    if (end > 0) value = substr(value, 1, end - 1)
  } else {
    sub(/[ \t]+#.*$/, "", value)
    sub(/^[ \t]+/, "", value)
    sub(/[ \t]+$/, "", value)
  }
  found = 1
  last = value
}
END {
  if (!found) exit 1
  print last
}
AWK
}
