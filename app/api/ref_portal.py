from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any
from urllib.parse import quote
from uuid import uuid4

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query, status
from fastapi.responses import RedirectResponse
from sqlalchemy import and_, func, select, text, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.database import get_db_session
from app.core.dependencies import get_current_principal
from app.core.security import AuthenticatedPrincipal
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
    RefUserUpdateRequest,
)
from app.services.notifications import RefNotificationTemplate, send_portal_email, send_ref_notification
from app.services.signed_links import (
    verify_assignment_action_token,
)


router = APIRouter(prefix="/ref-portal", tags=["ref_portal"])
settings = get_settings()


def _can_assign(principal: AuthenticatedPrincipal) -> bool:
    if principal.is_admin:
        return True
    return principal.ref_portal_role in {"admin", "assigner"}


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
    raw = association.raw_data or {}
    raw["admin_settings"] = normalized
    raw["admin_settings_updated_at"] = datetime.now(timezone.utc).isoformat()
    association.raw_data = raw
    association.updated_at = datetime.now(timezone.utc)

    await db.commit()
    await db.refresh(association)
    return normalized


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
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> RefPortalUser:
    if not _can_assign(principal):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Assigner/admin role required")

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

    user_id = _clean_text(payload.user_id) or str(uuid4())
    existing = await db.scalar(select(RefPortalUser).where(RefPortalUser.user_id == user_id))
    if existing:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="User already exists")

    existing_email = await db.scalar(
        select(RefPortalUser).where(
            RefPortalUser.association_id == scoped_association_id,
            func.lower(RefPortalUser.email) == email.lower(),
        )
    )
    if existing_email:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="User email already exists in association")

    now = datetime.now(timezone.utc)
    raw_data = dict(payload.raw_data or {})
    if first_name is not None:
        raw_data["firstName"] = first_name
    if last_name is not None:
        raw_data["lastName"] = last_name
    phone = _clean_text(payload.phone)
    if phone is not None:
        raw_data["phone"] = phone

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
    return user


@router.put("/users/{user_id}", response_model=RefUserSchema)
async def update_user(
    user_id: str,
    payload: RefUserUpdateRequest,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> RefPortalUser:
    if not _can_assign(principal):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Assigner/admin role required")

    user = await db.scalar(select(RefPortalUser).where(RefPortalUser.user_id == user_id))
    if not user:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")

    current_assoc = user.association_id
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

    wrapped_html = (
        "<div style=\"font-family:'SF Pro Text','Avenir Next','Segoe UI','Helvetica Neue',Arial,sans-serif;"
        "background:#f3f6f9;padding:18px 10px;color:#1c2735;\">"
        "<div style=\"max-width:660px;margin:0 auto;border:1px solid #e4e8ec;border-radius:16px;overflow:hidden;"
        "background:linear-gradient(160deg,#ffffff 0%,#fcfdff 65%,#f8fbfe 100%);box-shadow:0 10px 26px rgba(16,24,40,0.08);\">"
        "<div style=\"padding:18px 24px 22px;background:linear-gradient(140deg,#0f5d7a 0%,#2f6ea3 100%);color:#ffffff;\">"
        "<div style=\"display:flex;align-items:center;gap:11px;margin-bottom:12px;\">"
        f"{f'<img src=\"{logo_url}\" alt=\"logo\" style=\"width:40px;height:40px;border-radius:8px;object-fit:cover;border:1px solid rgba(255,255,255,0.45);background:rgba(255,255,255,0.15);\" />' if logo_url else ''}"
        f'<p style="margin:0;font-size:20px;line-height:1.2;font-weight:650;">{association_name}</p>'
        "</div>"
        '<p style="margin:0;font-size:11px;font-weight:620;letter-spacing:0.06em;text-transform:uppercase;opacity:0.88;">Refey Officiating</p>'
        f'<h1 style="margin:7px 0 0;font-size:35px;line-height:1.2;font-weight:700;letter-spacing:-0.02em;">{subject}</h1>'
        "</div>"
        f'<div style="padding:24px 24px 18px;font-size:18px;line-height:1.6;color:#1c2735;">{html}</div>'
        "<div style=\"padding:14px 24px 20px;background:#f9fbfd;border-top:1px solid #e4e8ec;\">"
        f'<p style="margin:0;color:#445263;font-size:12px;font-weight:650;text-transform:uppercase;letter-spacing:0.05em;">{association_name}</p>'
        '<p style="margin:5px 0 0;color:#6f7b89;font-size:12px;">This is an automated notification from your association scheduling system.</p>'
        "</div>"
        "</div>"
        "</div>"
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
