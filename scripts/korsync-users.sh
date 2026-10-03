#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

env_value() {
  local key="$1"
  local value
  [[ -f .env ]] || return 1
  value="$(
    awk -v key="$key" '
      index($0, key "=") == 1 {
        sub("^[^=]*=", "")
        sub(/^"/, "")
        sub(/"$/, "")
        sub(/^'\''/, "")
        sub(/'\''$/, "")
        print
        exit
      }
    ' .env
  )"
  [[ -n "$value" ]] || return 1
  printf '%s' "$value"
}

CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-$(env_value CONTAINER_RUNTIME || printf 'podman')}"
CONTAINER=korsync

usage() {
  cat <<EOF
Usage: $0 <command> [args]

Commands:
  list
  remove <username>
  rename <old-username> <new-username>
  change-password <username>
EOF
  exit 1
}

bun_exec() {
  "$CONTAINER_RUNTIME" exec "$CONTAINER" bun -e "$1"
}

# Each bun program is a here document in a function of its own rather than a
# multi line quoted argument, which kcov would count as shell lines that never
# run.
list_js() {
  cat <<'JS'
import { Database } from "bun:sqlite";
const db = new Database("/app/data/koreader-sync.db", { readonly: true });
const rows = db.query("SELECT id, username, created_at FROM users ORDER BY username").all();
if (rows.length === 0) { console.log("no users"); process.exit(0); }
console.log("ID\tUsername\tCreated");
for (const r of rows) console.log(`${r.id}\t${r.username}\t${r.created_at}`);
JS
}

cmd_list() {
  bun_exec "$(list_js)"
}

remove_js() {
  cat <<'JS'
import { Database } from "bun:sqlite";
const db = new Database("/app/data/koreader-sync.db");
const username = process.env.USERNAME;
const user = db.query("SELECT id FROM users WHERE username=?").get(username);
if (!user) { console.error(`user not found: ${username}`); process.exit(1); }
db.run("DELETE FROM progress WHERE user_id=?", [user.id]);
db.run("DELETE FROM users WHERE id=?", [user.id]);
console.log(`removed: ${username}`);
JS
}

cmd_remove() {
  local username="${1:?usage: remove <username>}"
  USERNAME="$username" "$CONTAINER_RUNTIME" exec -e USERNAME "$CONTAINER" bun -e "$(remove_js)"
}

rename_js() {
  cat <<'JS'
import { Database } from "bun:sqlite";
const db = new Database("/app/data/koreader-sync.db");
const result = db.run("UPDATE users SET username=? WHERE username=?", [process.env.NEW_NAME, process.env.OLD_NAME]);
if (result.changes === 0) { console.error(`user not found: ${process.env.OLD_NAME}`); process.exit(1); }
console.log(`renamed: ${process.env.OLD_NAME} -> ${process.env.NEW_NAME}`);
JS
}

cmd_rename() {
  local old="${1:?usage: rename <old-username> <new-username>}"
  local new="${2:?usage: rename <old-username> <new-username>}"
  OLD_NAME="$old" NEW_NAME="$new" "$CONTAINER_RUNTIME" exec -e OLD_NAME -e NEW_NAME "$CONTAINER" bun -e "$(rename_js)"
}

change_password_js() {
  cat <<'JS'
import { Database } from "bun:sqlite";
const salt = process.env.PASSWORD_SALT ?? "";
const hash = await Bun.password.hash(process.env.NEW_PASSWORD + salt);
const db = new Database("/app/data/koreader-sync.db");
const result = db.run("UPDATE users SET password=? WHERE username=?", [hash, process.env.USERNAME]);
if (result.changes === 0) { console.error(`user not found: ${process.env.USERNAME}`); process.exit(1); }
console.log(`password updated: ${process.env.USERNAME}`);
JS
}

cmd_change_password() {
  local username="${1:?usage: change-password <username>}"
  local password
  read -rsp "New password for ${username}: " password
  echo
  [[ -z "$password" ]] && {
    echo "password cannot be empty" >&2
    exit 1
  }
  USERNAME="$username" NEW_PASSWORD="$password" "$CONTAINER_RUNTIME" exec -e USERNAME -e NEW_PASSWORD "$CONTAINER" bun -e "$(change_password_js)"
}

[[ $# -lt 1 ]] && usage

case "$1" in
list) cmd_list ;;
remove) cmd_remove "${2:-}" ;;
rename) cmd_rename "${2:-}" "${3:-}" ;;
change-password) cmd_change_password "${2:-}" ;;
*) usage ;;
esac
