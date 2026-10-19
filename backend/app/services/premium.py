from __future__ import annotations

from typing import Any

from app.core.db import get_pool
from app.core.sessions import Actor


def _roles(value: Any) -> list[str]:
    if isinstance(value, list):
        return [str(r).lower() for r in value]
    if isinstance(value, str):
        return [value.lower()]
    return []


async def can_access_premium(actor: Actor) -> bool:
    """Admin, or userEntitlements/{uid} marks the account premium (server-written only)."""
    if actor.is_admin:
        return True
    ent = await get_pool().fetchval("SELECT data FROM documents WHERE path = $1", f"userEntitlements/{actor.uid}") or {}
    if str(ent.get("subscription", "")).lower() == "premium":
        return True
    if str(ent.get("subscriptionStatus", "")).lower() == "premium":
        return True
    return "admin" in _roles(ent.get("role", ent.get("roles")))
