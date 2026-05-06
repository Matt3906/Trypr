from datetime import datetime

from sqlalchemy import Boolean, DateTime, ForeignKey, Numeric, Text
from sqlalchemy.dialects.postgresql import ENUM, JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    pass


class TryprUser(Base):
    __tablename__ = "users"
    __table_args__ = {"schema": "trypr"}

    uid: Mapped[str] = mapped_column(Text, primary_key=True)
    email: Mapped[str | None] = mapped_column(Text)
    display_name: Mapped[str | None] = mapped_column(Text)


class TryprAdmin(Base):
    __tablename__ = "admins"
    __table_args__ = {"schema": "trypr"}

    uid: Mapped[str] = mapped_column(Text, primary_key=True)


class Trip(Base):
    __tablename__ = "trips"
    __table_args__ = {"schema": "trypr"}

    owner_uid: Mapped[str] = mapped_column(Text, primary_key=True)
    trip_id: Mapped[str] = mapped_column(Text, primary_key=True)
    trip_name: Mapped[str | None] = mapped_column(Text)
    destination_name: Mapped[str | None] = mapped_column(Text)
    start_date: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    end_date: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    is_verified: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    share_link_enabled: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    itinerary_data: Mapped[dict | list | None] = mapped_column(JSONB)
    created_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    updated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    raw_data: Mapped[dict] = mapped_column(JSONB, default=dict)


class TripShareInbox(Base):
    __tablename__ = "trip_share_inbox"
    __table_args__ = {"schema": "trypr"}

    recipient_uid: Mapped[str] = mapped_column(Text, primary_key=True)
    trip_id: Mapped[str] = mapped_column(Text, primary_key=True)
    owner_uid: Mapped[str | None] = mapped_column(Text)
    trip_ref: Mapped[str | None] = mapped_column(Text)
    trip_name: Mapped[str | None] = mapped_column(Text)
    owner_name: Mapped[str | None] = mapped_column(Text)
    raw_data: Mapped[dict] = mapped_column(JSONB, default=dict)


class TripSharedUser(Base):
    __tablename__ = "trip_shared_users"
    __table_args__ = {"schema": "trypr"}

    shared_entry_id: Mapped[str] = mapped_column(Text, primary_key=True)
    owner_uid: Mapped[str] = mapped_column(Text)
    trip_id: Mapped[str] = mapped_column(Text)
    shared_uid: Mapped[str | None] = mapped_column(Text)
    shared_email: Mapped[str | None] = mapped_column(Text)
    raw_data: Mapped[dict] = mapped_column(JSONB, default=dict)


class VerifiedTrip(Base):
    __tablename__ = "verified_trips"
    __table_args__ = {"schema": "trypr"}

    trip_id: Mapped[str] = mapped_column(Text, primary_key=True)
    source_owner_uid: Mapped[str | None] = mapped_column(Text)
    source_trip_id: Mapped[str | None] = mapped_column(Text)
    title: Mapped[str | None] = mapped_column(Text)
    raw_data: Mapped[dict] = mapped_column(JSONB, default=dict)


class TripJoinRequest(Base):
    __tablename__ = "trip_join_requests"
    __table_args__ = {"schema": "trypr"}

    request_id: Mapped[str] = mapped_column(Text, primary_key=True)
    owner_uid: Mapped[str | None] = mapped_column(Text)
    requester_uid: Mapped[str | None] = mapped_column(Text)
    requester_name: Mapped[str | None] = mapped_column(Text)
    trip_id: Mapped[str | None] = mapped_column(Text)
    trip_ref: Mapped[str | None] = mapped_column(Text)
    status: Mapped[str | None] = mapped_column(Text)


class RefPortalUser(Base):
    __tablename__ = "users"
    __table_args__ = {"schema": "ref_portal"}

    user_id: Mapped[str] = mapped_column(Text, primary_key=True)
    association_id: Mapped[str | None] = mapped_column(Text)
    email: Mapped[str | None] = mapped_column(Text)
    display_name: Mapped[str | None] = mapped_column(Text)
    role: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    updated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    raw_data: Mapped[dict] = mapped_column(JSONB, default=dict)


class RefPortalAssociation(Base):
    __tablename__ = "associations"
    __table_args__ = {"schema": "ref_portal"}

    association_id: Mapped[str] = mapped_column(Text, primary_key=True)
    name: Mapped[str | None] = mapped_column(Text)
    status: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    updated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    raw_data: Mapped[dict] = mapped_column(JSONB, default=dict)


class RefPortalGame(Base):
    __tablename__ = "games"
    __table_args__ = {"schema": "ref_portal"}

    game_id: Mapped[str] = mapped_column(Text, primary_key=True)
    association_id: Mapped[str | None] = mapped_column(Text)
    game_date: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    location: Mapped[str | None] = mapped_column(Text)
    division: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    updated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    raw_data: Mapped[dict] = mapped_column(JSONB, default=dict)


class RefPortalAssignment(Base):
    __tablename__ = "assignments"
    __table_args__ = {"schema": "ref_portal"}

    assignment_id: Mapped[str] = mapped_column(Text, primary_key=True)
    game_id: Mapped[str | None] = mapped_column(
        Text,
        ForeignKey("ref_portal.games.game_id", ondelete="SET NULL"),
    )
    referee_uid: Mapped[str | None] = mapped_column(
        Text,
        ForeignKey("ref_portal.users.user_id", ondelete="SET NULL"),
    )
    status: Mapped[str] = mapped_column(
        ENUM(
            "pending",
            "accepted",
            "declined",
            "expired",
            name="assignment_status",
            schema="ref_portal",
            create_type=False,
        ),
        default="pending",
        nullable=False,
    )
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    assigned_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    responded_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    updated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    raw_data: Mapped[dict] = mapped_column(JSONB, default=dict)


class TripExpense(Base):
    __tablename__ = "trip_expenses"
    __table_args__ = {"schema": "trypr"}

    owner_uid: Mapped[str] = mapped_column(Text, primary_key=True)
    trip_id: Mapped[str] = mapped_column(Text, primary_key=True)
    expense_id: Mapped[str] = mapped_column(Text, primary_key=True)
    amount: Mapped[float | None] = mapped_column(Numeric(12, 2))


class RefPortalMail(Base):
    __tablename__ = "mail"
    __table_args__ = {"schema": "ref_portal"}

    mail_id: Mapped[str] = mapped_column(Text, primary_key=True)
    recipient_email: Mapped[str | None] = mapped_column(Text)
    subject: Mapped[str | None] = mapped_column(Text)
    sent_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    raw_data: Mapped[dict] = mapped_column(JSONB, default=dict)


class RefPortalAvailability(Base):
    __tablename__ = "availability"
    __table_args__ = {"schema": "ref_portal"}

    availability_id: Mapped[str] = mapped_column(Text, primary_key=True)
    referee_uid: Mapped[str | None] = mapped_column(
        Text,
        ForeignKey("ref_portal.users.user_id", ondelete="SET NULL"),
    )
    starts_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    ends_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    status: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    updated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    raw_data: Mapped[dict] = mapped_column(JSONB, default=dict)


class RefPortalPickupRequest(Base):
    __tablename__ = "pickup_requests"
    __table_args__ = {"schema": "ref_portal"}

    pickup_request_id: Mapped[str] = mapped_column(Text, primary_key=True)
    assignment_id: Mapped[str | None] = mapped_column(
        Text,
        ForeignKey("ref_portal.assignments.assignment_id", ondelete="SET NULL"),
    )
    requester_uid: Mapped[str | None] = mapped_column(
        Text,
        ForeignKey("ref_portal.users.user_id", ondelete="SET NULL"),
    )
    status: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    updated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    raw_data: Mapped[dict] = mapped_column(JSONB, default=dict)
