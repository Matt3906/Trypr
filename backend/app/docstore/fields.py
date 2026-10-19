"""Value codec for the document store.

Wire format (matches frontend/src/backend/codec.ts):
  Timestamp           {"$ts": "2026-01-02T03:04:05.678Z"}      (stored as-is)
  serverTimestamp()   {"$op": "serverTimestamp"}               (resolved on write)
  increment(n)        {"$op": "increment", "n": 5}
  arrayUnion(...v)    {"$op": "arrayUnion", "v": [...]}
  arrayRemove(...v)   {"$op": "arrayRemove", "v": [...]}
  deleteField()       {"$op": "deleteField"}
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from typing import Any

from app.core.errors import ApiError

TS = "$ts"
OP = "$op"
MAX_DOC_BYTES = 2 * 1024 * 1024

_TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?Z$")


class _Delete:
    def __repr__(self) -> str:  # pragma: no cover
        return "<DELETE>"


DELETE = _Delete()


def fmt_ts(dt: datetime) -> str:
    dt = dt.astimezone(timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + f"{dt.microsecond // 1000:03d}Z"


def now_ts() -> dict[str, str]:
    return {TS: fmt_ts(datetime.now(timezone.utc))}


def is_ts(v: Any) -> bool:
    return isinstance(v, dict) and len(v) == 1 and TS in v and isinstance(v[TS], str)


def is_op(v: Any) -> bool:
    return isinstance(v, dict) and OP in v


def _normalise_ts(v: dict) -> dict:
    raw = v[TS]
    if not _TS_RE.match(raw):
        raise ApiError(400, "Invalid timestamp value")
    base, _, frac = raw[:-1].partition(".")
    dt = datetime.strptime(base, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    ms = int((frac + "000")[:3])
    return {TS: fmt_ts(dt.replace(microsecond=ms * 1000))}


def _eval_op(v: dict, cur: Any) -> Any:
    op = v.get(OP)
    if op == "serverTimestamp":
        return now_ts()
    if op == "deleteField":
        return DELETE
    if op == "increment":
        n = v.get("n")
        if isinstance(n, bool) or not isinstance(n, (int, float)):
            raise ApiError(400, "increment() needs a number")
        base = cur if isinstance(cur, (int, float)) and not isinstance(cur, bool) else 0
        return base + n
    if op in ("arrayUnion", "arrayRemove"):
        items = v.get("v")
        if not isinstance(items, list):
            raise ApiError(400, f"{op}() needs a list")
        items = [resolve_value(i, None, nested=True) for i in items]
        base = list(cur) if isinstance(cur, list) else []
        if op == "arrayUnion":
            for i in items:
                if i not in base:
                    base.append(i)
            return base
        return [b for b in base if b not in items]
    raise ApiError(400, f"Unknown field operation: {op!r}")


def resolve_value(v: Any, cur: Any, nested: bool = False) -> Any:
    """Resolve sentinels inside `v`. `cur` is the existing value at this location."""
    if isinstance(v, dict):
        if is_op(v):
            if nested:
                raise ApiError(400, "Field operations are not allowed inside arrays")
            return _eval_op(v, cur)
        if TS in v:
            if not is_ts(v):
                raise ApiError(400, "Invalid timestamp value")
            return _normalise_ts(v)
        out: dict[str, Any] = {}
        for k, vv in v.items():
            r = resolve_value(vv, None if not isinstance(cur, dict) else cur.get(k), nested)
            if r is not DELETE:
                out[k] = r
        return out
    if isinstance(v, list):
        return [resolve_value(i, None, nested=True) for i in v]
    return v


def apply_patch(base: dict[str, Any], patch: dict[str, Any]) -> dict[str, Any]:
    """set(..., merge=True) semantics: nested maps merge recursively; everything else replaces."""
    out = dict(base)
    for k, v in patch.items():
        cur = out.get(k)
        if isinstance(v, dict) and not is_op(v) and TS not in v:
            sub_base = cur if isinstance(cur, dict) and not is_ts(cur) else {}
            out[k] = apply_patch(sub_base, v)
        else:
            r = resolve_value(v, cur)
            if r is DELETE:
                out.pop(k, None)
            else:
                out[k] = r
    return out


def apply_update(base: dict[str, Any], updates: dict[str, Any]) -> dict[str, Any]:
    """updateDoc() semantics: top-level keys replace; dotted keys address nested fields."""
    out = json.loads(json.dumps(base))
    for key, v in updates.items():
        parts = key.split(".")
        node = out
        for p in parts[:-1]:
            nxt = node.get(p)
            if not isinstance(nxt, dict) or is_ts(nxt):
                nxt = {}
                node[p] = nxt
            node = nxt
        leaf = parts[-1]
        r = resolve_value(v, node.get(leaf))
        if r is DELETE:
            node.pop(leaf, None)
        else:
            node[leaf] = r
    return out


def check_size(data: dict[str, Any]) -> None:
    if len(json.dumps(data, separators=(",", ":"))) > MAX_DOC_BYTES:
        raise ApiError(413, "Document is too large")
