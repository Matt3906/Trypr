"""Opaque server-side sessions: a 256-bit token in an HttpOnly cookie; only its SHA-256 is stored."""

from __future__ import annotations

import hashlib
import secrets
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

import asyncpg
from fastapi import Depends, HTTPException, Request, Response, status

from app.core.config import get_settings
from app.core.db import get_pool

settings = get_settings()


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


@dataclass(slots=True)
class Actor:
    uid: str
    email: str
    is_admin: bool = False


async def create_session(conn: asyncpg.Connection, uid: str) -> str:
    token = secrets.token_urlsafe(32)
    now = datetime.now(timezone.utc)
    await conn.execute(
        "INSERT INTO sessions (token_hash, uid, created_at, expires_at, last_used_at) VALUES ($1,$2,$3,$4,$3)",
        hash_token(token),
        uid,
        now,
        now + timedelta(days=settings.session_ttl_days),
    )
    return token


async def revoke_session(conn: asyncpg.Connection, token: str) -> None:
    if token:
        await conn.execute("DELETE FROM sessions WHERE token_hash = $1", hash_token(token))


def set_session_cookie(response: Response, token: str) -> None:
    response.set_cookie(
        key=settings.session_cookie_name,
        value=token,
        max_age=settings.session_ttl_days * 86400,
        httponly=True,
        secure=settings.is_production,
        samesite="lax",
        path="/",
    )


def clear_session_cookie(response: Response) -> None:
    response.delete_cookie(
        key=settings.session_cookie_name,
        httponly=True,
        secure=settings.is_production,
        samesite="lax",
        path="/",
    )


async def load_actor(request: Request) -> Actor | None:
    token = request.cookies.get(settings.session_cookie_name)
    if not token:
        return None
    row = await get_pool().fetchrow(
        """
        SELECT a.uid, a.email,
               EXISTS (SELECT 1 FROM documents d WHERE d.path = 'admins/' || a.uid) AS has_admin_doc
        FROM sessions s JOIN accounts a ON a.uid = s.uid
        WHERE s.token_hash = $1 AND s.expires_at > now()
        """,
        hash_token(token),
    )
    if not row:
        return None
    is_admin = bool(row["has_admin_doc"]) or row["email"].lower() in settings.admin_email_set
    return Actor(uid=row["uid"], email=row["email"], is_admin=is_admin)


async def optional_actor(request: Request) -> Actor | None:
    return await load_actor(request)


async def require_actor(actor: Actor | None = Depends(optional_actor)) -> Actor:
    if actor is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Sign in required")
    return actor


async def purge_expired() -> None:
    pool = get_pool()
    await pool.execute("DELETE FROM sessions WHERE expires_at <= now()")
    await pool.execute("DELETE FROM password_resets WHERE expires_at <= now() OR used_at IS NOT NULL")
