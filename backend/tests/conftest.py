"""Integration tests run against a real Postgres: TEST_DATABASE_URL=postgresql://user@host:port/db pytest"""

from __future__ import annotations

import os

import httpx
import pytest
import pytest_asyncio

if not os.environ.get("TEST_DATABASE_URL"):
    pytest.skip("TEST_DATABASE_URL not set", allow_module_level=True)

os.environ["DATABASE_URL"] = os.environ["TEST_DATABASE_URL"]
os.environ["ENVIRONMENT"] = "development"
os.environ["ADMIN_EMAILS"] = "boss@example.com"
os.environ.setdefault("UPLOAD_DIR", "/tmp/trypr-test-uploads")

from app.core import db as dbmod  # noqa: E402
from app.main import app  # noqa: E402


@pytest_asyncio.fixture(scope="session", autouse=True)
async def _pool():
    await dbmod.init_pool()
    yield
    await dbmod.close_pool()


@pytest_asyncio.fixture(autouse=True)
async def _clean(_pool):
    from app.core.ratelimit import limiter

    limiter._hits.clear()
    pool = dbmod.get_pool()
    await pool.execute("TRUNCATE sessions, password_resets, documents, files, accounts CASCADE")
    yield


class Client:
    """A browser-like client with its own cookie jar."""

    def __init__(self) -> None:
        self.http = httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test")
        self.uid: str | None = None

    async def register(self, email: str, password: str = "password123") -> dict:
        r = await self.http.post("/api/auth/register", json={"email": email, "password": password})
        assert r.status_code == 200, r.text
        self.uid = r.json()["user"]["uid"]
        return r.json()["user"]

    async def post(self, url: str, **json):
        return await self.http.post(url, json=json)

    async def write(self, *writes, preconditions=None):
        body = {"writes": list(writes)}
        if preconditions:
            body["preconditions"] = preconditions
        return await self.http.post("/api/db/write", json=body)

    async def set(self, path, data, merge=False):
        return await self.write({"op": "set", "path": path, "data": data, "merge": merge})

    async def get(self, path):
        r = await self.http.post("/api/db/get", json={"path": path})
        return r

    async def query(self, **q):
        return await self.http.post("/api/db/query", json=q)


@pytest_asyncio.fixture
async def anon():
    c = Client()
    yield c
    await c.http.aclose()


@pytest_asyncio.fixture
async def alice():
    c = Client()
    await c.register("alice@example.com")
    yield c
    await c.http.aclose()


@pytest_asyncio.fixture
async def bob():
    c = Client()
    await c.register("bob@example.com")
    yield c
    await c.http.aclose()


@pytest_asyncio.fixture
async def boss():
    c = Client()
    await c.register("boss@example.com")
    yield c
    await c.http.aclose()


def ts(s="2026-01-01T00:00:00.000Z"):
    return {"$ts": s}


SERVER_TS = {"$op": "serverTimestamp"}
