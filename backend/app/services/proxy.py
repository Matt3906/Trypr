"""Server-side routing proxies (ported from the routeProxy / overpassProxy Cloud Functions)."""

from __future__ import annotations

import asyncio
import json
import logging
import time
from typing import Any

import httpx

from app.core.config import get_settings
from app.services import overpass_cache

settings = get_settings()
logger = logging.getLogger(__name__)

ORS_PROFILES = {"rail", "driving-car", "foot-walking", "cycling", "cycling-regular", "foot-hiking"}
OVERPASS_ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
    "https://lz4.overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
]
# overpass-api.de answers 406 to generic client user agents (python-httpx, curl), so identify the app.
OVERPASS_HEADERS = {"User-Agent": "Trypr/1.0 (+https://tryprtravel.com)", "Accept": "application/json"}
# Public mirrors are often slow or overloaded: rather than waiting for each one to time out in turn,
# start the next mirror after a short stagger and take whichever answers first.
_OVERPASS_STAGGER_S = 4.0
_OVERPASS_REQUEST_TIMEOUT_S = 35.0
_OVERPASS_DEADLINE_S = 40.0
_overpass_in_flight: dict[str, "asyncio.Task[tuple[int, str | dict]]"] = {}


def normalise_coordinates(raw: Any) -> list[list[float]]:
    out: list[list[float]] = []
    if not isinstance(raw, list):
        return out
    for pair in raw:
        if isinstance(pair, (list, tuple)) and len(pair) >= 2:
            try:
                lon, lat = float(pair[0]), float(pair[1])
            except (TypeError, ValueError):
                continue
            if lon == lon and lat == lat and abs(lon) != float("inf") and abs(lat) != float("inf"):
                out.append([lon, lat])
    return out


def _lonlat_to_latlon(coords: list) -> list[list[float]]:
    path = []
    for pair in coords:
        if isinstance(pair, list) and len(pair) >= 2:
            try:
                path.append([float(pair[1]), float(pair[0])])
            except (TypeError, ValueError):
                continue
    return path


async def route(provider: str, profile: str, coordinates: list[list[float]]) -> tuple[int, dict]:
    if provider == "ors":
        return await _ors(profile, coordinates)
    if provider == "graphhopper":
        return await _graphhopper(profile, coordinates)
    return 400, {"error": "UNSUPPORTED_PROVIDER", "provider": provider, "profile": profile}


async def _ors(profile: str, coordinates: list[list[float]]) -> tuple[int, dict]:
    profile = profile.strip().lower()
    if profile not in ORS_PROFILES:
        return 400, {"error": "UNSUPPORTED_ORS_PROFILE", "provider": "ors", "profile": profile}
    if not settings.openrouteservice_api_key:
        return 500, {"error": "ORS_KEY_MISSING", "provider": "ors", "profile": profile}
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.post(
                f"https://api.openrouteservice.org/v2/directions/{profile}/geojson",
                headers={"Authorization": settings.openrouteservice_api_key},
                json={"coordinates": coordinates},
            )
    except httpx.HTTPError as e:
        return 502, {"error": "ORS_REQUEST_FAILED", "provider": "ors", "profile": profile, "message": str(e)}
    if resp.status_code >= 400:
        return resp.status_code, {"error": "ORS_UPSTREAM_ERROR", "provider": "ors", "profile": profile,
                                  "upstreamStatus": resp.status_code, "upstreamBodyPreview": resp.text[:400]}
    try:
        data = resp.json()
    except ValueError:
        return 502, {"error": "ORS_INVALID_JSON", "provider": "ors", "profile": profile}
    features = data.get("features") or []
    if not features:
        return 502, {"error": "ORS_GEOMETRY_MISSING", "provider": "ors", "profile": profile}
    feature = features[0] or {}
    coords = (feature.get("geometry") or {}).get("coordinates") or []
    if len(coords) < 2:
        return 502, {"error": "ORS_GEOMETRY_INVALID", "provider": "ors", "profile": profile}
    path = _lonlat_to_latlon(coords)
    if len(path) < 2:
        return 502, {"error": "ORS_PATH_INVALID", "provider": "ors", "profile": profile}
    props = feature.get("properties") or {}
    summary = props.get("summary") or {}
    instructions = [
        str(step.get("instruction", "")).strip()
        for seg in props.get("segments") or []
        for step in (seg or {}).get("steps") or []
        if str((step or {}).get("instruction", "")).strip()
    ]
    return 200, {"provider": "ors", "profile": profile, "path": path,
                 "distanceMeters": float(summary.get("distance") or 0), "durationSeconds": float(summary.get("duration") or 0),
                 "instructions": instructions}


async def _graphhopper(profile: str, coordinates: list[list[float]]) -> tuple[int, dict]:
    profile = profile.strip().lower() or "hike"
    if not settings.graphhopper_api_key:
        return 500, {"error": "GRAPHHOPPER_KEY_MISSING", "provider": "graphhopper", "profile": profile}
    if len(coordinates) < 2:
        return 400, {"error": "COORDINATES_INVALID", "provider": "graphhopper", "profile": profile}
    params: list[tuple[str, str]] = [("profile", profile), ("points_encoded", "false"), ("key", settings.graphhopper_api_key)]
    params += [("point", f"{lat},{lon}") for lon, lat in coordinates]
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.get("https://graphhopper.com/api/1/route", params=params)
    except httpx.HTTPError as e:
        return 502, {"error": "GRAPHHOPPER_REQUEST_FAILED", "provider": "graphhopper", "profile": profile, "message": str(e)}
    if resp.status_code >= 400:
        return resp.status_code, {"error": "GRAPHHOPPER_UPSTREAM_ERROR", "provider": "graphhopper", "profile": profile,
                                  "upstreamStatus": resp.status_code, "upstreamBodyPreview": resp.text[:400]}
    try:
        data = resp.json()
    except ValueError:
        return 502, {"error": "GRAPHHOPPER_INVALID_JSON", "provider": "graphhopper", "profile": profile}
    paths = data.get("paths") or []
    if not paths:
        return 502, {"error": "GRAPHHOPPER_PATH_MISSING", "provider": "graphhopper", "profile": profile}
    first = paths[0] or {}
    path = _lonlat_to_latlon((first.get("points") or {}).get("coordinates") or [])
    if len(path) < 2:
        return 502, {"error": "GRAPHHOPPER_PATH_INVALID", "provider": "graphhopper", "profile": profile}
    return 200, {"provider": "graphhopper", "profile": profile, "path": path,
                 "distanceMeters": float(first.get("distance") or 0),
                 "durationSeconds": float(first.get("time") or 0) / 1000, "instructions": []}


class _OverpassAttemptFailed(Exception):
    def __init__(self, endpoint: str, status: int, body: str):
        super().__init__(f"{endpoint} {status}")
        self.detail = {"endpoint": endpoint, "status": status, "body": body[:400]}


async def _overpass_attempt(client: httpx.AsyncClient, endpoint: str, query: str, delay: float) -> str:
    if delay:
        await asyncio.sleep(delay)
    try:
        resp = await client.post(endpoint, data={"data": query})
    except httpx.HTTPError as e:
        raise _OverpassAttemptFailed(endpoint, 502, f"{type(e).__name__}: {e}") from e
    if resp.status_code >= 400:
        raise _OverpassAttemptFailed(endpoint, resp.status_code, resp.text)
    try:
        payload = await asyncio.to_thread(json.loads, resp.text)
    except ValueError as e:
        raise _OverpassAttemptFailed(endpoint, 502, resp.text) from e
    # A server-side timeout still comes back as 200 with a "runtime error" remark and no elements.
    remark = str(payload.get("remark") or "") if isinstance(payload, dict) else ""
    if "runtime error" in remark.lower() and not payload.get("elements"):
        raise _OverpassAttemptFailed(endpoint, 504, remark)
    return resp.text


async def _overpass_fetch(query: str) -> tuple[int, str | dict]:
    last: dict | None = None
    started = time.monotonic()
    async with httpx.AsyncClient(timeout=_OVERPASS_REQUEST_TIMEOUT_S, headers=OVERPASS_HEADERS) as client:
        attempts = [
            asyncio.create_task(_overpass_attempt(client, endpoint, query, i * _OVERPASS_STAGGER_S))
            for i, endpoint in enumerate(OVERPASS_ENDPOINTS)
        ]
        pending = set(attempts)
        try:
            while pending:
                remaining = _OVERPASS_DEADLINE_S - (time.monotonic() - started)
                if remaining <= 0:
                    break
                done, pending = await asyncio.wait(pending, timeout=remaining, return_when=asyncio.FIRST_COMPLETED)
                if not done:
                    break
                for task in done:
                    err = task.exception()
                    if err is None:
                        text = task.result()
                        await overpass_cache.put(query, text)
                        return 200, text
                    last = err.detail if isinstance(err, _OverpassAttemptFailed) else {"status": 502, "body": str(err)}
                    logger.info("overpass attempt failed: %s", last)
        finally:
            for task in attempts:
                task.cancel()
            await asyncio.gather(*attempts, return_exceptions=True)
    return 502, {"error": "OVERPASS_UPSTREAM_FAILED", "lastError": last}


def _overpass_fetch_shared(query: str) -> "asyncio.Task[tuple[int, str | dict]]":
    # The map overlay and the router often ask for the same box at the same time; share one upstream fetch.
    task = _overpass_in_flight.get(query)
    if task is None:
        task = asyncio.create_task(_overpass_fetch(query))
        _overpass_in_flight[query] = task
        task.add_done_callback(lambda _t: _overpass_in_flight.pop(query, None))
    return task


async def overpass(query: str) -> tuple[int, str | dict, str]:
    """Returns (status, body, cache_state). Body is raw JSON text on success."""
    query = query.strip()
    cached = await overpass_cache.get(query)
    if cached:
        if not cached.fresh:
            # Serve the old copy now and refresh it for next time.
            _overpass_fetch_shared(query)
            return 200, cached.text, "STALE"
        return 200, cached.text, "HIT"
    status, payload = await asyncio.shield(_overpass_fetch_shared(query))
    return status, payload, "MISS"
