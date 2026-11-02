"""Keep the Email contact point's message plain text.

Grafana's alert email template (public/emails/ng_alert_notification.html)
splits the contact point's `message` on newlines and renders each line through
Go's html/template followed by its own <br>, so every line is HTML escaped.
Tags written into the message arrive in the email as literal text, which is
what issue #375 reported. Nothing else reads this field before an alert
actually fires, so this is the only check that catches a regression.
"""

import re
from pathlib import Path

import pytest
import yaml

pytestmark = pytest.mark.unit

CONTACT_POINTS = (
    Path(__file__).resolve().parents[2]
    / "configs/grafana/config/provisioning/alerting/contact-points.yaml"
)
HTML_TAG = re.compile(r"</?\s*[A-Za-z][A-Za-z0-9]*\b[^>]*>")


def _email_message() -> str:
    doc = yaml.safe_load(CONTACT_POINTS.read_text())
    for point in doc["contactPoints"]:
        for receiver in point["receivers"]:
            if receiver["uid"] == "email-receiver":
                return receiver["settings"]["message"]
    pytest.fail(f"no email-receiver in {CONTACT_POINTS}")


def test_email_message_has_no_html_tags():
    tags = HTML_TAG.findall(_email_message())
    assert not tags, (
        f"email-receiver's message in {CONTACT_POINTS.name} contains HTML "
        f"{tags}; Grafana escapes it, so recipients see the tags as text"
    )
