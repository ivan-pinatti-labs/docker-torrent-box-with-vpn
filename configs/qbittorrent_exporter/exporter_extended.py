import faulthandler
import json
import logging
import os
import signal
import sys
import time
from dataclasses import dataclass, field
from enum import StrEnum, auto
from typing import Any, Iterable
from urllib.request import urlopen

from prometheus_client import start_http_server
from prometheus_client.core import REGISTRY, CounterMetricFamily, GaugeMetricFamily
from pythonjsonlogger import jsonlogger
from qbittorrentapi import Client, TorrentStates

faulthandler.enable()
logger = logging.getLogger()


class MetricType(StrEnum):
    GAUGE = auto()
    COUNTER = auto()


@dataclass
class Metric:
    name: str
    value: Any
    labels: dict[str, str] = field(default_factory=dict)
    help_text: str = ""
    metric_type: MetricType = MetricType.GAUGE


def _get_config_value(key: str, default: str = "") -> str:
    input_path = os.environ.get("FILE__" + key)
    if input_path:
        try:
            with open(input_path, "r", encoding="utf-8") as input_file:
                return input_file.read().strip()
        except OSError as e:
            logger.error("Unable to read %s from %s: %s", key, input_path, e)
    return os.environ.get(key, default)


def get_config() -> dict[str, Any]:
    return {
        "host": _get_config_value("QBITTORRENT_HOST"),
        "port": _get_config_value("QBITTORRENT_PORT"),
        "ssl": _get_config_value("QBITTORRENT_SSL", "False") == "True",
        "url_base": _get_config_value("QBITTORRENT_URL_BASE"),
        "username": _get_config_value("QBITTORRENT_USER"),
        "password": _get_config_value("QBITTORRENT_PASS"),
        "exporter_address": _get_config_value("EXPORTER_ADDRESS", "0.0.0.0"),
        "exporter_port": int(_get_config_value("EXPORTER_PORT", "8000")),
        "log_level": _get_config_value("EXPORTER_LOG_LEVEL", "INFO"),
        "metrics_prefix": _get_config_value("METRICS_PREFIX", "qbittorrent"),
        "gluetun_control_url": _get_config_value("GLUETUN_CONTROL_URL"),
        "verify_webui_certificate": (
            _get_config_value("VERIFY_WEBUI_CERTIFICATE", "True") == "True"
        ),
    }


class QbittorrentMetricsCollector:
    def __init__(self, config: dict[str, Any]) -> None:
        self.config = config
        self.server = f"{config['host']}:{config['port']}"
        protocol = "https" if config["ssl"] or config["port"] == "443" else "http"
        path = f"/{config['url_base']}" if config["url_base"] else ""
        self.connection_string = f"{protocol}://{self.server}{path}"
        self.client = Client(
            host=self.connection_string,
            username=config["username"],
            password=config["password"],
            VERIFY_WEBUI_CERTIFICATE=config["verify_webui_certificate"],
        )

    def collect(self) -> Iterable[GaugeMetricFamily | CounterMetricFamily]:
        for metric in self.get_qbittorrent_metrics():
            labels = list(metric.labels.keys())
            if metric.metric_type == MetricType.COUNTER:
                prom_metric = CounterMetricFamily(metric.name, metric.help_text, labels=labels)
            else:
                prom_metric = GaugeMetricFamily(metric.name, metric.help_text, labels=labels)
            prom_metric.add_metric(list(metric.labels.values()), metric.value)
            yield prom_metric

    def get_qbittorrent_metrics(self) -> list[Metric]:
        metrics: list[Metric] = []
        metrics.extend(self._get_status_metrics())
        metrics.extend(self._get_preference_metrics())
        metrics.extend(self._get_forwarded_port_metrics())
        metrics.extend(self._get_torrent_count_metrics())
        metrics.extend(self._get_per_torrent_metrics())
        return metrics

    def _get_status_metrics(self) -> list[Metric]:
        maindata: dict[str, Any] = {}
        version = ""
        try:
            maindata = self.client.sync_maindata()
            version = self.client.app.version
        except Exception as e:
            logger.error("Couldn't get server info: %s", e)

        state = maindata.get("server_state", {})
        prefix = self.config["metrics_prefix"]
        labels = {"server": self.server}

        return [
            Metric(
                name=f"{prefix}_up",
                value=1 if state else 0,
                labels={"version": version, "server": self.server},
                help_text="Whether qBittorrent is answering requests from this exporter.",
            ),
            Metric(
                name=f"{prefix}_connected",
                value=1 if state.get("connection_status", "") == "connected" else 0,
                labels=labels,
                help_text="Whether qBittorrent is connected to the BitTorrent network.",
            ),
            Metric(
                name=f"{prefix}_firewalled",
                value=1 if state.get("connection_status", "") == "firewalled" else 0,
                labels=labels,
                help_text="Whether qBittorrent is connected but firewalled.",
            ),
            Metric(
                name=f"{prefix}_dht_nodes",
                value=state.get("dht_nodes", 0),
                labels=labels,
                help_text="Number of connected DHT nodes.",
            ),
            Metric(
                name=f"{prefix}_free_space_on_disk",
                value=state.get("free_space_on_disk", 0),
                labels=labels,
                help_text="Free disk space reported by qBittorrent, in bytes.",
            ),
            Metric(
                name=f"{prefix}_dl_info_data",
                value=state.get("dl_info_data", 0),
                labels=labels,
                help_text="Data downloaded since qBittorrent started, in bytes.",
                metric_type=MetricType.COUNTER,
            ),
            Metric(
                name=f"{prefix}_up_info_data",
                value=state.get("up_info_data", 0),
                labels=labels,
                help_text="Data uploaded since qBittorrent started, in bytes.",
                metric_type=MetricType.COUNTER,
            ),
            Metric(
                name=f"{prefix}_alltime_dl",
                value=state.get("alltime_dl", 0),
                labels=labels,
                help_text="Total historical data downloaded, in bytes.",
                metric_type=MetricType.COUNTER,
            ),
            Metric(
                name=f"{prefix}_alltime_ul",
                value=state.get("alltime_ul", 0),
                labels=labels,
                help_text="Total historical data uploaded, in bytes.",
                metric_type=MetricType.COUNTER,
            ),
        ]

    def _get_preference_metrics(self) -> list[Metric]:
        preferences: dict[str, Any] = {}
        transfer_info: dict[str, Any] = {}
        speed_limits_mode = 0
        try:
            preferences = dict(self.client.app.preferences)
            transfer_info = dict(self.client.transfer.info)
            speed_limits_mode = int(self.client.transfer.speed_limits_mode)
        except Exception as e:
            logger.error("Couldn't get preferences: %s", e)

        prefix = self.config["metrics_prefix"]
        labels = {"server": self.server}

        return [
            Metric(
                name=f"{prefix}_listen_port",
                value=preferences.get("listen_port", 0),
                labels=labels,
                help_text="qBittorrent incoming listening port.",
            ),
            Metric(
                name=f"{prefix}_speed_limits_mode",
                value=speed_limits_mode,
                labels=labels,
                help_text="Current speed limit mode: 0 global, 1 alternative.",
            ),
            Metric(
                name=f"{prefix}_download_limit",
                value=preferences.get("dl_limit", 0),
                labels={"mode": "global", **labels},
                help_text="Configured global download rate limit in bytes per second.",
            ),
            Metric(
                name=f"{prefix}_upload_limit",
                value=preferences.get("up_limit", 0),
                labels={"mode": "global", **labels},
                help_text="Configured global upload rate limit in bytes per second.",
            ),
            Metric(
                name=f"{prefix}_download_limit",
                value=preferences.get("alt_dl_limit", 0),
                labels={"mode": "alternative", **labels},
                help_text="Configured alternative download rate limit in bytes per second.",
            ),
            Metric(
                name=f"{prefix}_upload_limit",
                value=preferences.get("alt_up_limit", 0),
                labels={"mode": "alternative", **labels},
                help_text="Configured alternative upload rate limit in bytes per second.",
            ),
            Metric(
                name=f"{prefix}_active_download_limit",
                value=transfer_info.get("dl_rate_limit", 0),
                labels=labels,
                help_text="Currently active download rate limit in bytes per second.",
            ),
            Metric(
                name=f"{prefix}_active_upload_limit",
                value=transfer_info.get("up_rate_limit", 0),
                labels=labels,
                help_text="Currently active upload rate limit in bytes per second.",
            ),
        ]

    def _get_forwarded_port_metrics(self) -> list[Metric]:
        # gluetun has no metrics endpoint, so its forwarded port is reported
        # here, next to the listen port it should match (#462). A failed
        # request reports nothing rather than 0, which means "none forwarded".
        # The timeout stays well inside Prometheus's 10s scrape timeout, so a
        # stuck control server cannot cost the qBittorrent metrics their scrape.
        url = self.config["gluetun_control_url"]
        if not url:
            return []
        try:
            with urlopen(url, timeout=2) as response:
                ports = json.load(response).get("ports") or []
        except Exception as e:
            logger.error("Couldn't get gluetun's forwarded port: %s", e)
            return []

        return [
            Metric(
                name="gluetun_forwarded_port",
                value=ports[0] if ports else 0,
                help_text="Port gluetun forwards through the VPN, 0 when it forwards none.",
            )
        ]

    def _fetch_categories(self) -> dict[str, dict[str, Any]]:
        try:
            categories = {
                key: dict(value)
                for key, value in dict(self.client.torrent_categories.categories).items()
            }
            categories["Uncategorized"] = {"name": "Uncategorized", "savePath": ""}
            return categories
        except Exception as e:
            logger.error("Couldn't fetch categories: %s", e)
            return {"Uncategorized": {"name": "Uncategorized", "savePath": ""}}

    def _fetch_torrents(self) -> list[dict[str, Any]]:
        try:
            return [dict(torrent) for torrent in self.client.torrents.info()]
        except Exception as e:
            logger.error("Couldn't fetch torrents: %s", e)
            return []

    def _get_torrent_count_metrics(self) -> list[Metric]:
        metrics: list[Metric] = []
        categories = self._fetch_categories()
        torrents = self._fetch_torrents()
        prefix = self.config["metrics_prefix"]

        for category in categories:
            category_torrents = [
                torrent
                for torrent in torrents
                if torrent.get("category") == category
                or (category == "Uncategorized" and torrent.get("category") == "")
            ]
            for state in TorrentStates:
                count = len(
                    [
                        torrent
                        for torrent in category_torrents
                        if torrent.get("state") == state.value
                    ]
                )
                metrics.append(
                    Metric(
                        name=f"{prefix}_torrents_count",
                        value=count,
                        labels={
                            "status": state.value,
                            "category": category,
                            "server": self.server,
                        },
                        help_text=(
                            f"Number of torrents in status {state.value} under "
                            f"category {category}."
                        ),
                    )
                )
        return metrics

    def _get_per_torrent_metrics(self) -> list[Metric]:
        metrics: list[Metric] = []
        prefix = self.config["metrics_prefix"]
        for torrent in self._fetch_torrents():
            labels = {
                "name": str(torrent.get("name", "")),
                "category": str(torrent.get("category") or "Uncategorized"),
                "tags": str(torrent.get("tags") or "untagged"),
                "state": str(torrent.get("state", "")),
                "server": self.server,
            }
            metrics.extend(
                [
                    Metric(
                        name=f"{prefix}_torrent_seeders",
                        value=torrent.get("num_seeds", 0),
                        labels=labels,
                        help_text="Current number of seeders for this torrent.",
                    ),
                    Metric(
                        name=f"{prefix}_torrent_uploaded",
                        value=torrent.get("uploaded", 0),
                        labels=labels,
                        help_text="Total data uploaded for this torrent, in bytes.",
                    ),
                    Metric(
                        name=f"{prefix}_torrent_completion_on",
                        value=torrent.get("completion_on", 0),
                        labels=labels,
                        help_text="Torrent completion time as Unix epoch seconds.",
                    ),
                    Metric(
                        name=f"{prefix}_torrent_last_activity",
                        value=torrent.get("last_activity", 0),
                        labels=labels,
                        help_text="Torrent last activity time as Unix epoch seconds.",
                    ),
                    Metric(
                        name=f"{prefix}_torrent_progress",
                        value=torrent.get("progress", 0),
                        labels=labels,
                        help_text="Torrent completion progress from 0 to 1.",
                    ),
                ]
            )
        return metrics


class ShutdownSignalHandler:
    def __init__(self) -> None:
        self.shutdown_count = 0
        signal.signal(signal.SIGINT, self._on_signal_received)
        signal.signal(signal.SIGTERM, self._on_signal_received)

    def is_shutting_down(self) -> bool:
        return self.shutdown_count > 0

    def _on_signal_received(self, _signal, _frame) -> None:
        if self.shutdown_count > 1:
            logger.warning("Forcibly killing exporter")
            sys.exit(1)
        logger.info("Exporter is shutting down")
        self.shutdown_count += 1


def main() -> None:
    log_handler = logging.StreamHandler()
    formatter = jsonlogger.JsonFormatter(
        "%(asctime) %(levelname) %(message)", datefmt="%Y-%m-%d %H:%M:%S"
    )
    log_handler.setFormatter(formatter)
    logger.addHandler(log_handler)

    config = get_config()
    logger.setLevel(config["log_level"])

    if not config["host"]:
        logger.error("No host specified, set QBITTORRENT_HOST")
        sys.exit(1)
    if not config["port"]:
        logger.error("No port specified, set QBITTORRENT_PORT")
        sys.exit(1)

    signal_handler = ShutdownSignalHandler()
    REGISTRY.register(QbittorrentMetricsCollector(config))
    start_http_server(config["exporter_port"], config["exporter_address"])
    logger.info(
        "Exporter listening on %s:%s",
        config["exporter_address"],
        config["exporter_port"],
    )

    while not signal_handler.is_shutting_down():
        time.sleep(1)


if __name__ == "__main__":
    main()
