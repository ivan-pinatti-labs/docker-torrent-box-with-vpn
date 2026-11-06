#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2022 Ivan Pinatti
"""
Prometheus exporter for per-container resource limits (CPU, PIDs) from the Podman API,
and per-container swap from each container's cgroup, which the Podman API does not
report (#459).
Exposes podman_container_cpu_limit_vcpus, podman_container_pids_limit,
podman_container_swap_usage_bytes and podman_container_swap_limit_bytes on :9889/metrics.
Results are cached for 30s to avoid hammering the Podman socket on every scrape.
"""

import json
import signal
import socket
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

SOCK_PATH = "/var/run/podman/podman.sock"
PORT = 9889
CACHE_TTL = 30
# The host's /sys/fs/cgroup, mounted read only. Podman reports each container's
# CgroupPath from that root, under whichever cgroup manager it runs (systemd puts
# it in the user's user@<uid>.service tree, cgroupfs under /user), so the whole
# tree is mounted rather than a path that differs from host to host (#459).
CGROUP_ROOT = Path("/host-cgroup")

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


def cgroup_dir(cgroup_path: str) -> Path | None:
    """The container's cgroup under CGROUP_ROOT, from the CgroupPath Podman
    reports, which is absolute from the host's cgroup root. None when Podman
    reports none, or a path that would step outside the mount."""
    parts = [p for p in cgroup_path.split("/") if p]
    if not parts or ".." in parts:
        return None
    return CGROUP_ROOT.joinpath(*parts)


def read_swap(directory: Path | None) -> tuple[int | None, int | None]:
    """memory.swap.current and memory.swap.max, each None when unreadable;
    the limit is None too when it is "max", which means no limit."""
    if directory is None:
        return None, None
    values = []
    for name in ("memory.swap.current", "memory.swap.max"):
        try:
            text = (directory / name).read_text().strip()
        except OSError:
            values.append(None)
            continue
        values.append(int(text) if text.isdigit() else None)
    return values[0], values[1]


def build_metrics() -> tuple[bytes, bool]:
    """The metrics body, and whether every container's details were read.

    A container whose detail lookup fails is left out of this body rather than
    reported with limits of 0, which the gauges use for "unlimited"; the caller
    does not cache an incomplete body, so the next scrape asks again.
    """
    containers = podman_get("/v4.0.0/libpod/containers/json?all=false")
    complete = True
    cpu_lines = [
        "# HELP podman_container_cpu_limit_vcpus Configured CPU limit in vCPUs (0 = unlimited).",
        "# TYPE podman_container_cpu_limit_vcpus gauge",
    ]
    pids_lines = [
        "# HELP podman_container_pids_limit Configured pids_limit per container (0 = unlimited or unset).",
        "# TYPE podman_container_pids_limit gauge",
    ]
    swap_lines = [
        "# HELP podman_container_swap_usage_bytes Swap in use, from the container's cgroup.",
        "# TYPE podman_container_swap_usage_bytes gauge",
    ]
    swap_limit_lines = [
        "# HELP podman_container_swap_limit_bytes Swap limit from the container's cgroup (absent when unlimited).",
        "# TYPE podman_container_swap_limit_bytes gauge",
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
            cgroup_path = detail.get("State", {}).get("CgroupPath") or ""
        except Exception:
            complete = False
            continue
        vcpus = int(nano) / 1_000_000_000
        cpu_lines.append(
            f'podman_container_cpu_limit_vcpus{{name="{name}"}} {vcpus:.4f}'
        )
        pids_lines.append(f'podman_container_pids_limit{{name="{name}"}} {int(pids)}')
        used, limit = read_swap(cgroup_dir(cgroup_path))
        if used is not None:
            swap_lines.append(f'podman_container_swap_usage_bytes{{name="{name}"}} {used}')
        if limit is not None:
            swap_limit_lines.append(
                f'podman_container_swap_limit_bytes{{name="{name}"}} {limit}'
            )
    lines = cpu_lines + pids_lines + swap_lines + swap_limit_lines
    return ("\n".join(lines) + "\n").encode(), complete


def get_metrics() -> bytes:
    now = time.monotonic()
    if now - _cache["ts"] > CACHE_TTL:
        body, complete = build_metrics()
        if not complete:
            return body
        _cache["body"] = body
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
