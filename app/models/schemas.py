from datetime import datetime
from decimal import Decimal
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field


class ORMModel(BaseModel):
    model_config = ConfigDict(from_attributes=True)


# ----------------------------
# trypr schema table mirrors
# ----------------------------
class TryprUserSchema(ORMModel):
    uid: str
    email: str | None = None
    display_name: str | None = None
    photo_url: str | None = None
    subscription: str | None = None
    subscription_status: str | None = None
    subscription_type: str | None = None
    stripe_customer_id: str | None = None
    current_period_end: datetime | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None
    raw_data: dict[str, Any] = Field(default_factory=dict)


class PublicUserSchema(ORMModel):
    uid: str
    display_name: str | None = None
    photo_url: str | None = None
    updated_at: datetime | None = None
    raw_data: dict[str, Any] = Field(default_factory=dict)


class AdminSchema(ORMModel):
    uid: str
    created_at: datetime | None = None
    updated_at: datetime | None = None
    raw_data: dict[str, Any] = Field(default_factory=dict)


class UserEntitlementSchema(ORMModel):
    uid: str
    subscription: str | None = None
    subscription_status: str | None = None
    subscription_type: str | None = None
    premium_source: str | None = None
    premium_plan: str | None = None
    stripe_customer_id: str | None = None
    stripe_subscription_id: str | None = None
    stripe_price_id: str | None = None
    current_period_end: datetime | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None
    raw_data: dict[str, Any] = Field(default_factory=dict)


class TripSchema(ORMModel):
    owner_uid: str
    trip_id: str
    trip_name: str | None = None
    destination_name: str | None = None
    start_date: datetime | None = None
    end_date: datetime | None = None
    is_verified: bool = False
    share_link_enabled: bool = False
    itinerary_data: dict[str, Any] | list[Any] | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None
    raw_data: dict[str, Any] = Field(default_factory=dict)


class TripSharedUserSchema(ORMModel):
    shared_entry_id: str
    owner_uid: str
    trip_id: str
    shared_uid: str | None = None
    shared_email: str | None = None
    created_at: datetime | None = None
    raw_data: dict[str, Any] = Field(default_factory=dict)


class TripShareInboxSchema(ORMModel):
    recipient_uid: str
    trip_id: str
    owner_uid: str | None = None
    trip_ref: str | None = None
    trip_name: str | None = None
    owner_name: str | None = None
    created_at: datetime | None = None
    raw_data: dict[str, Any] = Field(default_factory=dict)


class TripJoinRequestSchema(ORMModel):
    request_id: str
    owner_uid: str | None = None
    requester_uid: str | None = None
    requester_name: str | None = None
    trip_id: str | None = None
    trip_ref: str | None = None
    status: str | None = None
    created_at: datetime | None = None
    handled_at: datetime | None = None
    raw_data: dict[str, Any] = Field(default_factory=dict)


class FriendRequestSchema(ORMModel):
    owner_uid: str
    request_id: str
    from_uid: str | None = None
    from_name: str | None = None
    status: str | None = None
    created_at: datetime | None = None
    handled_at: datetime | None = None
    raw_data: dict[str, Any] = Field(default_factory=dict)


class TripMessageSchema(ORMModel):
    owner_uid: str
    trip_id: str
    message_id: str
    sender_uid: str | None = None
    text: str | None = None
    created_at: datetime | None = None
    raw_data: dict[str, Any] = Field(default_factory=dict)


class TripPackingItemSchema(ORMModel):
    owner_uid: str
    trip_id: str
    item_id: str
    name: str | None = None
    packed: bool | None = None
    created_at: datetime | None = None
    raw_data: dict[str, Any] = Field(default_factory=dict)


class TripExpenseSchema(ORMModel):
    owner_uid: str
    trip_id: str
    expense_id: str
    title: str | None = None
    amount: Decimal | None = None
    paid_by_uid: str | None = None
    category: str | None = None
    split_mode: str | None = None
    created_by_uid: str | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None
    raw_data: dict[str, Any] = Field(default_factory=dict)


class VerifiedTripSchema(ORMModel):
    trip_id: str
    source_owner_uid: str | None = None
    source_trip_id: str | None = None
    title: str | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None
    raw_data: dict[str, Any] = Field(default_factory=dict)


class AdminNoteSchema(ORMModel):
    admin_uid: str
    note_id: str
    note_text: str | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None
    raw_data: dict[str, Any] = Field(default_factory=dict)


class UnlistedPageSchema(ORMModel):
    page_slug: str
    title: str | None = None
    status: str | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None
    raw_data: dict[str, Any] = Field(default_factory=dict)


class UnlistedPageResponseSchema(ORMModel):
    page_slug: str
    response_id: str
    submitted_at: datetime | None = None
    created_at: datetime | None = None
    raw_data: dict[str, Any] = Field(default_factory=dict)


# ----------------------------
# ref_portal schema table mirrors
# ----------------------------
class RefAssociationSchema(ORMModel):
    association_id: str
    name: str | None = None
    status: str | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None
    raw_data: dict[str, Any] = Field(default_factory=dict)


class RefUserSchema(ORMModel):
    user_id: str
    association_id: str | None = None
    email: str | None = None
    display_name: str | None = None
    role: str | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None
    raw_data: dict[str, Any] = Field(default_factory=dict)


class RefGameSchema(ORMModel):
    game_id: str
    association_id: str | None = None
    game_date: datetime | None = None
    location: str | None = None
    division: str | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None
    raw_data: dict[str, Any] = Field(default_factory=dict)


class RefAssignmentSchema(ORMModel):
    assignment_id: str
    game_id: str | None = None
    referee_uid: str | None = None
    status: Literal["pending", "accepted", "declined", "expired"]
    expires_at: datetime | None = None
    assigned_at: datetime | None = None
    responded_at: datetime | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None
    raw_data: dict[str, Any] = Field(default_factory=dict)


class RefAvailabilitySchema(ORMModel):
    availability_id: str
    referee_uid: str | None = None
    starts_at: datetime | None = None
    ends_at: datetime | None = None
    status: str | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None
    raw_data: dict[str, Any] = Field(default_factory=dict)


class RefPickupRequestSchema(ORMModel):
    pickup_request_id: str
    assignment_id: str | None = None
    requester_uid: str | None = None
    status: str | None = None
    created_at: datetime | None = None
    updated_at: datetime | None = None
    raw_data: dict[str, Any] = Field(default_factory=dict)


class RefMailSchema(ORMModel):
    mail_id: str
    recipient_email: str | None = None
    subject: str | None = None
    sent_at: datetime | None = None
    created_at: datetime | None = None
    raw_data: dict[str, Any] = Field(default_factory=dict)


# ----------------------------
# API payload schemas
# ----------------------------
class TripCreateRequest(BaseModel):
    owner_uid: str | None = None
    trip_name: str
    destination_name: str | None = None
    start_date: datetime | None = None
    end_date: datetime | None = None
    itinerary_data: dict[str, Any] | list[Any] | None = None
    share_link_enabled: bool = False
    raw_data: dict[str, Any] = Field(default_factory=dict)


class TripShareRequest(BaseModel):
    recipient_uids: list[str] = Field(default_factory=list)
    recipient_emails: list[str] = Field(default_factory=list)


class TripVerifiedUpdateRequest(BaseModel):
    is_verified: bool


class AssignmentTriggerRequest(BaseModel):
    referee_uids: list[str]
    expires_in_hours: int = Field(default=24, ge=1, le=168)


class AssignmentCreateRequest(BaseModel):
    game_id: str
    referee_uid: str
    association_id: str | None = Field(default=None, max_length=120)
    notes: str | None = None


class AssignmentResponseRequest(BaseModel):
    status: Literal["accepted", "declined"]


class IncidentReportCreateRequest(BaseModel):
    report_type: str | None = Field(default="Special Incident", max_length=120)
    penalty_assessed_to: str | None = Field(default=None, max_length=200)
    player_number: str | None = Field(default=None, max_length=40)
    player_team: str | None = Field(default=None, max_length=80)
    penalty_code: str | None = Field(default=None, max_length=80)
    infraction: str | None = Field(default=None, max_length=160)
    period: str | None = Field(default=None, max_length=40)
    time: str | None = Field(default=None, max_length=40)
    score_at_time: str | None = Field(default=None, max_length=80)
    final_score: str | None = Field(default=None, max_length=80)
    details: str = Field(min_length=1, max_length=8000)
    injuries: str | None = Field(default=None, max_length=4000)
    further_problems: str | None = Field(default=None, max_length=4000)
    verbal_report_to: str | None = Field(default=None, max_length=200)
    report_date: str | None = Field(default=None, max_length=40)
    raw_data: dict[str, Any] = Field(default_factory=dict)


class SupervisionReportCreateRequest(BaseModel):
    evaluated_user_id: str | None = Field(default=None, max_length=160)
    reviewed_game_sheet: bool = False
    code: str | None = Field(default=None, max_length=120)
    subcode: str | None = Field(default=None, max_length=160)
    strengths: str | None = Field(default=None, max_length=6000)
    development: str | None = Field(default=None, max_length=6000)
    comments: str | None = Field(default=None, max_length=8000)
    overall_rating: str | None = Field(default=None, max_length=40)
    ratings: dict[str, Any] = Field(default_factory=dict)
    report_date: str | None = Field(default=None, max_length=40)
    raw_data: dict[str, Any] = Field(default_factory=dict)


class GameBatchItem(BaseModel):
    date: str | None = None  # YYYY-MM-DD
    time: str | None = None  # HH:MM
    home_team: str | None = None
    away_team: str | None = None
    arena: str | None = None
    division: str | None = None
    game_type: str | None = "LG"


class GameBatchCreateRequest(BaseModel):
    association_id: str = Field(min_length=1, max_length=120)
    games: list[GameBatchItem] = Field(default_factory=list)


class GameCreateRequest(BaseModel):
    association_id: str = Field(min_length=1, max_length=120)
    date: str | None = None
    time: str | None = None
    home_team: str | None = None
    away_team: str | None = None
    arena: str | None = None
    division: str | None = None
    game_type: str | None = "LG"
    status: str | None = "unassigned"
    raw_data: dict[str, Any] = Field(default_factory=dict)


class GameUpdateRequest(BaseModel):
    date: str | None = None
    time: str | None = None
    home_team: str | None = None
    away_team: str | None = None
    arena: str | None = None
    division: str | None = None
    game_type: str | None = None
    status: str | None = None
    raw_data: dict[str, Any] | None = None


class AssignmentUpdateRequest(BaseModel):
    status: Literal["pending", "accepted", "declined", "expired"] | None = None
    referee_uid: str | None = None
    notes: str | None = None
    raw_data: dict[str, Any] | None = None


class AvailabilityUpsertRequest(BaseModel):
    user_id: str = Field(min_length=1, max_length=255)
    association_id: str | None = Field(default=None, max_length=120)
    date: str = Field(min_length=8, max_length=32)
    type: str | None = Field(default=None, max_length=32)
    start_time: str | None = Field(default=None, max_length=8)
    end_time: str | None = Field(default=None, max_length=8)
    locked: bool | None = None
    raw_data: dict[str, Any] = Field(default_factory=dict)


class AvailabilityLockRequest(BaseModel):
    user_id: str = Field(min_length=1, max_length=255)
    date: str = Field(min_length=8, max_length=32)
    locked: bool


class PickupRequestCreateRequest(BaseModel):
    assignment_id: str | None = Field(default=None, max_length=255)
    requester_uid: str = Field(min_length=1, max_length=255)
    association_id: str | None = Field(default=None, max_length=120)
    raw_data: dict[str, Any] = Field(default_factory=dict)


class PickupRequestUpdateRequest(BaseModel):
    status: str | None = Field(default=None, max_length=32)
    raw_data: dict[str, Any] | None = None


class AssociationCreateRequest(BaseModel):
    name: str = Field(min_length=2, max_length=200)
    city: str | None = Field(default=None, max_length=120)
    province: str | None = Field(default=None, max_length=120)
    contact_email: str | None = Field(default=None, max_length=320)
    contact_name: str | None = Field(default=None, max_length=200)
    status: str | None = Field(default="active", max_length=32)
    association_id: str | None = Field(default=None, max_length=120)
    raw_data: dict[str, Any] = Field(default_factory=dict)


class AssociationUpdateRequest(BaseModel):
    name: str | None = Field(default=None, min_length=2, max_length=200)
    city: str | None = Field(default=None, max_length=120)
    province: str | None = Field(default=None, max_length=120)
    contact_email: str | None = Field(default=None, max_length=320)
    contact_name: str | None = Field(default=None, max_length=200)
    status: str | None = Field(default=None, max_length=32)
    raw_data: dict[str, Any] | None = None


class RefUserCreateRequest(BaseModel):
    user_id: str | None = Field(default=None, max_length=255)
    association_id: str | None = Field(default=None, max_length=120)
    email: str = Field(min_length=3, max_length=320)
    first_name: str | None = Field(default=None, max_length=120)
    last_name: str | None = Field(default=None, max_length=120)
    display_name: str | None = Field(default=None, max_length=240)
    phone: str | None = Field(default=None, max_length=80)
    role: str = Field(default="official", max_length=64)
    raw_data: dict[str, Any] = Field(default_factory=dict)


class RefUserUpdateRequest(BaseModel):
    association_id: str | None = Field(default=None, max_length=120)
    email: str | None = Field(default=None, max_length=320)
    first_name: str | None = Field(default=None, max_length=120)
    last_name: str | None = Field(default=None, max_length=120)
    display_name: str | None = Field(default=None, max_length=240)
    phone: str | None = Field(default=None, max_length=80)
    role: str | None = Field(default=None, max_length=64)
    raw_data: dict[str, Any] | None = None


class RefUserSelfUpdateRequest(BaseModel):
    first_name: str | None = Field(default=None, max_length=120)
    last_name: str | None = Field(default=None, max_length=120)
    phone: str | None = Field(default=None, max_length=80)
    date_of_birth: str | None = Field(default=None, max_length=20)
    address_street: str | None = Field(default=None, max_length=200)
    address_city: str | None = Field(default=None, max_length=120)
    address_state: str | None = Field(default=None, max_length=80)
    address_postal_code: str | None = Field(default=None, max_length=30)
    address_country: str | None = Field(default=None, max_length=80)
    emergency_contact_name: str | None = Field(default=None, max_length=200)
    emergency_contact_phone: str | None = Field(default=None, max_length=80)


class BroadcastMessageRequest(BaseModel):
    subject: str = Field(min_length=3, max_length=180)
    intro_text: str = Field(min_length=1, max_length=500)
    message_body: str = Field(min_length=1, max_length=10000)
    action_url: str | None = None
    action_label: str | None = None


class APIMessage(BaseModel):
    message: str
