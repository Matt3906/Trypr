from __future__ import annotations

import hashlib
from typing import Any

from app.core.errors import ApiError

_OPS = {"==", "!=", "<", "<=", ">", ">=", "in", "not-in", "array-contains", "array-contains-any"}
_CMP = {"<": "<", "<=": "<=", ">": ">", ">=": ">="}


def _field_path(field: str) -> list[str]:
    if not isinstance(field, str) or not field or len(field) > 500:
        raise ApiError(400, "Invalid field path")
    return field.split(".")


class Builder:
    def __init__(self) -> None:
        self.params: list[Any] = []

    def p(self, v: Any) -> str:
        self.params.append(v)
        return f"${len(self.params)}"


def build_query(
    *,
    parent: str | None,
    group: str | None,
    scope_sql: str,
    scope_params: list[Any],
    where: list[list[Any]],
    order_by: list[list[str]],
    limit: int | None,
) -> tuple[str, list[Any]]:
    b = Builder()
    conds: list[str] = []
    if group is not None:
        conds.append(f"coll = {b.p(group)}")
    else:
        conds.append(f"parent = {b.p(parent)}")

    # scope fragment uses $1.. for its own params; remap onto this builder's numbering
    if scope_params:
        remap = {f"${i + 1}": b.p(v) for i, v in enumerate(scope_params)}
        frag = scope_sql
        for k in sorted(remap, key=len, reverse=True):
            frag = frag.replace(k, remap[k])
        conds.append(frag)
    elif scope_sql != "TRUE":
        conds.append(scope_sql)

    for clause in where or []:
        if not isinstance(clause, list) or len(clause) != 3:
            raise ApiError(400, "Invalid where clause")
        field, op, value = clause
        if op not in _OPS:
            raise ApiError(400, f"Unsupported operator {op!r}")
        path = b.p(_field_path(field))
        col = f"(data #> {path}::text[])"
        if op == "==":
            conds.append(f"{col} = {b.p(value)}::jsonb")
        elif op == "!=":
            v = b.p(value)
            conds.append(f"({col} IS NOT NULL AND {col} <> {v}::jsonb)")
        elif op in _CMP:
            v = b.p(value)
            conds.append(f"({col} IS NOT NULL AND jsonb_typeof({col}) = jsonb_typeof({v}::jsonb) AND {col} {_CMP[op]} {v}::jsonb)")
        elif op == "in":
            if not isinstance(value, list) or not value:
                raise ApiError(400, "'in' needs a non-empty list")
            conds.append(f"{col} = ANY({b.p(value)}::jsonb[])")
        elif op == "not-in":
            if not isinstance(value, list) or not value:
                raise ApiError(400, "'not-in' needs a non-empty list")
            conds.append(f"({col} IS NOT NULL AND NOT ({col} = ANY({b.p(value)}::jsonb[])))")
        elif op == "array-contains":
            conds.append(f"({col} @> jsonb_build_array({b.p(value)}::jsonb))")
        elif op == "array-contains-any":
            if not isinstance(value, list) or not value:
                raise ApiError(400, "'array-contains-any' needs a non-empty list")
            conds.append(
                f"EXISTS (SELECT 1 FROM jsonb_array_elements({col}) e WHERE e = ANY({b.p(value)}::jsonb[]))"
            )

    order_parts: list[str] = []
    for item in order_by or []:
        if not isinstance(item, list) or not item:
            raise ApiError(400, "Invalid orderBy")
        direction = "DESC" if len(item) > 1 and str(item[1]).lower().startswith("desc") else "ASC"
        col = f"(data #> {b.p(_field_path(item[0]))}::text[])"
        conds.append(f"{col} IS NOT NULL")  # Firestore omits docs missing the ordered field
        order_parts.append(f"{col} {direction}")
    order_parts.append("path ASC")

    sql = (
        "SELECT path, id, data, rev FROM documents WHERE "
        + " AND ".join(conds)
        + " ORDER BY "
        + ", ".join(order_parts)
    )
    if limit is not None:
        if not isinstance(limit, int) or limit < 1 or limit > 5000:
            raise ApiError(400, "Invalid limit")
        sql += f" LIMIT {limit}"
    return sql, b.params


def etag_for(rows: list[Any]) -> str:
    h = hashlib.md5()
    for r in rows:
        h.update(f"{r['path']}:{r['rev']}|".encode())
    return h.hexdigest()
