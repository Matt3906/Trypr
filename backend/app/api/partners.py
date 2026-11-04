"""Affiliate partners: GET /api/partners (public details) and GET /api/go/<id> (logged redirect)."""

from __future__ import annotations

import logging
import re
from typing import Annotated

from fastapi import APIRouter, Depends, Query, Request
from fastapi.responses import JSONResponse, RedirectResponse

from app.core.db import get_pool
from app.core.errors import ApiError
from app.core.ratelimit import client_ip, limiter
from app.core.sessions import Actor, optional_actor
from app.services import partners

logger = logging.getLogger(__name__)
router = APIRouter(tags=["partners"])

_PLACEMENT = re.compile(r"[^a-z0-9_-]")


@router.get("/partners")
async def list_partners() -> JSONResponse:
    return JSONResponse({"partners": partners.public_view()}, headers={"Cache-Control": "public, max-age=300"})


@router.get("/go/{partner_id}")
async def go(
    request: Request,
    partner_id: str,
    placement: Annotated[str, Query(alias="from", max_length=40)] = "",
    actor: Actor | None = Depends(optional_actor),
):
    limiter.check(f"go:{client_ip(request)}", 120, 60)
    partner = partners.BY_ID.get(partner_id)
    if partner is None or not partners.host_allowed(partner.url):
        raise ApiError(404, "Unknown partner")
    try:  # the click log is for revenue reconciliation; it must never stand between a user and the redirect
        await get_pool().execute(
            "INSERT INTO partner_clicks (uid, partner, category, placement) VALUES ($1, $2, $3, $4)",
            actor.uid if actor else None, partner.id, partner.category, _PLACEMENT.sub("", placement.lower()),
        )
    except Exception:
        logger.exception("partner click log failed")
    return RedirectResponse(partner.url, status_code=302, headers={"Cache-Control": "no-store"})
