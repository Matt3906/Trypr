"""Firestore-shaped document API used by the frontend shim (frontend/src/backend/firestore.ts)."""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from app.core.db import get_pool
from app.core.errors import ApiError
from app.core.ratelimit import client_ip, limiter
from app.core.sessions import Actor, optional_actor
from app.docstore.paths import coll_path, doc_path
from app.docstore.query import build_query, etag_for
from app.docstore.rules import READ, Denied, Rules
from app.docstore.store import Precondition, WriteOp, apply_write, check_preconditions

router = APIRouter(prefix="/db", tags=["db"])

MAX_WRITES = 500


class GetReq(BaseModel):
    path: str
    if_rev: int | None = Field(default=None, alias="ifRev")  # reply notModified when unchanged

    model_config = {"populate_by_name": True}


class QueryReq(BaseModel):
    path: str | None = None  # collection path
    group: str | None = None  # collection-group id
    where: list[list[Any]] = Field(default_factory=list)
    order_by: list[list[str]] = Field(default_factory=list, alias="orderBy")
    limit: int | None = None
    etag: str | None = None  # client's last etag: reply notModified when unchanged

    model_config = {"populate_by_name": True}


class WriteReq(BaseModel):
    writes: list[WriteOp]
    preconditions: list[Precondition] = Field(default_factory=list)


def _row(r) -> dict[str, Any]:
    return {"id": r["id"] if "id" in r else r["path"].rsplit("/", 1)[-1], "path": r["path"], "data": r["data"], "rev": r["rev"]}


@router.post("/get")
async def get_doc(req: GetReq, actor: Actor | None = Depends(optional_actor)) -> dict[str, Any]:
    dp = doc_path(req.path)
    pool = get_pool()
    row = await pool.fetchrow("SELECT path, id, data, rev FROM documents WHERE path = $1", dp.path)
    if not row:
        return {"exists": False, "id": dp.id, "path": dp.path}
    try:
        await Rules(pool, actor).check(READ, dp.segs, row["data"], None)
    except Denied as e:
        raise ApiError(403, str(e)) from None
    if req.if_rev is not None and req.if_rev == row["rev"]:
        return {"notModified": True, "rev": row["rev"]}
    return {"exists": True, **_row(row)}


@router.post("/query")
async def query_docs(req: QueryReq, actor: Actor | None = Depends(optional_actor)) -> dict[str, Any]:
    if (req.path is None) == (req.group is None):
        raise ApiError(400, "Provide exactly one of path or group")
    pool = get_pool()
    rules = Rules(pool, actor)
    segs = coll_path(req.path) if req.path else None
    try:
        scope_sql, scope_params = await rules.list_scope(segs, req.group)
    except Denied as e:
        raise ApiError(403, str(e)) from None

    sql, params = build_query(
        parent="/".join(segs) if segs else None,
        group=req.group,
        scope_sql=scope_sql,
        scope_params=scope_params,
        where=req.where,
        order_by=req.order_by,
        limit=req.limit,
    )
    rows = await pool.fetch(sql, *params)
    etag = etag_for(rows)
    if req.etag and req.etag == etag:
        return {"notModified": True, "etag": etag}
    return {"docs": [_row(r) for r in rows], "etag": etag}


@router.post("/write")
async def write_docs(
    req: WriteReq, request: Request, actor: Actor | None = Depends(optional_actor)
) -> dict[str, Any]:
    if not req.writes or len(req.writes) > MAX_WRITES:
        raise ApiError(400, f"Provide between 1 and {MAX_WRITES} writes")
    if actor is None:
        # Anonymous writes (public form responses / uploads) are tightly rate limited.
        limiter.check(f"anon-write:{client_ip(request)}", 20, 60)

    pool = get_pool()
    async with pool.acquire() as conn:
        async with conn.transaction():
            rules = Rules(conn, actor)
            if req.preconditions:
                await check_preconditions(conn, req.preconditions)
            results = [await apply_write(conn, w, rules) for w in req.writes]
    return {"results": results}
