# Gluetun VPN Providers

This stack uses exactly one VPN implementation: Gluetun. Do not add provider-specific VPN
containers. Change providers by editing `configs/gluetun/.env` and, when needed, files under
`configs/gluetun/`.

For BitTorrent, prefer providers with server-side port forwarding. Without an inbound
forwarded port, qBittorrent can still download, but peer connectivity and seeding are
degraded.

## Proton Partnership

I am partnered with Proton VPN. If you choose Proton for this stack and want to
support the project, please consider using my partner link or code:

- Proton partner link: <https://go.getproton.me/SH2aV>

This is optional. The stack is provider-neutral at the Gluetun layer, and the
provider notes below are based on technical fit for torrenting, especially
WireGuard support and server-side port forwarding.

## Recommended Providers

| Provider                | Gluetun support                               | Torrent suitability      | Port forwarding model                                                          |
| ----------------------- | --------------------------------------------- | ------------------------ | ------------------------------------------------------------------------------ |
| Proton VPN              | Native OpenVPN and WireGuard                  | Recommended              | Gluetun can request and refresh a random forwarded port                        |
| AirVPN                  | Native OpenVPN and WireGuard                  | Recommended              | Manually reserve a port in AirVPN and allow it with `FIREWALL_VPN_INPUT_PORTS` |
| Private Internet Access | Native OpenVPN, WireGuard via custom provider | Recommended with caveats | Gluetun has a native port-forwarding integration                               |
| TorGuard                | Native OpenVPN, WireGuard via custom provider | Recommended              | Provider-managed/manual port forwarding                                        |

NordVPN is intentionally not a first-class torrent provider here. Gluetun can connect to
NordVPN, but NordVPN does not provide port forwarding, so it is a poor fit for qBittorrent.

## Getting your Proton VPN WireGuard key

`make bootstrap` checks `configs/gluetun/.secret` before doing anything else.
If it's still missing or the example placeholder and you're running it in a
real terminal, it asks which provider you're using. For Proton VPN it walks
you through both this key (input shows `*` per character instead of the key
itself) and the server country next (suggesting a different country each run
rather than always the same one) in one go, and writes both into
`configs/gluetun/.env` for you. In a non-interactive run (CI, a scripted
invocation) it always stops with instructions, since there's nowhere to
prompt.

To get the key ahead of time, or if you'd rather write the file yourself:

1. Log in at <https://account.proton.me> → VPN → Downloads → WireGuard configuration.
2. Enter a name, select your desired features (NetShield, VPN Accelerator), and click Create.
3. The generated config will look like:

   ```ini
   [Interface]
   # Key for <name>
   PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
   Address = 10.2.0.2/32
   DNS = 10.2.0.1

   [Peer]
   # SE#302
   PublicKey = ...
   AllowedIPs = 0.0.0.0/0
   Endpoint = 203.0.113.1:51820
   ```

4. Paste only the `PrivateKey` value (single line, no prefix) into
   `configs/gluetun/.secret`:

   ```shell
   echo "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" > configs/gluetun/.secret  # pragma: allowlist secret
   ```

This file is bind-mounted into Gluetun and excluded from git by
`configs/gluetun/.gitignore`. Never commit it.

## Proton VPN WireGuard Default

Once bootstrap has filled in `configs/gluetun/.env` for Proton (or you write it
yourself), it looks like this. Edit it directly later if you want to change
country, server, or port forwarding settings:

```dotenv
VPN_SERVICE_PROVIDER=protonvpn
VPN_TYPE=wireguard
WIREGUARD_IMPLEMENTATION=kernelspace
WIREGUARD_PRIVATE_KEY_SECRETFILE=/gluetun/.secret
SERVER_COUNTRIES=Netherlands
PORT_FORWARD_ONLY=on
VPN_PORT_FORWARDING=on
VPN_PORT_FORWARDING_PROVIDER=protonvpn
HTTP_CONTROL_SERVER_ADDRESS=:8000
HTTPPROXY=on
HTTPPROXY_LISTENING_ADDRESS=:8888
HTTPPROXY_STEALTH=on
HTTPPROXY_LOG=off
```

`HTTPPROXY*` powers the internal HTTP proxy Prowlarr can route tagged
indexers through; see
[docs/NETWORKING.md](NETWORKING.md#routing-selected-prowlarr-indexers-through-the-vpn).

qBittorrent follows the forwarded port on its own: `docker-compose-vpn.yml` sets
gluetun's `VPN_PORT_FORWARDING_UP_COMMAND` to `scripts/qbittorrent-port-forward.sh`, which
logs in to qBittorrent with its compose secrets and sets the listen port whenever Proton
changes it, no manual steps required. The compose value overrides an older command still
in `configs/gluetun/.env`. The script's lines start with `[PORTFWD]` in gluetun's log.
If upgrading from the old dedicated ProtonVPN container, do not delete the old
values until they are migrated. Copy the legacy Proton WireGuard private key or
old `PROTONVPN_KEY` value into `configs/gluetun/.secret`. Move the old
`PROTONVPN_SERVER` / `PROTONVPN_COUNTRY_AND_SERVER` selection into a Gluetun
server filter such as `SERVER_COUNTRIES`, `SERVER_HOSTNAMES`, or `SERVER_NAMES`
in `configs/gluetun/.env`.

**VPN status endpoints (read-only, via Nginx):**

| Endpoint                                   | Description                 |
| ------------------------------------------ | --------------------------- |
| `https://localhost/gluetun/v1/vpn/status`  | VPN connection state        |
| `https://localhost/gluetun/v1/portforward` | Current forwarded port      |
| `https://localhost/gluetun/v1/publicip/ip` | Exit IP address and country |

## AirVPN

Generate WireGuard credentials and reserve a forwarded port in the AirVPN client area:

```dotenv
VPN_SERVICE_PROVIDER=airvpn
VPN_TYPE=wireguard
WIREGUARD_IMPLEMENTATION=kernelspace
WIREGUARD_PRIVATE_KEY_SECRETFILE=/gluetun/.secret
WIREGUARD_PRESHARED_KEY=<airvpn-preshared-key>
WIREGUARD_ADDRESSES=<airvpn-address>/32
SERVER_COUNTRIES=Netherlands
VPN_PORT_FORWARDING=off
FIREWALL_VPN_INPUT_PORTS=<reserved-airvpn-port>
```

Set qBittorrent's listen port to the same reserved AirVPN port. AirVPN does not use the
Proton-style random port update command.

## Private Internet Access

PIA OpenVPN is the simplest supported path:

```dotenv
VPN_SERVICE_PROVIDER=private internet access
VPN_TYPE=openvpn
OPENVPN_USER=<pia-service-username>
OPENVPN_PASSWORD=<pia-service-password>
SERVER_REGIONS=Netherlands
PORT_FORWARD_ONLY=true
VPN_PORT_FORWARDING=on
VPN_PORT_FORWARDING_PROVIDER=private internet access
VPN_PORT_FORWARDING_USERNAME=<pia-service-username>
VPN_PORT_FORWARDING_PASSWORD=<pia-service-password>
HTTP_CONTROL_SERVER_ADDRESS=:8000
```

Keep the qBittorrent port update command enabled. Gluetun's PIA docs note provider-side
caveats with forwarded ports, so verify with an external torrent port checker after
deployment.

## TorGuard

TorGuard OpenVPN is native in Gluetun:

```dotenv
VPN_SERVICE_PROVIDER=torguard
VPN_TYPE=openvpn
OPENVPN_USER=<torguard-username>
OPENVPN_PASSWORD=<torguard-password>
SERVER_COUNTRIES=Netherlands
VPN_PORT_FORWARDING=off
FIREWALL_VPN_INPUT_PORTS=<torguard-forwarded-port>
```

Request the forwarded port in TorGuard's member area and set qBittorrent's listen port to
that same value. For TorGuard WireGuard, use Gluetun's `custom` provider with a generated
WireGuard config.

## References

- Gluetun supported providers: <https://github.com/qdm12/gluetun#features>
- Proton VPN provider docs: <https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/protonvpn.md>
- AirVPN provider docs: <https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/airvpn.md>
- PIA provider docs: <https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/private-internet-access.md>
- TorGuard provider docs: <https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/torguard.md>
- Servarr VPN guidance: <https://wiki.servarr.com/vpn>

---

See also: [README.md](../README.md), [docs/MAKE_COMMANDS.md](MAKE_COMMANDS.md)
