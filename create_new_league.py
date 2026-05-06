#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio

from app.jobs.create_new_league import create_new_league


async def _main() -> None:
    parser = argparse.ArgumentParser(
        description="Create a new ref_portal association and bootstrap its Admin user"
    )
    parser.add_argument("--association-id", required=True)
    parser.add_argument("--association-name", required=True)
    parser.add_argument("--admin-uid", required=True)
    parser.add_argument("--admin-email", required=True)
    parser.add_argument("--admin-display-name", default="Admin")
    args = parser.parse_args()

    await create_new_league(
        association_id=args.association_id,
        association_name=args.association_name,
        admin_uid=args.admin_uid,
        admin_email=args.admin_email,
        admin_display_name=args.admin_display_name,
    )

    print(
        "League onboarding complete: "
        f"association={args.association_id}, admin={args.admin_uid}, email={args.admin_email}"
    )


if __name__ == "__main__":
    asyncio.run(_main())
