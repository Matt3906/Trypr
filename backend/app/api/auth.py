"""Email + password auth with opaque server-side sessions (same pattern as the Refey backend)."""

from __future__ import annotations

import hashlib
import logging
import re
import secrets
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, Request, Response
from pydantic import BaseModel, Field

from app.core.config import get_settings
from app.core.db import get_pool
from app.core.email import EmailDeliveryError, send_email
from app.core.errors import ApiError
from app.core.passwords import hash_password, verify_password
from app.core.ratelimit import client_ip, limiter
from app.core.sessions import (
    Actor,
    clear_session_cookie,
    create_session,
    hash_token,
    optional_actor,
    revoke_session,
    set_session_cookie,
)

router = APIRouter(prefix="/auth", tags=["auth"])
settings = get_settings()
logger = logging.getLogger(__name__)

_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
_RESET_TTL = timedelta(hours=1)
# Verified against when the email is unknown so login timing doesn't reveal which emails exist.
_DUMMY_HASH = hash_password("not-a-real-password")


class Credentials(BaseModel):
    email: str = Field(max_length=254)
    password: str = Field(min_length=1, max_length=72)


class RegisterReq(Credentials):
    password: str = Field(min_length=8, max_length=72)


class ForgotReq(BaseModel):
    email: str = Field(max_length=254)


class ResetReq(BaseModel):
    token: str = Field(min_length=10, max_length=200)
    password: str = Field(min_length=8, max_length=72)


def _norm_email(raw: str) -> str:
    email = raw.strip().lower()
    if not _EMAIL_RE.match(email):
        raise ApiError(400, "Enter a valid email address")
    return email


async def _ensure_admin_doc(conn, uid: str, email: str) -> None:
    """ADMIN_EMAILS bootstrap: the UI gates on an admins/{uid} document."""
    if email.lower() not in settings.admin_email_set:
        return
    await conn.execute(
        """
        INSERT INTO documents (path, parent, coll, id, data)
        VALUES ($1, 'admins', 'admins', $2, $3)
        ON CONFLICT (path) DO NOTHING
        """,
        f"admins/{uid}",
        uid,
        {"createdAt": {"$ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")}, "source": "ADMIN_EMAILS"},
    )


async def _user_payload(conn, uid: str, email: str) -> dict:
    name = await conn.fetchval("SELECT data->>'displayName' FROM documents WHERE path = $1", f"users/{uid}")
    return {"uid": uid, "email": email, "displayName": name or None}


@router.post("/register")
async def register(req: RegisterReq, request: Request, response: Response) -> dict:
    limiter.check(f"register:{client_ip(request)}", 10, 3600)
    email = _norm_email(req.email)
    uid = secrets.token_urlsafe(21)
    pool = get_pool()
    async with pool.acquire() as conn:
        async with conn.transaction():
            exists = await conn.fetchval("SELECT 1 FROM accounts WHERE lower(email) = $1", email)
            if exists:
                raise ApiError(409, "An account with this email already exists. Try signing in.")
            await conn.execute(
                "INSERT INTO accounts (uid, email, password_hash, last_login_at) VALUES ($1,$2,$3,now())",
                uid,
                email,
                hash_password(req.password),
            )
            token = await create_session(conn, uid)
            await _ensure_admin_doc(conn, uid, email)
        set_session_cookie(response, token)
        return {"user": await _user_payload(conn, uid, email)}


@router.post("/login")
async def login(req: Credentials, request: Request, response: Response) -> dict:
    email = req.email.strip().lower()
    limiter.check(f"login-ip:{client_ip(request)}", 30, 600)
    limiter.check(f"login-email:{email}", 10, 600)
    pool = get_pool()
    async with pool.acquire() as conn:
        row = await conn.fetchrow("SELECT uid, email, password_hash FROM accounts WHERE lower(email) = $1", email)
        # Always run a bcrypt check so response time doesn't reveal whether the email exists.
        ok = verify_password(req.password, row["password_hash"] if row else _DUMMY_HASH)
        if not row or not ok:
            raise ApiError(401, "Invalid email or password", code="unauthenticated")
        await conn.execute("UPDATE accounts SET last_login_at = now() WHERE uid = $1", row["uid"])
        token = await create_session(conn, row["uid"])
        await _ensure_admin_doc(conn, row["uid"], row["email"])
        set_session_cookie(response, token)
        return {"user": await _user_payload(conn, row["uid"], row["email"])}


@router.post("/logout")
async def logout(request: Request, response: Response) -> dict:
    token = request.cookies.get(settings.session_cookie_name, "")
    async with get_pool().acquire() as conn:
        await revoke_session(conn, token)
    clear_session_cookie(response)
    return {"ok": True}


@router.get("/me")
async def me(actor: Actor | None = Depends(optional_actor)) -> dict:
    if actor is None:
        return {"user": None}
    async with get_pool().acquire() as conn:
        await _ensure_admin_doc(conn, actor.uid, actor.email)
        return {"user": await _user_payload(conn, actor.uid, actor.email)}


@router.post("/forgot-password")
async def forgot_password(req: ForgotReq, request: Request) -> dict:
    limiter.check(f"forgot-ip:{client_ip(request)}", 10, 3600)
    email = req.email.strip().lower()
    limiter.check(f"forgot-email:{email}", 3, 3600)
    pool = get_pool()
    row = await pool.fetchrow("SELECT uid, email FROM accounts WHERE lower(email) = $1", email)
    if row:
        token = secrets.token_urlsafe(32)
        await pool.execute(
            "INSERT INTO password_resets (token_hash, uid, expires_at) VALUES ($1,$2,$3)",
            hash_token(token),
            row["uid"],
            datetime.now(timezone.utc) + _RESET_TTL,
        )
        link = f"{settings.frontend_base_url.rstrip('/')}/reset-password?token={token}"
        text = (
            "Someone (hopefully you) asked to reset your Trypr password.\n\n"
            f"Choose a new password here (valid for 1 hour):\n{link}\n\n"
            "If you didn't ask for this, you can ignore this email."
        )
        try:
            await send_email(to_email=row["email"], subject="Reset your Trypr password", body_text=text)
        except EmailDeliveryError:
            logger.exception("Password reset email failed for uid=%s", row["uid"])
    # Same response whether or not the account exists.
    return {"ok": True}


@router.post("/reset-password")
async def reset_password(req: ResetReq, request: Request) -> dict:
    limiter.check(f"reset-ip:{client_ip(request)}", 20, 3600)
    pool = get_pool()
    async with pool.acquire() as conn:
        async with conn.transaction():
            row = await conn.fetchrow(
                "SELECT uid FROM password_resets WHERE token_hash = $1 AND used_at IS NULL AND expires_at > now() FOR UPDATE",
                hash_token(req.token),
            )
            if not row:
                raise ApiError(400, "This reset link is invalid or has expired.")
            await conn.execute("UPDATE accounts SET password_hash = $2 WHERE uid = $1", row["uid"], hash_password(req.password))
            await conn.execute("UPDATE password_resets SET used_at = now() WHERE token_hash = $1", hash_token(req.token))
            await conn.execute("DELETE FROM sessions WHERE uid = $1", row["uid"])  # sign out everywhere
    return {"ok": True}
