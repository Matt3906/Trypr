import json

import httpx
import pytest

from app.core.db import get_pool
from app.services import overpass_cache, proxy


@pytest.fixture(autouse=True)
async def _fresh_cache():
    overpass_cache.clear_memory()
    proxy.reset_overpass_limits()
    await get_pool().execute("TRUNCATE overpass_cache")
    yield
    overpass_cache.clear_memory()
    proxy.reset_overpass_limits()


def _mock_upstream(monkeypatch, handler):
    calls: list[httpx.Request] = []

    def record(request: httpx.Request) -> httpx.Response:
        calls.append(request)
        return handler(request)

    real_client = httpx.AsyncClient
    monkeypatch.setattr(proxy.httpx, "AsyncClient", lambda **kw: real_client(transport=httpx.MockTransport(record), **kw))
    monkeypatch.setattr(proxy, "_OVERPASS_STAGGER_S", 0.01)
    return calls


def _elements(body: str) -> list:
    return json.loads(body)["elements"]


async def test_overpass_hedges_past_failing_mirrors(monkeypatch):
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.host == "overpass-api.de":
            return httpx.Response(406, text="Not Acceptable")
        if request.url.host == "maps.mail.ru":
            # Server-side timeout: 200 with a runtime-error remark and no elements.
            return httpx.Response(200, json={"elements": [], "remark": "runtime error: Query timed out"})
        return httpx.Response(200, json={"elements": [{"type": "node", "id": 1}]})

    calls = _mock_upstream(monkeypatch, handler)
    status, body, cache = await proxy.overpass("[out:json];node(1);out;")
    assert status == 200 and cache == "MISS"
    assert _elements(body) == [{"type": "node", "id": 1}]
    assert calls and all(c.headers["user-agent"].startswith("Trypr/") for c in calls)


async def test_overpass_cache_survives_restart(monkeypatch):
    calls = _mock_upstream(monkeypatch, lambda r: httpx.Response(200, json={"elements": [{"type": "node", "id": 7}]}))
    await proxy.overpass("[out:json];node(7);out;")
    upstream_calls = len(calls)

    overpass_cache.clear_memory()  # as if the backend restarted
    status, body, cache = await proxy.overpass("[out:json];node(7);out;")
    assert (status, cache) == (200, "HIT")
    assert _elements(body) == [{"type": "node", "id": 7}]
    assert len(calls) == upstream_calls
    row = await get_pool().fetchrow("SELECT query, size_bytes FROM overpass_cache")
    assert row["query"] == "[out:json];node(7);out;" and row["size_bytes"] == len(body)


async def test_overpass_serves_stale_and_refreshes(monkeypatch):
    version = {"id": 1}
    _mock_upstream(monkeypatch, lambda r: httpx.Response(200, json={"elements": [{"type": "node", "id": version["id"]}]}))
    query = "[out:json];node(3);out;"
    await proxy.overpass(query)

    await get_pool().execute("UPDATE overpass_cache SET fetched_at = now() - interval '30 days'")
    overpass_cache.clear_memory()
    version["id"] = 2

    status, body, cache = await proxy.overpass(query)
    assert (status, cache) == (200, "STALE")
    assert _elements(body) == [{"type": "node", "id": 1}]
    await proxy._overpass_in_flight[query]  # the background refresh

    status, body, cache = await proxy.overpass(query)
    assert (status, cache) == (200, "HIT")
    assert _elements(body) == [{"type": "node", "id": 2}]


async def test_overpass_reports_upstream_failure_without_caching(monkeypatch):
    _mock_upstream(monkeypatch, lambda r: httpx.Response(504, text="busy"))
    status, body, _ = await proxy.overpass("[out:json];node(2);out;")
    assert status == 502 and body["error"] == "OVERPASS_UPSTREAM_FAILED"
    assert await get_pool().fetchval("SELECT count(*) FROM overpass_cache") == 0


async def test_overpass_backs_off_after_rate_limit(monkeypatch):
    calls = _mock_upstream(monkeypatch, lambda r: httpx.Response(429, text="Too Many Requests"))

    status, _, _ = await proxy.overpass("[out:json];node(10);out;")
    assert status == 502
    hosts = [c.url.host for c in calls]
    # overpass-api.de and lz4.overpass-api.de share a rate limit: only one of them is asked.
    assert sum(h.endswith("overpass-api.de") for h in hosts) == 1
    assert len(hosts) == len(set(hosts))

    # Every operator answered 429, so the next request does not touch any of them.
    calls.clear()
    status, body, _ = await proxy.overpass("[out:json];node(11);out;")
    assert status == 503 and body["error"] == "OVERPASS_COOLING_DOWN"
    assert calls == []


async def test_overpass_prune_drops_unused_rows(monkeypatch):
    _mock_upstream(monkeypatch, lambda r: httpx.Response(200, json={"elements": []}))
    await proxy.overpass("[out:json];node(4);out;")
    await proxy.overpass("[out:json];node(5);out;")
    await get_pool().execute(
        "UPDATE overpass_cache SET last_used_at = now() - interval '200 days' WHERE query LIKE '%node(4)%'"
    )
    assert await overpass_cache.prune() == 1
    assert await get_pool().fetchval("SELECT count(*) FROM overpass_cache") == 1
