from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Any, Mapping
from uuid import uuid4

from fastapi import BackgroundTasks
from jinja2 import Environment, FileSystemLoader, select_autoescape
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.database import AsyncSessionLocal
from app.core.email import EmailDeliveryError, send_email
from app.models.db_models import RefPortalAssociation, RefPortalMail, RefPortalUser


settings = get_settings()


class RefNotificationTemplate(str, Enum):
    GAME_CONFIRMATION_REQUIRED = "game_confirmation_required"
    BOOKING_UPDATE = "booking_update"
    GAME_REMINDER_24H = "game_reminder_24h"
    GAME_REMINDER_6H = "game_reminder_6h"
    BROADCAST_GROUP_MESSAGE = "broadcast_group_message"


_TEMPLATE_FILE = {
    RefNotificationTemplate.GAME_CONFIRMATION_REQUIRED: "email/game_confirmation_required.html",
    RefNotificationTemplate.BOOKING_UPDATE: "email/booking_update.html",
    RefNotificationTemplate.GAME_REMINDER_24H: "email/game_reminder_24h.html",
    RefNotificationTemplate.GAME_REMINDER_6H: "email/game_reminder_6h.html",
    RefNotificationTemplate.BROADCAST_GROUP_MESSAGE: "email/broadcast_group_message.html",
}

_TEMPLATE_HEADING = {
    RefNotificationTemplate.GAME_CONFIRMATION_REQUIRED: "Game Assignment Approval Required",
    RefNotificationTemplate.BOOKING_UPDATE: "Game Booking Update",
    RefNotificationTemplate.GAME_REMINDER_24H: "Game Reminder (3 Days)",
    RefNotificationTemplate.GAME_REMINDER_6H: "Game Reminder (Today)",
    RefNotificationTemplate.BROADCAST_GROUP_MESSAGE: "Association Broadcast",
}


_TEMPLATE_ROOT = Path(__file__).resolve().parent.parent / "templates"
_JINJA = Environment(
    loader=FileSystemLoader(str(_TEMPLATE_ROOT)),
    autoescape=select_autoescape(("html", "xml")),
    trim_blocks=True,
    lstrip_blocks=True,
)


@dataclass(slots=True)
class _NotificationEnvelope:
    mail_id: str
    recipient_email: str
    recipient_uid: str
    subject: str
    body_text: str
    body_html: str
    template: str
    association_id: str | None
    game_id: str | None
    assignment_id: str | None
    actor_uid: str | None
    sender_name: str | None
    context: dict[str, Any]


def _fallback_display_name(recipient: RefPortalUser) -> str:
    if recipient.display_name and recipient.display_name.strip():
        return recipient.display_name.strip()
    if recipient.email and "@" in recipient.email:
        return recipient.email.split("@", maxsplit=1)[0]
    return recipient.user_id


def _render_html(
    template_name: RefNotificationTemplate,
    *,
    subject: str,
    context: Mapping[str, Any],
) -> str:
    template = _JINJA.get_template(_TEMPLATE_FILE[template_name])
    payload = dict(context)
    payload.setdefault("heading", _TEMPLATE_HEADING[template_name])
    payload.setdefault("subject", subject)
    return template.render(**payload)


def _html_to_text(content: str) -> str:
    text = re.sub(r"(?is)<style.*?>.*?</style>", " ", content)
    text = re.sub(r"(?is)<script.*?>.*?</script>", " ", text)
    text = re.sub(r"(?is)<br\\s*/?>", "\\n", text)
    text = re.sub(r"(?is)</p>", "\\n\\n", text)
    text = re.sub(r"(?is)<[^>]+>", " ", text)
    text = re.sub(r"[ \\t]+", " ", text)
    text = re.sub(r"\\n\\s+", "\\n", text)
    text = re.sub(r"\\n{3,}", "\\n\\n", text)
    return text.strip()


async def _deliver_and_audit(envelope: _NotificationEnvelope) -> None:
    now = datetime.now(timezone.utc)
    sent_at: datetime | None = None
    delivery_status = "sent"
    error_message: str | None = None

    try:
        await send_email(
            to_email=envelope.recipient_email,
            subject=envelope.subject,
            body_text=envelope.body_text,
            body_html=envelope.body_html,
            sender_name=envelope.sender_name,
        )
        sent_at = datetime.now(timezone.utc)
    except EmailDeliveryError as exc:
        delivery_status = "failed"
        error_message = str(exc)
    finally:
        async with AsyncSessionLocal() as db:
            audit = RefPortalMail(
                mail_id=envelope.mail_id,
                recipient_email=envelope.recipient_email,
                subject=envelope.subject,
                sent_at=sent_at,
                created_at=now,
                raw_data={
                    "status": delivery_status,
                    "template": envelope.template,
                    "recipient_uid": envelope.recipient_uid,
                    "association_id": envelope.association_id,
                    "game_id": envelope.game_id,
                    "assignment_id": envelope.assignment_id,
                    "actor_uid": envelope.actor_uid,
                    "error": error_message,
                    "context": envelope.context,
                },
            )
            db.add(audit)
            await db.commit()


async def send_ref_notification(
    *,
    background_tasks: BackgroundTasks,
    db: AsyncSession,
    recipient_uid: str,
    template: RefNotificationTemplate,
    subject: str,
    context: Mapping[str, Any] | None = None,
    association_id: str | None = None,
    game_id: str | None = None,
    assignment_id: str | None = None,
    actor_uid: str | None = None,
) -> str:
    recipient = await db.scalar(
        select(RefPortalUser).where(RefPortalUser.user_id == recipient_uid)
    )
    if not recipient:
        raise ValueError(f"Ref portal user not found: {recipient_uid}")
    if not recipient.email:
        raise ValueError(f"Ref portal user has no email: {recipient_uid}")

    merged_context = dict(context or {})
    merged_context.setdefault("recipient_name", _fallback_display_name(recipient))
    merged_context.setdefault("recipient_email", recipient.email)
    merged_context.setdefault("logo_url", f"{settings.frontend_base_url.rstrip('/')}/RefeyLogo.jpeg")

    sender_name = "Refey Assigner"

    if association_id:
        association = await db.scalar(
            select(RefPortalAssociation).where(RefPortalAssociation.association_id == association_id)
        )
        if association:
            merged_context.setdefault("association_name", association.name)
            if association.name:
                sender_name = f"{association.name} Assigner"

    body_html = _render_html(template, subject=subject, context=merged_context)
    body_text = _html_to_text(body_html)

    mail_id = str(uuid4())
    envelope = _NotificationEnvelope(
        mail_id=mail_id,
        recipient_email=recipient.email,
        recipient_uid=recipient_uid,
        subject=subject,
        body_text=body_text,
        body_html=body_html,
        template=template.value,
        association_id=association_id,
        game_id=game_id,
        assignment_id=assignment_id,
        actor_uid=actor_uid,
        sender_name=sender_name,
        context=merged_context,
    )
    background_tasks.add_task(_deliver_and_audit, envelope)
    return mail_id


async def send_portal_email(
    *,
    background_tasks: BackgroundTasks,
    recipient_email: str,
    subject: str,
    body_html: str,
    body_text: str | None = None,
    template: str = "custom",
    recipient_uid: str | None = None,
    association_id: str | None = None,
    game_id: str | None = None,
    assignment_id: str | None = None,
    actor_uid: str | None = None,
    sender_name: str | None = None,
    context: Mapping[str, Any] | None = None,
) -> str:
    if not recipient_email:
        raise ValueError("Recipient email is required")

    mail_id = str(uuid4())
    envelope = _NotificationEnvelope(
        mail_id=mail_id,
        recipient_email=recipient_email,
        recipient_uid=recipient_uid or "",
        subject=subject,
        body_text=body_text or _html_to_text(body_html),
        body_html=body_html,
        template=template,
        association_id=association_id,
        game_id=game_id,
        assignment_id=assignment_id,
        actor_uid=actor_uid,
        sender_name=sender_name,
        context={
            "logo_url": f"{settings.frontend_base_url.rstrip('/')}/RefeyLogo.jpeg",
            **dict(context or {}),
        },
    )
    background_tasks.add_task(_deliver_and_audit, envelope)
    return mail_id
