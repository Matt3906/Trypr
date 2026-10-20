"""Two-level cache for Overpass responses: a byte-bounded in-memory LRU in front of Postgres.

Map data for lakes, portages and campsites barely changes, while the public Overpass mirrors are slow
and rate limited, so responses are kept for weeks. Entries older than FRESH_FOR_S are still served,
and the caller refreshes them in the background.
"""

from __future__ import annotations

import asyncio
import gzip
import hashlib
import logging
import time
from collections import OrderedDict
from dataclasses import dataclass

from app.core.db import get_pool

logger = logging.getLogger(__name__)

FRESH_FOR_S = 14 * 24 * 3600
PRUNE_UNUSED_AFTER_DAYS = 90
_MEMORY_BUDGET_BYTES = 64 * 1024 * 1024
# Skip the last_used_at write on hits if it was touched recently.
_TOUCH_INTERVAL = "1 day"


@dataclass
class CachedResponse:
    text: str
    fetched_at: float  # unix seconds

    @property
    def fresh(self) -> bool:
        return time.time() - self.fetched_at <= FRESH_FOR_S


_memory: "OrderedDict[str, CachedResponse]" = OrderedDict()
_memory_bytes = 0


def query_hash(query: str) -> str:
    return hashlib.sha256(query.encode()).hexdigest()


def _memory_get(key: str) -> CachedResponse | None:
    hit = _memory.get(key)
    if hit:
        _memory.move_to_end(key)
    return hit


def _memory_put(key: str, entry: CachedResponse) -> None:
    global _memory_bytes
    old = _memory.pop(key, None)
    if old:
        _memory_bytes -= len(old.text)
    if len(entry.text) > _MEMORY_BUDGET_BYTES // 4:
        return
    _memory[key] = entry
    _memory_bytes += len(entry.text)
    while _memory_bytes > _MEMORY_BUDGET_BYTES and _memory:
        _, evicted = _memory.popitem(last=False)
        _memory_bytes -= len(evicted.text)


def clear_memory() -> None:
    global _memory_bytes
    _memory.clear()
    _memory_bytes = 0


async def get(query: str) -> CachedResponse | None:
    key = query_hash(query)
    hit = _memory_get(key)
    if hit and hit.fresh:
        return hit
    try:
        pool = get_pool()
        row = await pool.fetchrow(
            "SELECT body_gzip, extract(epoch FROM fetched_at) AS fetched_at FROM overpass_cache WHERE query_hash = $1",
            key,
        )
        if row is None:
            return hit
        await pool.execute(
            f"UPDATE overpass_cache SET last_used_at = now() "
            f"WHERE query_hash = $1 AND last_used_at < now() - interval '{_TOUCH_INTERVAL}'",
            key,
        )
    except Exception:
        logger.exception("overpass cache read failed")
        return hit
    text = (await asyncio.to_thread(gzip.decompress, row["body_gzip"])).decode()
    entry = CachedResponse(text, float(row["fetched_at"]))
    _memory_put(key, entry)
    return entry


async def put(query: str, text: str) -> None:
    key = query_hash(query)
    _memory_put(key, CachedResponse(text, time.time()))
    try:
        body = await asyncio.to_thread(gzip.compress, text.encode(), 6)
        await get_pool().execute(
            """
            INSERT INTO overpass_cache (query_hash, query, body_gzip, size_bytes, fetched_at, last_used_at)
            VALUES ($1, $2, $3, $4, now(), now())
            ON CONFLICT (query_hash) DO UPDATE
               SET body_gzip = EXCLUDED.body_gzip, size_bytes = EXCLUDED.size_bytes,
                   fetched_at = now(), last_used_at = now()
            """,
            key, query, body, len(text),
        )
    except Exception:
        logger.exception("overpass cache write failed")


async def prune() -> int:
    """Drops responses nobody has asked for in a while. Called from the hourly janitor."""
    result = await get_pool().execute(
        f"DELETE FROM overpass_cache WHERE last_used_at < now() - interval '{PRUNE_UNUSED_AFTER_DAYS} days'"
    )
    return int(result.split()[-1]) if result else 0
