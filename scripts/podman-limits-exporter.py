#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
"""
Prometheus exporter for per-container resource limits (CPU, PIDs) from the Podman API.
Exposes podman_container_cpu_limit_vcpus and podman_container_pids_limit on :9889/metrics.
Results are cached for 30s to avoid hammering the Podman socket on every scrape.
"""

import json
import signal
import socket
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

SOCK_PATH = "/var/run/podman/podman.sock"
PORT = 9889
CACHE_TTL = 30

_cache: dict = {"body": b"", "ts": 0.0}


def podman_get(path: str) -> object:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(10)
        s.connect(SOCK_PATH)
        s.sendall(f"GET {path} HTTP/1.0\r\nHost: localhost\r\n\r\n".encode())
        buf = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    _, _, body = buf.partition(b"\r\n\r\n")
    return json.loads(body)


def build_metrics() -> bytes:
    containers = podman_get("/v4.0.0/libpod/containers/json?all=false")
    cpu_lines = [
        "# HELP podman_container_cpu_limit_vcpus Configured CPU limit in vCPUs (0 = unlimited).",
        "# TYPE podman_container_cpu_limit_vcpus gauge",
    ]
    pids_lines = [
        "# HELP podman_container_pids_limit Configured pids_limit per container (0 = unlimited or unset).",
        "# TYPE podman_container_pids_limit gauge",
    ]
    for c in containers:
        cid = c.get("Id", "")
        names = c.get("Names") or [cid[:12]]
        name = names[0].lstrip("/")
        try:
            detail = podman_get(f"/v4.0.0/libpod/containers/{cid}/json")
            host = detail.get("HostConfig", {})
            nano = host.get("NanoCpus") or 0
            pids = host.get("PidsLimit") or 0
        except Exception:
            nano = 0
            pids = 0
        vcpus = int(nano) / 1_000_000_000
        cpu_lines.append(
            f'podman_container_cpu_limit_vcpus{{name="{name}"}} {vcpus:.4f}'
        )
        pids_lines.append(f'podman_container_pids_limit{{name="{name}"}} {int(pids)}')
    return ("\n".join(cpu_lines + pids_lines) + "\n").encode()


def get_metrics() -> bytes:
    now = time.monotonic()
    if now - _cache["ts"] > CACHE_TTL:
        _cache["body"] = build_metrics()
        _cache["ts"] = now
    return _cache["body"]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args) -> None:
        pass

    def do_GET(self) -> None:
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        try:
            body = get_metrics()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except Exception as exc:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(str(exc).encode())


def handle_shutdown(_signum, _frame) -> None:
    raise SystemExit(0)


# A function rather than the body of the `__main__` block below so the unit
# tier can drive it with a stand-in server; see tests/unit/.
def main() -> None:
    signal.signal(signal.SIGINT, handle_shutdown)
    signal.signal(signal.SIGTERM, handle_shutdown)

    print(f"Serving on :{PORT}/metrics", flush=True)
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
