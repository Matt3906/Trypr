"""Server-side routing proxies (ported from the routeProxy / overpassProxy Cloud Functions)."""

from __future__ import annotations

import logging
import time
from collections import OrderedDict
from typing import Any

import httpx

from app.core.config import get_settings

settings = get_settings()
logger = logging.getLogger(__name__)

ORS_PROFILES = {"rail", "driving-car", "foot-walking", "cycling", "cycling-regular", "foot-hiking"}
OVERPASS_ENDPOINTS = [
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
    "https://overpass-api.de/api/interpreter",
    "https://lz4.overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
]
_CACHE_TTL = 20 * 60
_CACHE_MAX = 48
_cache: "OrderedDict[str, tuple[float, str]]" = OrderedDict()


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


def _cache_get(query: str, allow_stale: bool = False) -> str | None:
    hit = _cache.get(query)
    if not hit:
        return None
    if not allow_stale and time.time() - hit[0] > _CACHE_TTL:
        _cache.pop(query, None)
        return None
    return hit[1]


def _cache_put(query: str, text: str) -> None:
    _cache[query] = (time.time(), text)
    _cache.move_to_end(query)
    while len(_cache) > _CACHE_MAX:
        _cache.popitem(last=False)


async def overpass(query: str) -> tuple[int, str | dict, str]:
    """Returns (status, body, cache_state). Body is raw JSON text on success."""
    import json as _json

    query = query.strip()
    fresh = _cache_get(query)
    if fresh:
        return 200, fresh, "HIT"
    last: dict | None = None
    async with httpx.AsyncClient(timeout=14) as client:
        for endpoint in OVERPASS_ENDPOINTS:
            try:
                resp = await client.post(endpoint, data={"data": query})
            except httpx.HTTPError as e:
                last = {"endpoint": endpoint, "status": 502, "body": str(e)}
                continue
            if resp.status_code >= 400:
                last = {"endpoint": endpoint, "status": resp.status_code, "body": resp.text[:400]}
                continue
            try:
                _json.loads(resp.text)
            except ValueError:
                last = {"endpoint": endpoint, "status": 502, "body": resp.text[:400]}
                continue
            _cache_put(query, resp.text)
            return 200, resp.text, "MISS"
    stale = _cache_get(query, allow_stale=True)
    if stale:
        return 200, stale, "STALE"
    return 502, {"error": "OVERPASS_UPSTREAM_FAILED", "lastError": last}, "MISS"
