#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
set -euo pipefail

# Usage: ./scripts/seed-configs.sh <live-file>
# Seeds <live-file> from <live-file>.example on first bootstrap, the same
# copy-if-missing pattern scripts/seed-secrets.sh uses for .env.secrets.
# If <live-file> already exists, prompts interactively instead of silently
# overwriting or silently skipping. Never touches a live file that already
# exists in a non-interactive run (CI, scripted make bootstrap).

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <live-file>" >&2
  exit 1
fi

readonly LIVE="$1"
readonly EXAMPLE="$LIVE.example"

if [[ ! -f "$EXAMPLE" ]]; then
  echo "Missing $EXAMPLE" >&2
  exit 1
fi

if [[ ! -f "$LIVE" ]]; then
  mkdir -p "$(dirname "$LIVE")"
  cp "$EXAMPLE" "$LIVE"
  echo "[$LIVE] Seeded from $(basename "$EXAMPLE")."
  exit 0
fi

# Non-interactive (CI, scripted runs): never touch an existing live file.
[[ -t 0 ]] || exit 0

echo ""
echo "[$LIVE] already exists."
# Computed once rather than inside the case pattern below, where kcov cannot
# see the command substitution run and reports the pattern line as uncovered.
replace="Replace with $(basename "$EXAMPLE")"
select choice in "Skip (keep existing)" "Review diff" "$replace"; do
  case "$choice" in
  "Skip (keep existing)") break ;;
  "Review diff") diff -u "$LIVE" "$EXAMPLE" || true ;;
  "$replace")
    cp "$EXAMPLE" "$LIVE"
    echo "[$LIVE] Replaced."
    break
    ;;
  *) echo "Invalid choice." ;;
  esac
done
