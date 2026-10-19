"""Tiny in-process sliding-window limiter (the backend runs a single uvicorn worker)."""

from __future__ import annotations

import time
from collections import defaultdict, deque

from fastapi import HTTPException, Request, status


class RateLimiter:
    def __init__(self) -> None:
        self._hits: dict[str, deque[float]] = defaultdict(deque)

    def check(self, key: str, limit: int, window_seconds: int) -> None:
        now = time.monotonic()
        q = self._hits[key]
        while q and now - q[0] > window_seconds:
            q.popleft()
        if len(q) >= limit:
            raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "Too many attempts. Try again shortly.")
        q.append(now)
        if len(self._hits) > 20_000:  # bound memory
            for k in [k for k, v in self._hits.items() if not v or now - v[-1] > window_seconds]:
                self._hits.pop(k, None)


limiter = RateLimiter()


def client_ip(request: Request) -> str:
    return request.client.host if request.client else "unknown"
