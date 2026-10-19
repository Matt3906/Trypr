"""Outgoing email. DigitalOcean blocks SMTP, so production sends through the Gmail API (HTTPS/443)."""

from __future__ import annotations

import asyncio
import base64
import logging
import time
from email.message import EmailMessage
from email.utils import formataddr

import httpx

from app.core.config import get_settings

settings = get_settings()
logger = logging.getLogger(__name__)

_OAUTH_TOKEN_URL = "https://oauth2.googleapis.com/token"
_GMAIL_SEND_URL = "https://gmail.googleapis.com/gmail/v1/users/me/messages/send"

_token_lock = asyncio.Lock()
_access_token: str | None = None
_access_token_expires_at = 0.0


class EmailDeliveryError(RuntimeError):
    pass


async def _access(force: bool = False) -> str:
    global _access_token, _access_token_expires_at
    if not (settings.gmail_client_id and settings.gmail_client_secret and settings.gmail_refresh_token):
        raise EmailDeliveryError("EMAIL_PROVIDER=gmail_api but GMAIL_CLIENT_ID/SECRET/REFRESH_TOKEN are not all set")
    async with _token_lock:
        if not force and _access_token and time.monotonic() < _access_token_expires_at:
            return _access_token
        async with httpx.AsyncClient(timeout=20) as client:
            resp = await client.post(
                _OAUTH_TOKEN_URL,
                data={
                    "client_id": settings.gmail_client_id,
                    "client_secret": settings.gmail_client_secret,
                    "refresh_token": settings.gmail_refresh_token,
                    "grant_type": "refresh_token",
                },
            )
        if resp.status_code != 200:
            raise EmailDeliveryError(f"Google OAuth rejected the refresh token ({resp.status_code}): {resp.text[:200]}")
        payload = resp.json()
        _access_token = payload["access_token"]
        _access_token_expires_at = time.monotonic() + max(float(payload.get("expires_in", 3600)) - 60, 30)
        return _access_token


async def send_email(*, to_email: str, subject: str, body_text: str, body_html: str | None = None) -> None:
    if settings.email_provider != "gmail_api":
        # Dev/default: no provider configured — log so the link is still reachable locally.
        logger.warning("EMAIL_PROVIDER=%s; not sending. To=%s Subject=%s\n%s",
                       settings.email_provider, to_email, subject, body_text)
        return

    msg = EmailMessage()
    msg["From"] = formataddr((settings.sender_name, settings.sender_address))
    msg["To"] = to_email
    msg["Subject"] = subject
    msg.set_content(body_text)
    if body_html:
        msg.add_alternative(body_html, subtype="html")
    raw = base64.urlsafe_b64encode(msg.as_bytes()).decode("ascii")

    for attempt in (1, 2):
        token = await _access(force=attempt == 2)
        async with httpx.AsyncClient(timeout=30) as client:
            resp = await client.post(_GMAIL_SEND_URL, headers={"Authorization": f"Bearer {token}"}, json={"raw": raw})
        if resp.status_code == 200:
            return
        if resp.status_code == 401 and attempt == 1:
            continue
        raise EmailDeliveryError(f"Gmail API rejected the message ({resp.status_code}): {resp.text[:200]}")
