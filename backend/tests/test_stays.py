import asyncio
from dataclasses import replace
from datetime import date, timedelta
from urllib.parse import parse_qs, urlsplit

import pytest

from app.core.config import get_settings
from app.core.db import get_pool
from app.services.stays import engine, links
from app.services.stays.matching import cluster_offers, name_tokens
from app.services.stays.models import Offer, StayQuery
from app.services.stays.providers import link_hosts
from app.services.stays.providers.hotellook import parse as parse_hotellook

CHECK_IN = date.today() + timedelta(days=30)
Q = StayQuery(lat=51.1784, lon=-115.5708, check_in=CHECK_IN, check_out=CHECK_IN + timedelta(days=3),
              adults=2, currency="USD", radius_km=15, name="Banff")


def offer(provider="a", hid="1", name="Grand Plaza Hotel", lat=51.18, lon=-115.57, total=30000, **kw) -> Offer:
    return Offer(provider=provider, provider_hotel_id=hid, hotel_name=name, lat=lat, lon=lon, total_cents=total,
                 currency="USD", url=f"https://example.com/{provider}/{hid}", **kw)


class FakeProvider:
    link_hosts = ("example.com",)

    def __init__(self, id, offers=None, delay=0.0, error=None):
        self.id, self.label = id, id.upper()
        self.offers, self.delay, self.error, self.calls = offers or [], delay, error, 0

    def enabled(self):
        return True

    async def search(self, q):
        self.calls += 1
        if self.delay:
            await asyncio.sleep(self.delay)
        if self.error:
            raise self.error
        return self.offers


@pytest.fixture(autouse=True)
def _engine_state():
    engine.clear()
    yield
    engine.clear()


# --- matching ------------------------------------------------------------------------------------

def test_name_tokens_ignore_accents_punctuation_and_filler():
    assert name_tokens("Hôtel du Lac") == name_tokens("HOTEL DU LAC!") == ("du", "lac")
    assert name_tokens("The Hotel") == ("the", "hotel")  # all filler: keep the words rather than match on nothing


def test_same_hotel_with_different_names_and_coordinates_clusters():
    a = offer("a", "1", "Grand Plaza Hotel", 51.1800, -115.5700)
    b = offer("b", "9", "The Grand Plaza", 51.18015, -115.57005)  # ~20 m away
    assert len(cluster_offers([a, b])) == 1


def test_neighbouring_different_hotels_do_not_merge():
    a = offer("a", "1", "Grand Plaza Hotel", 51.1800, -115.5700)
    b = offer("b", "2", "Riverside Inn", 51.1801, -115.5701)  # next door, unrelated name
    assert len(cluster_offers([a, b])) == 2


def test_same_name_far_apart_does_not_merge():
    a = offer("a", "1", "Holiday Inn", 51.18, -115.57)
    b = offer("b", "2", "Holiday Inn", 51.28, -115.57)  # ~11 km
    assert len(cluster_offers([a, b])) == 2


def test_star_rating_conflict_blocks_a_merge():
    a = offer("a", "1", "Pinecone Hostel", stars=2)
    b = offer("b", "2", "Pinecone Hostel", stars=4)
    assert len(cluster_offers([a, b])) == 2


def test_clustering_is_independent_of_input_order():
    offers = [
        offer("a", "1", "Grand Plaza Hotel", 51.1800, -115.5700),
        offer("b", "2", "The Grand Plaza", 51.18010, -115.57005),
        offer("c", "3", "Grand Plaza", 51.17995, -115.57002),
        offer("a", "4", "Riverside Inn", 51.2, -115.6),
    ]
    forward = sorted(sorted(o.provider_hotel_id for o in g) for g in cluster_offers(offers))
    backward = sorted(sorted(o.provider_hotel_id for o in g) for g in cluster_offers(offers[::-1]))
    assert forward == backward == [["1", "2", "3"], ["4"]]


# --- click-out links -----------------------------------------------------------------------------

def test_link_roundtrip_and_tamper_detection():
    token = links.sign(offer("a", "1"), Q)
    claim = links.verify(token, {"a": ("example.com",)})
    assert claim and claim.url == "https://example.com/a/1" and claim.total_cents == 30000

    body, mac = token.split(".")
    assert links.verify(f"{body[:-2]}xx.{mac}", {"a": ("example.com",)}) is None
    assert links.verify(f"{body}.{mac[:-2]}xx", {"a": ("example.com",)}) is None
    assert links.verify("garbage", {"a": ("example.com",)}) is None


def test_link_expires():
    token = links.sign(offer("a", "1"), Q, now=1_000)
    assert links.verify(token, {"a": ("example.com",)}, now=1_000 + links.TOKEN_TTL_S - 1)
    assert links.verify(token, {"a": ("example.com",)}, now=1_000 + links.TOKEN_TTL_S + 1) is None


def test_link_host_must_belong_to_provider():
    token = links.sign(replace(offer("a", "1"), url="https://evil.test/x"), Q)
    assert links.verify(token, {"a": ("example.com",)}) is None
    assert links.verify(token, {"b": ("example.com",)}) is None  # unknown provider
    plain = links.sign(replace(offer("a", "1"), url="http://example.com/x"), Q)
    assert links.verify(plain, {"a": ("example.com",)}) is None  # https only
    sub = links.sign(replace(offer("a", "1"), url="https://www.example.com/x"), Q)
    assert links.verify(sub, {"a": ("example.com",)})
    lookalike = links.sign(replace(offer("a", "1"), url="https://notexample.com/x"), Q)
    assert links.verify(lookalike, {"a": ("example.com",)}) is None


def test_production_without_secret_cannot_sign(monkeypatch):
    s = get_settings()
    monkeypatch.setattr(s, "environment", "production")
    monkeypatch.setattr(s, "stays_signing_secret", "")
    assert not links.signing_available()
    with pytest.raises(RuntimeError):
        links.sign(offer(), Q)
    monkeypatch.setattr(s, "stays_signing_secret", "k")
    assert links.signing_available()


# --- Hotellook adapter ---------------------------------------------------------------------------

def test_hotellook_parse_builds_tagged_links_and_skips_bad_rows():
    payload = [
        {"priceFrom": 412.5, "hotelName": "Banff Springs", "hotelId": 99, "stars": 5,
         "location": {"name": "Banff", "geo": {"lat": 51.1646, "lon": -115.5625}}},
        {"priceFrom": 0, "hotelName": "Free?", "hotelId": 1, "location": {"geo": {"lat": 1, "lon": 1}}},
        {"hotelName": "No price", "hotelId": 2, "location": {"geo": {"lat": 1, "lon": 1}}},
        {"priceFrom": 10, "hotelName": "No geo", "hotelId": 3},
        "junk",
    ]
    offers = parse_hotellook(payload, Q, marker="12345")
    assert len(offers) == 1
    o = offers[0]
    assert (o.hotel_name, o.total_cents, o.stars, o.live) == ("Banff Springs", 41250, 5.0, False)
    qs = parse_qs(urlsplit(o.url).query)
    assert qs["marker"] == ["12345"] and qs["hotelId"] == ["99"] and qs["checkIn"] == [CHECK_IN.isoformat()]
    assert links.host_allowed(o.url, link_hosts()["hotellook"])
    assert parse_hotellook({"error": "bad token"}, Q, "") == []


# --- engine --------------------------------------------------------------------------------------

async def test_engine_finds_cheapest_provider_per_hotel_and_sorts_hotels():
    a = FakeProvider("a", [offer("a", "1", "Grand Plaza Hotel", total=40000), offer("a", "2", "Riverside Inn", total=20000)])
    b = FakeProvider("b", [offer("b", "7", "The Grand Plaza", 51.18005, -115.57003, total=35000)])
    res = await engine.search(Q, providers=[a, b])

    assert [h["name"] for h in res["hotels"]] == ["Riverside Inn", "Grand Plaza Hotel"]  # longest listing name wins
    plaza = res["hotels"][1]
    assert plaza["best"]["provider"] == "b" and plaza["best"]["totalCents"] == 35000
    assert [o["provider"] for o in plaza["offers"]] == ["b", "a"]
    assert plaza["savingsCents"] == 5000 and plaza["savingsPct"] == 12
    assert plaza["best"]["perNightCents"] == 11667  # 35000 / 3 nights
    assert plaza["best"]["url"].startswith("/api/stays/out?t=")
    assert "example.com" not in plaza["best"]["url"]  # partner URL is never exposed raw
    assert res["pending"] is False and res["nights"] == 3


async def test_one_provider_failing_does_not_break_the_rest():
    ok = FakeProvider("ok", [offer("ok", "1")])
    bad = FakeProvider("bad", error=RuntimeError("upstream 500"))
    res = await engine.search(Q, providers=[ok, bad])
    status = {p["id"]: p["status"] for p in res["providers"]}
    assert status == {"ok": "ok", "bad": "error"}
    assert len(res["hotels"]) == 1

    await engine.search(Q, providers=[ok, bad])
    assert bad.calls == 1  # the failure is negatively cached, not retried on every request


async def test_slow_provider_is_pending_then_served_from_cache():
    fast = FakeProvider("fast", [offer("fast", "1", total=50000)])
    slow = FakeProvider("slow", [offer("slow", "1", total=40000)], delay=0.3)

    first = await engine.search(Q, providers=[fast, slow], wait_s=0.05)
    assert first["pending"] is True
    assert {p["id"]: p["status"] for p in first["providers"]} == {"fast": "ok", "slow": "pending"}
    assert first["hotels"][0]["best"]["provider"] == "fast"

    await asyncio.sleep(0.4)
    second = await engine.search(Q, providers=[fast, slow], wait_s=0.05)
    assert second["pending"] is False
    assert second["hotels"][0]["best"]["provider"] == "slow"
    assert slow.calls == 1


async def test_concurrent_identical_searches_share_one_upstream_call():
    p = FakeProvider("a", [offer("a", "1")], delay=0.1)
    await asyncio.gather(*(engine.search(Q, providers=[p]) for _ in range(5)))
    assert p.calls == 1


async def test_wrong_currency_and_out_of_radius_offers_are_dropped():
    p = FakeProvider("a", [
        replace(offer("a", "1", "Good Hotel"), currency="EUR"),
        offer("a", "2", "Faraway Hotel", lat=52.5),
        offer("a", "3", "Free Hotel", total=0),
        offer("a", "4", "Fine Hotel"),
    ])
    res = await engine.search(Q, providers=[p])
    assert [h["name"] for h in res["hotels"]] == ["Fine Hotel"]


async def test_no_enabled_providers_reports_not_configured(monkeypatch):
    monkeypatch.setattr(get_settings(), "stays_demo", False)
    monkeypatch.setattr(get_settings(), "travelpayouts_token", "")
    res = await engine.search(Q)
    assert res["configured"] is False and res["hotels"] == []


# --- HTTP API ------------------------------------------------------------------------------------

@pytest.fixture
def demo_mode(monkeypatch):
    s = get_settings()
    monkeypatch.setattr(s, "stays_demo", True)
    monkeypatch.setattr(s, "environment", "development")
    monkeypatch.setattr(s, "stays_signing_secret", "")
    return s


def _params(**over):
    p = {"lat": 51.1784, "lon": -115.5708, "check_in": CHECK_IN.isoformat(),
         "check_out": (CHECK_IN + timedelta(days=2)).isoformat(), "adults": 2, "currency": "usd", "name": "Banff"}
    p.update(over)
    return p


async def test_search_endpoint_end_to_end_with_sample_providers(anon, demo_mode):
    r = await anon.http.get("/api/stays/search", params=_params())
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["sample"] is True and body["configured"] is True and body["currency"] == "USD"
    assert len(body["hotels"]) == 6  # six fake hotels, each reported by three providers, merged to one entry
    plaza = next(h for h in body["hotels"] if "Plaza" in h["name"])
    assert len(plaza["offers"]) == 3
    totals = [h["best"]["totalCents"] for h in body["hotels"]]
    assert totals == sorted(totals)


async def test_search_validation(anon, demo_mode):
    for over in (
        {"check_out": CHECK_IN.isoformat()},  # zero nights
        {"check_out": (CHECK_IN + timedelta(days=45)).isoformat()},  # too long
        {"check_in": (date.today() - timedelta(days=10)).isoformat(),
         "check_out": (date.today() - timedelta(days=8)).isoformat()},  # past
    ):
        assert (await anon.http.get("/api/stays/search", params=_params(**over))).status_code == 400
    assert (await anon.http.get("/api/stays/search", params=_params(lat=123))).status_code == 422
    assert (await anon.http.get("/api/stays/search", params=_params(currency="DOLLARS"))).status_code == 422


async def test_search_503_in_production_without_signing_secret(anon, demo_mode, monkeypatch):
    monkeypatch.setattr(demo_mode, "environment", "production")
    r = await anon.http.get("/api/stays/search", params=_params())
    assert r.status_code == 503


async def test_click_out_redirects_and_logs(alice, demo_mode):
    await get_pool().execute("TRUNCATE stay_clicks")
    body = (await alice.http.get("/api/stays/search", params=_params())).json()
    url = body["hotels"][0]["best"]["url"]

    r = await alice.http.get(url, follow_redirects=False)
    assert r.status_code == 302 and r.headers["location"].startswith("https://example.com/demo/")
    row = await get_pool().fetchrow("SELECT * FROM stay_clicks")
    assert row["uid"] == alice.uid and row["provider"].startswith("demo_") and row["total_cents"] > 0


async def test_click_out_rejects_forged_and_foreign_tokens(anon, demo_mode):
    assert (await anon.http.get("/api/stays/out", params={"t": "nope.nope"}, follow_redirects=False)).status_code == 400
    forged = links.sign(replace(offer("demo_a", "1"), url="https://evil.test/phish"), Q)
    assert (await anon.http.get("/api/stays/out", params={"t": forged}, follow_redirects=False)).status_code == 400


async def test_unconfigured_search_still_offers_a_commission_link_when_only_a_marker_is_set(anon, monkeypatch):
    s = get_settings()
    monkeypatch.setattr(s, "stays_demo", False)
    monkeypatch.setattr(s, "travelpayouts_token", "")
    monkeypatch.setattr(s, "travelpayouts_marker", "595446")
    monkeypatch.setattr(s, "environment", "development")
    monkeypatch.setattr(s, "stays_signing_secret", "")
    await get_pool().execute("TRUNCATE stay_clicks")

    body = (await anon.http.get("/api/stays/search", params=_params())).json()
    assert body["configured"] is False and body["hotels"] == []
    assert body["searchLink"]["label"] == "Hotellook"

    r = await anon.http.get(body["searchLink"]["url"], follow_redirects=False)
    assert r.status_code == 302
    target = urlsplit(r.headers["location"])
    qs = parse_qs(target.query)
    assert target.hostname == "search.hotellook.com" and qs["marker"] == ["595446"]
    assert qs["destination"] == ["Banff"] and qs["checkIn"] == [CHECK_IN.isoformat()]
    assert await get_pool().fetchval("SELECT count(*) FROM stay_clicks WHERE provider = 'hotellook'") == 1


async def test_no_search_link_without_a_marker(anon, monkeypatch):
    s = get_settings()
    monkeypatch.setattr(s, "stays_demo", False)
    monkeypatch.setattr(s, "travelpayouts_token", "")
    monkeypatch.setattr(s, "travelpayouts_marker", "")
    monkeypatch.setattr(s, "environment", "development")
    monkeypatch.setattr(s, "stays_signing_secret", "")
    body = (await anon.http.get("/api/stays/search", params=_params())).json()
    assert body["searchLink"] is None
