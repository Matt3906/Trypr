from __future__ import annotations

import logging

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import func, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.database import get_db_session
from app.core.security import AuthenticatedPrincipal, verify_firebase_token
from app.models.db_models import RefPortalUser, TryprAdmin, TryprUser


bearer_scheme = HTTPBearer(auto_error=False)
settings = get_settings()
logger = logging.getLogger(__name__)


def _get_admin_emails() -> set[str]:
    return {
        email.strip().lower()
        for email in settings.admin_emails.split(",")
        if email.strip()
    }


async def _link_ref_portal_user_by_email(
    db: AsyncSession,
    *,
    firebase_uid: str,
    email: str | None,
) -> RefPortalUser | None:
    """Re-key one legacy ref portal profile to the Firebase UID.

    Older invite flows could create ref_portal.users.user_id with a generated
    UUID while Firebase Auth later issued a different UID. Authenticated portal
    requests are scoped by Firebase UID, so those users looked unassigned after
    login even though admins could see their email inside an association.
    """
    normalized_email = (email or "").strip().lower()
    if not normalized_email:
        return None

    result = await db.scalars(
        select(RefPortalUser)
        .where(func.lower(RefPortalUser.email) == normalized_email)
        .order_by(RefPortalUser.created_at.asc().nulls_last(), RefPortalUser.user_id.asc())
        .limit(2)
    )
    matches = list(result.all())
    if not matches:
        return None
    if len(matches) > 1:
        logger.warning(
            "Ref portal email lookup is ambiguous; not auto-linking uid=%s email=%s",
            firebase_uid,
            normalized_email,
        )
        return None

    legacy_user = matches[0]
    if legacy_user.user_id == firebase_uid:
        return legacy_user

    old_uid = legacy_user.user_id
    logger.info(
        "Auto-linking legacy ref portal user row to Firebase UID (old_uid=%s firebase_uid=%s email=%s)",
        old_uid,
        firebase_uid,
        normalized_email,
    )

    await db.execute(
        text(
            """
            INSERT INTO ref_portal.users (
                user_id, association_id, email, display_name, role,
                created_at, updated_at, raw_data
            )
            SELECT :new_uid, association_id, email, display_name, role,
                   created_at, NOW(), raw_data || jsonb_build_object(
                       'linkedFromUserId', user_id,
                       'linkedBy', 'auth_email_match',
                       'linkedAt', NOW()::text
                   )
            FROM ref_portal.users
            WHERE user_id = :old_uid
            ON CONFLICT (user_id) DO NOTHING
            """
        ),
        {"new_uid": firebase_uid, "old_uid": old_uid},
    )
    await db.execute(
        text("UPDATE ref_portal.assignments SET referee_uid = :new_uid WHERE referee_uid = :old_uid"),
        {"new_uid": firebase_uid, "old_uid": old_uid},
    )
    await db.execute(
        text("UPDATE ref_portal.availability SET referee_uid = :new_uid WHERE referee_uid = :old_uid"),
        {"new_uid": firebase_uid, "old_uid": old_uid},
    )
    await db.execute(
        text("UPDATE ref_portal.pickup_requests SET requester_uid = :new_uid WHERE requester_uid = :old_uid"),
        {"new_uid": firebase_uid, "old_uid": old_uid},
    )
    await db.execute(
        text("DELETE FROM ref_portal.users WHERE user_id = :old_uid"),
        {"old_uid": old_uid},
    )
    await db.commit()

    return await db.scalar(select(RefPortalUser).where(RefPortalUser.user_id == firebase_uid))


async def get_current_principal(
    credentials: HTTPAuthorizationCredentials = Depends(bearer_scheme),
    db: AsyncSession = Depends(get_db_session),
) -> AuthenticatedPrincipal:
    if not credentials or not credentials.credentials:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing bearer token",
        )

    token_data = verify_firebase_token(credentials.credentials)
    uid = token_data.get("sub") or token_data.get("uid") or token_data.get("user_id")
    if not uid:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token missing uid claim",
        )

    email = token_data.get("email")

    try:
        trypr_user = await db.scalar(select(TryprUser.uid).where(TryprUser.uid == uid))
        ref_portal_user = await db.scalar(
            select(RefPortalUser).where(RefPortalUser.user_id == uid)
        )
        if not ref_portal_user:
            ref_portal_user = await _link_ref_portal_user_by_email(
                db,
                firebase_uid=uid,
                email=email,
            )
        is_admin = await db.scalar(select(TryprAdmin.uid).where(TryprAdmin.uid == uid))
    except Exception:
        logger.exception("Failed SQL principal lookup (uid=%s, email=%s)", uid, email)
        raise

    configured_admin = bool(email and email.lower() in _get_admin_emails())

    principal = AuthenticatedPrincipal(
        uid=uid,
        email=email,
        is_trypr_user=bool(trypr_user),
        is_ref_portal_user=bool(ref_portal_user),
        is_admin=bool(is_admin) or configured_admin,
        ref_portal_role=ref_portal_user.role if ref_portal_user else None,
        ref_portal_association_id=ref_portal_user.association_id if ref_portal_user else None,
    )

    if not principal.is_trypr_user and not principal.is_ref_portal_user and not principal.is_admin:
        logger.warning(
            "Authorization denied: user not provisioned (uid=%s, email=%s, configured_admin=%s)",
            principal.uid,
            principal.email,
            configured_admin,
        )
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Authenticated user is not provisioned in SQL user tables",
        )

    logger.info(
        "Resolved principal uid=%s email=%s is_admin=%s ref_role=%s ref_assoc=%s",
        principal.uid,
        principal.email,
        principal.is_admin,
        principal.ref_portal_role,
        principal.ref_portal_association_id,
    )

    return principal


def require_admin(principal: AuthenticatedPrincipal = Depends(get_current_principal)) -> AuthenticatedPrincipal:
    if not principal.is_admin:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Admin role required")
    return principal
