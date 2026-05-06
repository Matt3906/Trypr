from __future__ import annotations

from dataclasses import dataclass
import logging

import firebase_admin
from firebase_admin import auth, credentials
from fastapi import HTTPException, status
from google.auth.exceptions import DefaultCredentialsError
from google.auth.transport.requests import Request
from google.oauth2 import id_token as google_id_token

from app.core.config import get_settings


settings = get_settings()
logger = logging.getLogger(__name__)


def ensure_firebase_admin() -> None:
    if firebase_admin._apps:
        return

    if settings.firebase_credentials_path:
        cred = credentials.Certificate(settings.firebase_credentials_path)
        firebase_admin.initialize_app(
            cred,
            {"projectId": settings.firebase_project_id},
        )
        logger.info(
            "Initialized Firebase Admin with service account credential (project_id=%s)",
            settings.firebase_project_id,
        )
        return

    cred = credentials.ApplicationDefault()
    firebase_admin.initialize_app(
        cred,
        {"projectId": settings.firebase_project_id},
    )
    logger.info(
        "Initialized Firebase Admin with application default credential (project_id=%s)",
        settings.firebase_project_id,
    )


def verify_firebase_token(id_token: str) -> dict:
    ensure_firebase_admin()
    try:
        return auth.verify_id_token(id_token, check_revoked=False)
    except DefaultCredentialsError:
        # Local fallback: verify Firebase JWT against public certs when ADC is unavailable.
        try:
            decoded = google_id_token.verify_firebase_token(
                id_token,
                Request(),
                audience=settings.firebase_project_id,
            )
            if decoded:
                return decoded
            raise ValueError("Token decode returned empty payload")
        except Exception as exc:  # noqa: BLE001
            token_hint = "<empty>"
            if id_token:
                token_hint = (
                    f"{id_token[:12]}...{id_token[-8:]}"
                    if len(id_token) > 24
                    else "<short-token>"
                )
            logger.warning(
                "Firebase fallback verification failed (project_id=%s, token_hint=%s): %s",
                settings.firebase_project_id,
                token_hint,
                exc,
                exc_info=True,
            )
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Invalid Firebase ID token",
            ) from exc
    except Exception as exc:  # noqa: BLE001
        token_hint = "<empty>"
        if id_token:
            token_hint = (
                f"{id_token[:12]}...{id_token[-8:]}"
                if len(id_token) > 24
                else "<short-token>"
            )
        logger.warning(
            "Firebase token verification failed (project_id=%s, token_hint=%s): %s",
            settings.firebase_project_id,
            token_hint,
            exc,
            exc_info=True,
        )
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid Firebase ID token",
        ) from exc


@dataclass(slots=True)
class AuthenticatedPrincipal:
    uid: str
    email: str | None
    is_trypr_user: bool
    is_ref_portal_user: bool
    is_admin: bool
    ref_portal_role: str | None = None
    ref_portal_association_id: str | None = None
