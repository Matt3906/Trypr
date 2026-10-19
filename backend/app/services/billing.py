"""Stripe checkout / billing portal / webhook (ported from functions/index.js)."""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timezone
from urllib.parse import urlparse

import stripe

from app.core.config import get_settings
from app.core.db import get_pool
from app.core.errors import ApiError
from app.core.sessions import Actor
from app.docstore.fields import fmt_ts
from app.docstore.store import server_set

settings = get_settings()
logger = logging.getLogger(__name__)

PLANS = {
    "monthly": {"interval": "month", "amount": 400, "display": "$4/month"},
    "yearly": {"interval": "year", "amount": 3600, "display": "$36/year"},
}


def _client() -> stripe.StripeClient:
    if not settings.stripe_secret_key:
        raise ApiError(412, "Stripe is not configured. Set STRIPE_SECRET_KEY.")
    return stripe.StripeClient(settings.stripe_secret_key)


def _price_id(plan: str) -> str:
    return (settings.stripe_price_monthly if plan == "monthly" else settings.stripe_price_yearly).strip()


def _path(raw: str) -> str:
    raw = (raw or "/premium").strip() or "/premium"
    return raw if raw.startswith("/") else f"/{raw}"


def _origin(raw: str | None) -> str:
    try:
        u = urlparse((raw or "").strip())
        return f"{u.scheme}://{u.netloc}" if u.scheme in ("http", "https") and u.netloc else ""
    except ValueError:
        return ""


def _allowed_origins() -> list[str]:
    explicit = [o for o in (_origin(x) for x in settings.stripe_allowed_origins.split(",")) if o]
    if explicit:
        return list(dict.fromkeys(explicit))
    base = _origin(settings.frontend_base_url)
    return list(dict.fromkeys([base, "http://localhost:5173", "http://127.0.0.1:5173"]))


def _return_origin(candidate: str | None) -> str:
    allowed = _allowed_origins()
    req = _origin(candidate)
    return req if req in allowed else allowed[0]


async def _docs(uid: str) -> tuple[dict, dict]:
    pool = get_pool()
    ent = await pool.fetchval("SELECT data FROM documents WHERE path = $1", f"userEntitlements/{uid}") or {}
    usr = await pool.fetchval("SELECT data FROM documents WHERE path = $1", f"users/{uid}") or {}
    return ent, usr


async def _merge(path: str, patch: dict) -> None:
    async with get_pool().acquire() as conn:
        async with conn.transaction():
            await server_set(conn, path, patch, merge=True)


def _ts_now() -> dict:
    return {"$ts": fmt_ts(datetime.now(timezone.utc))}


async def create_checkout_session(data: dict, actor: Actor) -> dict:
    client = _client()
    plan = str(data.get("plan", "")).strip().lower()
    if plan not in PLANS:
        raise ApiError(400, 'Invalid plan. Use "monthly" or "yearly".')
    origin = _return_origin(data.get("returnOrigin"))
    success = f"{origin}{_path(settings.stripe_success_path)}?checkout=success&plan={plan}&session_id={{CHECKOUT_SESSION_ID}}"
    cancel = f"{origin}{_path(settings.stripe_cancel_path)}?checkout=cancelled&plan={plan}"

    ent, usr = await _docs(actor.uid)
    customer_id = str(ent.get("stripeCustomerId") or usr.get("stripeCustomerId") or "").strip()
    if customer_id:
        try:
            cust = await asyncio.to_thread(client.customers.retrieve, customer_id)
            if getattr(cust, "deleted", False):
                customer_id = ""
        except stripe.StripeError:
            customer_id = ""
    if not customer_id:
        created = await asyncio.to_thread(
            client.customers.create,
            params={
                "email": actor.email or usr.get("email") or None,
                "name": usr.get("displayName") or None,
                "metadata": {"uid": actor.uid},
            },
        )
        customer_id = created.id

    price = _price_id(plan)
    if price:
        line_item = {"price": price, "quantity": 1}
    else:
        cfg = PLANS[plan]
        line_item = {
            "price_data": {
                "currency": "usd",
                "unit_amount": cfg["amount"],
                "recurring": {"interval": cfg["interval"]},
                "product_data": {"name": "Trypr Premium", "description": "Unlock AI itinerary and route planning features."},
            },
            "quantity": 1,
        }
    session = await asyncio.to_thread(
        client.checkout.sessions.create,
        params={
            "mode": "subscription",
            "customer": customer_id,
            "line_items": [line_item],
            "allow_promotion_codes": True,
            "billing_address_collection": "auto",
            "success_url": success,
            "cancel_url": cancel,
            "client_reference_id": actor.uid,
            "metadata": {"uid": actor.uid, "plan": plan},
            "subscription_data": {"metadata": {"uid": actor.uid, "plan": plan}},
        },
    )
    pending = {"stripeCustomerId": customer_id, "premiumPlanPending": plan,
               "premiumCheckoutSessionId": session.id, "updatedAt": _ts_now()}
    await _merge(f"userEntitlements/{actor.uid}", pending)
    await _merge(f"users/{actor.uid}", pending)
    if not session.url:
        raise ApiError(500, "Stripe checkout URL missing from session response.", code="internal")
    return {"url": session.url, "sessionId": session.id, "plan": plan, "price": PLANS[plan]["display"]}


async def create_billing_portal(data: dict, actor: Actor) -> dict:
    client = _client()
    ent, usr = await _docs(actor.uid)
    customer_id = str(ent.get("stripeCustomerId") or usr.get("stripeCustomerId") or "").strip()
    if not customer_id:
        raise ApiError(412, "No Stripe customer found for this account.")
    origin = _return_origin(data.get("returnOrigin"))
    session = await asyncio.to_thread(
        client.billing_portal.sessions.create,
        params={"customer": customer_id, "return_url": f"{origin}{_path(settings.stripe_portal_return_path)}"},
    )
    return {"url": session.url}


# ---- webhook -----------------------------------------------------------------

def _is_active(status: str) -> bool:
    return status.lower() in ("active", "trialing", "past_due")


def _g(obj, key, default=None):
    try:
        v = obj[key]
    except (KeyError, TypeError, IndexError):
        return default
    return default if v is None else v


def _plan_from_price(price) -> str | None:
    interval = str(_g(_g(price, "recurring", {}), "interval", "")).lower()
    if interval == "month":
        return "monthly"
    if interval == "year":
        return "yearly"
    pid = _g(price, "id", "")
    for plan in PLANS:
        if pid and pid == _price_id(plan):
            return plan
    return None


async def _uid_for_customer(customer_id: str) -> str:
    if not customer_id:
        return ""
    row = await get_pool().fetchval(
        "SELECT id FROM documents WHERE parent = 'userEntitlements' AND data->>'stripeCustomerId' = $1 LIMIT 1",
        customer_id,
    )
    return row or ""


async def _set_premium(uid: str, *, active: bool, status: str, plan: str | None, customer_id: str,
                       subscription_id: str, price_id: str, period_end: int | None) -> None:
    now = _ts_now()
    status_label = (status or ("active" if active else "inactive")).lower()
    sub = "premium" if active else "free"
    common = {
        "subscription": sub,
        "subscriptionStatus": "premium" if active else status_label,
        "premiumSource": "stripe",
        "premiumPlan": plan,
        "updatedAt": now,
        "premiumEnabledAt" if active else "premiumDisabledAt": now,
    }
    ent = {**common, "subscriptionType": "Premium" if active else "Free",
           "stripeCustomerId": customer_id or None, "stripeSubscriptionId": subscription_id or None,
           "stripePriceId": price_id or None}
    usr = {**common, "subscriptionType": "Premium" if active else "Free"}
    if period_end:
        end = {"$ts": fmt_ts(datetime.fromtimestamp(int(period_end), tz=timezone.utc))}
        ent["currentPeriodEnd"] = end
        usr["currentPeriodEnd"] = end
    await _merge(f"userEntitlements/{uid}", ent)
    await _merge(f"users/{uid}", usr)


def _period_end(sub) -> int | None:
    pe = sub.get("current_period_end")
    if not pe:
        items = (sub.get("items") or {}).get("data") or []
        pe = items[0].get("current_period_end") if items else None
    return int(pe) if pe else None


async def handle_webhook(payload: bytes, signature: str) -> None:
    if not settings.stripe_webhook_secret:
        raise ApiError(500, "Stripe webhook is not configured.", code="internal")
    try:
        event = stripe.Webhook.construct_event(payload, signature, settings.stripe_webhook_secret)
    except (stripe.SignatureVerificationError, ValueError) as e:
        raise ApiError(400, "Webhook signature verification failed.") from e

    obj = event["data"]["object"]
    etype = event["type"]
    if etype == "checkout.session.completed":
        if obj.get("mode") != "subscription":
            return
        customer_id = str(obj.get("customer") or "")
        sub_id = str(obj.get("subscription") or "")
        uid = str((obj.get("metadata") or {}).get("uid") or obj.get("client_reference_id") or "") or await _uid_for_customer(customer_id)
        if not uid:
            logger.warning("checkout.session.completed without uid: %s", obj.get("id"))
            return
        plan = (obj.get("metadata") or {}).get("plan")
        status, period_end, price_id = "active", None, ""
        if sub_id:
            sub = await asyncio.to_thread(_client().subscriptions.retrieve, sub_id, params={"expand": ["items.data.price"]})
            status = str(sub.get("status", "active")).lower()
            period_end = _period_end(sub)
            price = ((sub.get("items") or {}).get("data") or [{}])[0].get("price")
            price_id = _g(price, "id", "")
            plan = plan or _plan_from_price(price)
        await _set_premium(uid, active=_is_active(status), status=status, plan=plan or "monthly",
                           customer_id=customer_id, subscription_id=sub_id, price_id=price_id, period_end=period_end)
    elif etype in ("customer.subscription.created", "customer.subscription.updated", "customer.subscription.deleted"):
        customer_id = str(obj.get("customer") or "")
        uid = str((obj.get("metadata") or {}).get("uid") or "") or await _uid_for_customer(customer_id)
        if not uid:
            logger.warning("%s without uid: %s", etype, obj.get("id"))
            return
        status = str(obj.get("status", "")).lower()
        price = ((obj.get("items") or {}).get("data") or [{}])[0].get("price")
        plan = (obj.get("metadata") or {}).get("plan") or _plan_from_price(price) or "monthly"
        await _set_premium(uid, active=_is_active(status), status=status, plan=plan, customer_id=customer_id,
                           subscription_id=str(obj.get("id") or ""), price_id=_g(price, "id", ""),
                           period_end=_period_end(obj))
