"""Signed click-out tokens.

Affiliate deeplinks never reach the browser directly. The API hands out `/api/stays/out?t=<token>`
instead; the token carries the partner URL plus what we want to log, signed with HMAC so nobody can
turn the redirect endpoint into an open redirect. The host is also checked against the provider's
own domains when the token is verified, as a second line of defence.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import time
from dataclasses import dataclass
from urllib.parse import urlsplit

from app.core.config import get_settings

from .models import Offer, StayQuery

TOKEN_TTL_S = 24 * 3600
_DEV_KEY = b"trypr-dev-only-stays-key"


@dataclass(frozen=True)
class Claim:
    url: str
    provider: str
    hotel: str
    total_cents: int
    currency: str
    check_in: str
    check_out: str


def _key() -> bytes | None:
    s = get_settings()
    if s.stays_signing_secret:
        return s.stays_signing_secret.encode()
    return None if s.is_production else _DEV_KEY


def signing_available() -> bool:
    return _key() is not None


def _b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _unb64(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def host_allowed(url: str, link_hosts: tuple[str, ...]) -> bool:
    parts = urlsplit(url)
    host = (parts.hostname or "").lower()
    if parts.scheme != "https" or not host:
        return False
    return any(host == h or host.endswith("." + h) for h in link_hosts)


def sign(offer: Offer, q: StayQuery, now: float | None = None) -> str:
    key = _key()
    if key is None:
        raise RuntimeError("STAYS_SIGNING_SECRET is not configured")
    payload = {
        "u": offer.url, "p": offer.provider, "h": offer.hotel_name[:120], "c": offer.total_cents,
        "cur": offer.currency, "ci": q.check_in.isoformat(), "co": q.check_out.isoformat(),
        "exp": int((now if now is not None else time.time()) + TOKEN_TTL_S),
    }
    body = _b64(json.dumps(payload, separators=(",", ":")).encode())
    mac = hmac.new(key, body.encode(), hashlib.sha256).digest()[:16]
    return f"{body}.{_b64(mac)}"


def verify(token: str, link_hosts_by_provider: dict[str, tuple[str, ...]], now: float | None = None) -> Claim | None:
    key = _key()
    if key is None or token.count(".") != 1 or len(token) > 4096:
        return None
    body, mac = token.split(".")
    try:
        expected = hmac.new(key, body.encode(), hashlib.sha256).digest()[:16]
        if not hmac.compare_digest(expected, _unb64(mac)):
            return None
        p = json.loads(_unb64(body))
        if float(p["exp"]) < (now if now is not None else time.time()):
            return None
        claim = Claim(p["u"], p["p"], p["h"], int(p["c"]), p["cur"], p["ci"], p["co"])
    except (ValueError, KeyError, TypeError):
        return None
    hosts = link_hosts_by_provider.get(claim.provider)
    if not hosts or not host_allowed(claim.url, hosts):
        return None
    return claim
