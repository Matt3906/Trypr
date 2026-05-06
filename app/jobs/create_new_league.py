from __future__ import annotations

import argparse
import asyncio
from datetime import datetime, timezone

from sqlalchemy import select

from app.core.database import AsyncSessionLocal
from app.models.db_models import RefPortalAssociation, RefPortalUser


async def create_new_league(
    *,
    association_id: str,
    association_name: str,
    admin_uid: str,
    admin_email: str,
    admin_display_name: str,
) -> None:
    now = datetime.now(timezone.utc)

    async with AsyncSessionLocal() as db:
        association = await db.scalar(
            select(RefPortalAssociation).where(RefPortalAssociation.association_id == association_id)
        )
        if association:
            association.name = association_name
            association.status = association.status or "active"
            association.updated_at = now
            raw = association.raw_data or {}
            raw.setdefault("onboarded_via", "create_new_league.py")
            association.raw_data = raw
        else:
            db.add(
                RefPortalAssociation(
                    association_id=association_id,
                    name=association_name,
                    status="active",
                    created_at=now,
                    updated_at=now,
                    raw_data={"onboarded_via": "create_new_league.py"},
                )
            )

        admin_user = await db.scalar(select(RefPortalUser).where(RefPortalUser.user_id == admin_uid))
        if admin_user:
            admin_user.association_id = association_id
            admin_user.email = admin_email
            admin_user.display_name = admin_display_name
            admin_user.role = "admin"
            admin_user.updated_at = now
            raw = admin_user.raw_data or {}
            raw.setdefault("onboarded_via", "create_new_league.py")
            admin_user.raw_data = raw
        else:
            db.add(
                RefPortalUser(
                    user_id=admin_uid,
                    association_id=association_id,
                    email=admin_email,
                    display_name=admin_display_name,
                    role="admin",
                    created_at=now,
                    updated_at=now,
                    raw_data={"onboarded_via": "create_new_league.py"},
                )
            )

        await db.commit()


async def _main() -> None:
    parser = argparse.ArgumentParser(description="Create a new ref_portal league and admin user")
    parser.add_argument("--association-id", required=True)
    parser.add_argument("--association-name", required=True)
    parser.add_argument("--admin-uid", required=True)
    parser.add_argument("--admin-email", required=True)
    parser.add_argument("--admin-display-name", default="League Admin")
    args = parser.parse_args()

    await create_new_league(
        association_id=args.association_id,
        association_name=args.association_name,
        admin_uid=args.admin_uid,
        admin_email=args.admin_email,
        admin_display_name=args.admin_display_name,
    )
    print(
        f"Created/updated league {args.association_id} ({args.association_name}) with admin {args.admin_uid}"
    )


if __name__ == "__main__":
    asyncio.run(_main())
