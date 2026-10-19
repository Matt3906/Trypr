import hashlib
import hmac
import json
import time

from app.core.config import get_settings
from tests.conftest import SERVER_TS

SUGGEST = {"module": "itinerary", "destinationName": "123 Main St, Banff, Alberta, Canada", "lat": 51.17, "lon": -115.57,
           "startDate": "2026-07-01", "endDate": "2026-07-05"}


async def fn(c, name, **data):
    return await c.http.post(f"/api/fn/{name}", json={"data": data})


async def test_functions_require_sign_in(anon):
    r = await fn(anon, "aiSuggest", **SUGGEST)
    assert r.status_code == 401 and r.json()["code"] == "unauthenticated"
    assert (await fn(anon, "nope")).status_code == 404


async def test_ai_suggest_premium_gate_and_fallback(alice, boss):
    r = await fn(alice, "aiSuggest", **SUGGEST)
    assert r.status_code == 403 and r.json()["message"] == "PREMIUM_REQUIRED" and r.json()["code"] == "permission-denied"

    # Admin has access; with no ANTHROPIC_API_KEY the server-side fallback answers.
    r = await fn(boss, "aiSuggest", **SUGGEST)
    assert r.status_code == 200
    s = r.json()["data"]["suggestions"]
    assert len(s) == 8 and s[0]["name"].startswith("Banff ") and {"estimatedPrice", "rating", "category"} <= set(s[0])

    r = await fn(boss, "aiSuggest", **{**SUGGEST, "module": "accommodations", "preferences": {"stayType": "camping"}})
    acc = r.json()["data"]["suggestions"]
    assert len(acc) == 3 and all(a["stayType"] == "camping" for a in acc)

    assert (await fn(boss, "aiSuggest", **{**SUGGEST, "module": "bogus"})).status_code == 400
    r = await fn(boss, "aiSuggest", **{**SUGGEST, "lat": None})
    assert r.status_code == 412 and r.json()["code"] == "failed-precondition"
    r = await fn(boss, "aiSuggest", **{**SUGGEST, "startDate": ""})
    assert r.status_code == 412


async def test_entitlement_grants_ai_access(alice, boss):
    await boss.set(f"userEntitlements/{alice.uid}", {"subscription": "premium"})
    assert (await fn(alice, "aiSuggest", **SUGGEST)).status_code == 200


async def test_stripe_not_configured(alice):
    r = await fn(alice, "createStripeCheckoutSession", plan="monthly")
    assert r.status_code == 412 and "STRIPE_SECRET_KEY" in r.json()["message"]
    assert (await fn(alice, "createStripeBillingPortal")).status_code == 412


def _signed(secret: str, payload: dict) -> tuple[bytes, str]:
    body = json.dumps(payload).encode()
    t = int(time.time())
    sig = hmac.new(secret.encode(), f"{t}.".encode() + body, hashlib.sha256).hexdigest()
    return body, f"t={t},v1={sig}"


async def test_stripe_webhook_updates_entitlements(alice, anon, monkeypatch):
    s = get_settings()
    monkeypatch.setattr(s, "stripe_webhook_secret", "whsec_test")
    await alice.set(f"users/{alice.uid}", {"displayName": "Al"}, merge=True)

    event = {
        "id": "evt_1", "object": "event", "type": "customer.subscription.created",
        "data": {"object": {"id": "sub_1", "customer": "cus_1", "status": "active", "current_period_end": 1893456000,
                            "metadata": {"uid": alice.uid, "plan": "yearly"},
                            "items": {"data": [{"price": {"id": "price_1", "recurring": {"interval": "year"}}}]}}},
    }
    body, header = _signed("whsec_test", event)
    r = await anon.http.post("/api/stripe/webhook", content=body, headers={"stripe-signature": header})
    assert r.status_code == 200, r.text

    ent = (await alice.get(f"userEntitlements/{alice.uid}")).json()["data"]
    assert ent["subscription"] == "premium" and ent["premiumPlan"] == "yearly" and ent["stripeCustomerId"] == "cus_1"
    assert ent["currentPeriodEnd"]["$ts"].startswith("2030-01-01")
    user = (await alice.get(f"users/{alice.uid}")).json()["data"]
    assert user["subscription"] == "premium" and user["displayName"] == "Al"

    # Cancellation downgrades; the customer->uid lookup works without metadata.
    event["type"] = "customer.subscription.deleted"
    event["data"]["object"]["status"] = "canceled"
    event["data"]["object"]["metadata"] = {}
    body, header = _signed("whsec_test", event)
    assert (await anon.http.post("/api/stripe/webhook", content=body, headers={"stripe-signature": header})).status_code == 200
    assert (await alice.get(f"userEntitlements/{alice.uid}")).json()["data"]["subscription"] == "free"

    bad = await anon.http.post("/api/stripe/webhook", content=body, headers={"stripe-signature": "t=1,v1=deadbeef"})
    assert bad.status_code == 400
    assert (await anon.http.post("/api/stripe/webhook", content=body)).status_code == 400


async def test_route_proxy_validation(anon):
    r = await anon.http.post("/api/route", json={"provider": "ors", "profile": "driving-car", "coordinates": [[1, 2]]})
    assert r.status_code == 400 and r.json()["error"] == "COORDINATES_INVALID"
    r = await anon.http.post("/api/route", json={"provider": "zzz", "coordinates": [[1, 2], [3, 4]]})
    assert r.status_code == 400 and r.json()["error"] == "UNSUPPORTED_PROVIDER"
    r = await anon.http.post("/api/route", json={"provider": "ors", "profile": "driving-car", "coordinates": [[1, 2], [3, 4]]})
    assert r.status_code == 500 and r.json()["error"] == "ORS_KEY_MISSING"
    assert (await anon.http.post("/api/overpass", json={})).status_code == 400
