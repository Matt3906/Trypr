import re

import pytest

from app.core import email as email_mod
from tests.conftest import Client


async def test_register_login_logout(anon):
    r = await anon.http.post("/api/auth/register", json={"email": "New@Example.com", "password": "password123"})
    assert r.status_code == 200
    assert r.json()["user"]["email"] == "new@example.com"
    assert "trypr_session" in r.cookies
    assert (await anon.http.get("/api/auth/me")).json()["user"]["email"] == "new@example.com"

    await anon.http.post("/api/auth/logout")
    assert (await anon.http.get("/api/auth/me")).json()["user"] is None

    r = await anon.http.post("/api/auth/login", json={"email": "NEW@example.com", "password": "password123"})
    assert r.status_code == 200


async def test_duplicate_and_bad_credentials(anon, alice):
    r = await anon.http.post("/api/auth/register", json={"email": "alice@example.com", "password": "password123"})
    assert r.status_code == 409 and r.json()["code"] == "already-exists"
    r = await anon.http.post("/api/auth/login", json={"email": "alice@example.com", "password": "wrong-password"})
    assert r.status_code == 401 and r.json()["code"] == "unauthenticated"
    r = await anon.http.post("/api/auth/login", json={"email": "nobody@example.com", "password": "whatever1"})
    assert r.status_code == 401
    r = await anon.http.post("/api/auth/register", json={"email": "x@example.com", "password": "short"})
    assert r.status_code == 422
    r = await anon.http.post("/api/auth/register", json={"email": "not-an-email", "password": "password123"})
    assert r.status_code == 400


async def test_password_reset_flow(anon, alice, monkeypatch):
    sent = []

    async def fake_send(**kw):
        sent.append(kw)

    from app.api import auth as auth_api

    monkeypatch.setattr(auth_api, "send_email", fake_send)
    r = await anon.http.post("/api/auth/forgot-password", json={"email": "alice@example.com"})
    assert r.status_code == 200 and len(sent) == 1
    # Unknown accounts get the same answer and no email.
    r = await anon.http.post("/api/auth/forgot-password", json={"email": "ghost@example.com"})
    assert r.status_code == 200 and len(sent) == 1

    token = re.search(r"token=([\w-]+)", sent[0]["body_text"]).group(1)
    r = await anon.http.post("/api/auth/reset-password", json={"token": token, "password": "brand-new-pass"})
    assert r.status_code == 200
    # Token is single-use; old sessions are revoked; new password works.
    assert (await anon.http.post("/api/auth/reset-password", json={"token": token, "password": "another-pass1"})).status_code == 400
    assert (await alice.http.get("/api/auth/me")).json()["user"] is None
    assert (await anon.http.post("/api/auth/login", json={"email": "alice@example.com", "password": "password123"})).status_code == 401
    assert (await anon.http.post("/api/auth/login", json={"email": "alice@example.com", "password": "brand-new-pass"})).status_code == 200


async def test_admin_bootstrap_from_env(boss, alice):
    # ADMIN_EMAILS account gets an admins/{uid} doc (the UI gates on it); others don't.
    assert (await boss.get(f"admins/{boss.uid}")).json()["exists"] is True
    assert (await alice.get(f"admins/{alice.uid}")).json()["exists"] is False


async def test_origin_guard(alice):
    r = await alice.http.post("/api/auth/logout", headers={"Origin": "https://evil.example"})
    assert r.status_code == 403
    r = await alice.http.post("/api/auth/logout", headers={"Origin": "https://tryprtravel.com"})
    assert r.status_code == 200
