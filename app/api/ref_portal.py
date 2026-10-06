from __future__ import annotations

import logging
import secrets
import string
from datetime import datetime, timedelta, timezone
from html import escape
from typing import Any
from urllib.parse import quote
from uuid import uuid4

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query, Request, status
from fastapi.responses import RedirectResponse, Response
from firebase_admin import auth as firebase_auth
from sqlalchemy import and_, func, select, text, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.database import get_db_session
from app.core.dependencies import get_current_principal
from app.core.security import AuthenticatedPrincipal, ensure_firebase_admin

logger = logging.getLogger(__name__)
from app.models.db_models import (
    RefPortalAssociation,
    RefPortalAssignment,
    RefPortalAvailability,
    RefPortalGame,
    RefPortalPickupRequest,
    RefPortalUser,
    TryprUser,
)
from app.models.schemas import (
    APIMessage,
    AssociationCreateRequest,
    AssociationUpdateRequest,
    AssignmentCreateRequest,
    IncidentReportCreateRequest,
    AssignmentResponseRequest,
    AssignmentTriggerRequest,
    AssignmentUpdateRequest,
    AvailabilityLockRequest,
    AvailabilityUpsertRequest,
    GameBatchCreateRequest,
    GameCreateRequest,
    GameUpdateRequest,
    PickupRequestCreateRequest,
    PickupRequestUpdateRequest,
    RefAssociationSchema,
    RefAssignmentSchema,
    RefAvailabilitySchema,
    RefGameSchema,
    RefPickupRequestSchema,
    RefUserSchema,
    RefUserCreateRequest,
    RefUserSelfUpdateRequest,
    RefUserUpdateRequest,
    SupervisionReportCreateRequest,
)
from app.services.notifications import RefNotificationTemplate, send_portal_email, send_ref_notification
from app.services.signed_links import (
    generate_calendar_subscription_token,
    verify_assignment_action_token,
    verify_calendar_subscription_token,
)


router = APIRouter(prefix="/ref-portal", tags=["ref_portal"])
settings = get_settings()


def _can_assign(principal: AuthenticatedPrincipal) -> bool:
    if principal.is_admin:
        return True
    return principal.ref_portal_role in {"admin", "assigner", "supervisor"}


def _scope_association_id(
    principal: AuthenticatedPrincipal,
    requested_association_id: str | None = None,
) -> str:
    if principal.is_admin and requested_association_id:
        return requested_association_id

    if principal.ref_portal_association_id:
        return principal.ref_portal_association_id

    raise HTTPException(
        status_code=status.HTTP_403_FORBIDDEN,
        detail="Association scope required",
    )


_TEMP_PASSWORD_ALPHABET = string.ascii_letters + string.digits

_INVITE_RATE_WINDOW_SECONDS = 60
_INVITE_RATE_MAX = 10
_invite_rate_buckets: dict[str, list[float]] = {}


def _check_invite_rate_limit(actor_uid: str | None) -> None:
    """Sliding-window rate limit: max N invite-style actions per actor per window."""
    if not actor_uid:
        return
    import time

    now = time.monotonic()
    bucket = _invite_rate_buckets.setdefault(actor_uid, [])
    cutoff = now - _INVITE_RATE_WINDOW_SECONDS
    while bucket and bucket[0] < cutoff:
        bucket.pop(0)
    if len(bucket) >= _INVITE_RATE_MAX:
        retry_after = max(1, int(bucket[0] + _INVITE_RATE_WINDOW_SECONDS - now))
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail=f"Too many invites. Try again in {retry_after}s.",
            headers={"Retry-After": str(retry_after)},
        )
    bucket.append(now)


def _generate_temp_password(length: int = 12) -> str:
    return "".join(secrets.choice(_TEMP_PASSWORD_ALPHABET) for _ in range(length))


def _provision_firebase_user(
    *,
    email: str,
    display_name: str | None,
) -> tuple[str, str | None]:
    """Return (firebase_uid, temp_password_or_None).

    Creates a new Firebase auth user with a generated temp password when no
    user with this email exists yet. Returns the existing Firebase UID and
    None for the password when the user already has a Firebase account.
    """
    ensure_firebase_admin()
    try:
        existing = firebase_auth.get_user_by_email(email)
        return existing.uid, None
    except firebase_auth.UserNotFoundError:
        pass
    except Exception as exc:  # pragma: no cover - defensive
        logger.exception("Failed to look up Firebase user by email: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Auth provider unavailable",
        ) from exc

    temp_password = _generate_temp_password()
    try:
        created = firebase_auth.create_user(
            email=email,
            password=temp_password,
            display_name=display_name or None,
            email_verified=False,
        )
    except firebase_auth.EmailAlreadyExistsError:
        # Race: another path created the user between our lookup and create.
        fetched = firebase_auth.get_user_by_email(email)
        return fetched.uid, None
    except Exception as exc:
        logger.exception("Failed to create Firebase user: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Could not create authentication account",
        ) from exc
    return created.uid, temp_password


def _wrap_branded_email_html(
    *,
    association_name: str,
    subject: str,
    inner_html: str,
    logo_url: str | None,
) -> str:
    """Wrap an inner HTML body in the shared Refey branded email shell."""
    safe_association_name = escape(association_name or "Refey")
    safe_subject = escape(subject or "Notification")
    safe_logo_url = escape(logo_url or "")
    logo_tag = (
        f"<img src=\"{safe_logo_url}\" alt=\"Refey\" width=\"64\" height=\"64\" style=\"width:64px;height:64px;"
        "border-radius:15px;object-fit:contain;background:#fff4ec;border:1px solid #fed7aa;"
        "padding:4px;display:block;\" />"
        if safe_logo_url
        else ""
    )
    return (
        "<div style=\"margin:0;padding:24px 12px 36px;background:#f1f5f9;"
        "font-family:'SF Pro Text','Inter','Segoe UI','Helvetica Neue',Arial,sans-serif;color:#0f172a;\">"
        "<div style=\"max-width:640px;margin:0 auto;background:#ffffff;border:1px solid #e2e8f0;"
        "border-radius:16px;overflow:hidden;box-shadow:0 1px 3px rgba(15,23,42,0.08),"
        "0 16px 36px rgba(15,23,42,0.08);\">"
        "<div style=\"height:8px;background:#f47c20;\"></div>"
        "<div style=\"padding:22px 24px 18px;border-bottom:1px solid #f1f5f9;\">"
        "<table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\" style=\"border-collapse:collapse;margin:0 0 22px;\">"
        "<tr><td style=\"vertical-align:middle;padding:0 30px 0 0;\">"
        f"{logo_tag}"
        "</td><td style=\"vertical-align:middle;padding:0;\">"
        f"<p style=\"margin:0;color:#0f172a;font-size:17px;font-weight:800;line-height:1.2;\">{safe_association_name}</p>"
        "<p style=\"margin:3px 0 0;color:#64748b;font-size:12px;font-weight:700;letter-spacing:0.04em;"
        "text-transform:uppercase;\">Refey Portal</p>"
        "</td></tr></table>"
        "<p style=\"margin:0 0 8px;color:#f47c20;font-size:12px;font-weight:800;letter-spacing:0.04em;"
        "text-transform:uppercase;\">Association Invite</p>"
        f"<h1 style=\"margin:0;color:#0f172a;font-size:28px;line-height:1.18;font-weight:800;"
        f"letter-spacing:-0.01em;\">{safe_subject}</h1>"
        "</div>"
        f"<div style=\"padding:24px;font-size:16px;line-height:1.65;color:#334155;\">{inner_html}</div>"
        "<div style=\"padding:16px 24px 20px;background:#f8fafc;border-top:1px solid #e2e8f0;\">"
        f"<p style=\"margin:0;color:#475569;font-size:12px;font-weight:800;text-transform:uppercase;"
        f"letter-spacing:0.05em;\">{safe_association_name}</p>"
        "<p style=\"margin:5px 0 0;color:#94a3b8;font-size:12px;line-height:1.5;\">"
        "This email was sent through Refey.</p>"
        "</div>"
        "</div>"
        "</div>"
    )


def _build_invite_email(
    *,
    display_name: str,
    association_name: str,
    email: str,
    temp_password: str | None,
    login_url: str,
) -> tuple[str, str]:
    """Return (subject, inner_html) for the association invite email."""
    greeting = escape(display_name or "there")
    safe_association_name = escape(association_name or "your association")
    safe_email = escape(email)
    safe_login_url = escape(login_url)
    if temp_password:
        subject = f"You're invited to {association_name}"
        safe_temp_password = escape(temp_password)
        credentials_block = (
            "<p style=\"margin:0 0 16px;\">Sign in with the credentials below. The first time you log in, "
            "you'll choose a new password and finish your profile.</p>"
            "<div style=\"background:#f8fafc;border:1px solid #e2e8f0;border-radius:14px;padding:16px;margin:16px 0;\">"
            "<p style=\"margin:0 0 10px;color:#64748b;font-size:12px;font-weight:800;letter-spacing:0.04em;"
            "text-transform:uppercase;\">Your Login Details</p>"
            "<table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\" style=\"border-collapse:collapse;width:100%;\">"
            "<tr><td style=\"padding:6px 16px 6px 0;color:#64748b;font-weight:700;width:150px;\">Email</td>"
            f"<td style=\"padding:6px 0;color:#0f172a;font-weight:700;\">{safe_email}</td></tr>"
            "<tr><td style=\"padding:6px 16px 6px 0;color:#64748b;font-weight:700;width:150px;\">Temporary password</td>"
            f"<td style=\"padding:6px 0;\"><code style=\"background:#fff4ec;border:1px solid #fed7aa;color:#9a3412;"
            f"padding:5px 10px;border-radius:8px;font-size:15px;font-weight:800;\">{safe_temp_password}</code></td></tr>"
            "</table></div>"
            "<p style=\"margin:0;color:#64748b;font-size:14px;\">This temporary password is for first sign-in only.</p>"
        )
        action_label = "Finish Account Setup"
    else:
        subject = f"You've been added to {association_name}"
        credentials_block = (
            f"<p style=\"margin:0 0 16px;\">Sign in with your existing Refey account "
            f"(<strong>{safe_email}</strong>) to access your games and schedule for this association.</p>"
        )
        action_label = "Sign In to Refey"

    inner_html = (
        f"<p style=\"margin:0 0 10px;font-weight:700;color:#0f172a;\">Hi {greeting},</p>"
        f"<p style=\"margin:0 0 16px;\">You have been invited to join <strong>{safe_association_name}</strong> on Refey.</p>"
        f"{credentials_block}"
        "<p style=\"margin:22px 0 0;\">"
        f"<a href=\"{safe_login_url}\" style=\"display:inline-block;background:#f47c20;color:#ffffff;"
        "text-decoration:none;padding:12px 18px;border-radius:11px;font-weight:800;line-height:1.1;\">"
        f"{action_label}</a>"
        "</p>"
    )
    return subject, inner_html


def _format_report_value(value: Any) -> str:
    return escape(str(value or "").strip())


def _incident_report_html(*, report: dict[str, Any], assignment: RefPortalAssignment, game: RefPortalGame | None) -> str:
    raw = assignment.raw_data or {}
    game_raw = game.raw_data if game else {}
    game_label = raw.get("gameLabel") or (
        f"{game_raw.get('homeTeam') or game_raw.get('home_team') or 'TBD'} vs "
        f"{game_raw.get('awayTeam') or game_raw.get('away_team') or 'TBD'}"
    )
    rows = [
        ("Game", game_label),
        ("Date/time", " ".join([str(raw.get("gameDate") or ""), str(raw.get("gameTime") or "")]).strip()),
        ("Arena", raw.get("arena") or (game.location if game else "")),
        ("Division", raw.get("division") or (game.division if game else "")),
        ("Official", report.get("officialName")),
        ("Role", raw.get("position") or raw.get("notes") or "Official"),
        ("Report type", report.get("reportType")),
        ("Penalty assessed to", report.get("penaltyAssessedTo")),
        ("Player #", report.get("playerNumber")),
        ("Player team", report.get("playerTeam")),
        ("Penalty code", report.get("penaltyCode")),
        ("Infraction", report.get("infraction")),
        ("Period/time", " ".join([str(report.get("period") or ""), str(report.get("time") or "")]).strip()),
        ("Score at time", report.get("scoreAtTime")),
        ("Final score", report.get("finalScore")),
        ("Verbal report made to", report.get("verbalReportTo")),
    ]
    row_html = "".join(
        "<tr>"
        f"<td style=\"padding:6px 14px 6px 0;color:#64748b;font-weight:700;vertical-align:top;\">{escape(label)}</td>"
        f"<td style=\"padding:6px 0;color:#0f172a;vertical-align:top;\">{_format_report_value(value) or '-'}</td>"
        "</tr>"
        for label, value in rows
    )
    return (
        "<p style=\"margin:0 0 14px;\">An official submitted a game incident report.</p>"
        "<div style=\"background:#f8fafc;border:1px solid #e2e8f0;border-radius:14px;padding:14px 16px;margin:14px 0;\">"
        f"<table role=\"presentation\" cellpadding=\"0\" cellspacing=\"0\" style=\"border-collapse:collapse;width:100%;font-size:14px;\">{row_html}</table>"
        "</div>"
        "<p style=\"margin:16px 0 6px;font-weight:800;color:#0f172a;\">Detailed outline</p>"
        f"<div style=\"white-space:pre-wrap;background:#ffffff;border:1px solid #e2e8f0;border-radius:12px;padding:12px;color:#334155;\">{_format_report_value(report.get('details'))}</div>"
        "<p style=\"margin:16px 0 6px;font-weight:800;color:#0f172a;\">Injuries</p>"
        f"<div style=\"white-space:pre-wrap;background:#ffffff;border:1px solid #e2e8f0;border-radius:12px;padding:12px;color:#334155;\">{_format_report_value(report.get('injuries')) or '-'}</div>"
        "<p style=\"margin:16px 0 6px;font-weight:800;color:#0f172a;\">Further problems</p>"
        f"<div style=\"white-space:pre-wrap;background:#ffffff;border:1px solid #e2e8f0;border-radius:12px;padding:12px;color:#334155;\">{_format_report_value(report.get('furtherProblems')) or '-'}</div>"
    )


async def _notify_incident_report(
    *,
    background_tasks: BackgroundTasks,
    db: AsyncSession,
    association: RefPortalAssociation | None,
    assignment: RefPortalAssignment,
    game: RefPortalGame | None,
    report: dict[str, Any],
    actor_uid: str | None,
) -> None:
    association_id = association.association_id if association else ((game.association_id if game else None) or "")
    association_name = (association.name if association and association.name else "Refey")
    recipients = await db.scalars(
        select(RefPortalUser).where(
            RefPortalUser.association_id == association_id,
            RefPortalUser.role == "assigner",
            RefPortalUser.email.is_not(None),
        )
    )
    recipient_rows = list(recipients.all())
    recipient_emails = {
        str(row.email).strip()
        for row in recipient_rows
        if row.email and str(row.email).strip()
    }
    if not recipient_emails:
        logger.warning("No assigner recipients for incident report assignment_id=%s", assignment.assignment_id)
        return

    raw = assignment.raw_data or {}
    subject = f"Incident report submitted: {raw.get('gameLabel') or 'Game'}"
    logo_url = f"{settings.frontend_base_url.rstrip('/')}/RefeyLogo.jpeg"
    body_html = _wrap_branded_email_html(
        association_name=association_name,
        subject=subject,
        inner_html=_incident_report_html(report=report, assignment=assignment, game=game),
        logo_url=logo_url,
    )
    for recipient_email in sorted(recipient_emails):
        await send_portal_email(
            background_tasks=background_tasks,
            recipient_email=recipient_email,
            subject=subject,
            body_html=body_html,
            template="ref_portal.incident_report",
            recipient_uid=None,
            association_id=association_id,
            game_id=assignment.game_id,
            assignment_id=assignment.assignment_id,
            actor_uid=actor_uid,
            sender_name=f"{association_name} Reports",
            context={
                "association_name": association_name,
                "source": "ref_portal.incident_report",
                "report_id": report.get("id"),
            },
        )


async def _send_invite_email(
    *,
    background_tasks: BackgroundTasks,
    association_name: str,
    association_id: str,
    actor_uid: str | None,
    recipient_email: str,
    recipient_uid: str,
    display_name: str,
    temp_password: str | None,
) -> None:
    login_url = f"{settings.frontend_base_url.rstrip('/')}/login"
    logo_url = f"{settings.frontend_base_url.rstrip('/')}/RefeyLogo.jpeg"
    subject, inner_html = _build_invite_email(
        display_name=display_name,
        association_name=association_name,
        email=recipient_email,
        temp_password=temp_password,
        login_url=login_url,
    )
    wrapped = _wrap_branded_email_html(
        association_name=association_name,
        subject=subject,
        inner_html=inner_html,
        logo_url=logo_url,
    )
    try:
        await send_portal_email(
            background_tasks=background_tasks,
            recipient_email=recipient_email,
            subject=subject,
            body_html=wrapped,
            template="ref_portal.association_invite",
            recipient_uid=recipient_uid,
            association_id=association_id,
            actor_uid=actor_uid,
            sender_name=f"{association_name} Assigner",
            context={
                "association_name": association_name,
                "logo_url": logo_url,
                "is_new_account": temp_password is not None,
            },
        )
    except Exception as exc:  # pragma: no cover - email failures shouldn't roll back invite
        logger.exception("Failed to queue association invite email: %s", exc)


def _format_utc_label(value: datetime | None) -> str | None:
    if not value:
        return None
    return value.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


def _extract_game_meta(game: RefPortalGame | None) -> dict[str, str | None]:
    if not game:
        return {
            "association_name": None,
            "game_date": None,
            "venue": None,
        }

    raw = game.raw_data or {}
    association_name = raw.get("association_name") or raw.get("association")
    venue = game.location or raw.get("venue") or raw.get("location") or raw.get("arena")

    return {
        "association_name": association_name,
        "game_date": _format_utc_label(game.game_date),
        "venue": venue,
    }


def _default_admin_settings() -> dict[str, Any]:
    return {
        "arenas": [],
        "divisionRules": [],
        "permissions": {
            "publicScheduleVisibility": "names",
            "officialDirectoryVisibility": "full",
            "allowPickupRequests": True,
        },
        "mileageRules": {
            "enabled": False,
            "ratePerKm": "0.65",
            "minimumKm": "0",
            "roundTrip": True,
            "maxClaimPerGame": "0",
        },
        "assignmentDefaults": {
            "autoLockAvailability": True,
            "autoEmailOnPublish": True,
            "maxAssignmentsPerDay": "2",
        },
    }


def _normalize_admin_settings(payload: Any) -> dict[str, Any]:
    defaults = _default_admin_settings()
    if not isinstance(payload, dict):
        return defaults

    normalized = {
        "arenas": payload.get("arenas") if isinstance(payload.get("arenas"), list) else [],
        "divisionRules": payload.get("divisionRules") if isinstance(payload.get("divisionRules"), list) else [],
        "permissions": {
            **defaults["permissions"],
            **(payload.get("permissions") if isinstance(payload.get("permissions"), dict) else {}),
        },
        "mileageRules": {
            **defaults["mileageRules"],
            **(payload.get("mileageRules") if isinstance(payload.get("mileageRules"), dict) else {}),
        },
        "assignmentDefaults": {
            **defaults["assignmentDefaults"],
            **(payload.get("assignmentDefaults") if isinstance(payload.get("assignmentDefaults"), dict) else {}),
        },
    }
    return normalized


def _parse_game_datetime(date_str: str | None, time_str: str | None) -> datetime | None:
    """Combine a YYYY-MM-DD date and HH:MM time into a tz-aware UTC datetime.

    The frontend stores/reads date and time as wall-clock strings (see
    `src/services/firestore.js:84-102`), so we treat the input as UTC to make
    the round-trip through `game_date` → `toIsoDate`/`toHmTime` lossless.
    Returns None if the date cannot be parsed.
    """
    if not date_str:
        return None
    raw = date_str.strip()
    if time_str and time_str.strip():
        raw = f"{raw}T{time_str.strip()}"
    try:
        parsed = datetime.fromisoformat(raw)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def _clean_text(value: str | None) -> str | None:
    if value is None:
        return None
    stripped = value.strip()
    return stripped or None


def _compose_display_name(first_name: str | None, last_name: str | None, fallback_email: str | None) -> str:
    pieces = [piece for piece in [first_name, last_name] if piece]
    if pieces:
        return " ".join(pieces)
    return fallback_email or "Official"


def _build_assignment_action_urls(
    *,
    assignment_id: str,
    association_id: str,
    expires_at: datetime | None,
) -> tuple[str, str]:
    root = settings.frontend_base_url.rstrip("/")
    base = f"{root}/my-games?assignment={quote(assignment_id, safe='')}&response="
    return (
        f"{base}accepted",
        f"{base}declined",
    )


@router.get("/associations", response_model=list[RefAssociationSchema])
async def list_associations(
    association_id: str | None = Query(default=None),
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> list[RefPortalAssociation]:
    statement = select(RefPortalAssociation).order_by(RefPortalAssociation.name.asc())
    if not (principal.is_admin and not association_id):
        scoped_association_id = _scope_association_id(principal, association_id)
        statement = statement.where(RefPortalAssociation.association_id == scoped_association_id)

    result = await db.scalars(statement)
    return list(result.all())


@router.post("/associations", response_model=RefAssociationSchema, status_code=status.HTTP_201_CREATED)
async def create_association(
    payload: AssociationCreateRequest,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> RefPortalAssociation:
    if not principal.is_admin:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Admin role required")

    association_id = payload.association_id or str(uuid4())
    existing = await db.scalar(
        select(RefPortalAssociation).where(RefPortalAssociation.association_id == association_id)
    )
    if existing:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Association already exists")

    now = datetime.now(timezone.utc)
    raw = dict(payload.raw_data or {})
    if payload.city is not None:
        raw["city"] = payload.city
    if payload.province is not None:
        raw["province"] = payload.province
    if payload.contact_email is not None:
        raw["contactEmail"] = payload.contact_email
    if payload.contact_name is not None:
        raw["contactName"] = payload.contact_name

    association = RefPortalAssociation(
        association_id=association_id,
        name=payload.name,
        status=payload.status or "active",
        created_at=now,
        updated_at=now,
        raw_data=raw,
    )
    db.add(association)
    await db.commit()
    await db.refresh(association)
    return association


@router.put("/associations/{association_id}", response_model=RefAssociationSchema)
async def update_association(
    association_id: str,
    payload: AssociationUpdateRequest,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> RefPortalAssociation:
    if not principal.is_admin:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Admin role required")

    association = await db.scalar(
        select(RefPortalAssociation).where(RefPortalAssociation.association_id == association_id)
    )
    if not association:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Association not found")

    if payload.name is not None:
        association.name = payload.name
    if payload.status is not None:
        association.status = payload.status

    raw = dict(association.raw_data or {})
    if payload.city is not None:
        raw["city"] = payload.city
    if payload.province is not None:
        raw["province"] = payload.province
    if payload.contact_email is not None:
        raw["contactEmail"] = payload.contact_email
    if payload.contact_name is not None:
        raw["contactName"] = payload.contact_name
    if payload.raw_data is not None:
        raw.update(payload.raw_data)
    association.raw_data = raw

    association.updated_at = datetime.now(timezone.utc)
    await db.commit()
    await db.refresh(association)
    return association


@router.delete("/associations/{association_id}", response_model=APIMessage)
async def delete_association(
    association_id: str,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> APIMessage:
    if not principal.is_admin:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Admin role required")

    association = await db.scalar(
        select(RefPortalAssociation).where(RefPortalAssociation.association_id == association_id)
    )
    if not association:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Association not found")

    await db.delete(association)
    await db.commit()
    return APIMessage(message="Association deleted")


@router.get("/associations/{association_id}/admin-settings", response_model=dict[str, Any])
async def get_admin_settings(
    association_id: str,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> dict[str, Any]:
    scoped_association_id = _scope_association_id(principal, association_id)
    if scoped_association_id != association_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Forbidden association scope")

    association = await db.scalar(
        select(RefPortalAssociation).where(RefPortalAssociation.association_id == scoped_association_id)
    )
    if not association:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Association not found")

    raw = association.raw_data or {}
    return _normalize_admin_settings(raw.get("admin_settings"))


@router.put("/associations/{association_id}/admin-settings", response_model=dict[str, Any])
async def put_admin_settings(
    association_id: str,
    payload: dict[str, Any],
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> dict[str, Any]:
    if not _can_assign(principal):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Assigner/admin role required")

    scoped_association_id = _scope_association_id(principal, association_id)
    if scoped_association_id != association_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Forbidden association scope")

    association = await db.scalar(
        select(RefPortalAssociation).where(RefPortalAssociation.association_id == scoped_association_id)
    )
    if not association:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Association not found")

    normalized = _normalize_admin_settings(payload)
    raw = dict(association.raw_data or {})
    raw["admin_settings"] = normalized
    raw["admin_settings_updated_at"] = datetime.now(timezone.utc).isoformat()
    association.raw_data = raw
    association.updated_at = datetime.now(timezone.utc)

    await db.commit()
    await db.refresh(association)
    return normalized


@router.put("/users/me", response_model=RefUserSchema)
async def update_my_profile(
    payload: RefUserSelfUpdateRequest,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> RefPortalUser:
    user = await db.scalar(select(RefPortalUser).where(RefPortalUser.user_id == principal.uid))
    if not user:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")

    raw_data = dict(user.raw_data or {})

    profile_field_map = {
        "first_name": "firstName",
        "last_name": "lastName",
        "phone": "phone",
        "date_of_birth": "dateOfBirth",
        "address_street": "addressStreet",
        "address_city": "addressCity",
        "address_state": "addressState",
        "address_postal_code": "addressPostalCode",
        "address_country": "addressCountry",
        "emergency_contact_name": "emergencyContactName",
        "emergency_contact_phone": "emergencyContactPhone",
    }

    for payload_key, raw_key in profile_field_map.items():
        value = getattr(payload, payload_key)
        if value is None:
            continue
        cleaned = _clean_text(value)
        if cleaned is None:
            raw_data.pop(raw_key, None)
        else:
            raw_data[raw_key] = cleaned

    user.raw_data = raw_data

    if payload.first_name is not None or payload.last_name is not None:
        user.display_name = _compose_display_name(
            raw_data.get("firstName"),
            raw_data.get("lastName"),
            user.email,
        )

    user.updated_at = datetime.now(timezone.utc)
    await db.commit()
    await db.refresh(user)
    return user


@router.get("/users/me/calendar-url")
async def get_my_calendar_url(
    request: Request,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
) -> dict[str, str]:
    try:
        token = generate_calendar_subscription_token(user_id=principal.uid)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail=str(exc)) from exc

    base = str(request.base_url).rstrip("/")
    ics_url = f"{base}/api/ref-portal/users/me/calendar.ics?token={token}"
    webcal_url = ics_url.replace("https://", "webcal://").replace("http://", "webcal://")
    google_url = f"https://calendar.google.com/calendar/r?cid={quote(ics_url, safe='')}"
    return {"ics_url": ics_url, "webcal_url": webcal_url, "google_calendar_url": google_url}


def _ics_escape(text_value: str) -> str:
    return (
        text_value.replace("\\", "\\\\")
        .replace(";", "\\;")
        .replace(",", "\\,")
        .replace("\n", "\\n")
        .replace("\r", "")
    )


def _ics_format_dt(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


@router.get("/users/me/calendar.ics")
async def get_my_calendar_feed(
    token: str = Query(...),
    db: AsyncSession = Depends(get_db_session),
) -> Response:
    user_id = verify_calendar_subscription_token(token)

    statement = (
        select(RefPortalAssignment, RefPortalGame)
        .join(RefPortalGame, RefPortalAssignment.game_id == RefPortalGame.game_id)
        .where(RefPortalAssignment.referee_uid == user_id)
        .where(RefPortalAssignment.status.in_(["accepted", "pending"]))
        .order_by(RefPortalGame.game_date.asc())
    )
    rows = (await db.execute(statement)).all()

    now_stamp = _ics_format_dt(datetime.now(timezone.utc))
    lines = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//Refey//Ref Portal//EN",
        "CALSCALE:GREGORIAN",
        "METHOD:PUBLISH",
        "X-WR-CALNAME:Refey Assignments",
        "X-WR-TIMEZONE:UTC",
    ]

    for assignment, game in rows:
        if not game.game_date:
            continue
        start = game.game_date if game.game_date.tzinfo else game.game_date.replace(tzinfo=timezone.utc)
        end = start + timedelta(hours=2)
        raw = game.raw_data or {}
        home = raw.get("homeTeam") or ""
        away = raw.get("awayTeam") or ""
        position = (assignment.raw_data or {}).get("position") or ""
        title_parts = [p for p in [f"{home} vs {away}".strip(" vs"), position] if p]
        summary = " — ".join(title_parts) or f"Game {game.game_id}"
        location = game.location or raw.get("arena") or ""
        description_parts = [
            f"Position: {position}" if position else None,
            f"Status: {assignment.status}",
            f"Division: {game.division or raw.get('division') or ''}".rstrip(": "),
        ]
        description = " | ".join([p for p in description_parts if p])

        lines.extend([
            "BEGIN:VEVENT",
            f"UID:assignment-{assignment.assignment_id}@refey",
            f"DTSTAMP:{now_stamp}",
            f"DTSTART:{_ics_format_dt(start)}",
            f"DTEND:{_ics_format_dt(end)}",
            f"SUMMARY:{_ics_escape(summary)}",
            f"DESCRIPTION:{_ics_escape(description)}",
            f"LOCATION:{_ics_escape(location)}",
            f"STATUS:{'CONFIRMED' if assignment.status == 'accepted' else 'TENTATIVE'}",
            "END:VEVENT",
        ])

    lines.append("END:VCALENDAR")
    body = "\r\n".join(lines) + "\r\n"
    return Response(
        content=body,
        media_type="text/calendar; charset=utf-8",
        headers={"Content-Disposition": 'attachment; filename="refey-assignments.ics"'},
    )


@router.get("/users", response_model=list[RefUserSchema])
async def list_users(
    association_id: str | None = Query(default=None),
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> list[RefPortalUser]:
    statement = select(RefPortalUser).order_by(RefPortalUser.display_name.asc())
    if not (principal.is_admin and not association_id):
        scoped_association_id = _scope_association_id(principal, association_id)
        statement = statement.where(RefPortalUser.association_id == scoped_association_id)

    result = await db.scalars(statement)
    return list(result.all())


@router.get("/users/invite-status")
async def get_user_invite_status(
    email: str = Query(min_length=3, max_length=320),
    association_id: str | None = Query(default=None),
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> dict[str, Any]:
    if not _can_assign(principal):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Assigner/admin role required")

    normalized_email = _clean_text(email)
    if not normalized_email:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="email is required")

    requested_association_id = _clean_text(association_id)
    scoped_association_id: str | None = None
    if requested_association_id:
        scoped_association_id = _scope_association_id(principal, requested_association_id)
    elif not principal.is_admin:
        scoped_association_id = _scope_association_id(principal)

    existing_user = await db.scalar(
        select(TryprUser.uid).where(func.lower(TryprUser.email) == normalized_email.lower())
    )

    ref_user_stmt = select(RefPortalUser.user_id).where(func.lower(RefPortalUser.email) == normalized_email.lower())
    if scoped_association_id:
        ref_user_stmt = ref_user_stmt.where(RefPortalUser.association_id == scoped_association_id)
    has_ref_portal_profile = await db.scalar(ref_user_stmt)

    return {
        "email": normalized_email,
        "existing_user": bool(existing_user),
        "has_ref_portal_profile": bool(has_ref_portal_profile),
        "invitation_mode": "login" if existing_user else "finish_account",
    }


@router.post("/users", response_model=RefUserSchema, status_code=status.HTTP_201_CREATED)
async def create_user(
    payload: RefUserCreateRequest,
    background_tasks: BackgroundTasks,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> RefPortalUser:
    if not _can_assign(principal):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Assigner/admin role required")

    _check_invite_rate_limit(principal.uid)

    email = _clean_text(payload.email)
    if not email:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="email is required")

    requested_association_id = _clean_text(payload.association_id)
    scoped_association_id = _scope_association_id(principal, requested_association_id)
    if requested_association_id and scoped_association_id != requested_association_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Forbidden association scope")

    association = await db.scalar(
        select(RefPortalAssociation).where(RefPortalAssociation.association_id == scoped_association_id)
    )
    if not association:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Association not found")

    first_name = _clean_text(payload.first_name)
    last_name = _clean_text(payload.last_name)
    display_name = _clean_text(payload.display_name) or _compose_display_name(first_name, last_name, email)
    role = _clean_text(payload.role) or "official"

    existing_email = await db.scalar(
        select(RefPortalUser).where(
            RefPortalUser.association_id == scoped_association_id,
            func.lower(RefPortalUser.email) == email.lower(),
        )
    )
    if existing_email:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="User email already exists in association")

    firebase_uid, temp_password = _provision_firebase_user(email=email, display_name=display_name)

    requested_user_id = _clean_text(payload.user_id)
    if requested_user_id and requested_user_id != firebase_uid:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="user_id must match the Firebase UID for this email",
        )

    user_id = firebase_uid
    existing = await db.scalar(select(RefPortalUser).where(RefPortalUser.user_id == user_id))
    if existing:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="User already exists")

    now = datetime.now(timezone.utc)
    raw_data = dict(payload.raw_data or {})
    if first_name is not None:
        raw_data["firstName"] = first_name
    if last_name is not None:
        raw_data["lastName"] = last_name
    phone = _clean_text(payload.phone)
    if phone is not None:
        raw_data["phone"] = phone
    if temp_password is not None:
        raw_data["needsOnboarding"] = True

    user = RefPortalUser(
        user_id=user_id,
        association_id=scoped_association_id,
        email=email,
        display_name=display_name,
        role=role,
        created_at=now,
        updated_at=now,
        raw_data=raw_data,
    )
    db.add(user)
    await db.commit()
    await db.refresh(user)

    await _send_invite_email(
        background_tasks=background_tasks,
        association_name=association.name or "your association",
        association_id=scoped_association_id,
        actor_uid=principal.uid,
        recipient_email=email,
        recipient_uid=firebase_uid,
        display_name=first_name or display_name or email,
        temp_password=temp_password,
    )

    return user


@router.post("/users/{user_id}/resend-invite", response_model=APIMessage)
async def resend_user_invite(
    user_id: str,
    background_tasks: BackgroundTasks,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> APIMessage:
    if not _can_assign(principal):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Assigner/admin role required")

    user = await db.scalar(select(RefPortalUser).where(RefPortalUser.user_id == user_id))
    if not user:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")

    if not principal.is_admin and principal.ref_portal_association_id != user.association_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Forbidden association scope")

    _check_invite_rate_limit(principal.uid)

    if not user.email:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="User has no email on file")

    association = await db.scalar(
        select(RefPortalAssociation).where(RefPortalAssociation.association_id == user.association_id)
    )

    ensure_firebase_admin()
    temp_password: str | None = None
    try:
        firebase_user = firebase_auth.get_user_by_email(user.email)
        firebase_uid = firebase_user.uid
        # Only reset the password for users we know haven't completed onboarding.
        # Otherwise an assigner could grief an active official by overwriting
        # their working password.
        if (user.raw_data or {}).get("needsOnboarding"):
            temp_password = _generate_temp_password()
            firebase_auth.update_user(firebase_uid, password=temp_password)
    except firebase_auth.UserNotFoundError:
        # No Firebase account yet — create one with a fresh temp password.
        firebase_uid, temp_password = _provision_firebase_user(email=user.email, display_name=user.display_name)
        if firebase_uid != user.user_id:
            raw_data = dict(user.raw_data or {})
            raw_data["needsOnboarding"] = True
            user.raw_data = raw_data
            user.updated_at = datetime.now(timezone.utc)
            await db.commit()
            await db.refresh(user)
    except Exception as exc:
        logger.exception("Failed to refresh Firebase account for resend invite: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Auth provider unavailable",
        ) from exc

    raw_data = dict(user.raw_data or {})
    if temp_password is not None and not raw_data.get("needsOnboarding"):
        raw_data["needsOnboarding"] = True
        user.raw_data = raw_data
        user.updated_at = datetime.now(timezone.utc)
        await db.commit()
        await db.refresh(user)

    first_name = (raw_data.get("firstName") or "").strip()
    display_name = first_name or user.display_name or user.email

    await _send_invite_email(
        background_tasks=background_tasks,
        association_name=(association.name if association and association.name else "your association"),
        association_id=user.association_id,
        actor_uid=principal.uid,
        recipient_email=user.email,
        recipient_uid=firebase_uid,
        display_name=display_name,
        temp_password=temp_password,
    )

    return APIMessage(message="Invite resent")


@router.put("/users/{user_id}", response_model=RefUserSchema)
async def update_user(
    user_id: str,
    payload: RefUserUpdateRequest,
    background_tasks: BackgroundTasks,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> RefPortalUser:
    if not _can_assign(principal):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Assigner/admin role required")

    user = await db.scalar(select(RefPortalUser).where(RefPortalUser.user_id == user_id))
    if not user:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")

    current_assoc = user.association_id
    invite_association: RefPortalAssociation | None = None
    if not principal.is_admin and principal.ref_portal_association_id != current_assoc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Forbidden association scope")

    requested_association_id = _clean_text(payload.association_id)
    if payload.association_id == "":
        requested_association_id = None

    if requested_association_id:
        scoped_association_id = _scope_association_id(principal, requested_association_id)
        if scoped_association_id != requested_association_id:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Forbidden association scope")
        association = await db.scalar(
            select(RefPortalAssociation).where(RefPortalAssociation.association_id == requested_association_id)
        )
        if not association:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Association not found")
        user.association_id = requested_association_id
        if requested_association_id != current_assoc:
            invite_association = association
    elif payload.association_id is not None:
        if not principal.is_admin:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Admin role required to remove association")
        user.association_id = None

    if payload.email is not None:
        email = _clean_text(payload.email)
        if not email:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="email cannot be empty")
        email_conflict = await db.scalar(
            select(RefPortalUser).where(
                RefPortalUser.user_id != user.user_id,
                RefPortalUser.association_id == user.association_id,
                func.lower(RefPortalUser.email) == email.lower(),
            )
        )
        if email_conflict:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="User email already exists in association")
        user.email = email

    if payload.role is not None:
        role = _clean_text(payload.role)
        if not role:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="role cannot be empty")
        user.role = role

    raw_data = dict(user.raw_data or {})
    if payload.raw_data is not None:
        raw_data.update(payload.raw_data)

    if payload.first_name is not None:
        first_name = _clean_text(payload.first_name)
        if first_name is None:
            raw_data.pop("firstName", None)
        else:
            raw_data["firstName"] = first_name

    if payload.last_name is not None:
        last_name = _clean_text(payload.last_name)
        if last_name is None:
            raw_data.pop("lastName", None)
        else:
            raw_data["lastName"] = last_name

    if payload.phone is not None:
        phone = _clean_text(payload.phone)
        if phone is None:
            raw_data.pop("phone", None)
        else:
            raw_data["phone"] = phone

    user.raw_data = raw_data

    if payload.display_name is not None:
        resolved_display = _clean_text(payload.display_name)
        if resolved_display:
            user.display_name = resolved_display
        else:
            user.display_name = _compose_display_name(
                raw_data.get("firstName"),
                raw_data.get("lastName"),
                user.email,
            )
    elif payload.first_name is not None or payload.last_name is not None:
        user.display_name = _compose_display_name(
            raw_data.get("firstName"),
            raw_data.get("lastName"),
            user.email,
        )

    user.updated_at = datetime.now(timezone.utc)
    await db.commit()
    await db.refresh(user)

    if invite_association and user.email:
        firebase_uid: str | None = None
        temp_password: str | None = None
        raw_after_save = dict(user.raw_data or {})

        try:
            ensure_firebase_admin()
            try:
                firebase_user = firebase_auth.get_user_by_email(user.email)
                firebase_uid = firebase_user.uid
                if raw_after_save.get("needsOnboarding"):
                    temp_password = _generate_temp_password()
                    firebase_auth.update_user(firebase_uid, password=temp_password)
            except firebase_auth.UserNotFoundError:
                firebase_uid, temp_password = _provision_firebase_user(
                    email=user.email,
                    display_name=user.display_name,
                )
                if temp_password is not None and not raw_after_save.get("needsOnboarding"):
                    raw_after_save["needsOnboarding"] = True
                    user.raw_data = raw_after_save
                    user.updated_at = datetime.now(timezone.utc)
                    await db.commit()
                    await db.refresh(user)
            first_name = (raw_after_save.get("firstName") or "").strip()
            await _send_invite_email(
                background_tasks=background_tasks,
                association_name=invite_association.name or "your association",
                association_id=invite_association.association_id,
                actor_uid=principal.uid,
                recipient_email=user.email,
                recipient_uid=firebase_uid or user.user_id,
                display_name=first_name or user.display_name or user.email,
                temp_password=temp_password,
            )
        except HTTPException:
            raise
        except Exception as exc:  # pragma: no cover - invite failures should not roll back profile edits
            logger.exception("Failed to queue invite after association update: %s", exc)

    return user


@router.delete("/users/{user_id}", response_model=APIMessage)
async def delete_user(
    user_id: str,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> APIMessage:
    if not principal.is_admin and principal.ref_portal_role != "supervisor":
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Supervisor/admin role required")

    user = await db.scalar(select(RefPortalUser).where(RefPortalUser.user_id == user_id))
    if not user:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")

    if not principal.is_admin and user.association_id != principal.ref_portal_association_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Forbidden association scope")

    await db.delete(user)
    await db.commit()
    return APIMessage(message="User deleted")


@router.get("/games", response_model=list[RefGameSchema])
async def list_games(
    association_id: str | None = Query(default=None),
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> list[RefPortalGame]:
    scoped_association_id = _scope_association_id(principal, association_id)
    statement = (
        select(RefPortalGame)
        .where(RefPortalGame.association_id == scoped_association_id)
        .order_by(RefPortalGame.game_date.asc(), RefPortalGame.game_id.asc())
    )
    result = await db.scalars(statement)
    return list(result.all())


@router.post("/games/batch", response_model=list[RefGameSchema], status_code=status.HTTP_201_CREATED)
async def create_games_batch(
    payload: GameBatchCreateRequest,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> list[RefPortalGame]:
    if not _can_assign(principal):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Assigner/admin role required")

    scoped_association_id = _scope_association_id(principal, payload.association_id)
    if scoped_association_id != payload.association_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Forbidden association scope")

    association = await db.scalar(
        select(RefPortalAssociation).where(RefPortalAssociation.association_id == scoped_association_id)
    )
    if not association:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Association not found")

    if not payload.games:
        return []

    now = datetime.now(timezone.utc)
    created: list[RefPortalGame] = []

    for item in payload.games:
        game_date = _parse_game_datetime(item.date, item.time)
        arena = (item.arena or "").strip()
        division = (item.division or "").strip()
        game_type = (item.game_type or "LG").strip().upper() or "LG"

        raw = {
            "homeTeam": (item.home_team or "").strip(),
            "awayTeam": (item.away_team or "").strip(),
            "arena": arena,
            "gameType": game_type,
            "status": "unassigned",
            "date": item.date,
            "time": item.time,
            "imported_by": principal.uid,
            "imported_at": now.isoformat(),
            "source": "fastapi.games.batch_import",
            "associationId": scoped_association_id,
        }

        game = RefPortalGame(
            game_id=str(uuid4()),
            association_id=scoped_association_id,
            game_date=game_date,
            location=arena or None,
            division=division or None,
            created_at=now,
            updated_at=now,
            raw_data=raw,
        )
        db.add(game)
        created.append(game)

    await db.commit()
    for game in created:
        await db.refresh(game)

    return created


@router.get("/assignments", response_model=list[RefAssignmentSchema])
async def list_assignments(
    association_id: str | None = Query(default=None),
    referee_uid: str | None = Query(default=None),
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> list[RefPortalAssignment]:
    scoped_association_id = _scope_association_id(principal, association_id)
    statement = (
        select(RefPortalAssignment)
        .join(RefPortalGame, RefPortalAssignment.game_id == RefPortalGame.game_id)
        .where(RefPortalGame.association_id == scoped_association_id)
        .order_by(RefPortalAssignment.created_at.desc(), RefPortalAssignment.assignment_id.desc())
    )
    if referee_uid:
        statement = statement.where(RefPortalAssignment.referee_uid == referee_uid)

    result = await db.scalars(statement)
    return list(result.all())


@router.post("/assignments", response_model=RefAssignmentSchema, status_code=status.HTTP_201_CREATED)
async def create_assignment(
    payload: AssignmentCreateRequest,
    background_tasks: BackgroundTasks,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> RefPortalAssignment:
    if not _can_assign(principal):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Assigner/admin role required")

    requested_association_id = _clean_text(payload.association_id)

    game = await db.scalar(
        select(RefPortalGame).where(RefPortalGame.game_id == payload.game_id)
    )
    if not game:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Game not found")

    game_association_id = _clean_text(game.association_id)
    if not game_association_id:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Game has no association scope")

    scoped_association_id = _scope_association_id(
        principal,
        requested_association_id or game_association_id,
    )

    if scoped_association_id != game_association_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Forbidden association scope")

    if requested_association_id and requested_association_id != game_association_id:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Assignment association does not match game")

    referee_in_association = await db.scalar(
        select(RefPortalUser).where(
            RefPortalUser.user_id == payload.referee_uid,
            RefPortalUser.association_id == scoped_association_id,
        )
    )
    if not referee_in_association:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Referee not found in association")

    now = datetime.now(timezone.utc)
    expires_at = now + timedelta(hours=24)
    assignment = RefPortalAssignment(
        assignment_id=str(uuid4()),
        game_id=payload.game_id,
        referee_uid=payload.referee_uid,
        status="pending",
        expires_at=expires_at,
        assigned_at=now,
        created_at=now,
        updated_at=now,
        raw_data={
            "created_by": principal.uid,
            "notes": payload.notes,
            "source": "fastapi.assignments.create",
            "association_id": scoped_association_id,
        },
    )
    db.add(assignment)
    await db.commit()
    await db.refresh(assignment)

    return assignment


@router.post("/games/{game_id}/trigger-assignments", response_model=list[RefAssignmentSchema])
async def trigger_game_assignments(
    game_id: str,
    payload: AssignmentTriggerRequest,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> list[RefPortalAssignment]:
    if not _can_assign(principal):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Assigner/admin role required")

    scoped_association_id = _scope_association_id(principal)

    game = await db.scalar(
        select(RefPortalGame).where(
            RefPortalGame.game_id == game_id,
            RefPortalGame.association_id == scoped_association_id,
        )
    )
    if not game:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Game not found in association")

    expires_at = datetime.now(timezone.utc) + timedelta(hours=payload.expires_in_hours)
    assignments: list[RefPortalAssignment] = []

    for referee_uid in payload.referee_uids:
        referee = await db.scalar(
            select(RefPortalUser).where(
                RefPortalUser.user_id == referee_uid,
                RefPortalUser.association_id == scoped_association_id,
            )
        )
        if not referee:
            continue

        assignment = RefPortalAssignment(
            assignment_id=str(uuid4()),
            game_id=game_id,
            referee_uid=referee_uid,
            status="pending",
            expires_at=expires_at,
            assigned_at=datetime.now(timezone.utc),
            created_at=datetime.now(timezone.utc),
            updated_at=datetime.now(timezone.utc),
            raw_data={
                "triggered_by": principal.uid,
                "source": "fastapi.trigger_assignments",
                "association_id": scoped_association_id,
            },
        )
        db.add(assignment)
        assignments.append(assignment)

    await db.commit()
    for assignment in assignments:
        await db.refresh(assignment)

    return assignments


@router.post("/notifications/custom", response_model=APIMessage)
async def queue_custom_notification(
    payload: dict[str, Any],
    background_tasks: BackgroundTasks,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> APIMessage:
    if not _can_assign(principal):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Assigner/admin role required")

    raw_to = payload.get("to")
    recipients: list[str] = []
    if isinstance(raw_to, str):
        if raw_to.strip():
            recipients = [raw_to.strip()]
    elif isinstance(raw_to, list):
        recipients = [str(value).strip() for value in raw_to if str(value).strip()]

    if not recipients:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="At least one recipient is required")

    subject = str(payload.get("subject") or "").strip()
    html = str(payload.get("html") or "").strip()
    text_body = payload.get("text")
    if not subject or not html:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="subject and html are required",
        )

    requested_association_id = payload.get("association_id")
    if requested_association_id is not None and not isinstance(requested_association_id, str):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="association_id must be a string")

    scoped_association_id = _scope_association_id(principal, requested_association_id)
    association = await db.scalar(
        select(RefPortalAssociation).where(RefPortalAssociation.association_id == scoped_association_id)
    )
    association_name = (association.name if association and association.name else "Refey")
    logo_url = f"{settings.frontend_base_url.rstrip('/')}/RefeyLogo.jpeg"

    wrapped_html = _wrap_branded_email_html(
        association_name=association_name,
        subject=subject,
        inner_html=html,
        logo_url=logo_url,
    )

    queued = 0
    for recipient_email in recipients:
        await send_portal_email(
            background_tasks=background_tasks,
            recipient_email=recipient_email,
            subject=subject,
            body_html=wrapped_html,
            body_text=str(text_body) if text_body is not None else None,
            template="custom_frontend",
            recipient_uid=None,
            association_id=scoped_association_id,
            game_id=str(payload.get("game_id")) if payload.get("game_id") is not None else None,
            assignment_id=str(payload.get("assignment_id")) if payload.get("assignment_id") is not None else None,
            actor_uid=principal.uid,
            sender_name=f"{association_name} Assigner",
            context={
                "source": "frontend.refey.custom_email",
                "association_name": association_name,
                "logo_url": logo_url,
            },
        )
        queued += 1

    return APIMessage(message=f"Queued {queued} email(s)")


@router.post("/assignments/{assignment_id}/respond", response_model=RefAssignmentSchema)
async def respond_to_assignment(
    assignment_id: str,
    payload: AssignmentResponseRequest,
    background_tasks: BackgroundTasks,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> RefPortalAssignment:
    scoped_association_id = _scope_association_id(principal)

    row = await db.execute(
        select(RefPortalAssignment, RefPortalGame)
        .join(RefPortalGame, RefPortalAssignment.game_id == RefPortalGame.game_id)
        .where(
            RefPortalAssignment.assignment_id == assignment_id,
            RefPortalGame.association_id == scoped_association_id,
        )
    )
    tuple_row = row.first()
    if not tuple_row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Assignment not found in association")

    assignment, game = tuple_row

    is_owner = assignment.referee_uid == principal.uid
    if not (is_owner or principal.is_admin):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only assignee or admin can respond")

    now = datetime.now(timezone.utc)
    if assignment.expires_at and assignment.expires_at < now and assignment.status == "pending":
        assignment.status = "expired"
        assignment.updated_at = now
        await db.commit()
        await db.refresh(assignment)
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Assignment has expired")

    if assignment.status == "expired":
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Assignment already expired")

    assignment.status = payload.status
    assignment.responded_at = now
    assignment.updated_at = now
    await db.commit()
    await db.refresh(assignment)

    if assignment.referee_uid:
        game_meta = _extract_game_meta(game)
        status_label = "Accepted" if payload.status == "accepted" else "Declined"
        try:
            await send_ref_notification(
                background_tasks=background_tasks,
                db=db,
                recipient_uid=assignment.referee_uid,
                template=RefNotificationTemplate.BOOKING_UPDATE,
                subject=f"Game Booking {status_label}: {assignment.game_id or 'Game'}",
                context={
                    "game_id": assignment.game_id,
                    "assignment_id": assignment.assignment_id,
                    "status_label": status_label,
                    "game_date": game_meta["game_date"],
                    "venue": game_meta["venue"],
                    "note": None,
                },
                association_id=scoped_association_id,
                game_id=assignment.game_id,
                assignment_id=assignment.assignment_id,
                actor_uid=principal.uid,
            )
        except ValueError:
            pass

    return assignment


@router.put("/assignments/{assignment_id}/respond", response_model=RefAssignmentSchema)
async def respond_to_assignment_put(
    assignment_id: str,
    payload: AssignmentResponseRequest,
    background_tasks: BackgroundTasks,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> RefPortalAssignment:
    return await respond_to_assignment(
        assignment_id=assignment_id,
        payload=payload,
        background_tasks=background_tasks,
        principal=principal,
        db=db,
    )


@router.get("/assignments/respond-link")
async def respond_to_assignment_via_signed_link(
    token: str,
    background_tasks: BackgroundTasks,
    db: AsyncSession = Depends(get_db_session),
) -> APIMessage:
    payload = verify_assignment_action_token(token)
    assignment_id = payload["aid"]
    status_value = payload["status"]
    association_id = payload["assoc"]

    row = await db.execute(
        select(RefPortalAssignment, RefPortalGame)
        .join(RefPortalGame, RefPortalAssignment.game_id == RefPortalGame.game_id)
        .where(
            RefPortalAssignment.assignment_id == assignment_id,
            RefPortalGame.association_id == association_id,
        )
    )
    tuple_row = row.first()
    if not tuple_row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Assignment not found")

    assignment, game = tuple_row

    now = datetime.now(timezone.utc)
    if assignment.status == "expired":
        return APIMessage(message="This assignment has already expired.")
    if assignment.expires_at and assignment.expires_at < now and assignment.status == "pending":
        assignment.status = "expired"
        assignment.updated_at = now
        await db.commit()
        return APIMessage(message="This assignment has expired.")

    assignment.status = status_value
    assignment.responded_at = now
    assignment.updated_at = now
    await db.commit()
    await db.refresh(assignment)

    if assignment.referee_uid:
        game_meta = _extract_game_meta(game)
        status_label = "Accepted" if status_value == "accepted" else "Declined"
        try:
            await send_ref_notification(
                background_tasks=background_tasks,
                db=db,
                recipient_uid=assignment.referee_uid,
                template=RefNotificationTemplate.BOOKING_UPDATE,
                subject=f"Game Booking {status_label}: {assignment.game_id or 'Game'}",
                context={
                    "game_id": assignment.game_id,
                    "assignment_id": assignment.assignment_id,
                    "status_label": status_label,
                    "game_date": game_meta["game_date"],
                    "venue": game_meta["venue"],
                    "note": "Submitted from one-click email link.",
                },
                association_id=game.association_id,
                game_id=assignment.game_id,
                assignment_id=assignment.assignment_id,
                actor_uid=None,
            )
        except ValueError:
            pass

    redirect_url = f"{settings.frontend_base_url.rstrip('/')}/my-games?response={status_value}"
    return RedirectResponse(url=redirect_url, status_code=status.HTTP_303_SEE_OTHER)


@router.post("/assignments/expire-overdue", response_model=APIMessage)
async def expire_overdue_assignments(
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> APIMessage:
    if not _can_assign(principal):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Assigner/admin role required")

    scoped_association_id = _scope_association_id(principal)
    now = datetime.now(timezone.utc)
    scoped_games = select(RefPortalGame.game_id).where(RefPortalGame.association_id == scoped_association_id)
    statement = (
        update(RefPortalAssignment)
        .where(
            and_(
                RefPortalAssignment.status == text("'pending'::ref_portal.assignment_status"),
                RefPortalAssignment.expires_at.is_not(None),
                RefPortalAssignment.expires_at < now,
                RefPortalAssignment.game_id.in_(scoped_games),
            )
        )
        .values(status=text("'expired'::ref_portal.assignment_status"), updated_at=now)
    )
    result = await db.execute(statement)
    await db.commit()
    expired_count = result.rowcount or 0
    return APIMessage(message=f"Expired {expired_count} overdue assignments")


@router.get("/assignments/pending-count")
async def pending_assignments_count(
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> dict[str, int]:
    if not _can_assign(principal):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Assigner/admin role required")

    scoped_association_id = _scope_association_id(principal)
    count = await db.scalar(
        select(func.count())
        .select_from(RefPortalAssignment)
        .join(RefPortalGame, RefPortalAssignment.game_id == RefPortalGame.game_id)
        .where(
            RefPortalAssignment.status == text("'pending'::ref_portal.assignment_status"),
            RefPortalGame.association_id == scoped_association_id,
        )
    )
    return {"pending_assignments": int(count or 0)}


def _apply_game_patch(game: RefPortalGame, payload: GameUpdateRequest, actor_uid: str) -> None:
    raw = dict(game.raw_data or {})
    changed_date = payload.date is not None
    changed_time = payload.time is not None
    date_value = payload.date if changed_date else raw.get("date")
    time_value = payload.time if changed_time else raw.get("time")
    if changed_date or changed_time:
        game.game_date = _parse_game_datetime(date_value, time_value)
        if date_value is not None:
            raw["date"] = date_value
        if time_value is not None:
            raw["time"] = time_value
    if payload.home_team is not None:
        raw["homeTeam"] = payload.home_team
    if payload.away_team is not None:
        raw["awayTeam"] = payload.away_team
    if payload.arena is not None:
        raw["arena"] = payload.arena
        game.location = payload.arena or None
    if payload.division is not None:
        game.division = payload.division or None
        raw["division"] = payload.division
    if payload.game_type is not None:
        raw["gameType"] = (payload.game_type or "LG").upper() or "LG"
    if payload.status is not None:
        raw["status"] = payload.status
    if payload.raw_data is not None:
        raw.update(payload.raw_data)
    raw["updated_by"] = actor_uid
    game.raw_data = raw
    game.updated_at = datetime.now(timezone.utc)


@router.post("/games", response_model=RefGameSchema, status_code=status.HTTP_201_CREATED)
async def create_game(
    payload: GameCreateRequest,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> RefPortalGame:
    if not _can_assign(principal):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Assigner/admin role required")

    scoped_association_id = _scope_association_id(principal, payload.association_id)
    if scoped_association_id != payload.association_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Forbidden association scope")

    association = await db.scalar(
        select(RefPortalAssociation).where(RefPortalAssociation.association_id == scoped_association_id)
    )
    if not association:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Association not found")

    now = datetime.now(timezone.utc)
    arena = (payload.arena or "").strip()
    division = (payload.division or "").strip()
    game_type = ((payload.game_type or "LG").strip().upper()) or "LG"

    raw = dict(payload.raw_data or {})
    raw.update(
        {
            "homeTeam": (payload.home_team or "").strip(),
            "awayTeam": (payload.away_team or "").strip(),
            "arena": arena,
            "gameType": game_type,
            "status": payload.status or "unassigned",
            "date": payload.date,
            "time": payload.time,
            "associationId": scoped_association_id,
            "created_by": principal.uid,
        }
    )

    game = RefPortalGame(
        game_id=str(uuid4()),
        association_id=scoped_association_id,
        game_date=_parse_game_datetime(payload.date, payload.time),
        location=arena or None,
        division=division or None,
        created_at=now,
        updated_at=now,
        raw_data=raw,
    )
    db.add(game)
    await db.commit()
    await db.refresh(game)
    return game


@router.put("/games/{game_id}", response_model=RefGameSchema)
async def update_game(
    game_id: str,
    payload: GameUpdateRequest,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> RefPortalGame:
    if not _can_assign(principal):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Assigner/admin role required")

    game = await db.scalar(select(RefPortalGame).where(RefPortalGame.game_id == game_id))
    if not game:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Game not found")

    if not principal.is_admin and principal.ref_portal_association_id != game.association_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Forbidden association scope")

    _apply_game_patch(game, payload, principal.uid)
    await db.commit()
    await db.refresh(game)
    return game


@router.delete("/games/{game_id}", response_model=APIMessage)
async def delete_game(
    game_id: str,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> APIMessage:
    if not _can_assign(principal):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Assigner/admin role required")

    game = await db.scalar(select(RefPortalGame).where(RefPortalGame.game_id == game_id))
    if not game:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Game not found")

    if not principal.is_admin and principal.ref_portal_association_id != game.association_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Forbidden association scope")

    await db.delete(game)
    await db.commit()
    return APIMessage(message="Game deleted")


@router.post("/assignments/{assignment_id}/incident-report", response_model=RefAssignmentSchema)
async def submit_assignment_incident_report(
    assignment_id: str,
    payload: IncidentReportCreateRequest,
    background_tasks: BackgroundTasks,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> RefPortalAssignment:
    assignment = await db.scalar(
        select(RefPortalAssignment).where(RefPortalAssignment.assignment_id == assignment_id)
    )
    if not assignment:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Assignment not found")

    game = None
    if assignment.game_id:
        game = await db.scalar(select(RefPortalGame).where(RefPortalGame.game_id == assignment.game_id))

    association_id = (game.association_id if game else None) or (assignment.raw_data or {}).get("associationId")
    if not association_id:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Assignment association is missing")

    can_manage = principal.is_admin or (_can_assign(principal) and principal.ref_portal_association_id == association_id)
    is_assigned_official = principal.uid == assignment.referee_uid
    if not can_manage and not is_assigned_official:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Cannot submit a report for this assignment")

    association = await db.scalar(
        select(RefPortalAssociation).where(RefPortalAssociation.association_id == association_id)
    )
    reporter = await db.scalar(select(RefPortalUser).where(RefPortalUser.user_id == principal.uid))
    reporter_name = (
        _compose_display_name(
            (reporter.raw_data or {}).get("firstName") if reporter else None,
            (reporter.raw_data or {}).get("lastName") if reporter else None,
            reporter.email if reporter else principal.email,
        )
        if reporter
        else (principal.email or "Official")
    )

    submitted_at = datetime.now(timezone.utc).isoformat()
    report = {
        "id": str(uuid4()),
        "submittedAt": submitted_at,
        "submittedByUid": principal.uid,
        "submittedByEmail": principal.email,
        "officialName": reporter_name,
        "reportType": _clean_text(payload.report_type) or "Special Incident",
        "penaltyAssessedTo": _clean_text(payload.penalty_assessed_to),
        "playerNumber": _clean_text(payload.player_number),
        "playerTeam": _clean_text(payload.player_team),
        "penaltyCode": _clean_text(payload.penalty_code),
        "infraction": _clean_text(payload.infraction),
        "period": _clean_text(payload.period),
        "time": _clean_text(payload.time),
        "scoreAtTime": _clean_text(payload.score_at_time),
        "finalScore": _clean_text(payload.final_score),
        "details": payload.details.strip(),
        "injuries": _clean_text(payload.injuries),
        "furtherProblems": _clean_text(payload.further_problems),
        "verbalReportTo": _clean_text(payload.verbal_report_to),
        "reportDate": _clean_text(payload.report_date) or submitted_at[:10],
        "rawData": payload.raw_data or {},
    }

    raw = dict(assignment.raw_data or {})
    reports = raw.get("incidentReports")
    if not isinstance(reports, list):
        reports = []
    reports.append(report)
    raw["incidentReports"] = reports
    raw["incidentReportCount"] = len(reports)
    raw["lastIncidentReportAt"] = submitted_at
    raw["updated_by"] = principal.uid
    assignment.raw_data = raw
    assignment.updated_at = datetime.now(timezone.utc)

    await db.commit()
    await db.refresh(assignment)

    try:
        await _notify_incident_report(
            background_tasks=background_tasks,
            db=db,
            association=association,
            assignment=assignment,
            game=game,
            report=report,
            actor_uid=principal.uid,
        )
    except Exception as exc:  # pragma: no cover - notification failure should not lose the report
        logger.exception("Failed to notify assigners about incident report: %s", exc)

    return assignment


@router.post("/assignments/{assignment_id}/supervision-report", response_model=RefAssignmentSchema)
async def submit_assignment_supervision_report(
    assignment_id: str,
    payload: SupervisionReportCreateRequest,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> RefPortalAssignment:
    if not _can_assign(principal):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Assigner/admin role required")

    assignment = await db.scalar(
        select(RefPortalAssignment).where(RefPortalAssignment.assignment_id == assignment_id)
    )
    if not assignment:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Assignment not found")

    game = None
    if assignment.game_id:
        game = await db.scalar(select(RefPortalGame).where(RefPortalGame.game_id == assignment.game_id))

    association_id = (game.association_id if game else None) or (assignment.raw_data or {}).get("associationId")
    if not association_id:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Assignment association is missing")

    if not principal.is_admin and principal.ref_portal_association_id != association_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Forbidden association scope")

    evaluated_user_id = _clean_text(payload.evaluated_user_id) or assignment.referee_uid
    evaluated_user = (
        await db.scalar(select(RefPortalUser).where(RefPortalUser.user_id == evaluated_user_id))
        if evaluated_user_id
        else None
    )
    supervisor = await db.scalar(select(RefPortalUser).where(RefPortalUser.user_id == principal.uid))

    def display_for(user: RefPortalUser | None, fallback_email: str | None, fallback: str) -> str:
        if not user:
            return fallback_email or fallback
        raw = user.raw_data or {}
        return _compose_display_name(raw.get("firstName"), raw.get("lastName"), user.email or fallback_email or fallback)

    submitted_at = datetime.now(timezone.utc).isoformat()
    report = {
        "id": str(uuid4()),
        "submittedAt": submitted_at,
        "submittedByUid": principal.uid,
        "submittedByEmail": principal.email,
        "supervisorName": display_for(supervisor, principal.email, "Supervisor"),
        "evaluatedUserId": evaluated_user_id,
        "officialName": display_for(
            evaluated_user,
            (assignment.raw_data or {}).get("officialName"),
            "Official",
        ),
        "reviewedGameSheet": bool(payload.reviewed_game_sheet),
        "code": _clean_text(payload.code),
        "subcode": _clean_text(payload.subcode),
        "strengths": _clean_text(payload.strengths),
        "development": _clean_text(payload.development),
        "comments": _clean_text(payload.comments),
        "overallRating": _clean_text(payload.overall_rating),
        "ratings": payload.ratings or {},
        "reportDate": _clean_text(payload.report_date) or submitted_at[:10],
        "rawData": payload.raw_data or {},
    }

    raw = dict(assignment.raw_data or {})
    reports = raw.get("supervisionReports")
    if not isinstance(reports, list):
        reports = []
    reports.append(report)
    raw["supervisionReports"] = reports
    raw["supervisionReportCount"] = len(reports)
    raw["lastSupervisionReportAt"] = submitted_at
    raw["updated_by"] = principal.uid
    assignment.raw_data = raw
    assignment.updated_at = datetime.now(timezone.utc)

    await db.commit()
    await db.refresh(assignment)
    return assignment


@router.put("/assignments/{assignment_id}", response_model=RefAssignmentSchema)
async def update_assignment(
    assignment_id: str,
    payload: AssignmentUpdateRequest,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> RefPortalAssignment:
    if not _can_assign(principal):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Assigner/admin role required")

    assignment = await db.scalar(
        select(RefPortalAssignment).where(RefPortalAssignment.assignment_id == assignment_id)
    )
    if not assignment:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Assignment not found")

    if payload.status is not None:
        assignment.status = payload.status
        if payload.status in {"accepted", "declined"}:
            assignment.responded_at = datetime.now(timezone.utc)
    if payload.referee_uid is not None:
        assignment.referee_uid = payload.referee_uid or None
    raw = dict(assignment.raw_data or {})
    if payload.notes is not None:
        raw["notes"] = payload.notes
    if payload.raw_data is not None:
        raw.update(payload.raw_data)
    raw["updated_by"] = principal.uid
    assignment.raw_data = raw
    assignment.updated_at = datetime.now(timezone.utc)

    await db.commit()
    await db.refresh(assignment)
    return assignment


@router.delete("/assignments/{assignment_id}", response_model=APIMessage)
async def delete_assignment(
    assignment_id: str,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> APIMessage:
    if not _can_assign(principal):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Assigner/admin role required")

    assignment = await db.scalar(
        select(RefPortalAssignment).where(RefPortalAssignment.assignment_id == assignment_id)
    )
    if not assignment:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Assignment not found")

    await db.delete(assignment)
    await db.commit()
    return APIMessage(message="Assignment deleted")


# --------- Availability ---------

def _availability_id(user_id: str, date_str: str) -> str:
    return f"{user_id}__{date_str}"


def _availability_time_window(date_str: str, start_time: str | None, end_time: str | None) -> tuple[datetime | None, datetime | None]:
    starts = _parse_game_datetime(date_str, start_time) if start_time else _parse_game_datetime(date_str, "00:00")
    ends = _parse_game_datetime(date_str, end_time) if end_time else _parse_game_datetime(date_str, "23:59")
    return starts, ends


@router.get("/availability", response_model=list[RefAvailabilitySchema])
async def list_availability(
    association_id: str | None = Query(default=None),
    referee_uid: str | None = Query(default=None),
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> list[RefPortalAvailability]:
    statement = select(RefPortalAvailability)
    if referee_uid:
        statement = statement.where(RefPortalAvailability.referee_uid == referee_uid)
    elif association_id:
        scoped_association_id = _scope_association_id(principal, association_id)
        user_rows = await db.scalars(
            select(RefPortalUser.user_id).where(RefPortalUser.association_id == scoped_association_id)
        )
        user_ids = list(user_rows.all())
        if not user_ids:
            return []
        statement = statement.where(RefPortalAvailability.referee_uid.in_(user_ids))
    else:
        if not principal.is_admin:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="association_id or referee_uid required")
    statement = statement.order_by(RefPortalAvailability.starts_at.asc())
    result = await db.scalars(statement)
    return list(result.all())


@router.post("/availability", response_model=RefAvailabilitySchema)
async def upsert_availability(
    payload: AvailabilityUpsertRequest,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> RefPortalAvailability:
    if not principal.is_admin and principal.uid != payload.user_id and not _can_assign(principal):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Cannot set availability for another user")

    availability_id = _availability_id(payload.user_id, payload.date)
    existing = await db.scalar(
        select(RefPortalAvailability).where(RefPortalAvailability.availability_id == availability_id)
    )
    now = datetime.now(timezone.utc)
    starts_at, ends_at = _availability_time_window(payload.date, payload.start_time, payload.end_time)

    raw = dict((existing.raw_data if existing else {}) or {})
    if payload.type is not None:
        raw["type"] = payload.type
    if payload.start_time is not None:
        raw["startTime"] = payload.start_time
    if payload.end_time is not None:
        raw["endTime"] = payload.end_time
    if payload.locked is not None:
        raw["locked"] = payload.locked
    if payload.association_id is not None:
        raw["associationId"] = payload.association_id
    raw["userId"] = payload.user_id
    raw["date"] = payload.date
    raw.update(payload.raw_data or {})

    status_value = payload.type if payload.type is not None else (existing.status if existing else None)

    if existing:
        existing.referee_uid = payload.user_id
        existing.starts_at = starts_at
        existing.ends_at = ends_at
        existing.status = status_value
        existing.raw_data = raw
        existing.updated_at = now
        target = existing
    else:
        target = RefPortalAvailability(
            availability_id=availability_id,
            referee_uid=payload.user_id,
            starts_at=starts_at,
            ends_at=ends_at,
            status=status_value,
            created_at=now,
            updated_at=now,
            raw_data=raw,
        )
        db.add(target)

    await db.commit()
    await db.refresh(target)
    return target


@router.post("/availability/lock", response_model=RefAvailabilitySchema)
async def lock_availability(
    payload: AvailabilityLockRequest,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> RefPortalAvailability:
    if not _can_assign(principal):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Assigner/admin role required")

    availability_id = _availability_id(payload.user_id, payload.date)
    existing = await db.scalar(
        select(RefPortalAvailability).where(RefPortalAvailability.availability_id == availability_id)
    )
    now = datetime.now(timezone.utc)
    raw = dict((existing.raw_data if existing else {}) or {})
    raw["locked"] = payload.locked
    raw["userId"] = payload.user_id
    raw["date"] = payload.date

    if existing:
        existing.raw_data = raw
        existing.updated_at = now
        target = existing
    else:
        starts_at, ends_at = _availability_time_window(payload.date, None, None)
        target = RefPortalAvailability(
            availability_id=availability_id,
            referee_uid=payload.user_id,
            starts_at=starts_at,
            ends_at=ends_at,
            status=None,
            created_at=now,
            updated_at=now,
            raw_data=raw,
        )
        db.add(target)

    await db.commit()
    await db.refresh(target)
    return target


# --------- Pickup requests ---------

@router.get("/pickup-requests", response_model=list[RefPickupRequestSchema])
async def list_pickup_requests(
    association_id: str | None = Query(default=None),
    requester_uid: str | None = Query(default=None),
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> list[RefPortalPickupRequest]:
    statement = select(RefPortalPickupRequest)
    if requester_uid:
        statement = statement.where(RefPortalPickupRequest.requester_uid == requester_uid)
    elif association_id:
        scoped_association_id = _scope_association_id(principal, association_id)
        user_rows = await db.scalars(
            select(RefPortalUser.user_id).where(RefPortalUser.association_id == scoped_association_id)
        )
        user_ids = list(user_rows.all())
        if not user_ids:
            return []
        statement = statement.where(RefPortalPickupRequest.requester_uid.in_(user_ids))
    statement = statement.order_by(RefPortalPickupRequest.created_at.desc())
    result = await db.scalars(statement)
    return list(result.all())


@router.post("/pickup-requests", response_model=RefPickupRequestSchema, status_code=status.HTTP_201_CREATED)
async def create_pickup_request(
    payload: PickupRequestCreateRequest,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> RefPortalPickupRequest:
    if not principal.is_admin and principal.uid != payload.requester_uid and not _can_assign(principal):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Cannot create pickup request for another user")

    now = datetime.now(timezone.utc)
    raw = dict(payload.raw_data or {})
    if payload.association_id:
        raw.setdefault("associationId", payload.association_id)
    raw.setdefault("requesterId", payload.requester_uid)

    row = RefPortalPickupRequest(
        pickup_request_id=str(uuid4()),
        assignment_id=payload.assignment_id or None,
        requester_uid=payload.requester_uid,
        status="pending",
        created_at=now,
        updated_at=now,
        raw_data=raw,
    )
    db.add(row)
    await db.commit()
    await db.refresh(row)
    return row


@router.put("/pickup-requests/{pickup_request_id}", response_model=RefPickupRequestSchema)
async def update_pickup_request(
    pickup_request_id: str,
    payload: PickupRequestUpdateRequest,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> RefPortalPickupRequest:
    row = await db.scalar(
        select(RefPortalPickupRequest).where(RefPortalPickupRequest.pickup_request_id == pickup_request_id)
    )
    if not row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Pickup request not found")

    is_requester = principal.uid == row.requester_uid
    if not principal.is_admin and not _can_assign(principal) and not is_requester:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Cannot modify this pickup request")

    if payload.status is not None:
        row.status = payload.status
    raw = dict(row.raw_data or {})
    if payload.raw_data is not None:
        raw.update(payload.raw_data)
    raw["updated_by"] = principal.uid
    row.raw_data = raw
    row.updated_at = datetime.now(timezone.utc)

    await db.commit()
    await db.refresh(row)
    return row


@router.delete("/pickup-requests/{pickup_request_id}", response_model=APIMessage)
async def delete_pickup_request(
    pickup_request_id: str,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> APIMessage:
    row = await db.scalar(
        select(RefPortalPickupRequest).where(RefPortalPickupRequest.pickup_request_id == pickup_request_id)
    )
    if not row:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Pickup request not found")

    is_requester = principal.uid == row.requester_uid
    if not principal.is_admin and not _can_assign(principal) and not is_requester:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Cannot delete this pickup request")

    await db.delete(row)
    await db.commit()
    return APIMessage(message="Pickup request deleted")
