from __future__ import annotations

from datetime import datetime, timezone
from uuid import uuid4

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import and_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.database import get_db_session
from app.core.dependencies import get_current_principal, require_admin
from app.core.security import AuthenticatedPrincipal
from app.models.db_models import Trip, TripShareInbox, TripSharedUser, TryprUser, VerifiedTrip
from app.models.schemas import (
    APIMessage,
    TripCreateRequest,
    TripSchema,
    TripShareRequest,
    TripVerifiedUpdateRequest,
)


router = APIRouter(prefix="/trypr", tags=["trypr"])


@router.post("/trips", response_model=TripSchema, status_code=status.HTTP_201_CREATED)
async def create_trip(
    payload: TripCreateRequest,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> Trip:
    owner_uid = payload.owner_uid or principal.uid

    if owner_uid != principal.uid and not principal.is_admin:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Cannot create trip for another user")

    existing_user = await db.scalar(select(TryprUser.uid).where(TryprUser.uid == owner_uid))
    if not existing_user:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Trip owner does not exist")

    now = datetime.now(timezone.utc)
    trip = Trip(
        owner_uid=owner_uid,
        trip_id=str(uuid4()),
        trip_name=payload.trip_name,
        destination_name=payload.destination_name,
        start_date=payload.start_date,
        end_date=payload.end_date,
        itinerary_data=payload.itinerary_data,
        share_link_enabled=payload.share_link_enabled,
        is_verified=False,
        created_at=now,
        updated_at=now,
        raw_data=payload.raw_data,
    )

    db.add(trip)
    await db.commit()
    await db.refresh(trip)
    return trip


@router.post("/trips/{owner_uid}/{trip_id}/share", response_model=APIMessage)
async def share_trip(
    owner_uid: str,
    trip_id: str,
    payload: TripShareRequest,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> APIMessage:
    if principal.uid != owner_uid and not principal.is_admin:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only owner or admin can share")

    trip = await db.scalar(
        select(Trip).where(and_(Trip.owner_uid == owner_uid, Trip.trip_id == trip_id))
    )
    if not trip:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Trip not found")

    if not payload.recipient_uids and not payload.recipient_emails:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="At least one recipient uid or email is required",
        )

    owner_name = principal.email or principal.uid
    now = datetime.now(timezone.utc)

    for recipient_uid in payload.recipient_uids:
        inbox = await db.scalar(
            select(TripShareInbox).where(
                and_(
                    TripShareInbox.recipient_uid == recipient_uid,
                    TripShareInbox.trip_id == trip_id,
                )
            )
        )

        if not inbox:
            inbox = TripShareInbox(
                recipient_uid=recipient_uid,
                trip_id=trip_id,
                owner_uid=owner_uid,
                trip_ref=f"users/{owner_uid}/trips/{trip_id}",
                trip_name=trip.trip_name,
                owner_name=owner_name,
                raw_data={"source": "fastapi.share"},
            )
            db.add(inbox)

        shared_link = TripSharedUser(
            shared_entry_id=f"{owner_uid}:{trip_id}:uid:{recipient_uid}",
            owner_uid=owner_uid,
            trip_id=trip_id,
            shared_uid=recipient_uid,
            shared_email=None,
            raw_data={"source": "fastapi.share", "created_at": now.isoformat()},
        )
        db.merge(shared_link)

    for recipient_email in payload.recipient_emails:
        shared_link = TripSharedUser(
            shared_entry_id=f"{owner_uid}:{trip_id}:email:{recipient_email.lower()}",
            owner_uid=owner_uid,
            trip_id=trip_id,
            shared_uid=None,
            shared_email=recipient_email,
            raw_data={"source": "fastapi.share", "created_at": now.isoformat()},
        )
        db.merge(shared_link)

    trip.share_link_enabled = True
    trip.updated_at = now

    await db.commit()
    return APIMessage(message="Trip shared successfully")


@router.get("/trips/{owner_uid}/{trip_id}/verified-badge")
async def get_trip_verified_badge(
    owner_uid: str,
    trip_id: str,
    principal: AuthenticatedPrincipal = Depends(get_current_principal),
    db: AsyncSession = Depends(get_db_session),
) -> dict[str, bool]:
    if principal.uid != owner_uid and not principal.is_admin:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only owner or admin can view")

    trip = await db.scalar(
        select(Trip).where(and_(Trip.owner_uid == owner_uid, Trip.trip_id == trip_id))
    )
    if not trip:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Trip not found")

    if trip.is_verified:
        return {"is_verified": True}

    verified = await db.scalar(
        select(VerifiedTrip.trip_id).where(VerifiedTrip.trip_id == trip_id)
    )
    return {"is_verified": bool(verified)}


@router.patch("/trips/{owner_uid}/{trip_id}/verified", response_model=TripSchema)
async def set_trip_verified_status(
    owner_uid: str,
    trip_id: str,
    payload: TripVerifiedUpdateRequest,
    _: AuthenticatedPrincipal = Depends(require_admin),
    db: AsyncSession = Depends(get_db_session),
) -> Trip:
    trip = await db.scalar(
        select(Trip).where(and_(Trip.owner_uid == owner_uid, Trip.trip_id == trip_id))
    )
    if not trip:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Trip not found")

    trip.is_verified = payload.is_verified
    trip.updated_at = datetime.now(timezone.utc)

    if payload.is_verified:
        verified = await db.scalar(select(VerifiedTrip).where(VerifiedTrip.trip_id == trip_id))
        if not verified:
            verified = VerifiedTrip(
                trip_id=trip_id,
                source_owner_uid=owner_uid,
                source_trip_id=trip_id,
                title=trip.trip_name,
                raw_data={"source": "fastapi.verify"},
            )
            db.add(verified)
        else:
            verified.source_owner_uid = owner_uid
            verified.source_trip_id = trip_id
            verified.title = trip.trip_name
    await db.commit()
    await db.refresh(trip)
    return trip
