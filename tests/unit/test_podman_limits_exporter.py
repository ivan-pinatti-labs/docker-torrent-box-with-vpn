"""Unit tests for scripts/podman-limits-exporter.py.

The Podman socket is a stand in that answers from a dictionary, and the HTTP
side is served on a loopback port the kernel picks, so nothing here needs
Podman or reaches past this machine.
"""

import http.client
import json
import signal
import threading
from http.server import HTTPServer

import pytest

pytestmark = pytest.mark.unit


@pytest.fixture
def exporter(load_script):
    return load_script("podman-limits-exporter.py")


class FakeSocket:
    """Answers one HTTP/1.0 request the way the Podman API socket does."""

    responses: dict[str, object] = {}
    connected_to: list[str] = []

    def __init__(self, family, kind):
        self.request = b""
        self.chunks: list[bytes] = []

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def settimeout(self, timeout):
        assert timeout == 10

    def connect(self, path):
        self.connected_to.append(path)

    def sendall(self, data):
        self.request = data
        path = data.decode().split()[1]
        answer = self.responses[path]
        if isinstance(answer, Exception):
            raise answer
        body = json.dumps(answer).encode()
        reply = b"HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n" + body
        # Split across two reads, as a real socket may deliver it.
        self.chunks = [reply[:20], reply[20:]]

    def recv(self, size):
        return self.chunks.pop(0) if self.chunks else b""


@pytest.fixture
def podman_api(exporter, monkeypatch):
    FakeSocket.responses = {}
    FakeSocket.connected_to = []
    monkeypatch.setattr(exporter.socket, "socket", FakeSocket)
    return FakeSocket.responses


def test_podman_get_reads_the_json_body(exporter, podman_api):
    podman_api["/v4.0.0/info"] = {"ok": True}
    assert exporter.podman_get("/v4.0.0/info") == {"ok": True}
    assert FakeSocket.connected_to == [exporter.SOCK_PATH]


def test_build_metrics(exporter, podman_api):
    listing = "/v4.0.0/libpod/containers/json?all=false"
    podman_api[listing] = [
        {"Id": "aaaa", "Names": ["/sonarr"]},
        {"Id": "bbbbbbbbbbbbbbbb", "Names": []},
        {"Id": "cccc", "Names": ["broken"]},
        {"Id": "dddd", "Names": ["unlimited"]},
    ]
    podman_api["/v4.0.0/libpod/containers/aaaa/json"] = {
        "HostConfig": {"NanoCpus": 1_500_000_000, "PidsLimit": 512}
    }
    podman_api["/v4.0.0/libpod/containers/bbbbbbbbbbbbbbbb/json"] = {
        "HostConfig": {"NanoCpus": 250_000_000, "PidsLimit": 0}
    }
    podman_api["/v4.0.0/libpod/containers/cccc/json"] = OSError("gone")
    podman_api["/v4.0.0/libpod/containers/dddd/json"] = {}
    body = exporter.build_metrics().decode()
    assert body.endswith("\n")
    lines = body.splitlines()
    assert 'podman_container_cpu_limit_vcpus{name="sonarr"} 1.5000' in lines
    assert 'podman_container_cpu_limit_vcpus{name="bbbbbbbbbbbb"} 0.2500' in lines
    assert 'podman_container_cpu_limit_vcpus{name="broken"} 0.0000' in lines
    assert 'podman_container_cpu_limit_vcpus{name="unlimited"} 0.0000' in lines
    assert 'podman_container_pids_limit{name="sonarr"} 512' in lines
    assert 'podman_container_pids_limit{name="broken"} 0' in lines
    assert "# TYPE podman_container_pids_limit gauge" in lines


def test_get_metrics_caches_for_the_ttl(exporter, monkeypatch):
    calls = []

    def build():
        calls.append(1)
        return f"body {len(calls)}".encode()

    clock = iter([1000.0, 1010.0, 1031.0])
    monkeypatch.setattr(exporter, "build_metrics", build)
    monkeypatch.setattr(exporter.time, "monotonic", lambda: next(clock))
    assert exporter.get_metrics() == b"body 1"
    assert exporter.get_metrics() == b"body 1"
    assert exporter.get_metrics() == b"body 2"


@pytest.fixture
def server(exporter):
    httpd = HTTPServer(("127.0.0.1", 0), exporter.Handler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    yield httpd.server_address[1]
    httpd.shutdown()
    httpd.server_close()


def _get(port, path):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        conn.request("GET", path)
        response = conn.getresponse()
        return response.status, dict(response.getheaders()), response.read()
    finally:
        conn.close()


def test_handler_serves_metrics(exporter, server, monkeypatch):
    monkeypatch.setattr(exporter, "get_metrics", lambda: b"metric 1\n")
    status, headers, body = _get(server, "/metrics")
    assert status == 200
    assert headers["Content-Type"].startswith("text/plain; version=0.0.4")
    assert headers["Content-Length"] == "9"
    assert body == b"metric 1\n"


def test_handler_refuses_other_paths(server):
    status, _, _ = _get(server, "/")
    assert status == 404


def test_handler_reports_a_failed_scrape(exporter, server, monkeypatch):
    def fail():
        raise RuntimeError("socket missing")

    monkeypatch.setattr(exporter, "get_metrics", fail)
    status, _, body = _get(server, "/metrics")
    assert status == 500
    assert body == b"socket missing"


def test_main_serves_on_the_port_and_exits_cleanly_on_a_signal(
    exporter, monkeypatch, capsys
):
    handlers = {}
    served = []

    class StubServer:
        def __init__(self, address, handler):
            served.append((address, handler))

        def serve_forever(self):
            served.append("serving")

    monkeypatch.setattr(
        exporter.signal, "signal", lambda sig, fn: handlers.update({sig: fn})
    )
    monkeypatch.setattr(exporter, "HTTPServer", StubServer)
    exporter.main()
    # What the exporter binds, asserted rather than bound: it listens on every
    # interface inside its own container on purpose.
    assert served == [(("0.0.0.0", 9889), exporter.Handler), "serving"]  # nosec B104
    assert "Serving on :9889/metrics" in capsys.readouterr().out
    assert handlers.keys() == {signal.SIGINT, signal.SIGTERM}
    with pytest.raises(SystemExit) as exit_info:
        handlers[signal.SIGTERM](signal.SIGTERM, None)
    assert exit_info.value.code == 0
