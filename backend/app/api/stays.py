"""Hotel price comparison: /api/stays/search (cheapest-first across providers) and /api/stays/out (click-out)."""

from __future__ import annotations

import logging
from datetime import date, timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, Query, Request
from fastapi.responses import JSONResponse, RedirectResponse

from app.core.config import get_settings
from app.core.db import get_pool
from app.core.errors import ApiError
from app.core.ratelimit import client_ip, limiter
from app.core.sessions import Actor, optional_actor
from app.services.stays import engine, links
from app.services.stays.models import Offer, StayQuery
from app.services.stays.providers import link_hosts
from app.services.stays.providers.hotellook import HotellookProvider, search_url

logger = logging.getLogger(__name__)
router = APIRouter(tags=["stays"])

MAX_NIGHTS = 30


@router.get("/stays/search")
async def search_stays(
    request: Request,
    lat: Annotated[float, Query(ge=-90, le=90)],
    lon: Annotated[float, Query(ge=-180, le=180)],
    check_in: date,
    check_out: date,
    adults: Annotated[int, Query(ge=1, le=8)] = 2,
    currency: Annotated[str, Query(pattern=r"^[A-Za-z]{3}$")] = "USD",
    radius_km: Annotated[float, Query(gt=0, le=50)] = 15.0,
    name: Annotated[str, Query(max_length=120)] = "",
) -> JSONResponse:
    limiter.check(f"stays:{client_ip(request)}", 40, 60)
    nights = (check_out - check_in).days
    if nights < 1 or nights > MAX_NIGHTS:
        raise ApiError(400, f"Stay must be between 1 and {MAX_NIGHTS} nights.")
    if check_in < date.today() - timedelta(days=1):
        raise ApiError(400, "Check-in date is in the past.")
    if not links.signing_available():
        raise ApiError(503, "Stay comparison is not configured.", "unavailable")

    q = StayQuery(lat=round(lat, 4), lon=round(lon, 4), check_in=check_in, check_out=check_out, adults=adults,
                  currency=currency.upper(), radius_km=radius_km, name=name.strip())
    payload = await engine.search(q)
    payload["searchLink"] = _search_link(q)
    return JSONResponse(payload, headers={"Cache-Control": "no-store"})


def _search_link(q: StayQuery) -> dict | None:
    """A commission-earning results page for these dates, shown when live prices are missing or empty."""
    url = search_url(q, get_settings().travelpayouts_marker)
    if url is None:
        return None
    stand_in = Offer(provider=HotellookProvider.id, provider_hotel_id="search", hotel_name=f"Search: {q.name}", lat=q.lat,
                     lon=q.lon, total_cents=0, currency=q.currency, url=url)
    return {"label": HotellookProvider.label, "url": f"/api/stays/out?t={links.sign(stand_in, q)}"}


@router.get("/stays/out")
async def click_out(request: Request, t: Annotated[str, Query(max_length=4096)], actor: Actor | None = Depends(optional_actor)):
    limiter.check(f"stays-out:{client_ip(request)}", 120, 60)
    claim = links.verify(t, link_hosts())
    if claim is None:
        raise ApiError(400, "This link is invalid or has expired. Search again to get a fresh one.")
    try:  # the click log is for revenue reconciliation; it must never stand between a user and the redirect
        await get_pool().execute(
            "INSERT INTO stay_clicks (uid, provider, hotel, total_cents, currency, check_in, check_out) "
            "VALUES ($1, $2, $3, $4, $5, $6, $7)",
            actor.uid if actor else None, claim.provider, claim.hotel, claim.total_cents, claim.currency,
            date.fromisoformat(claim.check_in), date.fromisoformat(claim.check_out),
        )
    except Exception:
        logger.exception("stay click log failed")
    return RedirectResponse(claim.url, status_code=302, headers={"Cache-Control": "no-store"})
