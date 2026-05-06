#!/usr/bin/env python3
"""Migrate Firestore data to Cloud SQL PostgreSQL.

Dependencies:
  pip install firebase-admin psycopg2-binary

Environment:
  FIREBASE_PROJECT_ID=trypr-5ee47
  PGHOST=<cloud-sql-ip-or-host>
  PGPORT=5432
  PGDATABASE=postgres
  PGUSER=postgres
  PGPASSWORD=<password>
  BATCH_SIZE=500

Notes:
  1) Apply migration/sql/schema.sql before running this script.
  2) This script is idempotent via ON CONFLICT upserts.
"""

from __future__ import annotations

import base64
import json
import os
from collections import defaultdict
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any, Dict, Iterable, List, Optional, Tuple

import firebase_admin
import psycopg2
from firebase_admin import credentials, firestore
from psycopg2.extras import Json, execute_values


ASSIGNMENT_STATUS = {"pending", "accepted", "declined", "expired"}


def to_utc_timestamp(value: Any) -> Optional[datetime]:
    if value is None:
        return None
    if isinstance(value, datetime):
        if value.tzinfo is None:
            return value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc)
    return None


def sanitize_firestore_value(value: Any) -> Any:
    if isinstance(value, datetime):
        return to_utc_timestamp(value)

    if isinstance(value, Decimal):
        return value

    if isinstance(value, (str, int, float, bool)) or value is None:
        return value

    if isinstance(value, bytes):
        return base64.b64encode(value).decode("ascii")

    # Firestore GeoPoint-like object
    if hasattr(value, "latitude") and hasattr(value, "longitude"):
        return {"latitude": float(value.latitude), "longitude": float(value.longitude)}

    # Firestore DocumentReference-like object
    if hasattr(value, "path") and hasattr(value, "id"):
        try:
            return str(value.path)
        except Exception:  # pragma: no cover - safety for unexpected SDK types
            return str(value)

    if isinstance(value, dict):
        return {str(k): sanitize_firestore_value(v) for k, v in value.items()}

    if isinstance(value, (list, tuple, set)):
        return [sanitize_firestore_value(v) for v in value]

    return str(value)


def normalize_doc(doc: Dict[str, Any]) -> Dict[str, Any]:
    return sanitize_firestore_value(doc if doc else {})


def pick_first(doc: Dict[str, Any], *keys: str) -> Any:
    for key in keys:
        if key in doc and doc[key] is not None:
            return doc[key]
    return None


def as_bool(doc: Dict[str, Any], *keys: str, default: bool = False) -> bool:
    val = pick_first(doc, *keys)
    if isinstance(val, bool):
        return val
    if isinstance(val, str):
        lowered = val.strip().lower()
        if lowered in {"true", "1", "yes", "y"}:
            return True
        if lowered in {"false", "0", "no", "n"}:
            return False
    if isinstance(val, (int, float)):
        return bool(val)
    return default


def as_text(doc: Dict[str, Any], *keys: str) -> Optional[str]:
    val = pick_first(doc, *keys)
    if val is None:
        return None
    return str(val)


def as_ts(doc: Dict[str, Any], *keys: str) -> Optional[datetime]:
    return to_utc_timestamp(pick_first(doc, *keys))


def as_numeric(doc: Dict[str, Any], *keys: str) -> Optional[Decimal]:
    val = pick_first(doc, *keys)
    if val is None:
        return None
    try:
        return Decimal(str(val))
    except Exception:
        return None


TABLES: Dict[str, Dict[str, Any]] = {
    "trypr.users": {
        "columns": [
            "uid",
            "email",
            "display_name",
            "photo_url",
            "subscription",
            "subscription_status",
            "subscription_type",
            "stripe_customer_id",
            "current_period_end",
            "created_at",
            "updated_at",
            "raw_data",
        ],
        "conflict": "(uid)",
    },
    "trypr.public_users": {
        "columns": ["uid", "display_name", "photo_url", "updated_at", "raw_data"],
        "conflict": "(uid)",
    },
    "trypr.admins": {
        "columns": ["uid", "created_at", "updated_at", "raw_data"],
        "conflict": "(uid)",
    },
    "trypr.user_entitlements": {
        "columns": [
            "uid",
            "subscription",
            "subscription_status",
            "subscription_type",
            "premium_source",
            "premium_plan",
            "stripe_customer_id",
            "stripe_subscription_id",
            "stripe_price_id",
            "current_period_end",
            "created_at",
            "updated_at",
            "raw_data",
        ],
        "conflict": "(uid)",
    },
    "trypr.trips": {
        "columns": [
            "owner_uid",
            "trip_id",
            "trip_name",
            "destination_name",
            "start_date",
            "end_date",
            "is_verified",
            "share_link_enabled",
            "itinerary_data",
            "created_at",
            "updated_at",
            "raw_data",
        ],
        "conflict": "(owner_uid, trip_id)",
    },
    "trypr.trip_shared_users": {
        "columns": [
            "shared_entry_id",
            "owner_uid",
            "trip_id",
            "shared_uid",
            "shared_email",
            "created_at",
            "raw_data",
        ],
        "conflict": "(shared_entry_id)",
    },
    "trypr.trip_share_inbox": {
        "columns": [
            "recipient_uid",
            "trip_id",
            "owner_uid",
            "trip_ref",
            "trip_name",
            "owner_name",
            "created_at",
            "raw_data",
        ],
        "conflict": "(recipient_uid, trip_id)",
    },
    "trypr.trip_join_requests": {
        "columns": [
            "request_id",
            "owner_uid",
            "requester_uid",
            "requester_name",
            "trip_id",
            "trip_ref",
            "status",
            "created_at",
            "handled_at",
            "raw_data",
        ],
        "conflict": "(request_id)",
    },
    "trypr.friend_requests": {
        "columns": [
            "owner_uid",
            "request_id",
            "from_uid",
            "from_name",
            "status",
            "created_at",
            "handled_at",
            "raw_data",
        ],
        "conflict": "(owner_uid, request_id)",
    },
    "trypr.trip_messages": {
        "columns": [
            "owner_uid",
            "trip_id",
            "message_id",
            "sender_uid",
            "text",
            "created_at",
            "raw_data",
        ],
        "conflict": "(owner_uid, trip_id, message_id)",
    },
    "trypr.trip_packing_items": {
        "columns": [
            "owner_uid",
            "trip_id",
            "item_id",
            "name",
            "packed",
            "created_at",
            "raw_data",
        ],
        "conflict": "(owner_uid, trip_id, item_id)",
    },
    "trypr.trip_expenses": {
        "columns": [
            "owner_uid",
            "trip_id",
            "expense_id",
            "title",
            "amount",
            "paid_by_uid",
            "category",
            "split_mode",
            "created_by_uid",
            "created_at",
            "updated_at",
            "raw_data",
        ],
        "conflict": "(owner_uid, trip_id, expense_id)",
    },
    "trypr.verified_trips": {
        "columns": [
            "trip_id",
            "source_owner_uid",
            "source_trip_id",
            "title",
            "created_at",
            "updated_at",
            "raw_data",
        ],
        "conflict": "(trip_id)",
    },
    "trypr.admin_notes": {
        "columns": [
            "admin_uid",
            "note_id",
            "note_text",
            "created_at",
            "updated_at",
            "raw_data",
        ],
        "conflict": "(admin_uid, note_id)",
    },
    "trypr.unlisted_pages": {
        "columns": [
            "page_slug",
            "title",
            "status",
            "created_at",
            "updated_at",
            "raw_data",
        ],
        "conflict": "(page_slug)",
    },
    "trypr.unlisted_page_responses": {
        "columns": [
            "page_slug",
            "response_id",
            "submitted_at",
            "created_at",
            "raw_data",
        ],
        "conflict": "(page_slug, response_id)",
    },
    "ref_portal.associations": {
        "columns": [
            "association_id",
            "name",
            "status",
            "created_at",
            "updated_at",
            "raw_data",
        ],
        "conflict": "(association_id)",
    },
    "ref_portal.users": {
        "columns": [
            "user_id",
            "association_id",
            "email",
            "display_name",
            "role",
            "created_at",
            "updated_at",
            "raw_data",
        ],
        "conflict": "(user_id)",
    },
    "ref_portal.games": {
        "columns": [
            "game_id",
            "association_id",
            "game_date",
            "location",
            "division",
            "created_at",
            "updated_at",
            "raw_data",
        ],
        "conflict": "(game_id)",
    },
    "ref_portal.assignments": {
        "columns": [
            "assignment_id",
            "game_id",
            "referee_uid",
            "status",
            "expires_at",
            "assigned_at",
            "responded_at",
            "created_at",
            "updated_at",
            "raw_data",
        ],
        "conflict": "(assignment_id)",
    },
    "ref_portal.availability": {
        "columns": [
            "availability_id",
            "referee_uid",
            "starts_at",
            "ends_at",
            "status",
            "created_at",
            "updated_at",
            "raw_data",
        ],
        "conflict": "(availability_id)",
    },
    "ref_portal.pickup_requests": {
        "columns": [
            "pickup_request_id",
            "assignment_id",
            "requester_uid",
            "status",
            "created_at",
            "updated_at",
            "raw_data",
        ],
        "conflict": "(pickup_request_id)",
    },
    "ref_portal.mail": {
        "columns": [
            "mail_id",
            "recipient_email",
            "subject",
            "sent_at",
            "created_at",
            "raw_data",
        ],
        "conflict": "(mail_id)",
    },
}


class BatchInserter:
    def __init__(self, conn, batch_size: int = 500):
        self.conn = conn
        self.batch_size = batch_size
        self.buffers: Dict[str, List[Tuple[Any, ...]]] = defaultdict(list)

    def add(self, table_key: str, row: Tuple[Any, ...]) -> None:
        self.buffers[table_key].append(row)
        if len(self.buffers[table_key]) >= self.batch_size:
            self.flush(table_key)

    def flush(self, table_key: str) -> None:
        rows = self.buffers.get(table_key)
        if not rows:
            return

        cfg = TABLES[table_key]
        columns = cfg["columns"]
        col_sql = ", ".join(columns)
        update_cols = [c for c in columns if c not in cfg["conflict"].strip("()").replace(" ", "").split(",")]
        update_sql = ", ".join([f"{c}=EXCLUDED.{c}" for c in update_cols])

        sql = (
            f"INSERT INTO {table_key} ({col_sql}) VALUES %s "
            f"ON CONFLICT {cfg['conflict']} DO UPDATE SET {update_sql}"
        )

        with self.conn.cursor() as cur:
            execute_values(cur, sql, rows, page_size=self.batch_size)
        self.buffers[table_key].clear()

    def flush_all(self) -> None:
        for key in list(self.buffers.keys()):
            self.flush(key)


def ensure_firebase() -> firestore.Client:
    project_id = os.getenv("FIREBASE_PROJECT_ID", "trypr-5ee47")

    if not firebase_admin._apps:
        firebase_admin.initialize_app(
            credentials.ApplicationDefault(),
            {"projectId": project_id},
        )

    return firestore.client()


def build_pg_conn():
    dsn = os.getenv("PG_DSN")
    if dsn:
        return psycopg2.connect(dsn)

    return psycopg2.connect(
        host=os.getenv("PGHOST", "127.0.0.1"),
        port=int(os.getenv("PGPORT", "5432")),
        dbname=os.getenv("PGDATABASE", "postgres"),
        user=os.getenv("PGUSER", "postgres"),
        password=os.getenv("PGPASSWORD", ""),
        sslmode=os.getenv("PGSSLMODE", "prefer"),
    )


def _json_default(value: Any) -> Any:
    if isinstance(value, datetime):
        return to_utc_timestamp(value).isoformat()
    if isinstance(value, Decimal):
        return str(value)
    return str(value)


def j(value: Dict[str, Any]) -> Json:
    return Json(value, dumps=lambda obj: json.dumps(obj, default=_json_default))


def normalized_status(value: Any) -> str:
    s = str(value or "pending").strip().lower()
    if s in ASSIGNMENT_STATUS:
        return s
    return "pending"


def migrate_firestore_to_postgres() -> None:
    batch_size = int(os.getenv("BATCH_SIZE", "500"))
    fs = ensure_firebase()
    conn = build_pg_conn()
    conn.autocommit = False

    inserter = BatchInserter(conn=conn, batch_size=batch_size)
    source_counts: Dict[str, int] = defaultdict(int)

    try:
        # users + nested collections
        for user_doc in fs.collection("users").stream():
            uid = user_doc.id
            user_data = normalize_doc(user_doc.to_dict() or {})
            source_counts["users"] += 1

            inserter.add(
                "trypr.users",
                (
                    uid,
                    as_text(user_data, "email"),
                    as_text(user_data, "displayName", "display_name", "name"),
                    as_text(user_data, "photoURL", "photo_url"),
                    as_text(user_data, "subscription"),
                    as_text(user_data, "subscriptionStatus", "subscription_status"),
                    as_text(user_data, "subscriptionType", "subscription_type"),
                    as_text(user_data, "stripeCustomerId", "stripe_customer_id"),
                    as_ts(user_data, "currentPeriodEnd", "current_period_end"),
                    as_ts(user_data, "createdAt", "created_at"),
                    as_ts(user_data, "updatedAt", "updated_at"),
                    j(user_data),
                ),
            )

            # users/{uid}/trips
            trips_ref = fs.collection("users").document(uid).collection("trips")
            for trip_doc in trips_ref.stream():
                trip_id = trip_doc.id
                trip_data = normalize_doc(trip_doc.to_dict() or {})
                source_counts["users.trips"] += 1

                itinerary_data = pick_first(trip_data, "itinerary_data", "itineraryData", "itinerary")
                if itinerary_data is None:
                    itinerary_data = {}

                inserter.add(
                    "trypr.trips",
                    (
                        uid,
                        trip_id,
                        as_text(trip_data, "tripName", "name", "title"),
                        as_text(trip_data, "destinationName", "destination", "locationName"),
                        as_ts(trip_data, "startDate", "start_date"),
                        as_ts(trip_data, "endDate", "end_date"),
                        as_bool(trip_data, "isVerified", "verified", "is_verified", default=False),
                        as_bool(trip_data, "shareLinkEnabled", "share_link_enabled", default=False),
                        j(itinerary_data if isinstance(itinerary_data, (dict, list)) else {}),
                        as_ts(trip_data, "createdAt", "created_at"),
                        as_ts(trip_data, "updatedAt", "updated_at"),
                        j(trip_data),
                    ),
                )

                # Derive shared users from arrays in trip document.
                shared_with = pick_first(trip_data, "sharedWith")
                shared_with_emails = pick_first(trip_data, "sharedWithEmails")

                uid_candidates: List[str] = []
                email_candidates: List[str] = []

                if isinstance(shared_with, list):
                    for val in shared_with:
                        sval = str(val)
                        if "@" in sval:
                            email_candidates.append(sval)
                        else:
                            uid_candidates.append(sval)

                if isinstance(shared_with_emails, list):
                    for val in shared_with_emails:
                        sval = str(val)
                        if "@" in sval:
                            email_candidates.append(sval)

                dedup_seen = set()
                for idx, shared_uid in enumerate(uid_candidates):
                    key = f"uid:{shared_uid}"
                    if key in dedup_seen:
                        continue
                    dedup_seen.add(key)
                    shared_entry_id = f"{uid}:{trip_id}:uid:{shared_uid}"
                    inserter.add(
                        "trypr.trip_shared_users",
                        (
                            shared_entry_id,
                            uid,
                            trip_id,
                            shared_uid,
                            None,
                            as_ts(trip_data, "updatedAt", "updated_at", "createdAt", "created_at"),
                            Json({"source": "trip.sharedWith", "value": shared_uid}),
                        ),
                    )

                for idx, shared_email in enumerate(email_candidates):
                    key = f"email:{shared_email.lower()}"
                    if key in dedup_seen:
                        continue
                    dedup_seen.add(key)
                    shared_entry_id = f"{uid}:{trip_id}:email:{shared_email.lower()}"
                    inserter.add(
                        "trypr.trip_shared_users",
                        (
                            shared_entry_id,
                            uid,
                            trip_id,
                            None,
                            shared_email,
                            as_ts(trip_data, "updatedAt", "updated_at", "createdAt", "created_at"),
                            Json({"source": "trip.sharedWithEmails", "value": shared_email}),
                        ),
                    )

                # users/{uid}/trips/{tripId}/messages
                for msg_doc in trips_ref.document(trip_id).collection("messages").stream():
                    msg_data = normalize_doc(msg_doc.to_dict() or {})
                    source_counts["users.trips.messages"] += 1
                    inserter.add(
                        "trypr.trip_messages",
                        (
                            uid,
                            trip_id,
                            msg_doc.id,
                            as_text(msg_data, "senderUid", "sender_uid"),
                            as_text(msg_data, "text", "message"),
                            as_ts(msg_data, "createdAt", "created_at"),
                            j(msg_data),
                        ),
                    )

                # users/{uid}/trips/{tripId}/packing
                for item_doc in trips_ref.document(trip_id).collection("packing").stream():
                    item_data = normalize_doc(item_doc.to_dict() or {})
                    source_counts["users.trips.packing"] += 1
                    inserter.add(
                        "trypr.trip_packing_items",
                        (
                            uid,
                            trip_id,
                            item_doc.id,
                            as_text(item_data, "name", "item"),
                            as_bool(item_data, "packed", "isPacked", default=False),
                            as_ts(item_data, "createdAt", "created_at"),
                            j(item_data),
                        ),
                    )

                # users/{uid}/trips/{tripId}/expenses
                for exp_doc in trips_ref.document(trip_id).collection("expenses").stream():
                    exp_data = normalize_doc(exp_doc.to_dict() or {})
                    source_counts["users.trips.expenses"] += 1
                    inserter.add(
                        "trypr.trip_expenses",
                        (
                            uid,
                            trip_id,
                            exp_doc.id,
                            as_text(exp_data, "title", "name"),
                            as_numeric(exp_data, "amount", "value"),
                            as_text(exp_data, "paidByUid", "paid_by_uid"),
                            as_text(exp_data, "category"),
                            as_text(exp_data, "splitMode", "split_mode"),
                            as_text(exp_data, "createdByUid", "created_by_uid"),
                            as_ts(exp_data, "createdAt", "created_at"),
                            as_ts(exp_data, "updatedAt", "updated_at"),
                            j(exp_data),
                        ),
                    )

            # users/{uid}/sharedTrips
            for shared_doc in fs.collection("users").document(uid).collection("sharedTrips").stream():
                shared_data = normalize_doc(shared_doc.to_dict() or {})
                source_counts["users.sharedTrips"] += 1
                inserter.add(
                    "trypr.trip_share_inbox",
                    (
                        uid,
                        shared_doc.id,
                        as_text(shared_data, "ownerUid", "owner_uid"),
                        as_text(shared_data, "tripRef", "trip_ref"),
                        as_text(shared_data, "tripName", "trip_name", "name"),
                        as_text(shared_data, "ownerName", "owner_name"),
                        as_ts(shared_data, "createdAt", "created_at"),
                        j(shared_data),
                    ),
                )

            # users/{uid}/friendRequests
            for fr_doc in fs.collection("users").document(uid).collection("friendRequests").stream():
                fr_data = normalize_doc(fr_doc.to_dict() or {})
                source_counts["users.friendRequests"] += 1
                inserter.add(
                    "trypr.friend_requests",
                    (
                        uid,
                        fr_doc.id,
                        as_text(fr_data, "fromUid", "from_uid", "requesterUid"),
                        as_text(fr_data, "fromName", "from_name", "requesterName"),
                        as_text(fr_data, "status"),
                        as_ts(fr_data, "createdAt", "created_at"),
                        as_ts(fr_data, "handledAt", "handled_at"),
                        j(fr_data),
                    ),
                )

        # admins + admins/{uid}/notes
        for admin_doc in fs.collection("admins").stream():
            admin_uid = admin_doc.id
            admin_data = normalize_doc(admin_doc.to_dict() or {})
            source_counts["admins"] += 1

            inserter.add(
                "trypr.admins",
                (
                    admin_uid,
                    as_ts(admin_data, "createdAt", "created_at"),
                    as_ts(admin_data, "updatedAt", "updated_at"),
                    j(admin_data),
                ),
            )

            for note_doc in fs.collection("admins").document(admin_uid).collection("notes").stream():
                note_data = normalize_doc(note_doc.to_dict() or {})
                source_counts["admins.notes"] += 1
                inserter.add(
                    "trypr.admin_notes",
                    (
                        admin_uid,
                        note_doc.id,
                        as_text(note_data, "note", "text", "content"),
                        as_ts(note_data, "createdAt", "created_at"),
                        as_ts(note_data, "updatedAt", "updated_at"),
                        j(note_data),
                    ),
                )

        # top-level simple collections in trypr schema
        top_level_trypr = [
            ("userEntitlements", "trypr.user_entitlements"),
            ("publicUsers", "trypr.public_users"),
            ("verifiedTrips", "trypr.verified_trips"),
            ("tripJoinRequests", "trypr.trip_join_requests"),
            ("unlistedPages", "trypr.unlisted_pages"),
        ]

        for collection_name, table_key in top_level_trypr:
            for doc in fs.collection(collection_name).stream():
                data = normalize_doc(doc.to_dict() or {})
                source_counts[collection_name] += 1

                if table_key == "trypr.user_entitlements":
                    inserter.add(
                        table_key,
                        (
                            doc.id,
                            as_text(data, "subscription"),
                            as_text(data, "subscriptionStatus", "subscription_status"),
                            as_text(data, "subscriptionType", "subscription_type"),
                            as_text(data, "premiumSource", "premium_source"),
                            as_text(data, "premiumPlan", "premium_plan"),
                            as_text(data, "stripeCustomerId", "stripe_customer_id"),
                            as_text(data, "stripeSubscriptionId", "stripe_subscription_id"),
                            as_text(data, "stripePriceId", "stripe_price_id"),
                            as_ts(data, "currentPeriodEnd", "current_period_end"),
                            as_ts(data, "createdAt", "created_at"),
                            as_ts(data, "updatedAt", "updated_at"),
                            j(data),
                        ),
                    )
                elif table_key == "trypr.public_users":
                    inserter.add(
                        table_key,
                        (
                            doc.id,
                            as_text(data, "displayName", "display_name", "name"),
                            as_text(data, "photoURL", "photo_url"),
                            as_ts(data, "updatedAt", "updated_at"),
                            j(data),
                        ),
                    )
                elif table_key == "trypr.verified_trips":
                    inserter.add(
                        table_key,
                        (
                            doc.id,
                            as_text(data, "ownerUid", "sourceOwnerUid", "source_owner_uid"),
                            as_text(data, "tripId", "sourceTripId", "source_trip_id"),
                            as_text(data, "title", "name", "tripName"),
                            as_ts(data, "createdAt", "created_at"),
                            as_ts(data, "updatedAt", "updated_at"),
                            j(data),
                        ),
                    )
                elif table_key == "trypr.trip_join_requests":
                    inserter.add(
                        table_key,
                        (
                            doc.id,
                            as_text(data, "ownerUid", "owner_uid"),
                            as_text(data, "requesterUid", "requester_uid"),
                            as_text(data, "requesterName", "requester_name"),
                            as_text(data, "tripId", "trip_id"),
                            as_text(data, "tripRef", "trip_ref"),
                            as_text(data, "status"),
                            as_ts(data, "createdAt", "created_at"),
                            as_ts(data, "handledAt", "handled_at"),
                            j(data),
                        ),
                    )
                elif table_key == "trypr.unlisted_pages":
                    inserter.add(
                        table_key,
                        (
                            doc.id,
                            as_text(data, "title", "name"),
                            as_text(data, "status"),
                            as_ts(data, "createdAt", "created_at"),
                            as_ts(data, "updatedAt", "updated_at"),
                            j(data),
                        ),
                    )

                    for response_doc in fs.collection("unlistedPages").document(doc.id).collection("responses").stream():
                        response_data = normalize_doc(response_doc.to_dict() or {})
                        source_counts["unlistedPages.responses"] += 1
                        inserter.add(
                            "trypr.unlisted_page_responses",
                            (
                                doc.id,
                                response_doc.id,
                                as_ts(response_data, "submittedAt", "submitted_at"),
                                as_ts(response_data, "createdAt", "created_at"),
                                j(response_data),
                            ),
                        )

        # ref portal top-level collections
        known_ref_user_ids = set()
        known_ref_game_ids = set()
        known_ref_assignment_ids = set()

        ref_portal_collections = [
            ("refAssigner_associations", "ref_portal.associations"),
            ("refAssigner_users", "ref_portal.users"),
            ("refAssigner_games", "ref_portal.games"),
            ("refAssigner_assignments", "ref_portal.assignments"),
            ("refAssigner_availability", "ref_portal.availability"),
            ("refAssigner_pickupRequests", "ref_portal.pickup_requests"),
            ("refAssigner_mail", "ref_portal.mail"),
        ]

        for collection_name, table_key in ref_portal_collections:
            for doc in fs.collection(collection_name).stream():
                data = normalize_doc(doc.to_dict() or {})
                source_counts[collection_name] += 1

                if table_key == "ref_portal.associations":
                    inserter.add(
                        table_key,
                        (
                            doc.id,
                            as_text(data, "name"),
                            as_text(data, "status"),
                            as_ts(data, "createdAt", "created_at"),
                            as_ts(data, "updatedAt", "updated_at"),
                            j(data),
                        ),
                    )
                elif table_key == "ref_portal.users":
                    known_ref_user_ids.add(doc.id)
                    inserter.add(
                        table_key,
                        (
                            doc.id,
                            as_text(data, "associationId", "association_id"),
                            as_text(data, "email"),
                            as_text(data, "displayName", "display_name", "name"),
                            as_text(data, "role"),
                            as_ts(data, "createdAt", "created_at"),
                            as_ts(data, "updatedAt", "updated_at"),
                            j(data),
                        ),
                    )
                elif table_key == "ref_portal.games":
                    known_ref_game_ids.add(doc.id)
                    inserter.add(
                        table_key,
                        (
                            doc.id,
                            as_text(data, "associationId", "association_id"),
                            as_ts(data, "gameDate", "game_date", "startsAt", "start_at"),
                            as_text(data, "location", "venue"),
                            as_text(data, "division"),
                            as_ts(data, "createdAt", "created_at"),
                            as_ts(data, "updatedAt", "updated_at"),
                            j(data),
                        ),
                    )
                elif table_key == "ref_portal.assignments":
                    known_ref_assignment_ids.add(doc.id)
                    game_id = as_text(data, "gameId", "game_id")
                    referee_uid = as_text(data, "refereeUid", "userId", "referee_uid")
                    inserter.add(
                        table_key,
                        (
                            doc.id,
                            game_id if game_id in known_ref_game_ids else None,
                            referee_uid if referee_uid in known_ref_user_ids else None,
                            normalized_status(pick_first(data, "status")),
                            as_ts(data, "expiresAt", "expires_at"),
                            as_ts(data, "assignedAt", "assigned_at"),
                            as_ts(data, "respondedAt", "responded_at"),
                            as_ts(data, "createdAt", "created_at"),
                            as_ts(data, "updatedAt", "updated_at"),
                            j(data),
                        ),
                    )
                elif table_key == "ref_portal.availability":
                    referee_uid = as_text(data, "refereeUid", "userId", "referee_uid")
                    inserter.add(
                        table_key,
                        (
                            doc.id,
                            referee_uid if referee_uid in known_ref_user_ids else None,
                            as_ts(data, "startsAt", "startAt", "starts_at"),
                            as_ts(data, "endsAt", "endAt", "ends_at"),
                            as_text(data, "status"),
                            as_ts(data, "createdAt", "created_at"),
                            as_ts(data, "updatedAt", "updated_at"),
                            j(data),
                        ),
                    )
                elif table_key == "ref_portal.pickup_requests":
                    assignment_id = as_text(data, "assignmentId", "assignment_id")
                    requester_uid = as_text(data, "requesterUid", "userId", "requester_uid")
                    inserter.add(
                        table_key,
                        (
                            doc.id,
                            assignment_id if assignment_id in known_ref_assignment_ids else None,
                            requester_uid if requester_uid in known_ref_user_ids else None,
                            as_text(data, "status"),
                            as_ts(data, "createdAt", "created_at"),
                            as_ts(data, "updatedAt", "updated_at"),
                            j(data),
                        ),
                    )
                elif table_key == "ref_portal.mail":
                    inserter.add(
                        table_key,
                        (
                            doc.id,
                            as_text(data, "to", "recipient", "recipientEmail", "recipient_email"),
                            as_text(data, "subject"),
                            as_ts(data, "sentAt", "sent_at"),
                            as_ts(data, "createdAt", "created_at"),
                            j(data),
                        ),
                    )

        inserter.flush_all()

        # Replace source count baseline used by validation SQL.
        with conn.cursor() as cur:
            cur.execute("TRUNCATE TABLE trypr.firestore_collection_counts")
            rows = [(name, count) for name, count in sorted(source_counts.items())]
            execute_values(
                cur,
                """
                INSERT INTO trypr.firestore_collection_counts (collection_name, doc_count)
                VALUES %s
                ON CONFLICT (collection_name)
                DO UPDATE SET
                  doc_count = EXCLUDED.doc_count,
                  captured_at = NOW()
                """,
                rows,
            )

        conn.commit()

        print("Migration completed successfully.")
        print("Captured Firestore source counts:")
        for name, count in sorted(source_counts.items()):
            print(f"  {name}: {count}")

    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    migrate_firestore_to_postgres()
