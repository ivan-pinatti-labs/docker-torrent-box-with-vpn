#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Mounts, unmounts and reports on the external storage share that backs
# DATA_FOLDER, and installs the fstab entry that brings it back after a reboot.
# All settings come from .env's ### EXTERNAL STORAGE block; see docs/STORAGE.md.
#
# Usage: storage-mount.sh {mount|unmount|status|install-boot|uninstall-boot}
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Both are overridable so the boot-entry path can be exercised by the test
# suite against a throwaway fstab with no privileges. Nothing else should set
# them: the defaults are what a real install uses.
FSTAB="${FSTAB:-/etc/fstab}"
SUDO="${SUDO-sudo}"
FSTAB_MARKER="# docker-torrent-box-with-vpn external storage"

# Reads one key from .env, stripping surrounding quotes. Deliberately not a
# `source`: .env defines UID, which is a readonly bash builtin, so sourcing it
# fails outright. Same approach as scripts/disk-status.sh.
env_value() {
  local key="$1" value
  [ -f .env ] || return 1
  value="$(
    awk -v key="$key" '
      index($0, key "=") == 1 {
        sub("^[^=]*=", "")
        sub(/^"/, ""); sub(/"$/, "")
        sub(/^'\''/, ""); sub(/'\''$/, "")
        print
        exit
      }
    ' .env
  )"
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

# .env expresses several paths in terms of other variables, e.g.
# STORAGE_MOUNTPOINT="${DATA_FOLDER}". env_value returns that literally, so a
# naive caller would mount into a directory named '${DATA_FOLDER}'. Expand the
# handful of keys that actually appear on the right hand side.
expand_env() {
  local v="$1"
  v="${v//\$\{DATA_FOLDER\}/$DATA_FOLDER}"
  v="${v//\$\{CONFIG_FOLDER\}/$CONFIG_FOLDER}"
  printf '%s' "$v"
}

DATA_FOLDER="$(env_value DATA_FOLDER || printf './data')"
CONFIG_FOLDER="$(env_value CONFIG_FOLDER || printf './configs')"
STORAGE_REMOTE="$(env_value STORAGE_REMOTE || printf '')"
STORAGE_MOUNTPOINT="$(expand_env "$(env_value STORAGE_MOUNTPOINT || printf "$DATA_FOLDER")")"
STORAGE_CREDENTIALS_FILE="$(expand_env "$(env_value STORAGE_CREDENTIALS_FILE || printf "$CONFIG_FOLDER/storage/.smbcredentials")")"

log() { printf '%s\n' "$*"; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# Absolute paths: fstab needs them, and so does every mount check below.
#
# Resolving the parent with a subshell cd and taking whatever comes out is not
# safe. When the parent does not exist the cd fails, the substitution is empty,
# and './missing/data' silently becomes '/data'. That is a real mountpoint at
# the root of the filesystem, and install-boot would write it to /etc/fstab.
# Resolve the parent explicitly and refuse if it is not there.
mountpoint_parent="$(cd "$(dirname "$STORAGE_MOUNTPOINT")" 2>/dev/null && pwd || true)"
[ -n "$mountpoint_parent" ] ||
  die "cannot resolve $STORAGE_MOUNTPOINT: $(dirname "$STORAGE_MOUNTPOINT") does not exist. Create it, or fix STORAGE_MOUNTPOINT in .env."
mountpoint_abs="$mountpoint_parent/$(basename "$STORAGE_MOUNTPOINT")"

# The mountpoint has to stay inside the repository, for the same reason
# permissions.py refuses manifest paths outside it: compose reads DATA_FOLDER
# relative to the repository, and a mount somewhere else leaves the apps
# reading one tree while the permissions manifest manages another. See
# docs/STORAGE.md, "Keep DATA_FOLDER Repository Relative". The `:` gives the
# accepting branch a command, which kcov needs to count that line as run.
case "$mountpoint_abs" in
"$repo_root" | "$repo_root"/*) : ;;
*) die "refusing mountpoint outside the repository: $mountpoint_abs (STORAGE_MOUNTPOINT must stay under $repo_root)" ;;
esac

credentials_abs="$repo_root/${STORAGE_CREDENTIALS_FILE#./}"

# True when $FSTAB already carries an entry for THIS checkout's mountpoint.
#
# Deliberately keyed on the mountpoint and not on FSTAB_MARKER. That marker is
# one fixed string with no path in it, so every checkout of this repository
# writes and then looks for the exact same comment. Confirmed live on a machine
# with two checkouts: the second one reported "fstab entry installed" for an
# entry that mounts the first one's data/, and would have gone on to report a
# share as set up for boot that it does not mount. `uninstall-boot` had the
# same flaw the other way round, deleting whichever block came first rather
# than its own. The mountpoint is the one field that is unique per checkout.
#
# Comment lines are skipped so the marker itself never counts as an entry, and
# field 2 is fstab's mountpoint column.
#
# The awk programs here are here documents rather than quoted arguments
# because kcov counts each line of a multi line quoted argument as a
# command of its own that never runs.
fstab_has_entry() {
  awk -v mp="$mountpoint_abs" -f /dev/stdin "$FSTAB" 2>/dev/null <<'AWK'
/^[[:space:]]*#/ { next }
NF >= 2 && $2 == mp { found = 1 }
END { exit !found }
AWK
}

require_configured() {
  [ -n "$STORAGE_REMOTE" ] || die "STORAGE_REMOTE is empty in .env; external storage is not configured."
  [ -f "$credentials_abs" ] || die "credentials file not found: $credentials_abs (copy .smbcredentials.example and fill it in)"
}

# Present in the mount table *and* actually usable. A CIFS session can die and
# leave the mount entry behind: findmnt still reports it while every access
# returns ENOENT, and the kernel logs "reconnect tcon failed". Seen live on
# 2026-08-12, when the whole stack came up against an unreadable data/ because
# this only asked findmnt. Reading the directory is what tells them apart.
is_mounted() {
  findmnt --noheadings --target "$mountpoint_abs" --source "$STORAGE_REMOTE" >/dev/null 2>&1 || return 1
  ls -A "$mountpoint_abs" >/dev/null 2>&1
}

# Distinguishes the stale case for reporting: the table says yes, the
# filesystem says no.
is_stale_mount() {
  findmnt --noheadings --target "$mountpoint_abs" --source "$STORAGE_REMOTE" >/dev/null 2>&1 &&
    ! ls -A "$mountpoint_abs" >/dev/null 2>&1
}

# Builds the option string. context= is not optional: CIFS has no
# security.selinux xattr, so Podman's :z relabel cannot work and the label has
# to arrive with the mount. Without it every container is denied by SELinux
# while the mode bits look perfectly fine, which reads as a permissions bug and
# is not one.
mount_options() {
  local opts="credentials=${credentials_abs}"
  opts="${opts},uid=$(env_value STORAGE_CIFS_UID || printf '1000')"
  opts="${opts},gid=$(env_value STORAGE_CIFS_GID || printf '1000')"
  opts="${opts},vers=$(env_value STORAGE_CIFS_VERSION || printf '3.1.1')"
  opts="${opts},file_mode=$(env_value STORAGE_CIFS_FILE_MODE || printf '0664')"
  opts="${opts},dir_mode=$(env_value STORAGE_CIFS_DIR_MODE || printf '0775')"
  local extra context
  extra="$(env_value STORAGE_CIFS_EXTRA_OPTIONS || printf '')"
  [ -n "$extra" ] && opts="${opts},${extra}"
  context="$(env_value STORAGE_SELINUX_CONTEXT || printf '')"
  [ -n "$context" ] && opts="${opts},context=${context}"
  printf '%s' "$opts"
}

stack_containers_running() {
  command -v podman >/dev/null 2>&1 || return 1
  [ -n "$(podman ps --filter "label=com.docker.compose.project=$(basename "$repo_root")" --format '{{.Names}}' 2>/dev/null)" ]
}

verify_mount() {
  local opts probe
  opts="$(findmnt --noheadings --output OPTIONS --target "$mountpoint_abs" 2>/dev/null || true)"
  case ",$opts," in
  *,noserverino,*) log "WARNING: mounted with noserverino; hardlinks will be invisible to rsync -H and to the apps." ;;
  esac
  # The whole point of one share is that imports hardlink instead of copying.
  # Prove it here rather than discovering it after a library has doubled.
  #
  # mktemp rather than a fixed name: this deletes the directory afterwards, and
  # a fixed name is one the share might already have, in which case the probe
  # would take somebody else's data with it.
  probe="$(mktemp -d "$mountpoint_abs/.storage-probe.XXXXXX" 2>/dev/null || true)"
  if [ -z "$probe" ]; then
    log "WARNING: could not create a probe directory on the share; skipping the hardlink check."
    return 0
  fi
  if mkdir -p "$probe/a" "$probe/b" 2>/dev/null &&
    : >"$probe/a/f" 2>/dev/null &&
    ln "$probe/a/f" "$probe/b/f" 2>/dev/null &&
    [ "$(stat -c %h "$probe/a/f" 2>/dev/null)" = "2" ]; then
    log "hardlinks: OK (link count 2 across subdirectories)"
  else
    log "WARNING: hardlink probe failed; imports will copy instead of link."
  fi
  rm -rf "$probe" 2>/dev/null || true
}

cmd_mount() {
  require_configured
  if is_mounted; then
    log "already mounted: $STORAGE_REMOTE -> $mountpoint_abs"
    return 0
  fi
  mkdir -p "$mountpoint_abs"
  # The check that matters most. A mount that silently fails leaves the apps
  # writing into the local directory underneath, which looks completely normal
  # until the share comes back and that data is nowhere to be seen.
  if [ -n "$(ls -A "$mountpoint_abs" 2>/dev/null)" ]; then
    die "$mountpoint_abs is not empty. Refusing to mount over existing data; move it aside first."
  fi
  log "mounting $STORAGE_REMOTE -> $mountpoint_abs"
  $SUDO mount -t cifs -o "$(mount_options)" "$STORAGE_REMOTE" "$mountpoint_abs" ||
    die "mount failed. Check the share name, credentials and that cifs-utils is installed."
  log "mounted."
  verify_mount
}

cmd_unmount() {
  if ! is_mounted; then
    log "not mounted: $mountpoint_abs"
    return 0
  fi
  if stack_containers_running; then
    die "stack containers are running; stop them first (make stop_all)."
  fi
  log "unmounting $mountpoint_abs"
  $SUDO umount "$mountpoint_abs" 2>/dev/null || {
    log "busy; retrying lazily"
    $SUDO umount --lazy "$mountpoint_abs" || die "unmount failed."
  }
  log "unmounted."
}

cmd_status() {
  log "remote:     ${STORAGE_REMOTE:-<not configured>}"
  log "mountpoint: $mountpoint_abs"
  if [ -z "$STORAGE_REMOTE" ]; then
    log "state:      external storage not configured"
    return 0
  fi
  local mounted=0
  if is_mounted; then
    mounted=1
    log "state:      mounted"
    log "fstype:     $(findmnt --noheadings --output FSTYPE --target "$mountpoint_abs")"
    log "options:    $(findmnt --noheadings --output OPTIONS --target "$mountpoint_abs")"
    df -h "$mountpoint_abs" | tail -1 | awk '{printf "space:      %s used of %s (%s free)\n", $3, $2, $4}'
  elif is_stale_mount; then
    # Worth calling out rather than reporting a plain "not mounted": the mount
    # table still lists it, so findmnt, /proc/mounts and df all disagree with
    # every actual read, and that is a confusing hour if you have not seen it.
    log "state:      STALE (mount entry present but unreadable)"
    log "            the SMB session died and could not reconnect; the share"
    log "            itself may be fine. Recover with:"
    log "              make storage_unmount && make storage_mount"
  else
    log "state:      NOT MOUNTED"
  fi
  # Reported either way. Returning early on an unmounted share was exactly
  # backwards: "is this set up to come back after a reboot" is most worth
  # answering when the share is not currently there.
  if fstab_has_entry; then
    log "boot:       fstab entry installed"
  else
    log "boot:       no fstab entry (run: make storage_install_boot)"
  fi
  [ "$mounted" = 1 ] || return 1
}

fstab_line() {
  # _netdev so the mount waits for the network, and nofail so a NAS that is
  # down cannot hold up boot: with nofail the unit is only wanted by
  # remote-fs.target and is not ordered before it, so boot carries on without
  # waiting either way.
  #
  # Deliberately not x-systemd.automount. It would leave an autofs mount at the
  # path until something touches it, and autofs reports its source as
  # 'systemd-1', so every findmnt based check here would read a healthy share
  # as NOT MOUNTED for as long as nothing had accessed it. nofail already
  # provides the only thing automount was wanted for.
  #
  # The trade either way is that the stack can reach `make start` before the
  # share is up, which is why that target refuses when STORAGE_REMOTE is set
  # and the share is not mounted.
  printf '%s %s cifs %s,_netdev,nofail 0 0\n' \
    "$STORAGE_REMOTE" "$mountpoint_abs" "$(mount_options)"
}

cmd_install_boot() {
  require_configured
  if fstab_has_entry; then
    die "an entry for $mountpoint_abs is already installed in $FSTAB; run uninstall-boot first."
  fi
  log "This will append the following to $FSTAB:"
  log ""
  log "  $FSTAB_MARKER"
  log "  $(fstab_line)"
  log ""
  log "A malformed fstab entry can affect boot. $FSTAB will be backed up first."
  printf 'Type yes to continue: '
  read -r reply
  [ "$reply" = "yes" ] || die "aborted."
  local backup="${FSTAB}.$(date +%Y-%m-%d-%H%M%S).bak"
  $SUDO cp -a "$FSTAB" "$backup"
  log "backed up $FSTAB -> $backup"

  # Build the whole candidate file and validate that, rather than appending to
  # the real one and checking afterwards. Warning about a bad entry while
  # leaving it in place, and then reporting success, is how a machine ends up
  # not booting.
  #
  # An fstab whose last line has no newline would otherwise get the marker
  # appended onto the end of it, silently corrupting that entry. Add the
  # missing newline, and end our own block with one so a later edit starts on
  # a fresh line.
  local candidate entry_only
  candidate="$(mktemp)" || die "could not create a temporary file."
  entry_only="$(mktemp)" || die "could not create a temporary file."
  cat "$FSTAB" >"$candidate"
  if [ -s "$candidate" ] && [ -n "$(tail -c 1 "$candidate")" ]; then
    printf '\n' >>"$candidate"
  fi
  printf '%s\n%s\n' "$FSTAB_MARKER" "$(fstab_line)" >>"$candidate"

  # Verify the new entry on its own rather than the assembled file. findmnt
  # --verify reports on every line it is given, so an unrelated entry that
  # someone already has in their fstab would otherwise block this install and
  # read as though the generated line were at fault.
  printf '%s\n' "$(fstab_line)" >"$entry_only"
  if ! findmnt --verify --verbose --tab-file "$entry_only" >/dev/null 2>&1; then
    rm -f "$candidate" "$entry_only"
    die "the generated entry does not parse; $FSTAB is unchanged (backup at $backup). Check STORAGE_REMOTE and the mount options in .env."
  fi

  $SUDO cp "$candidate" "$FSTAB"
  rm -f "$candidate" "$entry_only"
  # Only the system fstab has a systemd generator behind it; reloading for
  # any other file would be a no-op that still stalls on polkit.
  [ "$FSTAB" = /etc/fstab ] && { $SUDO systemctl daemon-reload 2>/dev/null || true; }
  log "installed. The share will mount at boot, once the network is up."
}

cmd_uninstall_boot() {
  fstab_has_entry || {
    log "no entry found for $mountpoint_abs in $FSTAB"
    return 0
  }
  local backup="${FSTAB}.$(date +%Y-%m-%d-%H%M%S).bak"
  $SUDO cp -a "$FSTAB" "$backup"
  log "backed up $FSTAB -> $backup"
  # Removes this checkout's own entry, and the marker comment sitting directly
  # above it, leaving any other checkout's block untouched. The previous
  # `sed -i "\|^${FSTAB_MARKER}$|,+1d"` keyed on the shared marker, so with two
  # checkouts installed it deleted whichever block appeared first in the file
  # rather than the one belonging to the clone it was run from.
  local scrubbed
  scrubbed="$(mktemp)" || die "could not create a temporary file."
  awk -v mp="$mountpoint_abs" -v marker="$FSTAB_MARKER" -f /dev/stdin "$FSTAB" >"$scrubbed" <<'AWK'
$0 == marker { held = $0; next }
/^[[:space:]]*#/ { if (held != "") { print held; held = "" } print; next }
NF >= 2 && $2 == mp { held = ""; next }
{ if (held != "") { print held; held = "" } print }
END { if (held != "") print held }
AWK
  $SUDO cp "$scrubbed" "$FSTAB"
  rm -f "$scrubbed"
  # Only the system fstab has a systemd generator behind it; reloading for
  # any other file would be a no-op that still stalls on polkit.
  [ "$FSTAB" = /etc/fstab ] && { $SUDO systemctl daemon-reload 2>/dev/null || true; }
  log "removed."
}

case "${1:-}" in
mount) cmd_mount ;;
unmount) cmd_unmount ;;
status) cmd_status ;;
install-boot) cmd_install_boot ;;
uninstall-boot) cmd_uninstall_boot ;;
*) die "usage: $(basename "$0") {mount|unmount|status|install-boot|uninstall-boot}" ;;
esac
