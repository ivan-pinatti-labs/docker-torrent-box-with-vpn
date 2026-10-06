"""TLS certificate checks: failures emit warnings, never hard failures.

Self-signed certs are common in this stack. These tests warn so operators
know about expiry or weak TLS without blocking CI on cert issues.
"""

import datetime
import socket
import ssl
import warnings

import pytest
import urllib3

from conftest import REPO_ROOT, env, skip_if_not_running

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

pytestmark = pytest.mark.tls

HOST = env("DOMAIN", "localhost")
HTTPS_PORT = int(env("NGINX_HTTPS_PORT", "443"))
EXPIRY_WARN_DAYS = 30
CERT_FILE = REPO_ROOT / "certs" / "server.crt"


def _get_cert(host: str, port: int) -> dict | None:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    # CERT_NONE skips certificate parsing entirely, so getpeercert() always
    # returns {} regardless of the real certificate's state. Trust the
    # stack's own self-signed cert directly (it can verify itself) so
    # verification actually succeeds and getpeercert() returns the parsed
    # fields instead of permanently no-op'ing these checks.
    try:
        ctx.load_verify_locations(cafile=str(CERT_FILE))
        ctx.verify_mode = ssl.CERT_REQUIRED
    except FileNotFoundError, ssl.SSLError:
        ctx.verify_mode = ssl.CERT_NONE
    try:
        with socket.create_connection((host, port), timeout=5) as raw:
            with ctx.wrap_socket(raw, server_hostname=host) as conn:
                return conn.getpeercert()
    except OSError, ssl.SSLError:
        return None


def _get_tls_version(host: str, port: int) -> str | None:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with socket.create_connection((host, port), timeout=5) as raw:
            with ctx.wrap_socket(raw, server_hostname=host) as conn:
                return conn.version()
    except OSError:
        return None


def test_tls_handshake_succeeds(running_containers):
    """TLS handshake must complete (self-signed certs are fine)."""
    skip_if_not_running("nginx", running_containers)
    version = _get_tls_version(HOST, HTTPS_PORT)
    assert version is not None, (
        f"TLS handshake to {HOST}:{HTTPS_PORT} failed: is nginx running and cert generated?"
    )


def test_tls_minimum_version(running_containers):
    """TLS version must be 1.2 or higher."""
    skip_if_not_running("nginx", running_containers)
    version = _get_tls_version(HOST, HTTPS_PORT)
    if version is None:
        pytest.skip("TLS handshake failed: cannot check version")
    assert version in ("TLSv1.2", "TLSv1.3"), (
        f"TLS version '{version}' is below minimum TLSv1.2"
    )


def test_certificate_not_expired(running_containers):
    """Warn (not fail) if the certificate is expired or expiring soon."""
    skip_if_not_running("nginx", running_containers)
    cert = _get_cert(HOST, HTTPS_PORT)
    if not cert:
        pytest.skip("Could not retrieve certificate")

    not_after_str = cert.get("notAfter")
    if not not_after_str:
        warnings.warn(
            f"Certificate at {HOST}:{HTTPS_PORT} has no notAfter field",
            UserWarning,
            stacklevel=2,
        )
        return

    not_after = datetime.datetime.strptime(not_after_str, "%b %d %H:%M:%S %Y %Z")
    now = datetime.datetime.now(datetime.UTC).replace(tzinfo=None)
    days_remaining = (not_after - now).days

    subject = dict(x[0] for x in cert.get("subject", []))
    issuer = dict(x[0] for x in cert.get("issuer", []))

    if days_remaining < 0:
        warnings.warn(
            f"Certificate EXPIRED {-days_remaining} days ago. "
            f"Subject={subject.get('commonName', '?')} Issuer={issuer.get('commonName', '?')} "
            f"Expired={not_after_str}",
            UserWarning,
            stacklevel=2,
        )
    elif days_remaining < EXPIRY_WARN_DAYS:
        warnings.warn(
            f"Certificate expires in {days_remaining} days. "
            f"Subject={subject.get('commonName', '?')} Issuer={issuer.get('commonName', '?')} "
            f"Expires={not_after_str}",
            UserWarning,
            stacklevel=2,
        )


def test_certificate_subject_logged(running_containers):
    """Log cert details for visibility, always passes."""
    skip_if_not_running("nginx", running_containers)
    cert = _get_cert(HOST, HTTPS_PORT)
    if not cert:
        pytest.skip("Could not retrieve certificate")
    subject = dict(x[0] for x in cert.get("subject", []))
    issuer = dict(x[0] for x in cert.get("issuer", []))
    not_after = cert.get("notAfter", "?")
    print(f"\nCert subject={subject} issuer={issuer} expires={not_after}")
