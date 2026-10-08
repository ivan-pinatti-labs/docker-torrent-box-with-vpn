# Container Limits

Container limits are set in `.env` and consumed by the Compose files through
YAML anchors. The anchor names describe service groups, while the actual CPU
and memory values stay configurable.

CPU values are quotas, not reservations. A container with `cpus: "0.5"` can use
up to half of one CPU when scheduled, but it does not reserve that capacity.
Memory is the RAM ceiling.

This stack does not set a `memswap_limit`. `podman-compose` (the version this
stack targets) does not implement that Compose key at all: it silently drops
it, regardless of what value is set. In its absence, Podman's own default
applies: each container gets swap headroom equal to its memory limit (so a
`1gb` memory limit effectively allows up to `2gb` of combined memory+swap).
That default already provides burst headroom without any extra configuration,
so there is nothing to set here.

This stack does not use CPU pinning. The Linux scheduler remains free to place
containers on any CPU.

| Group | Services | CPU env | Memory env | Default CPU | Default MEM |
| --- | --- | --- | --- | --- | --- |
| Nginx | `nginx` | `NGINX_CPUS` | `NGINX_MEMORY` | `0.5` | `512mb` |
| Homepage | `homepage` | `HOMEPAGE_CPUS` | `HOMEPAGE_MEMORY` | `0.25` | `256mb` |
| Servarr | `bazarr`, `lazylibrarian`, `lidarr`, `mylar`, `prowlarr`, `radarr`, `readarr`, `recyclarr`, `sonarr`, `whisparr` | `SERVARR_CPUS` | `SERVARR_MEMORY` | `0.5` | `512mb` |
| FlareSolverr | `flaresolverr` | `FLARESOLVERR_CPUS` | `FLARESOLVERR_MEMORY` | `1` | `1gb` |
| Downloaders | `qbittorrent`, `sabnzbd`, `nzbget`, `jdownloader2` | `DOWNLOADERS_CPUS` | `DOWNLOADERS_MEMORY` | `2` | `1gb` |
| NZBHydra2 | `nzbhydra2` | `NZBHYDRA2_CPUS` | `NZBHYDRA2_MEMORY` | `1` | `1gb` |
| Gluetun | `gluetun` | `GLUETUN_CPUS` | `GLUETUN_MEMORY` | `1` | `1gb` |
| Jellyfin | `jellyfin` | `JELLYFIN_CPUS` | `JELLYFIN_MEMORY` | `1` | `1gb` |
| Calibre | `calibre` | `CALIBRE_CPUS` | `CALIBRE_MEMORY` | `0.5` | `1gb` |
| Calibre-web | `calibre-web` | `CALIBREWEB_CPUS` | `CALIBREWEB_MEMORY` | `0.5` | `512mb` |
| Audiobookshelf | `audiobookshelf` | `AUDIOBOOKSHELF_CPUS` | `AUDIOBOOKSHELF_MEMORY` | `0.5` | `512mb` |
| KOReader sync | `korsync` | `KORSYNC_CPUS` | `KORSYNC_MEMORY` | `0.25` | `128mb` |
| Grafana | `grafana` | `GRAFANA_CPUS` | `GRAFANA_MEMORY` | `1` | `1.5gb` |
| Telemetry | `prometheus`, `loki`, `cadvisor`, `alloy`, `node_exporter`, `podman_exporter`, `podman_limits_exporter`, `nginx_exporter`, `qbittorrent_exporter`, `sabnzbd_exporter` | `TELEMETRY_CPUS` | `TELEMETRY_MEMORY` | `0.25` | `256mb` |
| Log rotation | `log_rotator` | `LOG_ROTATOR_CPUS` | `LOG_ROTATOR_MEMORY` | `0.25` | `64mb` |

Alloy shares `TELEMETRY_CPUS` with the rest of the Telemetry group but overrides its own
memory ceiling via `ALLOY_MEMORY` (default `512mb`) instead of `TELEMETRY_MEMORY`.

For Jellyfin CPU transcoding, increase `JELLYFIN_CPUS` to `2`. Hardware
transcoding through `/dev/dri` may not need that increase.

`JELLYFIN_DRI_DEVICE` names the GPU device Jellyfin gets, mapped to the same
path inside the container. It defaults to `/dev/dri`, the whole directory,
which is what a real host wants, and a deployment whose `.env` predates the
variable gets that same default. Set a single node such as `/dev/dri/card0`
only where the runtime cannot pass a directory on: the nested test runner
(docs/TESTING.md) is one, since a directory mapping fails for a container
started inside another container, and it sets `/dev/dri/card0` for that
reason.

jDownloader2 is a JVM application and carries an additional X11/VNC layer from
the `jlesage/jdownloader-2` image. Its JVM heap is capped at 384 MB via
`JDOWNLOADER_MAX_MEM=384m` in `configs/jdownloader2/.env`, with supporting JVM
options in `configs/jdownloader2/config/JDownloader2.vmoptions`, so total idle
memory stays within the 1 GB container ceiling.

Prometheus and Loki share the telemetry limits by default. Increase
`TELEMETRY_MEMORY` if metrics or logs retention grows.

## Shutdown grace periods

Compose gives a container ten seconds between SIGTERM and SIGKILL. Three get
longer through `stop_grace_period`, and `tests/test_containers.py` checks the
running containers carry it:

| Service | Grace | Why |
| --- | --- | --- |
| `nzbhydra2` | `120s` | NZBHydra2 v9 compacts its H2 database on a graceful shutdown, and its release notes ask docker users for 120s. A kill does not corrupt the database, it only skips the compaction, so the file stays larger than it needs to be. |
| `prometheus` | `30s` | Set with the observability stack, reason not recorded; Prometheus writes its head block and write ahead log on shutdown. |
| `alloy` | `30s` | Set with the observability stack, reason not recorded; Alloy flushes its buffered telemetry on shutdown. |

The value covers `make stop_all`, `make restart` and a plain compose stop or
restart. `make down` and the rotation and wiring scripts stop the stack with
their own 60 second timeout, which takes precedence, so under them NZBHydra2
can still be killed before it finishes compacting.

---

See also: [README.md](../README.md), [docs/MAKE_COMMANDS.md](MAKE_COMMANDS.md)
