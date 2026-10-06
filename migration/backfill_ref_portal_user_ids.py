#!/usr/bin/env python3
"""Backfill ref_portal.users.user_id to match the Firebase UID.

Before the invite flow was reworked, ref_portal.users.user_id was generated
with uuid4() at invite time, while authenticated requests resolve a profile via
`user_id == firebase_uid`. Any user whose user_id is a stray uuid4 (rather than
their Firebase UID) shows up as "no profile" after they log in, which breaks
the new onboarding redirect and most ref-portal authorization checks.

This script walks every RefPortalUser row, looks up the email in Firebase Auth,
and if there's a Firebase user whose UID differs from the stored user_id, it
re-points the row (and every FK reference) at the Firebase UID. Idempotent and
safe to re-run.

Dependencies:
  pip install firebase-admin psycopg2-binary

Environment:
  FIREBASE_PROJECT_ID=trypr-5ee47
  GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json
  PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD
  DRY_RUN=1   # set to skip writes; just print what would change
"""

from __future__ import annotations

import os
import sys
from typing import Iterable

import psycopg2
import psycopg2.extras

import firebase_admin
from firebase_admin import auth, credentials


def init_firebase() -> None:
    if firebase_admin._apps:
        return
    project_id = os.environ.get("FIREBASE_PROJECT_ID")
    cred_path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")
    if cred_path:
        firebase_admin.initialize_app(
            credentials.Certificate(cred_path),
            {"projectId": project_id} if project_id else None,
        )
    else:
        firebase_admin.initialize_app(options={"projectId": project_id} if project_id else None)


def fetch_users(conn) -> list[dict]:
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            "SELECT user_id, email FROM ref_portal.users WHERE email IS NOT NULL ORDER BY created_at"
        )
        return list(cur.fetchall())


def lookup_firebase_uid(email: str) -> str | None:
    try:
        return auth.get_user_by_email(email).uid
    except auth.UserNotFoundError:
        return None
    except Exception as exc:
        print(f"  ! Firebase lookup failed for {email}: {exc}", file=sys.stderr)
        return None


def repoint_user(conn, *, old_uid: str, new_uid: str, dry_run: bool) -> None:
    """Re-key the user row and every FK reference. Single transaction."""
    if dry_run:
        print(f"  [dry-run] would re-key {old_uid} -> {new_uid}")
        return

    with conn.cursor() as cur:
        # Insert a placeholder row keyed by new_uid that copies the old row's
        # data, then redirect FKs, then drop the old row. Done in one tx so a
        # crash mid-way doesn't orphan anything.
        cur.execute(
            """
            INSERT INTO ref_portal.users (
                user_id, association_id, email, display_name, role,
                created_at, updated_at, raw_data
            )
            SELECT %s, association_id, email, display_name, role,
                   created_at, updated_at, raw_data
            FROM ref_portal.users
            WHERE user_id = %s
            ON CONFLICT (user_id) DO NOTHING
            """,
            (new_uid, old_uid),
        )
        cur.execute(
            "UPDATE ref_portal.assignments SET referee_uid = %s WHERE referee_uid = %s",
            (new_uid, old_uid),
        )
        cur.execute(
            "UPDATE ref_portal.availability SET referee_uid = %s WHERE referee_uid = %s",
            (new_uid, old_uid),
        )
        cur.execute(
            "UPDATE ref_portal.pickup_requests SET requester_uid = %s WHERE requester_uid = %s",
            (new_uid, old_uid),
        )
        cur.execute("DELETE FROM ref_portal.users WHERE user_id = %s", (old_uid,))
    conn.commit()


def main() -> int:
    dry_run = os.environ.get("DRY_RUN") == "1"
    init_firebase()

    conn = psycopg2.connect(
        host=os.environ["PGHOST"],
        port=os.environ.get("PGPORT", "5432"),
        dbname=os.environ["PGDATABASE"],
        user=os.environ["PGUSER"],
        password=os.environ["PGPASSWORD"],
    )
    conn.autocommit = False

    examined = 0
    skipped_no_firebase = 0
    skipped_already_aligned = 0
    rekeyed = 0
    failures = 0

    try:
        users = fetch_users(conn)
        print(f"Found {len(users)} ref_portal.users rows.")
        for row in users:
            examined += 1
            old_uid = row["user_id"]
            email = (row["email"] or "").strip()
            if not email:
                continue
            firebase_uid = lookup_firebase_uid(email)
            if not firebase_uid:
                skipped_no_firebase += 1
                continue
            if firebase_uid == old_uid:
                skipped_already_aligned += 1
                continue
            print(f"Re-key {email}: {old_uid} -> {firebase_uid}")
            try:
                repoint_user(conn, old_uid=old_uid, new_uid=firebase_uid, dry_run=dry_run)
                rekeyed += 1
            except Exception as exc:
                conn.rollback()
                failures += 1
                print(f"  ! re-key failed for {email}: {exc}", file=sys.stderr)
    finally:
        conn.close()

    print()
    print("Summary:")
    print(f"  examined:              {examined}")
    print(f"  already aligned:       {skipped_already_aligned}")
    print(f"  no Firebase user:      {skipped_no_firebase}")
    print(f"  re-keyed:              {rekeyed}{' (dry-run)' if dry_run else ''}")
    print(f"  failures:              {failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
