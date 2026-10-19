"""Document writes. Everything here runs inside a caller-provided transaction."""

from __future__ import annotations

from typing import Any, Literal

import asyncpg
from pydantic import BaseModel, Field

from app.core.errors import ApiError
from app.docstore.fields import apply_patch, apply_update, check_size
from app.docstore.paths import DocPath, doc_path
from app.docstore.rules import CREATE, DELETE, UPDATE, Denied, Rules

# Written only by the server (Stripe webhook / checkout); clients can't set or clear them.
SERVER_MANAGED_USER_FIELDS = (
    "subscription",
    "subscriptionType",
    "subscriptionStatus",
    "premiumSource",
    "premiumPlan",
    "premiumEnabledAt",
    "premiumDisabledAt",
    "premiumPlanPending",
    "premiumCheckoutSessionId",
    "currentPeriodEnd",
    "stripeCustomerId",
    "stripeSubscriptionId",
    "stripePriceId",
)


class WriteOp(BaseModel):
    op: Literal["set", "update", "delete"]
    path: str
    data: dict[str, Any] | None = None
    merge: bool = False
    create_only: bool = Field(default=False, alias="createOnly")

    model_config = {"populate_by_name": True}


class Precondition(BaseModel):
    path: str
    rev: int | None = None  # None => document must not exist


async def fetch(conn: asyncpg.Connection, path: str, *, lock: bool = False) -> asyncpg.Record | None:
    return await conn.fetchrow(
        "SELECT path, data, rev FROM documents WHERE path = $1" + (" FOR UPDATE" if lock else ""), path
    )


def _protect_user_fields(dp: DocPath, existing: dict | None, final: dict, is_admin: bool) -> None:
    if is_admin or dp.segs[0] != "users" or len(dp.segs) != 2:
        return
    for k in SERVER_MANAGED_USER_FIELDS:
        if existing is not None and k in existing:
            final[k] = existing[k]
        else:
            final.pop(k, None)


async def _upsert(conn: asyncpg.Connection, dp: DocPath, data: dict) -> int:
    return await conn.fetchval(
        """
        INSERT INTO documents (path, parent, coll, id, data)
        VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (path) DO UPDATE
           SET data = EXCLUDED.data, rev = documents.rev + 1, updated_at = now()
        RETURNING rev
        """,
        dp.path,
        dp.parent,
        dp.coll,
        dp.id,
        data,
    )


async def apply_write(
    conn: asyncpg.Connection, w: WriteOp, rules: Rules | None
) -> dict[str, Any]:
    """Apply one write. `rules=None` means a trusted server-side write (no authorization)."""
    dp = doc_path(w.path)
    row = await fetch(conn, dp.path, lock=True)
    existing = row["data"] if row else None

    if w.op == "delete":
        if rules:
            try:
                await rules.check(DELETE, dp.segs, existing, None)
            except Denied as e:
                raise ApiError(403, str(e)) from None
        if row:
            await conn.execute("DELETE FROM documents WHERE path = $1", dp.path)
            if rules and dp.segs[0] == "users" and len(dp.segs) == 4 and dp.segs[2] == "trips":
                rules.forget_trip(dp.segs[1], dp.segs[3])
        return {"path": dp.path, "rev": None}

    data = w.data or {}
    if w.op == "update":
        if existing is None:
            raise ApiError(404, "No document to update")
        final = apply_update(existing, data)
    else:  # set
        if w.create_only and existing is not None:
            raise ApiError(409, "Document already exists")
        final = apply_patch(existing if (w.merge and existing) else {}, data)

    _protect_user_fields(dp, existing, final, bool(rules and rules.admin) or rules is None)
    check_size(final)

    if rules:
        try:
            await rules.check(UPDATE if existing is not None else CREATE, dp.segs, existing, final)
        except Denied as e:
            raise ApiError(403, str(e)) from None

    rev = await _upsert(conn, dp, final)
    if rules and dp.segs[0] == "users" and len(dp.segs) == 4 and dp.segs[2] == "trips":
        rules.forget_trip(dp.segs[1], dp.segs[3])
    return {"path": dp.path, "rev": rev}


async def check_preconditions(conn: asyncpg.Connection, pres: list[Precondition]) -> None:
    for pre in pres:
        dp = doc_path(pre.path)
        row = await fetch(conn, dp.path, lock=True)
        current = row["rev"] if row else None
        if current != pre.rev:
            raise ApiError(409, "Document changed during the transaction", code="aborted")


async def server_set(
    conn: asyncpg.Connection, path: str, data: dict[str, Any], *, merge: bool = True
) -> dict[str, Any]:
    """Trusted write used by server code (Stripe webhook, admin bootstrap)."""
    return await apply_write(conn, WriteOp(op="set", path=path, data=data, merge=merge), None)
