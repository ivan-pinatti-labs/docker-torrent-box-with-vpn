# Monitoring

The observability stack collects container and host metrics with Prometheus, ships logs via
Grafana Alloy to Loki, and surfaces everything in Grafana.

## Services

| Service                | Role                                                                                    | Profile                          |
| ---------------------- | --------------------------------------------------------------------------------------- | -------------------------------- |
| podman_exporter        | Per-container metrics from the Podman socket                                            | `PODMAN_EXPORTER_PROFILE`        |
| podman_limits_exporter | Per-container CPU/memory limits from the Podman socket                                  | `PODMAN_LIMITS_EXPORTER_PROFILE` |
| node_exporter          | Host OS and hardware metrics                                                            | `NODE_EXPORTER_PROFILE`          |
| nginx_exporter         | Nginx stub_status metrics                                                               | `NGINX_EXPORTER_PROFILE`         |
| qbittorrent_exporter   | qBittorrent-specific metrics (free disk, etc.)                                          | `QBITTORRENT_EXPORTER_PROFILE`   |
| sabnzbd_exporter       | SABnzbd queue, status, and downloader metrics                                           | `SABNZBD_EXPORTER_PROFILE`       |
| cAdvisor               | Root-cgroup metrics (limited under rootless Podman)                                     | `CADVISOR_PROFILE`               |
| Prometheus             | Scrapes and stores time-series data                                                     | `PROMETHEUS_PROFILE`             |
| Alloy                  | Log shipper: tails nginx, SABnzbd, qBittorrent, and jDownloader2 logs, forwards to Loki | `ALLOY_PROFILE`                  |
| Loki                   | Log storage and query backend                                                           | `LOKI_PROFILE`                   |
| Grafana                | Dashboards and alerting UI                                                              | `GRAFANA_PROFILE`                |

> **cAdvisor in rootless Podman:** cAdvisor only exposes the root cgroup (`id="/"`) when running
> under rootless Podman. It cannot provide per-container CPU or memory breakdowns. Use
> `podman_exporter` for per-container metrics and join with `podman_container_info` for
> human-readable names:
>
> ```promql
> rate(podman_container_cpu_seconds_total[5m]) * on(id) group_left(name) podman_container_info
> ```

### Podman limits exporter

`podman_limits_exporter` does not use a published exporter image. It runs
`scripts/podman-limits-exporter.py` inside a stock Python container, with the
script and the rootless Podman socket both mounted read-only. The script
queries the libpod API and exposes two gauges on port `9889`:

- `podman_container_cpu_limit_vcpus`: configured CPU limit in vCPUs (`0` means unlimited).
- `podman_container_pids_limit`: configured `pids_limit` (`0` means unlimited or unset).

Responses are cached for 30 seconds so Prometheus scrapes do not hammer the
Podman socket.

## Enabling

Set the following in `.env`:

```dotenv
PODMAN_EXPORTER_PROFILE=enabled
PODMAN_LIMITS_EXPORTER_PROFILE=enabled
NODE_EXPORTER_PROFILE=enabled
NGINX_EXPORTER_PROFILE=enabled
QBITTORRENT_EXPORTER_PROFILE=enabled
SABNZBD_EXPORTER_PROFILE=enabled
CADVISOR_PROFILE=enabled
PROMETHEUS_PROFILE=enabled
ALLOY_PROFILE=enabled
LOKI_PROFILE=enabled
GRAFANA_PROFILE=enabled
```

Then restart the stack:

```shell
make down && make start
```

## Network Architecture

```text
[Browser]
    │ HTTPS (nginx on port 443)
    ▼
nginx ── (apps + observability networks)
    │
    │ observability bridge (internal: true)
    ├──▶ prometheus:9090    /admin/prometheus/
    └──▶ grafana:3000       /admin/grafana/
              ▲                    │ apps network (internet)
              │ scrapes            │ (for SMTP and Telegram alerts)
         cadvisor
         podman_exporter
         podman_limits_exporter
         node_exporter
         nginx_exporter
         qbittorrent_exporter
         sabnzbd_exporter
```

The `observability` bridge is `internal: true`; containers on it cannot route to the internet.
Grafana is also attached to the `apps` network (non-internal) so it can reach AWS SES and Telegram
for alert delivery.

## Accessing the UIs

| Service    | URL                                |
| ---------- | ---------------------------------- |
| Grafana    | `https://<host>/admin/grafana/`    |
| Prometheus | `https://<host>/admin/prometheus/` |

## Prometheus

Scrape config: `configs/prometheus/prometheus.yml`

Active scrape jobs (the `job` name is the Prometheus job label, not the container name):

| Job                      | Endpoint                                         |
| ------------------------ | ------------------------------------------------ |
| `cadvisor`               | `cadvisor:8080/admin/cadvisor/metrics`           |
| `podman`                 | `podman_exporter:9882/metrics`                   |
| `podman_limits_exporter` | `podman_limits_exporter:9889/metrics`            |
| `node_exporter`          | `node_exporter:9100/admin/node_exporter/metrics` |
| `qbittorrent`            | `qbittorrent_exporter:17871/metrics`             |
| `sabnzbd`                | `sabnzbd_exporter:9387/metrics`                  |
| `nginx`                  | `nginx_exporter:9113/metrics`                    |
| `prometheus`             | Self-metrics                                     |

Retention is configured via `PROMETHEUS_RETENTION_TIME` and `PROMETHEUS_RETENTION_SIZE` in `.env`.
Persistent data lives in `storage/prometheus/data/` (gitignored).

## Loki and Alloy

Alloy tails nginx access/error logs from `${LOGS_FOLDER}/nginx/`, SABnzbd application logs
from `configs/sabnzbd/config/logs/`, qBittorrent application logs from
`configs/qbittorrent/config/qBittorrent/logs/`, and jDownloader2 application logs from
`configs/jdownloader2/config/log/`, then forwards them to Loki. Configuration:
`configs/alloy/config/config.alloy`.

Loki stores logs in `storage/loki/data/` (gitignored).
Configuration: `configs/loki/config/loki.yml`.

## Grafana

Default credentials: `admin` / `admin` (change on first login).

Configuration: `configs/grafana/config/grafana.ini`. Key settings:

- `protocol = http`: Grafana serves plain HTTP; nginx handles TLS termination
- `root_url = %(protocol)s://%(domain)s/admin/grafana/`: required for correct asset paths
  behind the subpath proxy
- `serve_from_sub_path = true`: required for subpath proxy

Provisioning files (datasources, dashboards, alerting) live under
`configs/grafana/config/provisioning/`.

Dashboard queries match containers by suffix (`name=~".*sonarr"`), never by exact name:
podman_exporter's `name` label is the real container name, which carries `CONTAINER_PREFIX`,
and Grafana does not interpolate environment variables in queries. Like the alert rules, this
assumes one stack per podman user; with two, a panel shows both stacks' containers.
`tests/unit/test_grafana_dashboards.py` refuses exact and bare-regex name matchers, and any
container name that no compose file defines.

The Podman Containers dashboard scopes its container queries to the stack's pod through a
`pod` variable, found from the stack's own gluetun container
(`label_values(podman_container_info{name=~".*gluetun"}, pod_name)`). podman-compose names
the pod `pod_<project>`, and the project name is `COMPOSE_PROJECT_NAME` or, by default, the
checkout's directory name, so it cannot be written into the dashboard. Its qBittorrent and
SABnzbd application rows read those apps' own exporters, which this stack's Prometheus
scrapes, so they ignore the `pod` and `container` variables and always show this stack.

The bundled SABnzbd dashboard is provisioned from
`configs/grafana/config/provisioning/dashboards/downloaders/sabnzbd.json`. Alerting includes
SABnzbd exporter-down and stalled-queue rules in
`configs/grafana/config/provisioning/alerting/rules.yaml`.

Persistent data is stored in `storage/grafana/data/` (gitignored).
