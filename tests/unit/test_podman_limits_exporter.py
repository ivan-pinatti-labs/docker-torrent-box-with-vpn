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


class Status:
    """A non-200 answer: the status line and the JSON body Podman sends with it."""

    def __init__(self, line: bytes, body: object):
        self.line, self.body = line, body


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
        status = b"200 OK"
        if isinstance(answer, Status):
            status, answer = answer.line, answer.body
        body = json.dumps(answer).encode()
        reply = (
            b"HTTP/1.0 " + status + b"\r\nContent-Type: application/json\r\n\r\n" + body
        )
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


def test_podman_get_refuses_an_error_status(exporter, podman_api):
    """A container removed since the listing answers 404 with a JSON body."""
    path = "/v4.0.0/libpod/containers/gone/json"
    podman_api[path] = Status(b"404 Not Found", {"cause": "no such container"})
    with pytest.raises(OSError, match="404 Not Found"):
        exporter.podman_get(path)


def test_podman_get_refuses_a_reply_without_a_status(exporter, monkeypatch):
    class Silent(FakeSocket):
        def sendall(self, data):
            self.chunks = []

    monkeypatch.setattr(exporter.socket, "socket", Silent)
    with pytest.raises(OSError):
        exporter.podman_get("/v4.0.0/info")


def test_build_metrics_leaves_out_a_container_removed_since_the_listing(
    exporter, podman_api
):
    podman_api["/v4.0.0/libpod/containers/json?all=false"] = [
        {"Id": "gone", "Names": ["gone"]}
    ]
    podman_api["/v4.0.0/libpod/containers/gone/json"] = Status(
        b"404 Not Found", {"cause": "no such container"}
    )
    body, complete = exporter.build_metrics()
    assert b'name="gone"' not in body
    assert complete is False


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
    body, complete = exporter.build_metrics()
    body = body.decode()
    assert body.endswith("\n")
    lines = body.splitlines()
    assert 'podman_container_cpu_limit_vcpus{name="sonarr"} 1.5000' in lines
    assert 'podman_container_cpu_limit_vcpus{name="bbbbbbbbbbbb"} 0.2500' in lines
    assert 'podman_container_cpu_limit_vcpus{name="unlimited"} 0.0000' in lines
    assert 'podman_container_pids_limit{name="sonarr"} 512' in lines
    assert "# TYPE podman_container_pids_limit gauge" in lines
    # A failed lookup leaves the container out rather than reporting 0, which
    # the gauges use for "unlimited", and marks the body incomplete.
    assert not [line for line in lines if 'name="broken"' in line]
    assert complete is False


def test_build_metrics_is_complete_when_every_lookup_succeeds(exporter, podman_api):
    podman_api["/v4.0.0/libpod/containers/json?all=false"] = [
        {"Id": "aaaa", "Names": ["sonarr"]}
    ]
    podman_api["/v4.0.0/libpod/containers/aaaa/json"] = {}
    _, complete = exporter.build_metrics()
    assert complete is True


USER_SERVICE = "/user.slice/user-1000.slice/user@1000.service"


@pytest.mark.parametrize(
    "path",
    [
        # systemd, as on a desktop host
        f"{USER_SERVICE}/user.slice/libpod-aaaa.scope/container",
        # cgroupfs, as in CI's nested runner
        "/user/3d6eaf152c7d",
    ],
)
def test_cgroup_dir_maps_the_path_under_the_mounted_root(exporter, path):
    expected = exporter.CGROUP_ROOT.joinpath(*path.strip("/").split("/"))
    assert exporter.cgroup_dir(path) == expected


def test_cgroup_dir_refuses_no_path_and_a_way_out(exporter):
    assert exporter.cgroup_dir("") is None
    assert exporter.cgroup_dir("/user/../../etc") is None


def test_read_swap(exporter, tmp_path):
    (tmp_path / "memory.swap.current").write_text("4096\n")
    (tmp_path / "memory.swap.max").write_text("1073741824\n")
    assert exporter.read_swap(tmp_path) == (4096, 1073741824)
    (tmp_path / "memory.swap.max").write_text("max\n")
    assert exporter.read_swap(tmp_path) == (4096, None)
    (tmp_path / "memory.swap.current").unlink()
    assert exporter.read_swap(tmp_path) == (None, None)
    assert exporter.read_swap(None) == (None, None)


def test_build_metrics_reads_swap_from_the_cgroup(
    exporter, podman_api, tmp_path, monkeypatch
):
    monkeypatch.setattr(exporter, "CGROUP_ROOT", tmp_path)
    scope = tmp_path / "user" / "aaaa"
    scope.mkdir(parents=True)
    (scope / "memory.swap.current").write_text("2048\n")
    (scope / "memory.swap.max").write_text("536870912\n")
    podman_api["/v4.0.0/libpod/containers/json?all=false"] = [
        {"Id": "aaaa", "Names": ["sonarr"]},
        {"Id": "bbbb", "Names": ["gone"]},
    ]
    podman_api["/v4.0.0/libpod/containers/aaaa/json"] = {
        "State": {"CgroupPath": "/user/aaaa"}
    }
    # Its cgroup is not there (stopped between the listing and the read).
    podman_api["/v4.0.0/libpod/containers/bbbb/json"] = {
        "State": {"CgroupPath": "/user/bbbb"}
    }
    lines = exporter.build_metrics()[0].decode().splitlines()
    assert 'podman_container_swap_usage_bytes{name="sonarr"} 2048' in lines
    assert 'podman_container_swap_limit_bytes{name="sonarr"} 536870912' in lines
    assert not [line for line in lines if 'name="gone"' in line and "swap" in line]
    assert "# TYPE podman_container_swap_usage_bytes gauge" in lines


def test_get_metrics_caches_for_the_ttl(exporter, monkeypatch):
    calls = []

    def build():
        calls.append(1)
        return f"body {len(calls)}".encode(), True

    clock = iter([1000.0, 1010.0, 1031.0])
    monkeypatch.setattr(exporter, "build_metrics", build)
    monkeypatch.setattr(exporter.time, "monotonic", lambda: next(clock))
    assert exporter.get_metrics() == b"body 1"
    assert exporter.get_metrics() == b"body 1"
    assert exporter.get_metrics() == b"body 2"


def test_get_metrics_does_not_cache_an_incomplete_body(exporter, monkeypatch):
    """After a failed lookup the next scrape asks Podman again, rather than
    serving the gap for the rest of the TTL."""
    bodies = iter([(b"partial", False), (b"whole", True)])
    clock = iter([2000.0, 2001.0, 2002.0])
    monkeypatch.setattr(exporter, "_cache", {"body": b"", "ts": 0.0})
    monkeypatch.setattr(exporter, "build_metrics", lambda: next(bodies))
    monkeypatch.setattr(exporter.time, "monotonic", lambda: next(clock))
    assert exporter.get_metrics() == b"partial"
    assert exporter.get_metrics() == b"whole"
    assert exporter.get_metrics() == b"whole"


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
