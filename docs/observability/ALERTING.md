# Alerting

Grafana Alerting (Unified Alerting) is used for all notifications. Rules are provisioned from
`configs/grafana/config/provisioning/alerting/rules.yaml` and loaded automatically on container
start. Notifications are delivered by email (AWS SES) and Telegram.

## Alert Rules

Rule groups and their evaluation interval: Container Resource Alerts (1m), Disk Growth
Alerts (5m), SABnzbd Alerts (1m), qBittorrent Alerts (1m), qBittorrent Slow Checks (1h, for
conditions that only change over hours/days), and Gluetun Alerts (1m).

| **Rule** | **Condition** | **Pending for** | **Severity** |
| -------- | ------------- | --------------- | ------------ |
| Container CPU > 90% | Per-container CPU averaged over 5 m exceeds 90% of all host cores | 5 m | (default) |
| Container Memory > 80% | Per-container memory vs. configured limit exceeds 80% | 5 m | (default) |
| Host Disk > 80% | Any real filesystem (excl. rootfs) above 80% used | 10 m | warning |
| Host Disk > 90% | Any real filesystem above 90% used | 5 m | critical |
| node_exporter Down | Prometheus cannot scrape `node_exporter` | 5 m | critical |
| qBittorrent Free Disk < 100 GiB | Free space reported by qBittorrent falls below 100 GiB | 10 m | warning |
| SABnzbd Exporter Down | Prometheus cannot scrape the SABnzbd exporter | 5 m | critical |
| SABnzbd Queue Stalled | Queue has items but download rate stays below 1 KB/s | 15 m | warning |
| qBittorrent Down | qBittorrent exporter cannot reach the WebUI | 5 m | critical |
| qBittorrent Firewalled | qBittorrent reports it cannot accept incoming peer connections | 10 m | warning |
| Torrent Stalled > 1 Week | A torrent has been stalled with no activity for over 7 days | 0 s (checked hourly) | warning |
| qBittorrent DHT Nodes Low | DHT node count drops below 200 | 0 s (checked hourly) | warning |
| Gluetun Container Down | Gluetun container state is not `running` | 2 m | critical |
| Gluetun VPN Disconnected | qBittorrent reports no BitTorrent network connectivity | 5 m | critical |
| Gluetun NAT PMP Port Lost | qBittorrent is firewalled, the forwarded-port lease may have expired | 15 m | warning |

Container metrics come from `podman_exporter` rather than cAdvisor. In rootless Podman, cAdvisor
only exposes the root cgroup and cannot provide per-container breakdowns. The CPU and memory
queries join `podman_container_*` metrics with `podman_container_info` using
`* on(id) group_left(name)` to produce human-readable container names in alert messages.

## Email via AWS SES

SMTP is configured in `configs/grafana/config/grafana.ini` under the `[smtp]` section using
`${VAR}` interpolation. Add the following to `configs/grafana/.env` (excluded from git by its
`.gitignore`):

```dotenv
GRAFANA_SMTP_ENABLED=true
GRAFANA_SMTP_HOST=email-smtp.<region>.amazonaws.com:587
GRAFANA_SMTP_USER=<ses_smtp_username>
GRAFANA_SMTP_PASSWORD=<ses_smtp_password>
GRAFANA_SMTP_FROM_ADDRESS=alerts@yourdomain.com
GRAFANA_ALERT_EMAIL_TO=you@example.com
```

SES SMTP credentials are generated separately from regular IAM access keys. In the AWS Console,
go to SES → SMTP settings → Create SMTP credentials.

## Telegram

Grafana's YAML provisioning re-coerces numeric chat IDs to JSON integers, which the Telegram
integration then rejects. Configure the Telegram contact point once through the Grafana UI instead:

1. Open **Alerting → Contact points → Add contact point**
2. Name it `Telegram`, set type to `Telegram`
3. Set **Bot API Token** (from @BotFather) and **Chat ID** (numeric, from `getUpdates`)
4. Save and test

A fully commented YAML example is in
`configs/grafana/config/provisioning/alerting/contact-points.yaml` for reference. Add your
bot token and chat ID to `configs/grafana/.env`:

```dotenv
GRAFANA_TELEGRAM_TOKEN=<bot_token>
GRAFANA_TELEGRAM_CHAT_ID=<chat_id>
```

To disable Telegram delivery without touching the notification policy, clear
`GRAFANA_TELEGRAM_TOKEN` in `.env` and recreate the container.

## Notification Policy

All alerts route to the Email contact point by default. The Telegram contact point is included
via a child route with `continue: true`, so both channels always fire. Policy is defined in
`configs/grafana/config/provisioning/alerting/notification-policy.yaml`.

Default timing: `group_wait=30s`, `group_interval=5m`, `repeat_interval=4h`. The
"Torrent Stalled > 1 Week" alert overrides this with `group_interval=24h` and
`repeat_interval=24h`, since re-notifying every 4 hours for a condition that only changes
over days would just be noise.

## Internet Access

Grafana needs to reach the AWS SES SMTP endpoint and Telegram's API. The Grafana service is
attached to both the `observability` network (internal, for Prometheus and Loki) and the `apps`
network (non-internal, outbound internet). This is set in `docker-compose-observability.yml`:

```yaml
networks: ["observability", "apps"]
```

## Reloading Provisioning

After changing only the YAML alerting files (rules, contact points, notification policy), reload
without recreating the container:

```shell
curl -X POST http://<user>:<password>@127.0.0.1/admin/grafana/api/admin/provisioning/alerting/reload
```

After changing `grafana.ini` or `configs/grafana/.env`, the container must be recreated so the
new values are picked up:

```shell
podman stop grafana && podman rm grafana
set -a; . <(grep -hE '^[A-Z0-9_]+_VERSION=' versions.env .env); set +a
podman-compose -f docker-compose-observability.yml --profile enabled up --detach grafana
```
