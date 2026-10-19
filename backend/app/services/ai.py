"""AI trip suggestions (ported from the aiSuggest Cloud Function; Vertex AI replaced by the Claude API)."""

from __future__ import annotations

import json
import logging
import re
from typing import Any

import anthropic

from app.core.config import get_settings
from app.core.errors import ApiError
from app.core.sessions import Actor
from app.services.premium import can_access_premium

settings = get_settings()
logger = logging.getLogger(__name__)

SYSTEM_ACCOMMODATIONS = (
    "You are a travel assistant API. Your ONLY job is to return a JSON array of 3 accommodation options based on the "
    "provided location and dates. Return ONLY valid JSON with keys: name, address, price_estimate (number only), "
    "rating (number 1-5), stayType. Respect stay_type exactly (hotel, hostel, camping). If route_intent=between_stops, "
    "keep options along the route between from and to and realistically within max_travel_minutes and max_radius_km of "
    "the provided coordinates. Do not include markdown formatting or conversational text."
)
SYSTEM_ITINERARY = (
    "You are a travel assistant API. Return ONLY valid JSON. Your ONLY job is to return a JSON array of 8 activity "
    "options based on the provided location and dates. Keys: name, address, estimatedPrice (number only), rating "
    "(number 1-5), category. Keep every suggestion realistically within max_travel_minutes and max_radius_km of the "
    "provided coordinates; do not suggest far county/region-wide options. No markdown or conversational text."
)

_REGION_EXACT = {"golden horseshoe", "greater toronto area", "gta", "ontario", "canada", "united states", "usa", "north america"}
_REGION_TOKENS = (" region", " county", " district", " province", " state", " territory", " area", " metro", " greater ")
_COUNTRIES = ("canada", "united states", "usa", "ontario", "quebec", "alberta")
_POI_TOKENS = (
    "church", "cathedral", "mosque", "temple", "museum", "gallery", "park", "hotel", "resort", "restaurant", "cafe",
    "mall", "plaza", "school", "university", "college", "station", "airport", "hospital", "clinic", "arena",
    "stadium", "library", "theatre", "theater",
)
_ROAD_TOKENS = (" street", " st", " road", " rd", " avenue", " ave", " boulevard", " blvd", " drive", " dr",
                " highway", " hwy", " lane", " ln")


def _clamp(v: Any, n: int) -> str:
    return str("" if v is None else v)[:n]


def _looks_region(value: str) -> bool:
    lower = value.strip().lower()
    if not lower:
        return False
    if lower in _REGION_EXACT or any(t in lower for t in _REGION_TOKENS):
        return True
    return any(lower == c or lower.endswith(f", {c}") or f" {c}," in lower for c in _COUNTRIES)


def _looks_poi(value: str) -> bool:
    lower = value.strip().lower()
    return bool(lower) and any(t in lower for t in _POI_TOKENS)


def _looks_street(seg: str) -> bool:
    s = seg.lower()
    return bool(re.search(r"\d", s)) or any(t in s for t in _ROAD_TOKENS)


def city_label(value: Any) -> str:
    raw = str(value or "").strip()
    if not raw:
        return "Nearby City"
    for part in (p.strip() for p in raw.split(",")):
        if len(part) < 2 or _looks_region(part) or _looks_poi(part) or _looks_street(part):
            continue
        return _clamp(part, 120)
    if not _looks_region(raw) and not _looks_poi(raw):
        return _clamp(raw, 120)
    return "Nearby City"


def _num(v: Any, default: float = 0.0) -> float:
    try:
        f = float(v)
        return f if f == f and f not in (float("inf"), float("-inf")) else default
    except (TypeError, ValueError):
        return default


def _max_travel(prefs: dict | None) -> int:
    raw = _num((prefs or {}).get("maxTravelMinutes", (prefs or {}).get("travelMinutes", 30)), 30)
    return max(10, min(60, round(raw)))


def _stay_type(prefs: dict | None) -> str:
    raw = str((prefs or {}).get("stayType", (prefs or {}).get("accommodationType", "hotel"))).strip().lower()
    if raw in ("camping", "campground", "camp"):
        return "camping"
    return "hostel" if raw == "hostel" else "hotel"


def _radius_km(minutes: int) -> int:
    return max(6, min(40, round(minutes * 0.75)))


def build_prompt(module: str, destination: str, lat: float, lon: float, start: str, end: str, prefs: dict | None) -> str:
    base = f"location={_clamp(destination, 200)}; lat={lat:.6f}; lon={lon:.6f}; start={_clamp(start, 32)}; end={_clamp(end, 32)}"
    prefs_s = f"; preferences={json.dumps(prefs)}" if isinstance(prefs, dict) else ""
    minutes = _max_travel(prefs)
    radius = _radius_km(minutes)
    if module == "accommodations":
        p = prefs or {}
        frm = _clamp(p.get("routeFrom") or p.get("from") or "", 120)
        to = _clamp(p.get("routeTo") or p.get("to") or "", 120)
        scope = f"; route_intent=between_stops; from={frm}; to={to}" if str(p.get("routeIntent", "")).strip().lower() == "between_stops" and frm and to else ""
        return base + f"; stay_type={_stay_type(prefs)}; max_travel_minutes={minutes}; max_radius_km={radius}" + scope + prefs_s
    return base + f"; strict_local=true; max_travel_minutes={minutes}; max_radius_km={radius}" + prefs_s


def _fallback_rating(seed: int, i: int) -> float:
    return max(3.8, min(4.9, 3.8 + ((seed + i * 17) % 12) / 10.0))


def fallback_suggestions(module: str, destination: str, prefs: dict | None) -> list[dict]:
    city = city_label(destination)
    seed = sum(ord(c) for c in city) % 100000
    tier = str((prefs or {}).get("budgetTier", "moderate")).lower()
    mult = 0.75 if tier == "budget" else 1.5 if tier == "luxury" else 1.0

    if module == "accommodations":
        stay = _stay_type(prefs)
        if stay == "camping":
            names, prices = [f"{city} Campground", f"{city} RV & Tent Site", f"{city} Nature Campsite"], [45, 60, 75]
        elif stay == "hostel":
            names, prices = [f"{city} Central Hostel", f"{city} Backpacker House", f"{city} Social Hostel"], [50, 72, 95]
        else:
            names, prices = [f"{city} Central Hotel", f"{city} Riverside Suites", f"{city} Boutique Stay"], [120, 165, 210]
        return [
            {"name": n, "address": f"{i + 1} Main St, {city}", "price": round(prices[i] * mult),
             "rating": _fallback_rating(seed, i), "stayType": stay, "source": "server_fallback"}
            for i, n in enumerate(names)
        ]

    kind = str((prefs or {}).get("activityType", "exploring")).lower()
    category = {
        "adventure": "Adventure", "fooddrink": "Restaurant", "food_drink": "Restaurant", "food": "Restaurant",
        "culturemuseum": "Museum", "culture": "Museum", "museum": "Museum", "relaxation": "Free Time",
        "sightseeing": "Sightseeing", "attractions": "Sightseeing",
    }.get(kind, "Exploring")
    acts = ["City highlights walk", "Scenic viewpoint stop", "Local food experience", "Historic district exploration",
            "Cultural center visit", "Neighborhood market stroll", "Sunset photo session", "Signature local attraction"]
    prices = [0, 12, 28, 15, 20, 10, 0, 25]
    minutes = _max_travel(prefs)
    return [
        {"name": f"{city} {a}", "address": f"{10 + i} Center Ave, {city}", "estimatedPrice": round(prices[i] * mult),
         "rating": _fallback_rating(seed, i), "category": category, "maxTravelMinutes": minutes, "source": "server_fallback"}
        for i, a in enumerate(acts)
    ]


def _parse_json_text(text: str) -> Any:
    t = text.strip()
    if t.startswith("```"):
        t = re.sub(r"^```[a-zA-Z]*\s*", "", t)
        t = re.sub(r"\s*```\s*$", "", t)
    return json.loads(t.strip())


async def _ask_claude(system: str, prompt: str, max_tokens: int) -> Any:
    if not settings.anthropic_api_key:
        raise RuntimeError("ANTHROPIC_API_KEY is not set")
    client = anthropic.AsyncAnthropic(api_key=settings.anthropic_api_key, timeout=25.0, max_retries=1)
    resp = await client.messages.create(
        model=settings.ai_model,
        max_tokens=max_tokens,
        system=system,
        messages=[{"role": "user", "content": prompt}],
        extra_body={"output_config": {"effort": "low"}},  # short structured answer: keep latency/cost down
    )
    if resp.stop_reason in ("refusal", "max_tokens"):
        raise RuntimeError(f"model stopped early: {resp.stop_reason}")
    text = "".join(b.text for b in resp.content if getattr(b, "type", "") == "text")
    if not text.strip():
        raise RuntimeError("empty model response")
    return _parse_json_text(text)


def _normalise(module: str, raw: Any, prefs: dict | None) -> list[dict]:
    arr = raw if isinstance(raw, list) else (raw.get("suggestions") if isinstance(raw, dict) else None)
    arr = arr if isinstance(arr, list) else []
    out: list[dict] = []
    for s in arr[: 3 if module == "accommodations" else 12]:
        if not isinstance(s, dict):
            continue
        rating = max(0.0, min(5.0, _num(s.get("rating"))))
        if module == "accommodations":
            price = _num(s.get("price_estimate", s.get("priceEstimate", s.get("price"))))
            stay = _stay_type({"stayType": s.get("stayType") or (prefs or {}).get("stayType")})
            out.append({"name": _clamp(s.get("name"), 200), "address": _clamp(s.get("address"), 300),
                        "price": price, "rating": rating, "stayType": stay})
        else:
            out.append({"name": _clamp(s.get("name"), 200), "address": _clamp(s.get("address"), 300),
                        "estimatedPrice": _num(s.get("estimatedPrice", s.get("price"))), "rating": rating,
                        "category": _clamp(s.get("category") or "Exploring", 32)})
    return out


async def ai_suggest(data: dict, actor: Actor) -> dict:
    if not await can_access_premium(actor):
        raise ApiError(403, "PREMIUM_REQUIRED")
    module = str(data.get("module", "")).lower()
    if module not in ("accommodations", "itinerary"):
        raise ApiError(400, "Invalid module")
    destination = _clamp(data.get("destinationName"), 200)
    start, end = _clamp(data.get("startDate"), 32), _clamp(data.get("endDate"), 32)
    prefs = data.get("preferences") if isinstance(data.get("preferences"), dict) else None
    lat, lon = _num(data.get("lat"), float("nan")), _num(data.get("lon", data.get("lng")), float("nan"))
    if not start or not end:
        raise ApiError(412, "Trip dates required")
    if lat != lat or lon != lon:
        raise ApiError(412, "Waypoint coordinates required")

    label = city_label(destination)
    prompt = build_prompt(module, label, lat, lon, start, end, prefs)
    system = SYSTEM_ACCOMMODATIONS if module == "accommodations" else SYSTEM_ITINERARY
    try:
        raw = await _ask_claude(system, prompt, 6000 if module == "itinerary" else 3000)
    except Exception:  # provider/parse failure -> deterministic fallback, same as the old function
        logger.exception("AI provider failed; returning fallback suggestions")
        raw = {"suggestions": fallback_suggestions(module, label, prefs)}
    return {"module": module, "suggestions": _normalise(module, raw, prefs)}
