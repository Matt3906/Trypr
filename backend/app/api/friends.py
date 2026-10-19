"""Friend requests. Cross-user writes can't be safe client-side rules, so they live here."""

from __future__ import annotations

from datetime import datetime, timezone
from uuid import uuid4

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from app.core.db import get_pool
from app.core.errors import ApiError
from app.core.ratelimit import limiter
from app.core.sessions import Actor, require_actor
from app.docstore.fields import fmt_ts
from app.docstore.store import server_set

router = APIRouter(prefix="/friends", tags=["friends"])


class RequestReq(BaseModel):
    email: str = Field(max_length=254)


class AcceptReq(BaseModel):
    request_id: str = Field(alias="requestId", max_length=200)
    model_config = {"populate_by_name": True}


class RemoveReq(BaseModel):
    uid: str = Field(max_length=200)


def _uid_of(entry) -> str:
    if isinstance(entry, dict):
        return str(entry.get("uid") if entry.get("uid") is not None else entry.get("id", ""))
    return str(entry)


async def _display(conn, uid: str, email: str) -> str:
    name = await conn.fetchval("SELECT data->>'displayName' FROM documents WHERE path = $1", f"users/{uid}")
    return name or email or uid


async def _friends(conn, uid: str) -> list:
    data = await conn.fetchval("SELECT data FROM documents WHERE path = $1", f"users/{uid}")
    return list((data or {}).get("friends") or [])


@router.post("/request")
async def send_request(req: RequestReq, actor: Actor = Depends(require_actor)) -> dict:
    limiter.check(f"friend-req:{actor.uid}", 20, 3600)
    email = req.email.strip().lower()
    async with get_pool().acquire() as conn:
        async with conn.transaction():
            target = await conn.fetchrow("SELECT uid, email FROM accounts WHERE lower(email) = $1", email)
            if not target:
                raise ApiError(404, "No user found")
            if target["uid"] == actor.uid:
                raise ApiError(400, "You can't add yourself")
            if any(_uid_of(f) == target["uid"] for f in await _friends(conn, actor.uid)):
                raise ApiError(409, "You're already friends")
            dup = await conn.fetchval(
                "SELECT 1 FROM documents WHERE parent = $1 AND data->>'fromUid' = $2 AND coalesce(data->>'status','pending') = 'pending'",
                f"users/{target['uid']}/friendRequests",
                actor.uid,
            )
            if not dup:
                await server_set(
                    conn,
                    f"users/{target['uid']}/friendRequests/{uuid4().hex[:20]}",
                    {
                        "fromUid": actor.uid,
                        "fromEmail": actor.email,
                        "fromName": await _display(conn, actor.uid, actor.email),
                        "createdAt": {"$ts": fmt_ts(datetime.now(timezone.utc))},
                        "status": "pending",
                    },
                    merge=False,
                )
    return {"ok": True}


@router.post("/accept")
async def accept(req: AcceptReq, actor: Actor = Depends(require_actor)) -> dict:
    async with get_pool().acquire() as conn:
        async with conn.transaction():
            rpath = f"users/{actor.uid}/friendRequests/{req.request_id}"
            r = await conn.fetchval("SELECT data FROM documents WHERE path = $1 FOR UPDATE", rpath)
            if r is None:
                raise ApiError(404, "Friend request not found")
            from_uid = r.get("fromUid") or ""
            from_email = r.get("fromEmail") or ""
            from_name = r.get("fromName") or from_email or from_uid

            if not from_uid:  # legacy request without a uid: record the name only
                mine = await _friends(conn, actor.uid)
                mine.append({"uid": "", "displayName": from_name, "email": from_email})
                await server_set(conn, f"users/{actor.uid}", {"friends": mine})
            else:
                for u in sorted({actor.uid, from_uid}):  # stable lock order
                    await conn.execute("SELECT 1 FROM documents WHERE path = $1 FOR UPDATE", f"users/{u}")
                mine = await _friends(conn, actor.uid)
                if not any(_uid_of(f) == from_uid for f in mine):
                    mine.append({"uid": from_uid, "displayName": from_name, "email": from_email})
                theirs = await _friends(conn, from_uid)
                if not any(_uid_of(f) == actor.uid for f in theirs):
                    theirs.append({
                        "uid": actor.uid,
                        "displayName": await _display(conn, actor.uid, actor.email),
                        "email": actor.email,
                    })
                await server_set(conn, f"users/{actor.uid}", {"friends": mine})
                await server_set(conn, f"users/{from_uid}", {"friends": theirs})
            await conn.execute("DELETE FROM documents WHERE path = $1", rpath)
    return {"ok": True}


@router.post("/remove")
async def remove(req: RemoveReq, actor: Actor = Depends(require_actor)) -> dict:
    async with get_pool().acquire() as conn:
        async with conn.transaction():
            for u in sorted({actor.uid, req.uid}):
                await conn.execute("SELECT 1 FROM documents WHERE path = $1 FOR UPDATE", f"users/{u}")
            mine = [f for f in await _friends(conn, actor.uid) if _uid_of(f) != req.uid]
            await server_set(conn, f"users/{actor.uid}", {"friends": mine})
            if await conn.fetchval("SELECT 1 FROM documents WHERE path = $1", f"users/{req.uid}"):
                theirs = [f for f in await _friends(conn, req.uid) if _uid_of(f) != actor.uid]
                await server_set(conn, f"users/{req.uid}", {"friends": theirs})
    return {"ok": True}
