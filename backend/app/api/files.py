"""File storage on local disk (replaces Firebase Storage). Rules mirror the old storage.rules."""

from __future__ import annotations

import json
import logging
import os
import uuid
from pathlib import Path

from fastapi import APIRouter, Depends, File, Form, Request, UploadFile
from fastapi.responses import FileResponse

from app.core.config import get_settings
from app.core.db import get_pool
from app.core.errors import ApiError
from app.core.ratelimit import client_ip, limiter
from app.core.sessions import Actor, optional_actor
from app.docstore.paths import _segments

router = APIRouter(prefix="/files", tags=["files"])
settings = get_settings()
logger = logging.getLogger(__name__)

_PUBLIC_READ_PREFIXES = ("verifiedTrips", "unlistedPages", "unlistedFormUploads")
# Types that are safe to render inline from the API origin; everything else downloads.
_INLINE_TYPES = ("image/png", "image/jpeg", "image/gif", "image/webp", "image/avif", "application/pdf")
_INLINE_PREFIXES = ("video/", "audio/")
_ANON_UPLOAD_TYPES = ("application/", "image/", "text/")


def _can_read(segs: list[str], actor: Actor | None) -> bool:
    if segs[0] in _PUBLIC_READ_PREFIXES:
        return True
    if segs[0] in ("tripDocuments", "tripPhotos"):
        return actor is not None
    if segs[0] == "users" and len(segs) > 2:
        return actor is not None and actor.uid == segs[1]
    return False


def _can_write(segs: list[str], actor: Actor | None, content_type: str, size: int) -> bool:
    if segs[0] in ("verifiedTrips", "unlistedPages"):
        return bool(actor and actor.is_admin)
    if segs[0] == "unlistedFormUploads" and len(segs) > 2:
        return size < 15 * 1024 * 1024 and content_type.startswith(_ANON_UPLOAD_TYPES)
    if segs[0] in ("tripDocuments", "tripPhotos") and len(segs) > 2:
        return actor is not None
    if segs[0] == "users" and len(segs) > 2:
        return actor is not None and actor.uid == segs[1]
    return False


def _storage_file(key: str) -> Path:
    return Path(settings.upload_dir) / key[:2] / key


@router.post("/upload")
async def upload(
    request: Request,
    path: str = Form(...),
    file: UploadFile = File(...),
    content_type: str = Form("", alias="contentType"),
    custom_metadata: str = Form("{}", alias="customMetadata"),
    actor: Actor | None = Depends(optional_actor),
) -> dict:
    segs = _segments(path)
    if len(segs) < 2:
        raise ApiError(400, "Invalid file path")
    ctype = (content_type or file.content_type or "application/octet-stream").strip().lower()[:200]
    if actor is None:
        limiter.check(f"anon-upload:{client_ip(request)}", 10, 60)

    # Stream to disk with a hard size cap.
    max_bytes = settings.max_upload_mb * 1024 * 1024
    key = uuid.uuid4().hex
    dest = _storage_file(key)
    dest.parent.mkdir(parents=True, exist_ok=True)
    size = 0
    try:
        with dest.open("wb") as out:
            while chunk := await file.read(1024 * 1024):
                size += len(chunk)
                if size > max_bytes:
                    raise ApiError(413, f"File is larger than {settings.max_upload_mb} MB")
                out.write(chunk)
        if not _can_write(segs, actor, ctype, size):
            raise ApiError(403 if actor else 401, "You can't upload to this location")
        try:
            meta = json.loads(custom_metadata or "{}")
            if not isinstance(meta, dict):
                meta = {}
        except ValueError:
            meta = {}

        pool = get_pool()
        async with pool.acquire() as conn:
            async with conn.transaction():
                old = await conn.fetchval("SELECT storage_key FROM files WHERE path = $1 FOR UPDATE", "/".join(segs))
                await conn.execute(
                    """
                    INSERT INTO files (path, storage_key, content_type, size, custom_metadata, uploaded_by)
                    VALUES ($1,$2,$3,$4,$5,$6)
                    ON CONFLICT (path) DO UPDATE SET storage_key = EXCLUDED.storage_key,
                        content_type = EXCLUDED.content_type, size = EXCLUDED.size,
                        custom_metadata = EXCLUDED.custom_metadata, uploaded_by = EXCLUDED.uploaded_by,
                        created_at = now()
                    """,
                    "/".join(segs), key, ctype, size, meta, actor.uid if actor else None,
                )
        if old:
            _storage_file(old).unlink(missing_ok=True)
    except BaseException:
        dest.unlink(missing_ok=True)
        raise
    return {"path": "/".join(segs), "size": size, "contentType": ctype}


@router.get("/{file_path:path}")
async def download(file_path: str, actor: Actor | None = Depends(optional_actor)) -> FileResponse:
    segs = _segments(file_path)
    row = await get_pool().fetchrow(
        "SELECT storage_key, content_type FROM files WHERE path = $1", "/".join(segs)
    )
    if not row:
        raise ApiError(404, "File not found")
    if not _can_read(segs, actor):
        raise ApiError(403 if actor else 401, "You don't have access to this file")
    disk = _storage_file(row["storage_key"])
    if not os.path.exists(disk):
        raise ApiError(404, "File not found")

    ctype = row["content_type"]
    inline = ctype in _INLINE_TYPES or ctype.startswith(_INLINE_PREFIXES)
    public = segs[0] in _PUBLIC_READ_PREFIXES
    headers = {
        "Cache-Control": ("public" if public else "private") + ", max-age=3600",
        "X-Content-Type-Options": "nosniff",
        "Content-Security-Policy": "sandbox; default-src 'none'",
        "Cross-Origin-Resource-Policy": "cross-origin",
    }
    return FileResponse(
        disk,
        media_type=ctype,
        filename=None if inline else segs[-1],
        content_disposition_type="inline" if inline else "attachment",
        headers=headers,
    )
