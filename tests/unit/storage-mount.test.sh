#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for scripts/storage-mount.sh. Every line of the script has to run in
# one of them: `make coverage` runs this file under kcov and fails below 100%.
#
# The script reads .env from the repository it lives in, so it runs through a
# symlink in a scratch repository with its own .env, data/ and fstab (FSTAB).
# sudo, mount, umount, findmnt, df, podman and systemctl are stubs, and PATH
# holds nothing else but the handful of ordinary tools the script uses, so no
# share is mounted, no real fstab is read or written and no container is
# asked anything. The stubs read their answers from files under state/.

set -o errexit
set -o pipefail
set -o nounset

__script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/storage-mount.sh"
__bash="$(command -v bash)"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0
__repo="${__scratch}/repo"
__state="${__scratch}/state"
__bin="${__scratch}/bin"
__fstab="${__scratch}/fstab"

mkdir -p "${__bin}" "${__state}"
for tool in awk basename cat cp date dirname ln ls mkdir mktemp rm stat tail; do
  ln -s "$(command -v "${tool}")" "${__bin}/${tool}"
done

# Writes an executable stub. Stubs are pure bash, so they need nothing on PATH.
stub() {
  local name="${1}" body="${2}"
  printf '#!%s\nstate=%q\n%s\n' "${__bash}" "${__state}" "${body}" >"${__bin}/${name}"
  chmod +x "${__bin}/${name}"
}

stub sudo 'echo "sudo $*" >>"${state}/log"
exec "$@"'
stub mount 'echo "mount $*" >>"${state}/log"
[[ ! -f "${state}/mount-fails" ]]'
stub umount 'echo "umount $*" >>"${state}/log"
if [[ "${1}" == --lazy ]]; then [[ ! -f "${state}/lazy-fails" ]]; else [[ ! -f "${state}/umount-busy" ]]; fi'
stub systemctl 'echo "systemctl $*" >>"${state}/log"'
stub podman 'cat "${state}/podman-ps" 2>/dev/null || true'
stub df 'printf "Filesystem Size Used Avail Use%% Mounted\n//server/share 10T 4T 6T 40%% /data\n"'
# --verify fails on demand; --output prints the recorded options; any other
# query answers whether the share is in the mount table.
stub findmnt 'case " $* " in
*" --verify "*) [[ ! -f "${state}/verify-fails" ]] ;;
*" --output OPTIONS "*) cat "${state}/options" 2>/dev/null || true ;;
*" --output FSTYPE "*) echo cifs ;;
*) [[ -f "${state}/mounted" ]] ;;
esac'

# Resets the scratch repository and every stub answer. The arguments are .env
# lines; with none, .env holds a complete configuration.
fresh_repo() {
  rm -rf "${__repo}" "${__state:?}"/* "${__fstab}" "${__bin}/ln.fail" "${__bin}/mktemp.fail"
  mkdir -p "${__repo}/scripts" "${__repo}/configs/storage" "${__repo}/data"
  ln -s "${__script}" "${__repo}/scripts/storage-mount.sh"
  echo "username=someone" >"${__repo}/configs/storage/.smbcredentials"
  if [[ $# -gt 0 ]]; then
    printf '%s\n' "$@" >"${__repo}/.env"
  else
    cat >"${__repo}/.env" <<'EOF'
CONFIG_FOLDER=./configs
DATA_FOLDER=./data
STORAGE_REMOTE="//server/share"
STORAGE_MOUNTPOINT="${DATA_FOLDER}"
STORAGE_CREDENTIALS_FILE='${CONFIG_FOLDER}/storage/.smbcredentials'
STORAGE_CIFS_UID=1001
STORAGE_CIFS_EXTRA_OPTIONS=noperm
STORAGE_SELINUX_CONTEXT=system_u:object_r:container_file_t:s0
EOF
  fi
  printf 'UUID=1 / ext4 defaults 0 1' >"${__fstab}"
}

run() {
  __status=0
  PATH="${__bin}" FSTAB="${__fstab}" "${__bash}" "${__repo}/scripts/storage-mount.sh" "$@" \
    <"${__scratch}/stdin" >"${__scratch}/out" 2>"${__scratch}/err" || __status=$?
  touch "${__state}/log"
}

# check <name> <expected exit> <file> <text>: the run exited as expected and
# <text>, which may span lines, is in out, err, log (the stubs' calls) or fstab.
check() {
  local name="${1}" want_status="${2}" file="${3}" want="${4}" path
  case "${file}" in
  fstab) path="${__fstab}" ;;
  log) path="${__state}/log" ;;
  *) path="${__scratch}/${file}" ;;
  esac
  if [[ "${__status}" -ne "${want_status}" ]]; then
    echo "FAIL ${name}: exit ${__status}, wanted ${want_status}" >&2
    cat "${__scratch}/out" "${__scratch}/err" >&2
    __failures=$((__failures + 1))
  elif ! tr '\n' '|' <"${path}" | grep --quiet --fixed-strings -- "${want//$'\n'/|}"; then
    echo "FAIL ${name}: '${want}' not in ${file}" >&2
    cat "${path}" >&2
    __failures=$((__failures + 1))
  else
    echo "ok ${name}"
  fi
}

refute() {
  local name="${1}" file="${2}" unwanted="${3}"
  if grep --quiet --fixed-strings -- "${unwanted}" "${file}"; then
    echo "FAIL ${name}: '${unwanted}' found in ${file}" >&2
    __failures=$((__failures + 1))
  else
    echo "ok ${name}"
  fi
}

: >"${__scratch}/stdin"

# Arguments and configuration.
fresh_repo
run
check "rejects a missing subcommand" 1 err "usage: storage-mount.sh {mount|unmount|status"

fresh_repo
rm "${__repo}/.env"
run status
check "no .env means not configured" 0 out "state:      external storage not configured"
check "no .env falls back to ./data" 0 out "mountpoint: ${__repo}/data"

fresh_repo "STORAGE_REMOTE=" "STORAGE_MOUNTPOINT=./missing/data"
run status
check "refuses a mountpoint whose parent is missing" 1 err "./missing does not exist"

fresh_repo "STORAGE_MOUNTPOINT=../outside"
run status
check "refuses a mountpoint outside the repository" 1 err "refusing mountpoint outside the repository"

# status
fresh_repo
touch "${__state}/mounted"
echo "rw,serverino" >"${__state}/options"
printf '%s\n' "# docker-torrent-box-with-vpn external storage" "//server/share ${__repo}/data cifs opts 0 0" >"${__fstab}"
run status
check "status reports a mounted share" 0 out "state:      mounted"
check "status reports the filesystem type" 0 out "fstype:     cifs"
check "status reports the free space" 0 out "space:      4T used of 10T (6T free)"
check "status finds this checkout's fstab entry" 0 out "boot:       fstab entry installed"

fresh_repo
touch "${__state}/mounted"
rmdir "${__repo}/data"
printf '%s\n' "# docker-torrent-box-with-vpn external storage" "//server/share /elsewhere/data cifs opts 0 0" >"${__fstab}"
run status
check "status calls out a stale mount" 1 out "state:      STALE"
check "another checkout's entry is not this one's" 1 out "boot:       no fstab entry"

fresh_repo
run status
check "status reports an unmounted share" 1 out "state:      NOT MOUNTED"

# mount
fresh_repo "STORAGE_REMOTE="
run mount
check "mount needs STORAGE_REMOTE" 1 err "STORAGE_REMOTE is empty"

fresh_repo
rm "${__repo}/configs/storage/.smbcredentials"
run mount
check "mount needs the credentials file" 1 err "credentials file not found: ${__repo}/configs/storage/.smbcredentials"

fresh_repo
touch "${__state}/mounted"
run mount
check "mount leaves a mounted share alone" 0 out "already mounted: //server/share -> ${__repo}/data"

fresh_repo
touch "${__repo}/data/local-file"
run mount
check "mount refuses to cover existing data" 1 err "is not empty. Refusing to mount"

fresh_repo
echo "rw,noserverino" >"${__state}/options"
run mount
check "mount builds the options from .env" 0 log "sudo mount -t cifs -o credentials=${__repo}/configs/storage/.smbcredentials,uid=1001,gid=1000,vers=3.1.1,file_mode=0664,dir_mode=0775,noperm,context=system_u:object_r:container_file_t:s0 //server/share ${__repo}/data"
check "mount warns about noserverino" 0 out "WARNING: mounted with noserverino"
check "mount proves hardlinks work" 0 out "hardlinks: OK"
refute "the hardlink probe cleans up after itself" <(ls -A "${__repo}/data") ".storage-probe"

fresh_repo
touch "${__state}/mount-fails"
run mount
check "mount reports a failed mount" 1 err "mount failed."

fresh_repo
stub ln.fail 'exit 1'
mv "${__bin}/ln" "${__scratch}/ln.real"
mv "${__bin}/ln.fail" "${__bin}/ln"
run mount
mv "${__scratch}/ln.real" "${__bin}/ln"
check "mount warns when hardlinks fail" 0 out "WARNING: hardlink probe failed"

fresh_repo
stub mktemp.fail 'exit 1'
mv "${__bin}/mktemp" "${__scratch}/mktemp.real"
mv "${__bin}/mktemp.fail" "${__bin}/mktemp"
run mount
mv "${__scratch}/mktemp.real" "${__bin}/mktemp"
check "mount skips the probe it cannot create" 0 out "could not create a probe directory"

# unmount
fresh_repo
run unmount
check "unmount of an unmounted share is a no-op" 0 out "not mounted: ${__repo}/data"

fresh_repo
touch "${__state}/mounted"
echo "torrent-box-qbittorrent" >"${__state}/podman-ps"
run unmount
check "unmount refuses while the stack runs" 1 err "stack containers are running"

fresh_repo
touch "${__state}/mounted"
run unmount
check "unmount unmounts" 0 log "sudo umount ${__repo}/data"
check "unmount reports success" 0 out "unmounted."

fresh_repo
touch "${__state}/mounted" "${__state}/umount-busy"
run unmount
check "unmount retries a busy share lazily" 0 log "umount --lazy ${__repo}/data"

fresh_repo
touch "${__state}/mounted" "${__state}/umount-busy" "${__state}/lazy-fails"
run unmount
check "unmount reports a failed lazy unmount" 1 err "unmount failed."

fresh_repo
touch "${__state}/mounted"
rm "${__bin}/podman"
run unmount
check "unmount without podman proceeds" 0 out "unmounted."
stub podman 'cat "${state}/podman-ps" 2>/dev/null || true'

# install-boot
fresh_repo "STORAGE_REMOTE="
run install-boot
check "install-boot needs a configuration" 1 err "STORAGE_REMOTE is empty"

fresh_repo
printf '%s\n' "//server/share ${__repo}/data cifs opts 0 0" >"${__fstab}"
run install-boot
check "install-boot refuses a second entry" 1 err "already installed in ${__fstab}"

fresh_repo
echo no >"${__scratch}/stdin"
run install-boot
check "install-boot needs a yes" 1 err "aborted."
check "install-boot shows the entry first" 1 out "//server/share ${__repo}/data cifs credentials="

fresh_repo
echo yes >"${__scratch}/stdin"
touch "${__state}/verify-fails"
run install-boot
check "install-boot refuses an entry that does not parse" 1 err "the generated entry does not parse"
check "install-boot backs up first" 1 log "sudo cp -a ${__fstab} ${__fstab}."
refute "a rejected entry leaves fstab alone" "${__fstab}" "external storage"

fresh_repo
run install-boot
check "install-boot appends the entry" 0 out "installed. The share will mount at boot"
check "install-boot ends the last line before its block" 0 fstab "UUID=1 / ext4 defaults 0 1
# docker-torrent-box-with-vpn external storage"
check "install-boot writes the entry" 0 fstab ",_netdev,nofail 0 0"
refute "install-boot reloads systemd only for /etc/fstab" "${__state}/log" "systemctl"

# uninstall-boot
fresh_repo
run uninstall-boot
check "uninstall-boot without an entry is a no-op" 0 out "no entry found for ${__repo}/data"

fresh_repo
{
  echo "UUID=1 / ext4 defaults 0 1"
  echo "# docker-torrent-box-with-vpn external storage"
  echo "//other/share /elsewhere/data cifs opts 0 0"
  echo "# docker-torrent-box-with-vpn external storage"
  echo "//server/share ${__repo}/data cifs opts 0 0"
  echo "# docker-torrent-box-with-vpn external storage"
  echo "# a comment after a dangling marker"
  echo "# docker-torrent-box-with-vpn external storage"
} >"${__fstab}"
run uninstall-boot
check "uninstall-boot removes its entry" 0 out "removed."
check "uninstall-boot keeps another checkout's block" 0 fstab "# docker-torrent-box-with-vpn external storage
//other/share /elsewhere/data cifs opts 0 0"
check "uninstall-boot keeps a marker followed by a comment" 0 fstab "# docker-torrent-box-with-vpn external storage
# a comment after a dangling marker"
refute "uninstall-boot drops its own entry" "${__fstab}" "${__repo}/data"
if [[ "$(grep -c "external storage" "${__fstab}")" -ne 3 ]]; then
  echo "FAIL uninstall-boot dropped the wrong markers" >&2
  cat "${__fstab}" >&2
  __failures=$((__failures + 1))
fi

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
