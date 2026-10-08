# Network Architecture

This document is the canonical description of how containers, networks, and traffic flow
through the stack. If this file disagrees with a compose file, the compose file is wrong.

## 1. Purpose and constraints

The stack keeps qBittorrent behind a single VPN exit, while Servarr, observability, and
media services run on normal container networks by default.

Hard constraints that shape the design:

1. **One VPN gateway.** The stack uses exactly one `gluetun` instance.
2. **qBittorrent traffic must egress via VPN.** Servarr apps are direct by default;
   individual services can opt into VPN routing with route override files.
3. **The qBittorrent killswitch must be structural**, not firewall based. qBittorrent peer
   and tracker traffic is raw TCP/UDP and cannot be funnelled through an HTTP or SOCKS
   proxy, and iptables only killswitches are fragile across container restarts.
4. **Jellyfin is dual access.** It must be reachable both directly on the LAN (ports 8096
   and 8920), and through nginx at `/jellyfin/`.
5. **Grafana and Prometheus UIs are reverse proxied only.** No direct host ports.

Given constraint 1, every service that must exit through the VPN shares gluetun's network
namespace via `network_mode: container:${VPN_PROVIDER}`. Compose forbids combining that
setting with `networks:`, so VPN route override files use `networks: !reset []`.

## 2. ASCII network diagram

```text
                 ┌───────────────────────────────────────────────────────┐
                 │  HOST LAN                                              │
                 │  published ports:                                      │
                 │    80/tcp   → nginx (redirect to 443)                  │
                 │    443/tcp  → nginx                                    │
                 │    8096/tcp → jellyfin (direct HTTP)                   │
                 │    8920/tcp → jellyfin (direct HTTPS)                  │
                 └──┬──────────────────────────────────────┬──────────────┘
                    │                                      │
           ┌────────▼──────────┐                  ┌────────▼──────────┐
           │ edge (bridge)     │                  │ media (bridge)    │
           │                   │                  │                   │
           │  nginx            │                  │  jellyfin ◄───┐   │
           │                   │                  │  nginx ───────┘   │
           └──┬──────┬─────────┘                  └─────────▲─────────┘
              │      │                                      │
              │      │      (nginx is multi homed across edge,
              │      │       services, observability, media)
              │      │                                      │
   ┌──────────▼──┐   │   ┌────────────────────────┐         │
   │ services    │   │   │ observability          │         │
   │ (bridge,    │   │   │ (bridge, internal)     │         │
   │  internal)  │   │   │                        │         │
   │             │   │   │  nginx ◄──────┐        │         │
   │  nginx      │   │   │  prometheus ──┤        │         │
   │  gluetun    │   └───┼─►grafana ◄────┤        │         │
   │   (eth0)    │       │  alloy        │        │         │
   │             │       │  node_exp     │        │         │
   │             │       │  podman_exp   │        │         │
   │             │       │  gluetun ─────┘        │         │
   │             │       │   (eth1)               │         │
   └──────┬──────┘       └──────────┬─────────────┘         │
          │                         │                       │
          └───────────┬─────────────┘                       │
                      │                                     │
             ┌────────▼───────────────────────────────┐     │
             │ gluetun (container)                    │     │
             │ cap_add: NET_ADMIN, NET_RAW            │     │
             │                                        │     │
             │   NICs:                                │     │
             │     • eth0 → wan bridge (bootstrap)    │     │
             │     • eth1 → services bridge           │     │
             │     • eth2 → observability bridge      │     │
             │     • wg0  → VPN provider tunnel       │     │
             │                                        │     │
             │   FIREWALL_OUTBOUND_SUBNETS allows     │     │
             │   172.16/12, 10/8, 192.168/16 so       │     │
             │   east west traffic to nginx and       │     │
             │   prometheus works without going       │     │
             │   through wg0. Internet egress is      │     │
             │   wg0 only. If gluetun dies, the       │     │
             │   namespace dies, and VPN routed       │     │
             │   lose network. STRUCTURAL KILLSWITCH. │     │
             │                                        │     │
             │ ┌────────────────────────────────────┐ │     │
             │ │ VPN routed services                │ │     │
             │ │ (network_mode: container:gluetun)  │ │     │
             │ │                                    │ │     │
             │ │  TORRENT                           │ │     │
             │ │    qbittorrent        :8085 https  │ │     │
             │ │    qbittorrent_exp    :17871       │ │     │
             │ │                                    │ │     │
             │ │  NZB                               │ │     │
             │ │    sabnzbd            :8087 https  │ │     │
             │ │    sabnzbd_exporter   :9387        │ │     │
             │ │                                    │ │     │
             │ │  SERVARR                           │ │     │
             │ │    sonarr      :8989  radarr :7878 │ │     │
             │ │    lidarr      :8686  readarr:8787 │ │     │
             │ │    bazarr      :6767  prowlarr:9696│ │     │
             │ │    recyclarr   (no port)           │ │     │
             │ │    flaresolverr :8191              │ │     │
             │ └────────────────────────────────────┘ │     │
             └────────────────────────────────────────┘     │
                                                            │
                     (jellyfin stays isolated from VPN, ───┘
                      LAN streaming, no VPN requirement)
```

Reading the diagram: qBittorrent and any opted-in VPN-routed service listen inside gluetun's
namespace, so their web ports are reachable on gluetun's `services` bridge IP. Direct
Servarr services live on `apps` for normal egress and on `services` for internal app-to-app
traffic. Nothing private is reachable from the LAN directly; browser traffic lands on
nginx, while app-to-app traffic uses service DNS on `services`.

## 3. Network inventory

| Network         | Driver | Internal | Members                                                                                                                                                                              | Role                                                                                                       |
| --------------- | ------ | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| `edge`          | bridge | no       | nginx                                                                                                                                                                                | Publishes host ports 80 and 443                                                                            |
| `wan`           | bridge | no       | gluetun                                                                                                                                                                              | Bootstrap route: gives gluetun internet access to reach the VPN provider endpoint and establish the tunnel |
| `apps`          | bridge | no       | nginx, grafana, homepage, calibre, calibre-web, nzbhydra2, direct Servarr apps                                                                                                       | Normal app egress and reverse proxy reachability                                                           |
| `services`      | bridge | yes      | nginx, gluetun, homepage, calibre, calibre-web, nzbhydra2, qbittorrent_exporter, sabnzbd_exporter, direct Servarr apps                                                               | Internal app-to-app traffic and access to qBittorrent through gluetun's bridge IP                          |
| `observability` | bridge | yes      | nginx, gluetun, homepage, prometheus, loki, grafana, alloy, cadvisor, node_exporter, podman_exporter, podman_limits_exporter, nginx_exporter, qbittorrent_exporter, sabnzbd_exporter | Metric scraping, plus grafana and prometheus reachability from nginx                                       |
| `media`         | bridge | no       | nginx, homepage, jellyfin, audiobookshelf, calibre, calibre-web, korsync                                                                                                             | Jellyfin reverse proxy from nginx (LAN also talks to jellyfin direct)                                      |

`services` and `observability` are `internal: true`. Docker does not install a default
route on those bridges, so gluetun's bridge NICs on them cannot send traffic to the
internet. Any clear net egress attempt from gluetun's `services` or `observability` NIC
fails at the Docker layer before reaching gluetun's own firewall. Defense in depth.

The `wan` bridge is non-internal by necessity: gluetun must reach the VPN provider endpoint
to bring up the tunnel. Once the tunnel is up, all outbound traffic from VPN-routed
namespace sharers routes through it, not through `wan`. Gluetun's own firewall
(`FIREWALL_OUTBOUND_SUBNETS`) restricts clear-net egress on the `wan` NIC to the VPN server
handshake only.

## 4. Service placement

| Service                                                                                                        | Placement                                                            | Reason                                                                                                                        |
| -------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| **gluetun**                                                                                                    | `networks: [wan, services, observability]` plus wg0 tunnel           | Gateway. Owns VPN egress, bridges east west traffic to nginx and prometheus.                                                  |
| **nginx**                                                                                                      | `networks: [edge, apps, services, observability, media]`             | Sole web entry. Multi homed so it can reach every upstream. No VPN coupling.                                                  |
| **qbittorrent**                                                                                                | `network_mode: container:${VPN_PROVIDER}`                            | Peer and tracker traffic must go through wg0. Killswitch mandatory.                                                           |
| **qbittorrent_exporter**                                                                                       | `networks: [observability, services]`                                | Scrapes qBittorrent through gluetun's services IP; does not share the VPN namespace.                                          |
| **sabnzbd**                                                                                                    | `network_mode: container:${VPN_PROVIDER}`                            | Usenet traffic must go through wg0. Killswitch mandatory.                                                                     |
| **sabnzbd_exporter**                                                                                           | `networks: [observability, services]`                                | Scrapes SABnzbd through gluetun's services IP and exposes metrics internally.                                                 |
| **nzbget**                                                                                                     | `network_mode: container:${VPN_PROVIDER}` when enabled               | Optional legacy usenet route.                                                                                                 |
| **jdownloader2**                                                                                               | `network_mode: container:${VPN_PROVIDER}`                            | Download traffic must go through wg0, same killswitch as qBittorrent and SABnzbd.                                             |
| **sonarr, radarr, lidarr, readarr, bazarr, prowlarr, recyclarr, flaresolverr, whisparr, lazylibrarian, mylar** | `networks: [apps, services]` by default                              | Direct app traffic, while still reaching qBittorrent through gluetun's services IP.                                           |
| **servarr VPN route overrides**                                                                                | `network_mode: container:${VPN_PROVIDER}` plus `networks: !reset []` | Per-service opt-in VPN routing without duplicating service definitions. Route files also add service-name aliases to gluetun. |
| **nzbhydra2**                                                                                                  | `networks: [apps, services]`                                         | Indexer meta search, direct egress by default.                                                                                |
| **homepage**                                                                                                   | `networks: [apps, services, media, observability]`                   | Dashboard needs reachability to services across every network it links to.                                                    |
| **calibre, calibre-web**                                                                                       | `networks: [media, apps, services]`                                  | Reachable from Jellyfin's `media` bridge and from Readarr/LazyLibrarian on `apps`/`services`.                                 |
| **korsync, audiobookshelf**                                                                                    | `networks: [media]`                                                  | Media-adjacent services with no VPN or Servarr coupling.                                                                      |
| **prometheus, grafana, loki, alloy**                                                                           | `networks: [observability]` (grafana also `apps`)                    | Internal only; grafana additionally sits on `apps` for direct reachability from nginx.                                        |
| **cadvisor, node_exporter, podman_exporter, podman_limits_exporter, nginx_exporter**                           | `networks: [observability]`                                          | Metrics sources, internal only.                                                                                               |
| **log_rotator**                                                                                                | no `networks:` key (default project network)                         | Local file rotation only; no service reachability needed.                                                                     |
| **jellyfin**                                                                                                   | `networks: [media]` plus `ports: [8096, 8920]`                       | Media streaming on LAN. Direct access preserves client UX.                                                                    |

## 5. Traffic flows

The hop sequence for every user facing path:

| Path                                              | Hops                                                                                                                                                                             |
| ------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Browser to servarr UI (e.g. `/sonarr/`)           | LAN → host:443 → nginx (edge) → nginx (apps) → `sonarr-http:8989` by default; VPN route overrides make that protocol-specific alias resolve to gluetun on the `services` bridge. |
| Browser to qbittorrent UI (`/qbittorrent/`)       | LAN → host:443 → nginx (edge) → nginx (services) → gluetun services IP:8085 → qbittorrent                                                                                        |
| Browser to grafana (`/admin/grafana/`)            | LAN → host:443 → nginx (edge) → nginx (observability) → grafana:3000                                                                                                             |
| Browser to prometheus (`/admin/prometheus/`)      | LAN → host:443 → nginx (edge) → nginx (observability) → prometheus:9090                                                                                                          |
| Browser to jellyfin via proxy (`/jellyfin/`)      | LAN → host:443 → nginx (edge) → nginx (media) → jellyfin:8096                                                                                                                    |
| LAN client to jellyfin direct                     | LAN → host:8096 or host:8920 → jellyfin (no nginx, no VPN)                                                                                                                       |
| Browser to gluetun control API (`/gluetun/…`)     | LAN → host:443 → nginx (edge) → nginx (services) → gluetun services IP:8000 → gluetun control server                                                                             |
| Prometheus scrape to qbittorrent_exporter         | prometheus → gluetun observability IP:17871 → exporter in gluetun namespace                                                                                                      |
| Prometheus scrape to node_exporter                | prometheus → gluetun observability IP:9100 → node_exporter in gluetun namespace                                                                                                  |
| Sonarr to qBittorrent API (download client)       | sonarr → services bridge → gluetun services IP `172.28.0.10:8085`                                                                                                                |
| Sonarr/Radarr/Lidarr/Readarr/Whisparr to Prowlarr | app → services bridge → `http://prowlarr:9696/prowlarr/...`; if Prowlarr is VPN-routed, `prowlarr` resolves to gluetun by route alias.                                           |
| Prowlarr to Arr apps                              | prowlarr → services bridge → `http://sonarr:8989/sonarr`, `http://radarr:7878/radarr`, etc.; VPN-routed apps keep the same DNS name by route alias.                              |
| Prowlarr tagged indexer to internet               | prowlarr → services bridge → `gluetun:8888` HTTP proxy → VPN tunnel → provider exit → internet                                                                                   |
| qBittorrent to tracker or peer                    | qbittorrent → VPN tunnel → provider exit → internet                                                                                                                              |
| Any VPN namespaced service to internet            | → VPN tunnel → provider exit → internet (only route out, blocked if VPN is down)                                                                                                 |

Note on east west traffic: active Arr download-client configs use `172.28.0.10:8085`, not
`127.0.0.1`, so they keep working when Arr services run outside Gluetun. Arr/Prowlarr/
Recyclarr links use direct service DNS, not nginx, so they work the same whether either
side is direct or VPN-routed.

## 6. Killswitch

### How it works

The qBittorrent killswitch is structural, not a firewall rule. qBittorrent uses
`network_mode: container:${VPN_PROVIDER}`, which means its network namespace **is**
gluetun's network namespace. It does not have an independent network stack. If the gluetun
container dies, the namespace is destroyed by the kernel, and qBittorrent loses all network
connectivity the same instant. There is no window in which torrent traffic could leak.

Gluetun additionally runs with `cap_add: [NET_ADMIN, NET_RAW]` and maintains its own
iptables policy: default DROP on `wg0` input, default DROP on clear net egress, ACCEPT only
on the configured `FIREWALL_OUTBOUND_SUBNETS` (Docker private ranges), and on the forwarded
peer port when port forwarding is enabled.

### Failure modes covered

- **gluetun container crashes.** Namespace gone, qBittorrent instantly offline. Covered.
- **VPN tunnel drops** (VPN reconnect, server failure). Gluetun's firewall blocks
  qBittorrent clear net egress until the tunnel is back. Covered.
- **Host restarts.** Compose brings gluetun up first for VPN-routed services with
  healthcheck dependencies. Covered.

### Failure modes not covered

- **Container escape** (kernel exploit, privilege escalation). Out of scope for a network layer killswitch.
- **Host compromise.** Ditto.
- **LAN adversary** who can route to gluetun's `services` bridge IP. Mitigated by
  `internal: true` on the bridge and by application auth, but the bridge is not a privacy
  boundary, LAN is trusted by design.

## 7. Binding to `0.0.0.0` inside gluetun's namespace

**Q: if qbittorrent, sabnzbd, jdownloader2, servarr, or legacy nzbget bind `0.0.0.0`, do
their web UIs become reachable from the public internet via gluetun's wg0 interface?**

**A: no, because of two independent layers of protection.**

| Path                                                            | Default behavior                                                                                                                        |
| --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| Random internet to gluetun's VPN exit IP, arbitrary port        | Blocked by the provider's network policy where applicable and by gluetun's default DROP input policy on the VPN interface.              |
| Internet to gluetun's VPN exit IP, the port forwarded peer port | Allowed by design: gluetun auto opens the PF port so qbittorrent can accept peer connections. This is the only internet reachable port. |
| LAN to gluetun's `services` bridge IP, any port                 | Reachable from containers on the `services` bridge. `services` is `internal: true`, so no NAT to the internet.                          |
| LAN to gluetun's `observability` bridge IP, any port            | Same as above, `observability` is `internal: true`.                                                                                     |

### Hardening applied

qBittorrent binds its WebUI to gluetun's `services` bridge IP (`172.28.0.10`). The subnets
for `services` (`172.28.0.0/24`) and `observability` (`172.29.0.0/24`) are declared in
`docker-compose.yml` under `ipam.config`, so gluetun always receives the same IPs on both
bridges regardless of the host. This makes the config portable without relying on Docker
auto-assigned ranges.

Declaring a subnet only fixes the address for containers that request it explicitly
(`ipv4_address:` in compose); it does not by itself protect that address from being handed
to some other container that has no static IP of its own. Docker/Podman's default dynamic
allocator has no notion of "reserved" addresses, only "already taken" ones, so a container
without a static IP can be assigned a low, seemingly-reserved address before its intended
owner ever claims it. `services`, `media` and `apps` each carve out an explicit `ip_range`
for dynamic allocation (`SERVICES_DYNAMIC_IP_RANGE`, `MEDIA_DYNAMIC_IP_RANGE`,
`APPS_DYNAMIC_IP_RANGE` in `.env`) that excludes their static addresses, so this can't
happen. Confirmed live, twice, before
`SERVICES_DYNAMIC_IP_RANGE` existed: a container with no static IP of its own was
dynamically handed `vpn_mock`'s reserved address on the `services` network, leaving gluetun
dialing an endpoint nothing was listening on. See `docs/VPN_MOCK.md`.

Exceptions that legitimately bind `0.0.0.0`:

- **flaresolverr** has no supported bind-address knob.
- **jdownloader2** (jlesage web GUI) has no supported bind-address knob either, same as
  flaresolverr.
- **qbittorrent peer listener** must accept inbound on `wg0` for port-forwarded peer
  connections (this is the one intentionally internet facing port).

**Gluetun firewall policy** (set in `configs/gluetun/.env`):

```env
FIREWALL_VPN_INPUT_PORTS=          # empty: no VPN side ingress beyond PF
FIREWALL_INPUT_PORTS=              # empty: no bridge side policy override
FIREWALL_OUTBOUND_SUBNETS=172.16.0.0/12,10.89.0.0/16,192.168.0.0/16
```

**Gluetun HTTP proxy.** `HTTPPROXY=on` exposes an internal HTTP proxy on
`gluetun:8888` for Prowlarr indexer proxy rules. The port is not published to
the host; it is only reachable from containers on the internal `services`
network. Prowlarr should use this proxy only through a matching indexer tag such
as `vpn`, so normal indexers keep direct egress.

**`internal: true` on both Docker bridges.** Even if gluetun's iptables were mis configured,
Docker would not install a default route on these bridges, so gluetun's bridge NICs cannot
send traffic to the internet through them.

**Reverse proxy trust.** Every app behind nginx that reads forwarded headers trusts them
from nginx's own address and from nothing else, so no other container on a shared bridge
can claim to be the browser:

| App                                                 | Trusts                               | Set by                                                                   |
| --------------------------------------------------- | ------------------------------------ | ------------------------------------------------------------------------ |
| Sonarr, Radarr, Lidarr, Prowlarr, Readarr, Whisparr | `NGINX_APPS_IP`, `NGINX_SERVICES_IP` | `<APP>__SERVER__TRUSTEDNETWORKS` in `docker-compose-servarr.yml`         |
| qBittorrent                                         | `NGINX_SERVICES_IP`                  | `scripts/wire-connections.sh`, through its API (`make wire_connections`) |
| Jellyfin                                            | `NGINX_MEDIA_IP`                     | `KnownProxies`, `make configure_jellyfin_network`                        |

nginx holds a fixed address on each of those networks (`docker-compose-proxy.yml`), which
is why `apps` has a subnet of its own (`APPS_SUBNET`, with `APPS_DYNAMIC_IP_RANGE` keeping
`NGINX_APPS_IP` out of the dynamic pool). A Servarr app is reached on `apps`, or on
`services` when it is routed through gluetun, so it trusts both of nginx's addresses.

Each one is a real fix, not tidiness. Since Sonarr 4.0.20, and the same change in Radarr,
Prowlarr and Lidarr, the Servarr apps honour `X-Forwarded-Proto` and `-Host` only from a
trusted network, and the default trusts loopback alone; behind an untrusted nginx they
redirected to `http://localhost/<app>/login`, losing https and nginx's port.
qBittorrent with reverse proxy support off sees every browser as nginx, so its ban after
five failed logins lands on nginx and locks everyone out for an hour.

**Upgrading an existing deployment.** A `.env` from before these variables takes their
values from `.env.example` (the Makefile fills them in), but the `apps` network it already
has carries a range podman picked, so `make start` stops on the subnet check and names it.
Run `make down`, then `make start`, to recreate it, then `make wire_connections` for
qBittorrent. If `SERVICES_SUBNET` was moved off its default, set `NGINX_SERVICES_IP` in
`.env` to an address inside it, below `SERVICES_DYNAMIC_IP_RANGE`.

### Post deploy verification

```bash
nc -vz <VPN-exit-IP> <any web UI port>     # times out
nc -vz <VPN-exit-IP> <PF peer port>        # connects (peer protocol)
```

## 8. Design choice rationale

- **Why nginx left gluetun's namespace.** Nginx has no VPN requirement. It only terminates
  inbound TLS and forwards to upstreams. Coupling its lifecycle to the VPN container made
  every VPN reconnect restart the web UI. Moving nginx out decouples lifecycles, lets it
  proxy observability even when the VPN is reconnecting, and makes upstream URLs self
  documenting (`gluetun:<port>` instead of ambiguous `127.0.0.1:<port>`).
- **Why not one gluetun per stack.** Would give each stack its own network and killswitch,
  but it burns extra VPN device slots and complicates routing. One gateway is simpler and
  matches the structural killswitch design.
- **Why `services` and `observability` are `internal: true`.** Docker skips the default
  route on internal bridges. Gluetun's bridge side NICs physically cannot egress to the
  internet through those bridges, independent of any firewall configuration. Defense in
  depth on top of gluetun's own iptables.
- **Why there is a `wan` bridge.** Gluetun needs internet access to reach the VPN provider
  endpoint and bring up the tunnel. Both `services` and `observability` are
  `internal: true`, so a non-internal bootstrap bridge is required. Only gluetun sits on
  `wan`, no namespace-sharing containers join it.
- **Why `debug` is gone.** Grafana and Prometheus are behind nginx at `/admin/grafana/` and
  `/admin/prometheus/`. No direct host port is needed, the extra bridge only increased
  surface area.
- **Why jellyfin stays out of the VPN.** Jellyfin serves media to LAN clients. Routing it
  through the VPN would only add latency and break local discovery. It's dual homed, direct
  on `media` bridge published ports, and reachable through nginx at `/jellyfin/` for remote
  use over the same TLS endpoint.
- **Why Jellyfin has env-driven URL modes.** Jellyfin only has one global Base URL. This
  stack defaults `JELLYFIN_BASE_URL=/jellyfin`, so the main Nginx path is canonical and
  direct clients should include `/jellyfin`. Setting `JELLYFIN_PROXY_DOMAIN` adds a
  dedicated Nginx vhost, while setting `JELLYFIN_BASE_URL=` makes root direct/domain access
  canonical at the cost of making `/jellyfin/` a non-canonical compatibility path.
- **Why qBittorrent binds to `172.28.0.10` (gluetun's `services` bridge IP) rather than
  `0.0.0.0`.** Binding only to the bridge NIC means the WebUI is not reachable on `wg0`
  regardless of firewall state, an additional safety margin. Portability is preserved
  because the subnets are defined via `ipam.config` in `docker-compose.yml`, so gluetun
  always gets the same IP on every machine running this stack.

## 9. Operational notes

### Routing a service through the VPN

The default route is direct for Servarr apps and VPN for qBittorrent. To move a direct
service behind Gluetun, pass service names with `VPN_ON`.

```bash
make start                         # default: Servarr direct, qBittorrent VPN
make start VPN_ON="sonarr"
make start VPN_ON="sonarr,radarr"
make start VPN_ON="sonarr radarr"
make start VPN_ON="servarr"        # all Servarr apps behind Gluetun
make down                          # stops the same routed variant automatically
```

`VPN_ON` can also be set in `.env` because the Makefile includes that file. Command-line
values override `.env`, so `make start VPN_ON="sonarr"` wins over `VPN_ON=` in `.env`.

```env
VPN_ON=
# VPN_ON=sonarr,radarr
# VPN_ON=servarr
```

`make start` writes the resolved `VPN_ON` to `.vpn_on.state` (gitignored). `make down`,
`make stop`, and `make restart` read that file and reapply the same routing when `VPN_ON`
isn't passed explicitly, so you don't have to repeat it to avoid a mismatch between what's
running and what Compose tears down. Passing `VPN_ON` explicitly on any of those commands
always overrides the remembered value. `down` clears the state file once the stack is torn
down. Unknown or misspelled service names in `VPN_ON` fail the `make` invocation
immediately with the list of valid values, instead of silently starting with fewer routes
than requested.

`VPN_ON` maps to files in `docker-compose.routes/`. `ROUTE_FILES` remains available as the
low-level escape hatch for custom route files.

Each route file must stay tiny: set `network_mode: container:${VPN_PROVIDER}`, clear the
normal network list with `networks: !reset []`, and add aliases on gluetun's `services`
network. Use the plain service alias for app-to-app traffic and the protocol-specific
`*-http` or `*-https` alias for nginx. Do not copy the whole service definition into a
route file.

Example:

```yaml
services:
  sonarr:
    depends_on:
      "${VPN_PROVIDER}":
        condition: service_healthy
        restart: true
    network_mode: container:${VPN_PROVIDER}
    networks: !reset []

  gluetun:
    networks:
      services:
        aliases: [sonarr, sonarr-http]
```

Why this works: app-to-app configs use stable service DNS names (`sonarr`, `radarr`,
`prowlarr`, etc.) on `services`, while nginx uses dedicated protocol aliases (`sonarr-http`,
`radarr-https`, etc.) on `apps`. In VPN mode the route file makes both names resolve to
Gluetun on `services`, where the namespace-sharing service is listening. This avoids
ambiguous multi-network DNS answers and keeps Arr/Prowlarr links direct instead of going
through nginx.

### Routing selected Prowlarr indexers through the VPN

Prowlarr supports per-indexer proxies by tag. This stack uses Gluetun's built-in
HTTP proxy for that path, so the Prowlarr container can stay direct while only
selected indexer requests use VPN egress.

In Prowlarr, open `Settings -> Indexers`, add an `HTTP` proxy, and set:

| Field               | Value         |
| ------------------- | ------------- |
| Name                | `Gluetun VPN` |
| Tags                | `vpn`         |
| Host                | `gluetun`     |
| Port                | `8888`        |
| Username / Password | blank         |

Add the `vpn` tag to each indexer that should use the VPN. Leave indexers
untagged when they should keep normal Prowlarr egress. For Cloudflare-protected
indexers, keep the existing `flaresolverr` tag and add `vpn` only when the same
indexer should also use the VPN proxy.

Current DNS behavior: direct Servarr containers use Podman bridge DNS
(`10.89.2.1` and/or `172.28.0.1`). Containers in Gluetun's namespace use
Gluetun's local DNS forwarder at `127.0.0.1`; with the default config, Gluetun's
upstream resolver is Cloudflare with malicious-domain blocking enabled.

### Adding a new service that does not need the VPN

1. Attach it to an appropriate existing bridge (`media` for streaming, `observability` for
   metrics, or define a new one).
2. If it needs a reverse proxy entry, add nginx to that bridge too, and add a `location`
   block with `proxy_pass http://<service>:<port>;`.

### Verifying the killswitch

```bash
docker exec qbittorrent curl -sS --max-time 5 https://ipinfo.io/ip    # returns VPN IP
docker stop gluetun
docker exec qbittorrent curl -sS --max-time 5 https://ipinfo.io/ip    # fails, no network
docker start gluetun
```

Nginx stays up across this whole sequence, `/admin/grafana/` keeps working, VPN backed
routes return 502 until gluetun is healthy again.

### Reading Prometheus targets

Visit `https://<host>/admin/prometheus/targets`. Every target should be UP. Targets that
live inside the VPN namespace use `gluetun:<port>` as the host portion, that is correct,
not a bug.

---

See also: [README.md](../README.md), [docs/MAKE_COMMANDS.md](MAKE_COMMANDS.md)
