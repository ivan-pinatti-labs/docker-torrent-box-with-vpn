#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
#
# Tests for scripts/rotate-certificate.sh. Every line of the script has to run
# in one of them: `make coverage` runs this file under kcov and fails below
# 100%.
#
# The script works from the directory above its own, so it runs here through
# a symlink in a scratch scripts/ directory, against a scratch certs/, .env
# and app configs. openssl, xmlstarlet and yq are stubs: openssl writes
# placeholder files instead of generating keys, xmlstarlet edits the one
# element the script asks for with sed, and yq only records its call. PATH
# holds nothing else but the text tools the script needs.

set -o errexit
set -o pipefail
set -o nounset

__script="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/rotate-certificate.sh"
__bash="$(command -v bash)"
__scratch="$(mktemp -d)"
trap 'rm -rf "${__scratch}"' EXIT
__failures=0
__apps="lidarr prowlarr radarr readarr sonarr whisparr"

stub() {
  local dir="${1}" name="${2}" body="${3}"
  printf '#!%s\n%s\n' "${__bash}" "${body}" >"${dir}/${name}"
  chmod +x "${dir}/${name}"
}

bin="${__scratch}/bin"
mkdir -p "${bin}"
for tool in dirname grep cut tr sed chmod; do
  ln -s "$(command -v "${tool}")" "${bin}/${tool}"
done
stub "${bin}" openssl "echo \"openssl \$*\" >>'${__scratch}/log'
case \"\${1}\" in
rand) echo 'NEW/pass+word=' ;;
req) echo key >certs/server.key; echo crt >certs/server.crt ;;
pkcs12) echo pfx >certs/server.pfx ;;
x509) echo 'sha256 Fingerprint=AA:BB' ;;
esac"
# `sel` succeeds only when the element exists. `ed` rewrites it, unless the
# file is named in `stuck`, which stands in for an edit that did not land.
stub "${bin}" xmlstarlet "echo \"xmlstarlet \$*\" >>'${__scratch}/log'
file=\"\${!#}\"
if [[ \"\${1}\" == sel ]]; then
  grep -q '<SslCertPassword>' \"\${file}\"
  exit
fi
element=\"\${5##*/}\"
value=\"\${7}\"
grep -qxF \"\${file}\" '${__scratch}/stuck' 2>/dev/null && exit 0
sed -i \"s|<\${element}>[^<]*<|<\${element}>\${value}<|\" \"\${file}\""
stub "${bin}" yq "echo \"yq \$* sslKey=\${sslKey}\" >>'${__scratch}/log'"

# A fresh scratch repository: Sonarr has SSL off (no element), every other
# app and Jellyfin hold the old password.
fresh_repo() {
  local repo="${__scratch}/repo"
  rm -rf "${repo}" "${__scratch}/log" "${__scratch}/stuck"
  mkdir -p "${repo}/scripts" "${repo}/certs"
  ln -s "${__script}" "${repo}/scripts/rotate-certificate.sh"
  printf '%s\n' CERT_COUNTRY=US CERT_STATE=NY CERT_CITY=NYC CERT_ORGANIZATION=Org \
    CERT_OU=Unit CERT_FQDN=box.example CERT_PASSWORD=previous >"${repo}/certs/cert.conf"
  printf '%s\n' UID=1000 JELLYFIN_PROXY_DOMAIN=jf.example LAN_IP=192.0.2.10 \
    GLUETUN_SERVICES_IP=172.16.0.2 GLUETUN_OBSERVABILITY_IP=172.17.0.2 >"${repo}/.env"
  for app in ${__apps}; do
    mkdir -p "${repo}/configs/${app}/config"
    if [[ "${app}" == sonarr ]]; then
      echo '<Config><Port>1</Port></Config>' >"${repo}/configs/${app}/config/config.xml"
    else
      echo '<Config><SslCertPassword>previous</SslCertPassword></Config>' \
        >"${repo}/configs/${app}/config/config.xml"
    fi
  done
  mkdir -p "${repo}/configs/jellyfin/config" "${repo}/configs/nzbhydra2/config"
  echo '<NetworkConfiguration><CertificatePassword>previous</CertificatePassword></NetworkConfiguration>' \
    >"${repo}/configs/jellyfin/config/network.xml"
  echo 'main: {}' >"${repo}/configs/nzbhydra2/config/nzbhydra.yml"
}

run() {
  __status=0
  (cd / && PATH="${bin}" "${__bash}" "${__scratch}/repo/scripts/rotate-certificate.sh") \
    >"${__scratch}/out" 2>"${__scratch}/err" || __status=$?
}

check() {
  local name="${1}" status="${2}" file="${3}" want="${4}"
  if [[ "${__status}" -ne "${status}" ]]; then
    echo "FAIL ${name}: exit ${__status}, wanted ${status}" >&2
    cat "${__scratch}/err" >&2
    __failures=$((__failures + 1))
  elif ! grep --quiet --fixed-strings -- "${want}" "${__scratch}/${file}"; then
    echo "FAIL ${name}: '${want}' not in ${file}" >&2
    cat "${__scratch}/${file}" >&2
    __failures=$((__failures + 1))
  else
    echo "ok ${name}"
  fi
}

fresh_repo
run
check "builds the subject from cert.conf" 0 log "-subj /C=US/ST=NY/L=NYC/O=Org/OU=Unit/CN=box.example"
check "adds every name and address from .env" 0 log "DNS:box.example, DNS:jf.example, DNS:localhost, IP:127.0.0.1, IP:192.0.2.10, IP:172.16.0.2, IP:172.17.0.2"
check "drops / + = from the new password" 0 log "pass:NEWpassword"
check "stores the new password in cert.conf" 0 repo/certs/cert.conf "CERT_PASSWORD=NEWpassword"
check "updates an app with SSL on" 0 repo/configs/radarr/config/config.xml "<SslCertPassword>NEWpassword<"
check "reports it" 0 out "[Radarr] OK"
check "skips an app with SSL off" 0 out "[Sonarr] skipped (SSL disabled, no SslCertPassword element)"
check "updates Jellyfin" 0 repo/configs/jellyfin/config/network.xml "<CertificatePassword>NEWpassword<"
check "updates NZBHydra2 through yq" 0 log "sslKey=NEWpassword"
check "masks the old password" 0 out "Old password: prev****"
check "masks the new password" 0 out "New password: NEWp****"
if [[ "$(stat -c %a "${__scratch}/repo/certs/server.key")" != 644 ]]; then
  echo "FAIL the key is not left world readable" >&2
  __failures=$((__failures + 1))
fi

fresh_repo
echo configs/prowlarr/config/config.xml >"${__scratch}/stuck"
run
check "fails when an app's password did not change" 1 err "[Prowlarr] ERROR: SslCertPassword did not update as expected"

fresh_repo
echo configs/jellyfin/config/network.xml >"${__scratch}/stuck"
run
check "fails when Jellyfin's password did not change" 1 err "ERROR: CertificatePassword did not update as expected"

if [[ "${__failures}" -gt 0 ]]; then
  echo "${__failures} failed" >&2
  exit 1
fi
