from __future__ import annotations

import asyncio
import smtplib
from email.message import EmailMessage
from email.utils import formataddr
from pathlib import Path

from app.core.config import get_settings


settings = get_settings()
_REFEY_LOGO_CID = "refey-logo"
_REFEY_LOGO_PATH = Path(__file__).resolve().parent.parent / "assets" / "RefeyLogo.jpeg"


class EmailDeliveryError(RuntimeError):
    """Raised when SMTP delivery fails."""


def _prepare_html_for_inline_logo(body_html: str) -> tuple[str, bytes | None]:
    if "RefeyLogo.jpeg" not in body_html:
        return body_html, None

    if not _REFEY_LOGO_PATH.exists():
        return body_html, None

    rewritten = body_html.replace(
        f"{settings.frontend_base_url.rstrip('/')}/RefeyLogo.jpeg",
        f"cid:{_REFEY_LOGO_CID}",
    )
    rewritten = rewritten.replace("/RefeyLogo.jpeg", f"cid:{_REFEY_LOGO_CID}")

    try:
        logo_bytes = _REFEY_LOGO_PATH.read_bytes()
    except OSError:
        return body_html, None

    return rewritten, logo_bytes


def _send_sync(
    *,
    to_email: str,
    subject: str,
    body_text: str,
    body_html: str | None = None,
    sender_name: str | None = None,
) -> None:
    if not settings.smtp_host:
        raise EmailDeliveryError("SMTP_HOST is not configured")

    smtp_secret = settings.smtp_api_key or settings.smtp_password
    sender_header = settings.smtp_sender
    if sender_name:
        sender_header = formataddr((sender_name, settings.smtp_sender))

    message = EmailMessage()
    message["From"] = sender_header
    message["To"] = to_email
    message["Subject"] = subject
    message.set_content(body_text)
    if body_html:
        html_body, inline_logo = _prepare_html_for_inline_logo(body_html)
        message.add_alternative(html_body, subtype="html")

        if inline_logo:
            html_part = message.get_body(preferencelist=("html",))
            if html_part is not None:
                html_part.add_related(
                    inline_logo,
                    maintype="image",
                    subtype="jpeg",
                    cid=f"<{_REFEY_LOGO_CID}>",
                    disposition="inline",
                    filename="RefeyLogo.jpeg",
                )

    with smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=10) as smtp:
        smtp.ehlo()

        if settings.smtp_use_starttls:
            smtp.starttls()
            smtp.ehlo()

        if settings.smtp_username and not smtp_secret:
            raise EmailDeliveryError("SMTP_USERNAME is set but no SMTP_API_KEY/SMTP_PASSWORD provided")

        if settings.smtp_username:
            smtp.login(settings.smtp_username, smtp_secret or "")

        smtp.send_message(message)


async def send_email(
    *,
    to_email: str,
    subject: str,
    body_text: str,
    body_html: str | None = None,
    sender_name: str | None = None,
) -> None:
    try:
        await asyncio.to_thread(
            _send_sync,
            to_email=to_email,
            subject=subject,
            body_text=body_text,
            body_html=body_html,
            sender_name=sender_name,
        )
    except Exception as exc:  # noqa: BLE001
        raise EmailDeliveryError(str(exc)) from exc
