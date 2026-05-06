from __future__ import annotations

import logging

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
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
