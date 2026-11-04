# App Links

These tables list every app's link, protocol (HTTP or HTTPS), and login. Some
apps are available on both HTTP and HTTPS, some only on one. Not all apps are
fully working through the reverse proxy (Nginx) yet.

Every password marked "rotated" is set by `make bootstrap`'s final step and
again by every later `make rotate_all`; there is no fixed default to write
down. See [docs/ROTATION.md](ROTATION.md) for how to read the current value
back (Homepage's dashboard links to every app and most current-credential
consumers already hold it directly).

Jellyfin defaults to Nginx subpath access at `https://<domain>/jellyfin/`.
This is controlled by `JELLYFIN_BASE_URL=/jellyfin`, seeded into Jellyfin's
`network.xml` from `network.xml.example` like every other app's config, so it
takes effect from Jellyfin's genuine first boot with no extra step. If you
change `JELLYFIN_BASE_URL` or `JELLYFIN_KNOWN_PROXY` later, run `make
configure_jellyfin_network` to apply the new values (idempotent, safe to
re-run any time). To make a dedicated hostname available through Nginx, set
`JELLYFIN_PROXY_DOMAIN`, for example `jellyfin.example.com`. Direct ports `8096`
and `8920` remain published; with the default base URL, direct clients should
use `/jellyfin` too. If you set `JELLYFIN_BASE_URL=` for clean root access on
direct/domain URLs, the main `/jellyfin/` proxy path is no longer Jellyfin's
canonical URL.

## One host name per app

Set `APP_PROXY_DOMAIN`, for example `example.com`, and every app with a web UI
behind Nginx also answers on a host name of its own:
`https://sonarr.example.com/` redirects to `https://sonarr.example.com/sonarr/`,
and the app works from there. The name is the app's path with `_` as `-`
(`calibre-web` for `/calibre_web/`), and the `/admin/` apps go by their bare
name (`grafana`, `prometheus`, `cadvisor`). Jellyfin uses
`JELLYFIN_PROXY_DOMAIN` instead, and the paths that are not a UI (FlareSolverr,
Gluetun, KOReader Sync, the Calibre content server, Node Exporter) have no host
name. The paths of the shared host keep working, and its `/` still opens
Homepage. Left at its default, `invalid`, nothing changes.

- **DNS.** Point each name, or `*.example.com`, at this host in your own
  resolver.
- **Certificate.** `make generate_certificate` and `make rotate_certificate`
  add `*.${APP_PROXY_DOMAIN}` to the self signed certificate. A certificate of
  your own has to cover it too. A wildcard covers one label only:
  `sonarr.box.example.com` needs `*.box.example.com`, not `*.example.com`.
- **Changing it on a running stack.** A certificate made before the setting
  does not name the new host names, and nginx reads the setting only when its
  container is created (`make start` keeps a running one). Run
  `make rotate_certificate`, then the recreate command it prints, which
  includes nginx. With a certificate of your own, recreate nginx alone the same
  way.
- **Password managers.** This is what the host names are for: a password
  manager tells logins apart by address, and Android's autofill only sees the
  host name. Match each login on the host (the "Host" match in Bitwarden),
  not the base domain, or every app's login is offered on every app again.

## **HTTP**

| **App**        | **Link**                         | **User**     | **Password** |
| -------------- | -------------------------------- | ------------ | ------------ |
| Audiobookshelf | <http://localhost:13378/>        | root         | rotated      |
| Bazarr         | <http://localhost:6767/>         | bazarr       | rotated      |
| KOReader Sync  | <http://localhost:3000/>         | -            | -            |
| Calibre        | <http://localhost:8080/>         | calibre      | rotated      |
| Calibre-Web    | <http://localhost:8083/>         | admin        | rotated      |
| FlareSolverr   | <http://localhost:8191/>         | -            | -            |
| Lidarr         | <http://localhost:8686/>         | lidarr       | rotated      |
| Nginx          | <http://localhost:8080/>         | -            | -            |
| jDownloader2   | <https://localhost:5800/>        | jdownloader2 | rotated      |
| SABnzbd        | <http://localhost:8086/sabnzbd/> | sabnzbd      | rotated      |
| Prowlarr       | <http://localhost:9696/>         | prowlarr     | rotated      |
| Radarr         | <http://localhost:7878/>         | radarr       | rotated      |
| Readarr        | <http://localhost:8787/>         | readarr      | rotated      |
| Sonarr         | <http://localhost:8989/>         | sonarr       | rotated      |
| Whisparr       | <http://localhost:6969/>         | whisparr     | rotated      |

## **HTTPS**

| **App**        | **Link**                               | **User**      | **Password**  |
| -------------- | -------------------------------------- | ------------- | ------------- |
| Audiobookshelf | <http://localhost:13378/>              | root          | rotated       |
| Calibre        | <https://localhost:8181/>              | calibre       | rotated       |
| LazyLibrarian  | <https://localhost:5299/lazylibrarian> | lazylibrarian | rotated       |
| Lidarr         | <https://localhost:6868/>              | lidarr        | rotated       |
| Nginx          | <https://localhost:8443/>              | -             | -             |
| Mylar          | <https://localhost:8091/mylar/>        | mylar         | rotated       |
| SABnzbd        | <https://localhost:8087/sabnzbd/>      | sabnzbd       | rotated       |
| NzbHydra2      | <https://localhost:5077/nzbhydra2/>    | admin         | rotated       |
| Prowlarr       | <https://localhost:6969/>              | prowlarr      | rotated       |
| qBitTorrent    | <https://localhost:8085/>              | qbittorrent   | rotated       |
| Radarr         | <https://localhost:7879/>              | radarr        | rotated       |
| Readarr        | <https://localhost:8788/>              | readarr       | rotated       |
| Whisparr       | <https://localhost:9898/>              | whisparr      | rotated       |

## **HTTPS through reverse proxy (Nginx)**

> The port is required: the default `NGINX_HTTPS_PORT` is `8443`, not the
> standard `443` (see [README §Requisites](../README.md#requisites) for the
> rootless-ports note), so a link like `https://localhost/sonarr/` with no
> port will fail to connect. Substitute your own `NGINX_HTTPS_PORT` below if
> you changed it from the default.

| **App**            | **Link**                                        | **User**      | **Password**  |
| ------------------ | ----------------------------------------------- | ------------- | ------------- |
| Audiobookshelf     | <https://localhost:8443/audiobookshelf/>        | root          | rotated       |
| Bazarr             | <https://localhost:8443/bazarr/>                | bazarr        | rotated       |
| Calibre            | <https://localhost:8443/calibre/>               | calibre       | rotated       |
| Calibre-Web        | <https://localhost:8443/calibre_web/>           | admin         | rotated       |
| Cleanuparr         | <https://localhost:8443/cleanuparr/>            | cleanuparr    | rotated       |
| FlareSolverr       | <https://localhost:8443/flaresolverr/>          | -             | -             |
| Gluetun VPN status | <https://localhost:8443/gluetun/v1/vpn/status>  | -             | -             |
| Gluetun port       | <https://localhost:8443/gluetun/v1/portforward> | -             | -             |
| Gluetun exit IP    | <https://localhost:8443/gluetun/v1/publicip/ip> | -             | -             |
| Jellyfin           | <https://localhost:8443/jellyfin/>              | jellyfin      | rotated       |
| KOReader Sync      | <https://localhost:8443/korsync/>               | -             | -             |
| Lazylibrarian      | <https://localhost:8443/lazylibrarian/>         | lazylibrarian | rotated       |
| Lidarr             | <https://localhost:8443/lidarr/>                | lidarr        | rotated       |
| Mylar              | <https://localhost:8443/mylar/>                 | mylar         | rotated       |
| SABnzbd            | <https://localhost:8443/sabnzbd/>               | sabnzbd       | rotated       |
| NzbHydra2          | <https://localhost:8443/nzbhydra2/>             | admin         | rotated       |
| Prowlarr           | <https://localhost:8443/prowlarr/>              | prowlarr      | rotated       |
| qBitTorrent        | <https://localhost:8443/qbittorrent/>           | qbittorrent   | rotated       |
| Radarr             | <https://localhost:8443/radarr/>                | radarr        | rotated       |
| Readarr            | <https://localhost:8443/readarr/>               | readarr       | rotated       |
| Sonarr             | <https://localhost:8443/sonarr/>                | sonarr        | rotated       |
| Whisparr           | <https://localhost:8443/whisparr/>              | whisparr      | rotated       |

---

## Indexers

### Torrent

LazyLibrarian ---> Prowlarr ---> Flaresolverr\
Lidarr ---> Prowlarr ---> Flaresolverr\
Mylar ---> Prowlarr ---> Flaresolverr\
Radarr ---> Prowlarr ---> Flaresolverr\
Readarr ---> Prowlarr ---> Flaresolverr\
Sonarr ---> Prowlarr ---> Flaresolverr

Legacy Jackett setups may still use
`NzbHydra2 ---> Jackett ---> Flaresolverr`. If `JACKETT_PROFILE=enabled`, the
legacy direct URL is <http://localhost:9117/> and the legacy reverse-proxy URL is
<https://localhost/jackett/>.

### Usenet

LazyLibrarian ---> NzbHydra2\
Lidarr ---> NzbHydra2\
Mylar ---> NzbHydra2\
Radarr ---> NzbHydra2\
Readarr ---> NzbHydra2\
Sonarr ---> NzbHydra2

---

## Downloaders

### Torrent

LazyLibrarian ---> qBitTorrent\
Lidarr ---> qBitTorrent\
Mylar ---> qBitTorrent\
Radarr ---> qBitTorrent\
Readarr ---> qBitTorrent\
Sonarr ---> qBitTorrent

qBittorrent is also wired to TrackersList's qBittorrent feed. The bundled
config enables adding trackers from a URL and points qBittorrent at
`https://cf.trackerslist.com/best.txt`. See
<https://trackerslist.com/#/?id=qbittorrent> for the upstream qBittorrent
tracker-list details.

### Usenet

LazyLibrarian ---> SABnzbd\
Lidarr ---> SABnzbd\
Mylar ---> SABnzbd\
Radarr ---> SABnzbd\
Readarr ---> SABnzbd\
Sonarr ---> SABnzbd

---

## Library Managers

### Movies / Series / Music

Lidarr ---> Jellyfin\
Radarr ---> Jellyfin\
Sonarr ---> Jellyfin

Plex is a legacy, disabled-by-default alternative; see
[README's Legacy Apps table](../README.md#legacy-apps).

### AudioBooks / eBooks / Comics

LazyLibrarian ---> Calibre\
Mylar ---> Calibre\
Readarr ---> Calibre

See [docs/CALIBRE.md](CALIBRE.md) and [docs/KORSYNC.md](KORSYNC.md)
for configuration details.

### Subtitles (Movies / TV Shows)

Bazarr ---> Sonarr\
Bazarr ---> Radarr

---

See also: [README.md](../README.md), [docs/CONNECTIONS.md](CONNECTIONS.md)
