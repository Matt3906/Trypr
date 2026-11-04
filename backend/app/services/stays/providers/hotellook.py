"""Travelpayouts / Hotellook: a metasearch that itself compares ~70 booking sites.

Open to ordinary affiliates (sign up at travelpayouts.com, no contract), which is why it is the first
real provider. It serves *cached* "from" prices that were seen in recent searches, so offers are marked
live=False and the partner re-checks the price after the click-out.

Endpoint shapes below follow Hotellook's public "cache.json" API and have NOT been exercised against the
live service from this repo (it needs a token). The parser is defensive and covered by tests with a
recorded-shape fixture; confirm both URLs against the current Travelpayouts docs when you add the token.
"""

from __future__ import annotations

import logging
from urllib.parse import urlencode

import httpx

from app.core.config import get_settings

from ..models import Offer, StayQuery

logger = logging.getLogger(__name__)

API_URL = "https://engine.hotellook.com/api/v2/cache.json"
LINK_URL = "https://search.hotellook.com/hotels"
TIMEOUT_S = 10.0


class HotellookProvider:
    id = "hotellook"
    label = "Hotellook"
    link_hosts = ("hotellook.com", "tp.media")

    def enabled(self) -> bool:
        return bool(get_settings().travelpayouts_token)

    async def search(self, q: StayQuery) -> list[Offer]:
        s = get_settings()
        if not q.name:
            return []  # the API searches by place name, not coordinates
        params = {
            "location": q.name, "currency": q.currency.lower(), "checkIn": q.check_in.isoformat(),
            "checkOut": q.check_out.isoformat(), "adults": q.adults, "limit": 100, "token": s.travelpayouts_token,
        }
        async with httpx.AsyncClient(timeout=TIMEOUT_S) as client:
            resp = await client.get(API_URL, params=params)
        resp.raise_for_status()
        return parse(resp.json(), q, s.travelpayouts_marker)


def search_url(q: StayQuery, marker: str) -> str | None:
    """Hotellook's own results page for these dates, tagged with the affiliate marker.

    Needs only the marker (no API token), so it can earn commission before price-API access exists.
    search.hotellook.com hands off to Travelpayouts' tracker, which carries `marker` through.
    """
    if not marker or not q.name:
        return None
    params = {
        "destination": q.name, "checkIn": q.check_in.isoformat(), "checkOut": q.check_out.isoformat(),
        "adults": q.adults, "currency": q.currency.lower(), "language": "en", "marker": marker,
    }
    return f"{LINK_URL}?{urlencode(params)}"


def parse(payload: object, q: StayQuery, marker: str) -> list[Offer]:
    if not isinstance(payload, list):
        return []
    offers: list[Offer] = []
    for item in payload:
        try:
            geo = item["location"]["geo"]
            lat, lon = float(geo["lat"]), float(geo["lon"])
            price = float(item["priceFrom"])
            hotel_id = str(item["hotelId"])
            name = str(item["hotelName"]).strip()
        except (KeyError, TypeError, ValueError):
            continue
        if not name or price <= 0:
            continue
        link = {
            "hotelId": hotel_id, "checkIn": q.check_in.isoformat(), "checkOut": q.check_out.isoformat(),
            "adults": q.adults, "currency": q.currency.lower(),
        }
        if marker:
            link["marker"] = marker
        stars = item.get("stars")
        offers.append(
            Offer(
                provider=HotellookProvider.id, provider_hotel_id=hotel_id, hotel_name=name, lat=lat, lon=lon,
                total_cents=round(price * 100), currency=q.currency, url=f"{LINK_URL}?{urlencode(link)}",
                stars=float(stars) if isinstance(stars, (int, float)) and stars > 0 else None,
            )
        )
    return offers
