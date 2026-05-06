from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone

from fastapi import BackgroundTasks
from sqlalchemy import and_, text, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import AsyncSessionLocal
from app.models.db_models import RefPortalAssignment, RefPortalGame
from app.services.notifications import RefNotificationTemplate, send_ref_notification


async def expire_pending_assignments_once() -> int:
    now = datetime.now(timezone.utc)
    async with AsyncSessionLocal() as session:  # type: AsyncSession
        statement = (
            update(RefPortalAssignment)
            .where(
                and_(
                    RefPortalAssignment.status == text("'pending'::ref_portal.assignment_status"),
                    RefPortalAssignment.expires_at.is_not(None),
                    RefPortalAssignment.expires_at < now,
                )
            )
            .values(
                status=text("'expired'::ref_portal.assignment_status"),
                updated_at=now,
            )
        )
        result = await session.execute(statement)
        await session.commit()
        return int(result.rowcount or 0)


def _should_send(game_date: datetime | None, now: datetime, lead_hours: int) -> bool:
    if not game_date:
        return False
    target = game_date - timedelta(hours=lead_hours)
    return target <= now <= (target + timedelta(minutes=59))


async def send_upcoming_game_reminders_once() -> dict[str, int]:
    now = datetime.now(timezone.utc)
    sent_3d = 0
    sent_today = 0

    async with AsyncSessionLocal() as session:  # type: AsyncSession
        rows = await session.execute(
            text(
                """
                SELECT
                  a.assignment_id,
                  a.referee_uid,
                  a.game_id,
                  a.raw_data,
                  g.association_id,
                  g.game_date,
                  g.location,
                  g.division,
                  g.raw_data AS game_raw
                FROM ref_portal.assignments a
                JOIN ref_portal.games g ON g.game_id = a.game_id
                WHERE a.status = 'accepted'
                  AND g.game_date IS NOT NULL
                  AND g.game_date > :now
                  AND g.game_date <= :horizon
                """
            ),
            {
                "now": now,
                "horizon": now + timedelta(hours=73),
            },
        )

        for record in rows.mappings():
            assignment_id = record["assignment_id"]
            referee_uid = record["referee_uid"]
            game_id = record["game_id"]
            association_id = record["association_id"]
            game_date = record["game_date"]
            location = record["location"]
            game_raw = record["game_raw"] or {}
            assignment_raw = record["raw_data"] or {}

            if not referee_uid or not game_id or not game_date:
                continue

            background_tasks = BackgroundTasks()
            game_date_label = game_date.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

            if _should_send(game_date, now, lead_hours=72) and not assignment_raw.get("reminder_3d_sent_at"):
                await send_ref_notification(
                    background_tasks=background_tasks,
                    db=session,
                    recipient_uid=referee_uid,
                    template=RefNotificationTemplate.GAME_REMINDER_24H,
                    subject=f"Game Reminder (3 Days): {game_id}",
                    context={
                        "game_id": game_id,
                        "assignment_id": assignment_id,
                        "game_date": game_date_label,
                        "venue": location or game_raw.get("venue") or game_raw.get("arena"),
                    },
                    association_id=association_id,
                    game_id=game_id,
                    assignment_id=assignment_id,
                    actor_uid=None,
                )
                await background_tasks()
                assignment_raw["reminder_3d_sent_at"] = now.isoformat()
                sent_3d += 1

            if _should_send(game_date, now, lead_hours=6) and not assignment_raw.get("reminder_today_sent_at"):
                await send_ref_notification(
                    background_tasks=background_tasks,
                    db=session,
                    recipient_uid=referee_uid,
                    template=RefNotificationTemplate.GAME_REMINDER_6H,
                    subject=f"Assignment Today Reminder: {game_id}",
                    context={
                        "game_id": game_id,
                        "assignment_id": assignment_id,
                        "game_date": game_date_label,
                        "venue": location or game_raw.get("venue") or game_raw.get("arena"),
                    },
                    association_id=association_id,
                    game_id=game_id,
                    assignment_id=assignment_id,
                    actor_uid=None,
                )
                await background_tasks()
                assignment_raw["reminder_today_sent_at"] = now.isoformat()
                sent_today += 1

            await session.execute(
                update(RefPortalAssignment)
                .where(RefPortalAssignment.assignment_id == assignment_id)
                .values(raw_data=assignment_raw, updated_at=now)
            )

        await session.commit()

    return {"sent_3d": sent_3d, "sent_today": sent_today}


async def _main() -> None:
    count = await expire_pending_assignments_once()
    print(f"Expired assignments: {count}")
    reminders = await send_upcoming_game_reminders_once()
    print(f"Reminder emails sent: 3d={reminders['sent_3d']} today={reminders['sent_today']}")


if __name__ == "__main__":
    asyncio.run(_main())
