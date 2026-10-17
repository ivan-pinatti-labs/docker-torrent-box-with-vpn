#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
set -euo pipefail

# Rotate the self-signed certificate: regenerate server.key/server.crt/server.pfx
# with a new password, then sync that password into every consumer app.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
cd "$REPO_ROOT"

readonly CERT_CONF="certs/cert.conf"

# Read a KEY=value entry from a file without sourcing it (.env defines UID,
# which is a readonly bash builtin, so `source .env` fails). A file seeded
# before a key existed takes its .example's value for it, the default make
# applies. A key in neither is named before the script stops: a bare grep miss
# under pipefail used to end it silently.
env_value() {
  local key="$1" file
  for file in "$2" "$2.example"; do
    if grep -q "^${key}=" "$file" 2>/dev/null; then
      grep -m1 "^${key}=" "$file" | cut -d= -f2-
      return 0
    fi
  done
  echo "ERROR: ${key} is set in neither $2 nor $2.example." >&2
  return 1
}

CERT_COUNTRY="$(env_value CERT_COUNTRY "$CERT_CONF")"
CERT_STATE="$(env_value CERT_STATE "$CERT_CONF")"
CERT_CITY="$(env_value CERT_CITY "$CERT_CONF")"
CERT_ORGANIZATION="$(env_value CERT_ORGANIZATION "$CERT_CONF")"
CERT_OU="$(env_value CERT_OU "$CERT_CONF")"
CERT_FQDN="$(env_value CERT_FQDN "$CERT_CONF")"
CERT_PASSWORD="$(env_value CERT_PASSWORD "$CERT_CONF")"
JELLYFIN_PROXY_DOMAIN="$(env_value JELLYFIN_PROXY_DOMAIN .env)"
LAN_IP="$(env_value LAN_IP .env)"
GLUETUN_SERVICES_IP="$(env_value GLUETUN_SERVICES_IP .env)"
GLUETUN_OBSERVABILITY_IP="$(env_value GLUETUN_OBSERVABILITY_IP .env)"

readonly OLD_CERT_PASSWORD="$CERT_PASSWORD"
NEW_CERT_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=')"
readonly NEW_CERT_PASSWORD

mask() {
  local val="$1"
  echo "${val:0:4}****"
}

echo "======================================================================"
echo " Regenerating certificate..."
echo "======================================================================"

openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 \
  -subj "/C=${CERT_COUNTRY}/ST=${CERT_STATE}/L=${CERT_CITY}/O=${CERT_ORGANIZATION}/OU=${CERT_OU}/CN=${CERT_FQDN}" \
  -addext "subjectAltName = DNS:${CERT_FQDN}, DNS:${JELLYFIN_PROXY_DOMAIN}, DNS:localhost, IP:127.0.0.1, IP:${LAN_IP}, IP:${GLUETUN_SERVICES_IP}, IP:${GLUETUN_OBSERVABILITY_IP}" \
  -keyout certs/server.key -out certs/server.crt

openssl pkcs12 -export -out certs/server.pfx -inkey certs/server.key -in certs/server.crt \
  -password "pass:${NEW_CERT_PASSWORD}"

# The certificate files are read by many services running as distinct
# non-root container UIDs (nginx, qBittorrent, SABnzbd, Grafana, the arr
# apps, Jellyfin), so under rootless Podman they must stay world-readable.
# The host repo directory restricts outside access; the pfx additionally
# protects its private key with the PKCS#12 password.
chmod 644 certs/server.key certs/server.crt certs/server.pfx

echo "Hash for the new certificate is..."
openssl x509 -noout -fingerprint -sha256 -inform pem -in certs/server.crt

sed -i "s|^CERT_PASSWORD=.*|CERT_PASSWORD=${NEW_CERT_PASSWORD}|" "$CERT_CONF"

echo ""
echo "======================================================================"
echo " Syncing new password into app configs..."
echo "======================================================================"

# Args: app_name xml_path
update_xml_ssl_password() {
  local app_name="$1"
  local xml_path="$2"
  if ! xmlstarlet sel -t -v '/Config/SslCertPassword' "$xml_path" >/dev/null 2>&1; then
    echo "[$app_name] skipped (SSL disabled, no SslCertPassword element)"
    return 0
  fi
  xmlstarlet --quiet ed --inplace --update '/Config/SslCertPassword' \
    --value "$NEW_CERT_PASSWORD" "$xml_path" # pragma: allowlist secret
  local written
  written=$(grep -oPm1 '(?<=<SslCertPassword>)[^<]+' "$xml_path")
  if [[ "$written" != "$NEW_CERT_PASSWORD" ]]; then
    echo "[$app_name] ERROR: SslCertPassword did not update as expected in $xml_path" >&2
    return 1
  fi
  echo "[$app_name] OK"
}

update_xml_ssl_password "Lidarr" "configs/lidarr/config/config.xml"
update_xml_ssl_password "Prowlarr" "configs/prowlarr/config/config.xml"
update_xml_ssl_password "Radarr" "configs/radarr/config/config.xml"
update_xml_ssl_password "Readarr" "configs/readarr/config/config.xml"
update_xml_ssl_password "Sonarr" "configs/sonarr/config/config.xml"
update_xml_ssl_password "Whisparr" "configs/whisparr/config/config.xml"

echo -n "[Jellyfin] "
xmlstarlet --quiet ed --inplace --update '/NetworkConfiguration/CertificatePassword' \
  --value "$NEW_CERT_PASSWORD" "configs/jellyfin/config/network.xml" # pragma: allowlist secret
jellyfin_written=$(grep -oPm1 '(?<=<CertificatePassword>)[^<]+' "configs/jellyfin/config/network.xml")
if [[ "$jellyfin_written" != "$NEW_CERT_PASSWORD" ]]; then
  echo "ERROR: CertificatePassword did not update as expected in configs/jellyfin/config/network.xml" >&2
  exit 1
fi
echo "OK"

echo -n "[NZBHydra2] "
sslKey="$NEW_CERT_PASSWORD" yq -i '(.main.sslKeyStorePassword) = strenv(sslKey)' \
  "configs/nzbhydra2/config/nzbhydra.yml"
echo "OK"

echo ""
echo "======================================================================"
echo " Certificate rotation complete."
echo "======================================================================"
echo "Old password: $(mask "$OLD_CERT_PASSWORD")  (shown as: first4****)"
echo "New password: $(mask "$NEW_CERT_PASSWORD")  (full value stored in ${CERT_CONF})"
echo ""
echo "Restart every app that uses the certificate for the new password to take effect"
echo "(the first line exports the image pins, see docs/MAKE_COMMANDS.md, \"Image versions\"):"
echo "  set -a; . <(grep -hE '^[A-Z0-9_]+_VERSION=' versions.env .env); set +a"
echo "  podman-compose --file docker-compose.yml --profile enabled up -d --force-recreate \\"
echo "    lidarr prowlarr radarr readarr sonarr whisparr jellyfin nzbhydra2 nginx"
