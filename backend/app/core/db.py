from __future__ import annotations

import json
import logging
from pathlib import Path

import asyncpg

from app.core.config import get_settings

logger = logging.getLogger(__name__)

_pool: asyncpg.Pool | None = None
_SCHEMA_LOCK_ID = 7_251_001


async def _init_conn(conn: asyncpg.Connection) -> None:
    # jsonb <-> native Python objects.
    await conn.set_type_codec(
        "jsonb", encoder=json.dumps, decoder=json.loads, schema="pg_catalog", format="text"
    )
    await conn.set_type_codec(
        "json", encoder=json.dumps, decoder=json.loads, schema="pg_catalog", format="text"
    )


async def init_pool() -> asyncpg.Pool:
    global _pool
    if _pool is None:
        s = get_settings()
        _pool = await asyncpg.create_pool(s.dsn, min_size=1, max_size=10, init=_init_conn)
        await ensure_schema()
    return _pool


async def close_pool() -> None:
    global _pool
    if _pool is not None:
        await _pool.close()
        _pool = None


def get_pool() -> asyncpg.Pool:
    if _pool is None:
        raise RuntimeError("Database pool is not initialised")
    return _pool


async def ensure_schema() -> None:
    sql = (Path(__file__).resolve().parent.parent / "schema.sql").read_text()
    async with get_pool().acquire() as conn:
        async with conn.transaction():
            await conn.execute("SELECT pg_advisory_xact_lock($1)", _SCHEMA_LOCK_ID)
            await conn.execute(sql)
    logger.info("Database schema ready")
