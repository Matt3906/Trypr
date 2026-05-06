from __future__ import annotations

import base64
import hashlib
import hmac
import json
from datetime import datetime, timedelta, timezone
from typing import Any

from fastapi import HTTPException, status

from app.core.config import get_settings


settings = get_settings()


def _b64url_encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("utf-8").rstrip("=")


def _b64url_decode(encoded: str) -> bytes:
    pad_len = (4 - (len(encoded) % 4)) % 4
    return base64.urlsafe_b64decode(encoded + ("=" * pad_len))


def _sign(payload_b64: str, secret: str) -> str:
    digest = hmac.new(secret.encode("utf-8"), payload_b64.encode("utf-8"), hashlib.sha256).digest()
    return _b64url_encode(digest)


def generate_assignment_action_token(
    *,
    assignment_id: str,
    association_id: str,
    status_value: str,
    expires_at: datetime | None = None,
    ttl_hours: int = 48,
) -> str:
    secret = settings.ref_portal_action_secret
    if not secret:
        raise ValueError("REF_PORTAL_ACTION_SECRET is required for signed action links")

    expiry = expires_at or (datetime.now(timezone.utc) + timedelta(hours=ttl_hours))
    payload: dict[str, Any] = {
        "aid": assignment_id,
        "assoc": association_id,
        "status": status_value,
        "exp": int(expiry.astimezone(timezone.utc).timestamp()),
    }
    payload_json = json.dumps(payload, separators=(",", ":"), sort_keys=True)
    payload_b64 = _b64url_encode(payload_json.encode("utf-8"))
    signature = _sign(payload_b64, secret)
    return f"{payload_b64}.{signature}"


def verify_assignment_action_token(token: str) -> dict[str, Any]:
    secret = settings.ref_portal_action_secret
    if not secret:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Signed link secret is not configured",
        )

    try:
        payload_b64, signature = token.split(".", maxsplit=1)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid token format") from exc

    expected_signature = _sign(payload_b64, secret)
    if not hmac.compare_digest(signature, expected_signature):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid token signature")

    try:
        payload = json.loads(_b64url_decode(payload_b64).decode("utf-8"))
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid token payload") from exc

    exp = payload.get("exp")
    if not isinstance(exp, int):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid token expiry")

    now_ts = int(datetime.now(timezone.utc).timestamp())
    if exp < now_ts:
        raise HTTPException(status_code=status.HTTP_410_GONE, detail="Signed link has expired")

    aid = payload.get("aid")
    assoc = payload.get("assoc")
    status_value = payload.get("status")
    if not isinstance(aid, str) or not aid:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid assignment token")
    if not isinstance(assoc, str) or not assoc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid association token")
    if status_value not in {"accepted", "declined"}:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Invalid assignment action")

    return payload
