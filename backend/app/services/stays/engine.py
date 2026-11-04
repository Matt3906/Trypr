"""Fan-out search across price providers, merged into one cheapest-first list of hotels.

Per provider, results are cached (short TTL) and concurrent identical searches share one upstream
request (single-flight). A request waits at most `wait_s` for the providers; slow ones keep running in
the background, land in the cache, and are reported as "pending" so the client asks again a moment later
and gets them instantly. One provider failing or hanging never blocks or breaks the others.
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import statistics
import time
from collections import OrderedDict

from . import links
from .matching import cluster_offers, haversine_m
from .models import Offer, ProviderResult, StayQuery
from .providers import enabled_providers
from .providers.base import Provider

logger = logging.getLogger(__name__)

WAIT_S = 4.0  # how long one request waits for providers before answering with what it has
FETCH_BUDGET_S = 25.0  # hard cap on one upstream fetch, including the part after the request answered
OK_TTL_S = 15 * 60
ERROR_TTL_S = 30  # negative cache, so a broken provider is not hammered by every retry
MAX_HOTELS = 60
_CACHE_MAX = 2000

_cache: "OrderedDict[tuple, tuple[float, ProviderResult]]" = OrderedDict()
_inflight: "dict[tuple, asyncio.Task[ProviderResult]]" = {}


def clear() -> None:
    _cache.clear()
    _inflight.clear()


def _cache_get(key: tuple) -> ProviderResult | None:
    hit = _cache.get(key)
    if hit is None:
        return None
    if hit[0] <= time.monotonic():
        _cache.pop(key, None)
        return None
    _cache.move_to_end(key)
    return hit[1]


def _cache_put(key: tuple, result: ProviderResult, ttl: float) -> None:
    _cache[key] = (time.monotonic() + ttl, result)
    _cache.move_to_end(key)
    while len(_cache) > _CACHE_MAX:
        _cache.popitem(last=False)


async def _fetch(provider: Provider, q: StayQuery, key: tuple) -> ProviderResult:
    try:
        try:
            async with asyncio.timeout(FETCH_BUDGET_S):
                offers = await provider.search(q)
            result, ttl = ProviderResult("ok", offers), OK_TTL_S
        except Exception as e:  # isolate every provider failure
            logger.warning("stay provider %s failed: %s: %s", provider.id, type(e).__name__, e)
            result, ttl = ProviderResult("error", [], type(e).__name__), ERROR_TTL_S
        # Cache first, then drop the in-flight marker, so there is no window where neither exists.
        _cache_put(key, result, ttl)
        return result
    finally:
        _inflight.pop(key, None)


def _start(provider: Provider, q: StayQuery) -> "ProviderResult | asyncio.Task[ProviderResult]":
    key = (provider.id, q)
    cached = _cache_get(key)
    if cached is not None:
        return cached
    task = _inflight.get(key)
    if task is None:
        task = _inflight[key] = asyncio.create_task(_fetch(provider, q, key))
    return task


def _hotel_id(offers: list[Offer]) -> str:
    seed = "|".join(sorted(f"{o.provider}:{o.provider_hotel_id}" for o in offers))
    return hashlib.sha256(seed.encode()).hexdigest()[:16]


def _offer_out(o: Offer, label: str, q: StayQuery) -> dict:
    return {
        "provider": o.provider, "providerLabel": label, "totalCents": o.total_cents,
        "perNightCents": round(o.total_cents / q.nights), "currency": o.currency,
        "taxesIncluded": o.taxes_included, "freeCancellation": o.free_cancellation,
        "breakfast": o.breakfast, "live": o.live,
        "url": f"/api/stays/out?t={links.sign(o, q)}",
    }


def _merge(offers: list[Offer], labels: dict[str, str], q: StayQuery) -> list[dict]:
    usable = []
    for o in offers:
        if o.total_cents <= 0 or o.currency != q.currency:
            continue  # no FX here: comparing across currencies would make "cheapest" wrong
        if haversine_m(q.lat, q.lon, o.lat, o.lon) > q.radius_km * 1000:
            continue
        usable.append(o)

    hotels = []
    for group in cluster_offers(usable):
        # Cheapest per provider (a provider may list several rooms/rates for one hotel).
        best_per_provider: dict[str, Offer] = {}
        for o in group:
            cur = best_per_provider.get(o.provider)
            if cur is None or o.total_cents < cur.total_cents:
                best_per_provider[o.provider] = o
        ranked = sorted(best_per_provider.values(), key=lambda o: (o.total_cents, o.provider))
        # Descriptive fields: prefer the richest listing.
        rep = max(group, key=lambda o: (o.image is not None, o.address is not None, len(o.hotel_name)))
        stars = [o.stars for o in group if o.stars is not None]
        lat, lon = statistics.fmean(o.lat for o in group), statistics.fmean(o.lon for o in group)
        saving = ranked[-1].total_cents - ranked[0].total_cents
        hotels.append({
            "id": _hotel_id(group), "name": rep.hotel_name, "lat": lat, "lon": lon,
            "stars": max(stars) if stars else None, "address": rep.address, "image": rep.image,
            "distanceKm": round(haversine_m(q.lat, q.lon, lat, lon) / 1000, 2),
            "best": _offer_out(ranked[0], labels[ranked[0].provider], q),
            "offers": [_offer_out(o, labels[o.provider], q) for o in ranked],
            "savingsCents": saving, "savingsPct": round(100 * saving / ranked[-1].total_cents) if saving else 0,
            "sample": all(o.sample for o in ranked),
        })
    hotels.sort(key=lambda h: (h["best"]["totalCents"], -(h["stars"] or 0), h["name"]))
    return hotels[:MAX_HOTELS]


async def search(q: StayQuery, *, wait_s: float = WAIT_S, providers: list[Provider] | None = None) -> dict:
    active = enabled_providers() if providers is None else providers
    labels = {p.id: p.label for p in active}
    if not active:
        return {"configured": False, "pending": False, "providers": [], "hotels": [], "nights": q.nights,
                "currency": q.currency, "sample": False}

    started = {p.id: _start(p, q) for p in active}
    waiting = [t for t in started.values() if isinstance(t, asyncio.Task)]
    if waiting:
        # shield-free on purpose: asyncio.wait never cancels the tasks when it times out.
        await asyncio.wait(waiting, timeout=wait_s)

    statuses, offers = [], []
    for p in active:
        r = started[p.id]
        if isinstance(r, asyncio.Task):
            r = r.result() if r.done() and not r.cancelled() else None
        if r is None:
            statuses.append({"id": p.id, "label": p.label, "status": "pending", "count": 0})
            continue
        statuses.append({"id": p.id, "label": p.label, "status": r.status, "count": len(r.offers)})
        offers.extend(r.offers)

    hotels = _merge(offers, labels, q)
    return {
        "configured": True,
        "pending": any(s["status"] == "pending" for s in statuses),
        "providers": statuses, "hotels": hotels, "nights": q.nights, "currency": q.currency,
        "sample": any(h["sample"] for h in hotels),
    }
