#!/usr/bin/env python3
"""Exercise Mailpit's SMTP, HTTP, and POP3 user-facing protocols."""

from __future__ import annotations

import argparse
import email.message
import email.policy
import email.parser
import json
import os
import poplib
import smtplib
import sys
import time
import urllib.error
import urllib.request


class SmokeError(RuntimeError):
    """A Mailpit protocol or lifecycle contract was not satisfied."""


def _url_host(host: str) -> str:
    if ":" in host and not host.startswith("["):
        return f"[{host}]"
    return host


def _url(host: str, port: int, path: str) -> str:
    return f"http://{_url_host(host)}:{port}{path}"


def _canonical_message_id(value: str) -> str:
    return value.strip().removeprefix("<").removesuffix(">").strip()


def _http_json(host: str, port: int) -> dict:
    request = urllib.request.Request(_url(host, port, "/api/v1/messages"))
    try:
        with urllib.request.urlopen(request, timeout=3) as response:
            if response.status != 200:
                raise SmokeError(f"Mailpit API returned HTTP {response.status}")
            try:
                value = json.loads(response.read().decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise SmokeError("Mailpit API returned invalid JSON") from error
    except urllib.error.HTTPError as error:
        raise SmokeError(f"Mailpit API returned HTTP {error.code}") from error
    except urllib.error.URLError as error:
        raise SmokeError(f"Mailpit API is unavailable: {error.reason}") from error
    if not isinstance(value, dict):
        raise SmokeError("Mailpit API response is not an object")
    return value


def _wait_ready(host: str, http_port: int, timeout: float) -> dict:
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        try:
            request = urllib.request.Request(_url(host, http_port, "/"))
            with urllib.request.urlopen(request, timeout=3) as response:
                if response.status != 200:
                    raise SmokeError(f"Mailpit UI returned HTTP {response.status}")
                response.read(1)
            return _http_json(host, http_port)
        except (SmokeError, OSError, urllib.error.URLError) as error:
            last_error = error
            time.sleep(0.25)
    detail = f": {last_error}" if last_error else ""
    raise SmokeError(f"Mailpit UI/API did not become ready{detail}")


def _message_present(payload: dict, message_id: str) -> bool:
    expected = _canonical_message_id(message_id)
    messages = payload.get("messages")
    if not isinstance(messages, list):
        raise SmokeError("Mailpit API response has no messages array")
    return any(
        isinstance(item, dict)
        and _canonical_message_id(str(item.get("MessageID", ""))) == expected
        for item in messages
    )


def _send_smtp(host: str, smtp_port: int, message_id: str) -> None:
    header_message_id = message_id.strip()
    if not header_message_id.startswith("<"):
        header_message_id = f"<{header_message_id}>"
    message = email.message.EmailMessage(policy=email.policy.SMTP)
    message["Message-ID"] = header_message_id
    message["From"] = "mailpit-smoke-sender@example.test"
    message["To"] = "mailpit-smoke-recipient@example.test"
    message["Subject"] = "Mailpit functional smoke"
    message.set_content("Mailpit functional smoke message")
    try:
        with smtplib.SMTP(host, smtp_port, timeout=5) as client:
            client.send_message(message)
    except (OSError, smtplib.SMTPException) as error:
        raise SmokeError(f"Mailpit SMTP send failed: {error}") from error


def _pop3_has_message(host: str, pop3_port: int, message_id: str) -> bool:
    expected = _canonical_message_id(message_id)
    try:
        client = poplib.POP3(host, pop3_port, timeout=5)
        try:
            client.user("smoke")
            client.pass_("smoke-password")
            status, listings, _ = client.list()
            if not status.startswith(b"+OK"):
                raise SmokeError("Mailpit POP3 LIST failed")
            for listing in listings:
                try:
                    index = int(listing.split(None, 1)[0])
                except (ValueError, IndexError) as error:
                    raise SmokeError("Mailpit POP3 LIST returned an invalid message") from error
                status, lines, _ = client.retr(index)
                if not status.startswith(b"+OK"):
                    raise SmokeError("Mailpit POP3 RETR failed")
                parsed = email.parser.BytesParser(policy=email.policy.default).parsebytes(
                    b"\r\n".join(lines)
                )
                if _canonical_message_id(parsed.get("Message-ID", "")) == expected:
                    return True
            return False
        finally:
            try:
                client.quit()
            except poplib.error_proto:
                client.close()
    except SmokeError:
        raise
    except (OSError, poplib.error_proto) as error:
        text = str(error)
        if "authentication" in text.lower() or "auth" in text.lower():
            raise SmokeError(f"Mailpit POP3 authentication failed: {error}") from error
        raise SmokeError(f"Mailpit POP3 check failed: {error}") from error


def run(host: str, http_port: int, smtp_port: int, pop3_port: int, message_id: str) -> None:
    if not _canonical_message_id(message_id):
        raise SmokeError("MESSAGE_ID must not be empty")
    timeout = float(os.environ.get("MAILPIT_SMOKE_TIMEOUT", "45"))
    require_existing = os.environ.get("MAILPIT_SMOKE_REQUIRE_EXISTING") == "1"
    payload = _wait_ready(host, http_port, timeout)

    if not _message_present(payload, message_id):
        if require_existing:
            raise SmokeError(
                f"Mailpit message {message_id} is missing before persistence protocol checks"
            )
        _send_smtp(host, smtp_port, message_id)

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        payload = _http_json(host, http_port)
        if _message_present(payload, message_id) and _pop3_has_message(host, pop3_port, message_id):
            print(f"Mailpit smoke passed for Message-ID {message_id}")
            return
        time.sleep(0.25)
    raise SmokeError(f"Mailpit message {message_id} was not retrievable over HTTP and POP3")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host")
    parser.add_argument("http_port", type=int)
    parser.add_argument("smtp_port", type=int)
    parser.add_argument("pop3_port", type=int)
    parser.add_argument("message_id")
    args = parser.parse_args()
    try:
        run(args.host, args.http_port, args.smtp_port, args.pop3_port, args.message_id)
    except (SmokeError, ValueError) as error:
        print(f"mailpit smoke failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
