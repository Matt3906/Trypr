"""Authorization for the document store — a Python port of the old firestore.rules.

Deliberate differences from the Firestore rules (all tightenings or fixes for flows the rules
could never have supported):
  * `users/{uid}` server-managed premium/Stripe fields are preserved on client writes (see docs.py).
  * Admins may also update/delete trips and read trip subcollections (the Admin Panel needs it).
  * `users/{uid}/friendRequests` is readable/deletable by its owner only; requests are created and
    accepted through /api/friends/* (cross-user writes can't be expressed safely as client rules).
  * The trip owner may (re)write a recipient's `sharedTrips/{tripId}` inbox entry.
"""

from __future__ import annotations

import re
from typing import Any

import asyncpg

from app.core.sessions import Actor
from app.docstore.fields import is_ts

TRIP_REF_RE = re.compile(r"^users/[^/]+/trips/[^/]+$")
READ, CREATE, UPDATE, DELETE = "read", "create", "update", "delete"


class Denied(Exception):
    pass


def _s(v: Any, max_len: int) -> bool:
    return isinstance(v, str) and len(v) <= max_len


def _num(v: Any) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


class Rules:
    def __init__(self, conn: asyncpg.Connection | asyncpg.Pool, actor: Actor | None) -> None:
        self.conn = conn
        self.actor = actor
        self._trips: dict[tuple[str, str], dict | None] = {}

    # ---- helpers -----------------------------------------------------------
    @property
    def uid(self) -> str | None:
        return self.actor.uid if self.actor else None

    @property
    def signed_in(self) -> bool:
        return self.actor is not None

    @property
    def admin(self) -> bool:
        return bool(self.actor and self.actor.is_admin)

    def is_self(self, uid: str) -> bool:
        return self.actor is not None and self.actor.uid == uid

    async def _trip(self, owner: str, trip_id: str) -> dict | None:
        key = (owner, trip_id)
        if key not in self._trips:
            self._trips[key] = await self.conn.fetchval(
                "SELECT data FROM documents WHERE path = $1", f"users/{owner}/trips/{trip_id}"
            )
        return self._trips[key]

    async def is_shared_with(self, owner: str, trip_id: str) -> bool:
        if not self.actor:
            return False
        trip = await self._trip(owner, trip_id)
        if not trip:
            return False
        shared = trip.get("sharedWith")
        emails = trip.get("sharedWithEmails")
        email = self.actor.email
        if isinstance(shared, list) and (self.actor.uid in shared or email in shared):
            return True
        return isinstance(emails, list) and email in emails

    async def can_read_trip(self, owner: str, trip_id: str) -> bool:
        return self.is_self(owner) or await self.is_shared_with(owner, trip_id)

    def forget_trip(self, owner: str, trip_id: str) -> None:
        self._trips.pop((owner, trip_id), None)

    # ---- document rules -----------------------------------------------------
    async def check(
        self, op: str, segs: tuple[str, ...], existing: dict | None, final: dict | None
    ) -> None:
        if not await self._allowed(op, segs, existing, final):
            raise Denied(f"Missing or insufficient permissions ({op} {'/'.join(segs)})")

    async def _allowed(self, op: str, segs: tuple[str, ...], existing: dict | None, final: dict | None) -> bool:
        n, c = len(segs), segs[0]
        uid = self.uid

        if c == "users":
            if n == 2:
                u = segs[1]
                if op == READ:
                    return self.is_self(u) or self.admin
                if op == CREATE:
                    return self.is_self(u)
                return self.is_self(u) or self.admin

            if n == 4 and segs[2] == "trips":
                u, t = segs[1], segs[3]
                if op == READ:
                    return (
                        await self.can_read_trip(u, t)
                        or self.admin
                        or bool(existing and existing.get("shareLinkEnabled") is True)
                    )
                if op == CREATE:
                    return self.is_self(u)
                if op == UPDATE:
                    return self.is_self(u) or self.admin or await self.is_shared_with(u, t)
                return self.is_self(u) or self.admin

            if n == 6 and segs[2] == "trips" and segs[4] in ("messages", "packing", "expenses"):
                u, t, sub = segs[1], segs[3], segs[4]
                if op == READ:
                    return await self.can_read_trip(u, t) or self.admin
                if not await self.can_read_trip(u, t):
                    return False
                if sub == "messages":
                    return (
                        op == CREATE
                        and final is not None
                        and final.get("senderUid") == uid
                        and _s(final.get("text"), 2000)
                        and is_ts(final.get("createdAt"))
                    )
                if sub == "packing":
                    if op == DELETE:
                        return True
                    return final is not None and _s(final.get("name"), 200) and is_ts(final.get("createdAt"))
                # expenses
                if op == DELETE:
                    return True
                if final is None:
                    return False
                ok = (
                    _s(final.get("title"), 200)
                    and _num(final.get("amount"))
                    and final["amount"] > 0
                    and ("paidByUid" not in final or _s(final.get("paidByUid"), 128))
                    and ("category" not in final or _s(final.get("category"), 64))
                    and final.get("splitMode") in ("group", "personal")
                    and is_ts(final.get("createdAt"))
                    and _s(final.get("createdByUid"), 128)
                )
                if op == CREATE:
                    return bool(ok and final.get("createdByUid") == uid)
                return bool(
                    ok
                    and existing is not None
                    and final.get("createdAt") == existing.get("createdAt")
                    and final.get("createdByUid") == existing.get("createdByUid")
                )

            if n == 4 and segs[2] == "sharedTrips":
                u, t = segs[1], segs[3]
                if self.is_self(u):
                    return True
                if op in (CREATE, UPDATE) and self.signed_in and final is not None:
                    return bool(
                        final.get("ownerUid") == uid
                        and final.get("tripRef") == f"users/{uid}/trips/{t}"
                        and _s(final.get("tripName"), 200)
                        and _s(final.get("ownerName"), 200)
                        and is_ts(final.get("createdAt"))
                        and (op == CREATE or (existing or {}).get("ownerUid") in (None, uid))
                    )
                return False

            if n == 4 and segs[2] == "friendRequests":
                return op != CREATE and self.is_self(segs[1])
            return False

        if c == "userEntitlements" and n == 2:
            return self.is_self(segs[1]) if op == READ else self.admin

        if c == "admins":
            if n == 2:
                return self.is_self(segs[1]) if op == READ else self.admin
            if n == 4 and segs[2] == "notes":
                return self.is_self(segs[1])
            return False

        if c == "verifiedTrips" and n == 2:
            return True if op == READ else self.admin

        if c == "publicUsers" and n == 2:
            return self.signed_in if op == READ else self.is_self(segs[1])

        if c == "tripJoinRequests" and n == 2:
            if not self.signed_in:
                return False
            if op == READ:
                return bool(existing and uid in (existing.get("ownerUid"), existing.get("requesterUid")))
            if op == CREATE:
                return bool(
                    final is not None
                    and final.get("requesterUid") == uid
                    and isinstance(final.get("tripRef"), str)
                    and TRIP_REF_RE.match(final["tripRef"])
                    and isinstance(final.get("ownerUid"), str)
                    and isinstance(final.get("tripId"), str)
                    and isinstance(final.get("requesterName"), str)
                    and final.get("status") == "pending"
                )
            if op == UPDATE:
                if not (existing and final is not None and uid == existing.get("ownerUid")):
                    return False
                changed = {k for k in set(existing) | set(final) if existing.get(k) != final.get(k)}
                return changed <= {"status", "handledAt"} and final.get("status") in ("pending", "approved", "denied")
            return False

        if c == "unlistedPages":
            if n == 2:
                return True if op == READ else self.admin
            if n == 4 and segs[2] == "responses":
                if op == CREATE:
                    return True
                return self.admin
            return False

        return False

    # ---- list (collection / collection-group) queries ------------------------
    async def list_scope(self, segs: tuple[str, ...] | None, group: str | None) -> tuple[str, list[Any]]:
        """Return an extra SQL predicate (using $-placeholders numbered from 1 within the fragment,
        renumbered by the caller) restricting a query to documents the actor may read.

        Raises Denied when the actor may not list the collection at all.
        """
        if group is not None:
            if group == "trips" and self.admin:
                return "TRUE", []
            raise Denied("Missing or insufficient permissions (collection group)")

        assert segs is not None
        n, c = len(segs), segs[0]

        if c == "users" and n == 1:
            if self.admin:
                return "TRUE", []
        elif c == "users" and n == 3 and segs[2] == "trips":
            if self.is_self(segs[1]) or self.admin:
                return "TRUE", []
        elif c == "users" and n == 5 and segs[2] == "trips" and segs[4] in ("messages", "packing", "expenses"):
            if await self.can_read_trip(segs[1], segs[3]) or self.admin:
                return "TRUE", []
        elif c == "users" and n == 3 and segs[2] in ("sharedTrips", "friendRequests"):
            if self.is_self(segs[1]):
                return "TRUE", []
        elif c == "admins" and n == 3 and segs[2] == "notes":
            if self.is_self(segs[1]):
                return "TRUE", []
        elif c in ("verifiedTrips", "unlistedPages") and n == 1:
            return "TRUE", []
        elif c == "unlistedPages" and n == 3 and segs[2] == "responses":
            if self.admin:
                return "TRUE", []
        elif c == "publicUsers" and n == 1:
            if self.signed_in:
                return "TRUE", []
        elif c == "tripJoinRequests" and n == 1:
            if self.signed_in:
                return "(data->>'ownerUid' = $1 OR data->>'requesterUid' = $1)", [self.uid]
        raise Denied("Missing or insufficient permissions (list)")
