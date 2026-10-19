"""Callable-function style endpoints (replaces Firebase Cloud Functions httpsCallable)."""

from __future__ import annotations

from typing import Any, Awaitable, Callable

from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse, Response

from app.core.errors import ApiError
from app.core.ratelimit import client_ip, limiter
from app.core.sessions import Actor, optional_actor
from app.services import billing, proxy
from app.services.ai import ai_suggest

router = APIRouter(tags=["functions"])

Handler = Callable[[dict, Actor], Awaitable[dict]]
FUNCTIONS: dict[str, Handler] = {
    "createStripeCheckoutSession": billing.create_checkout_session,
    "createStripeBillingPortal": billing.create_billing_portal,
    "aiSuggest": ai_suggest,
}


@router.post("/fn/{name}")
async def call_function(name: str, body: dict[str, Any], actor: Actor | None = Depends(optional_actor)) -> dict:
    handler = FUNCTIONS.get(name)
    if handler is None:
        raise ApiError(404, "Unknown function")
    if actor is None:
        raise ApiError(401, "Sign in required")
    limiter.check(f"fn:{actor.uid}", 60, 60)
    data = body.get("data")
    return {"data": await handler(data if isinstance(data, dict) else {}, actor)}


@router.post("/stripe/webhook")
async def stripe_webhook(request: Request) -> dict:
    signature = request.headers.get("stripe-signature")
    if not signature:
        raise ApiError(400, "Missing Stripe signature.")
    await billing.handle_webhook(await request.body(), signature)
    return {"received": True}


# --- public routing proxies (same paths the frontend falls back to) ---------------------------

@router.post("/route")
async def route_proxy(request: Request, body: dict[str, Any]) -> JSONResponse:
    limiter.check(f"route:{client_ip(request)}", 120, 60)
    provider = str(body.get("provider") or "ors").strip().lower()
    profile = str(body.get("profile") or "").strip().lower()
    coords = proxy.normalise_coordinates(body.get("coordinates"))
    if len(coords) < 2:
        return JSONResponse({"error": "COORDINATES_INVALID", "provider": provider, "profile": profile}, 400)
    status, payload = await proxy.route(provider, profile, coords)
    return JSONResponse(payload, status)


@router.post("/overpass")
async def overpass_proxy(request: Request, body: dict[str, Any]) -> Response:
    limiter.check(f"overpass:{client_ip(request)}", 60, 60)
    query = str(body.get("query") or "").strip()
    if not query:
        return JSONResponse({"error": "QUERY_REQUIRED"}, 400)
    status, payload, cache = await proxy.overpass(query)
    headers = {"X-Trypr-Overpass-Cache": cache}
    if isinstance(payload, dict):
        return JSONResponse(payload, status, headers=headers)
    return Response(payload, status, media_type="application/json", headers=headers)
