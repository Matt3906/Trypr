BEGIN;

CREATE SCHEMA IF NOT EXISTS trypr;
CREATE SCHEMA IF NOT EXISTS ref_portal;

CREATE TYPE ref_portal.assignment_status AS ENUM (
  'pending',
  'accepted',
  'declined',
  'expired'
);

-- -----------------------------
-- TRYPR DOMAIN
-- -----------------------------
CREATE TABLE IF NOT EXISTS trypr.users (
  uid TEXT PRIMARY KEY,
  email TEXT,
  display_name TEXT,
  photo_url TEXT,
  subscription TEXT,
  subscription_status TEXT,
  subscription_type TEXT,
  stripe_customer_id TEXT,
  current_period_end TIMESTAMPTZ,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_data JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS trypr.public_users (
  uid TEXT PRIMARY KEY,
  display_name TEXT,
  photo_url TEXT,
  updated_at TIMESTAMPTZ,
  raw_data JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS trypr.admins (
  uid TEXT PRIMARY KEY,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_data JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS trypr.user_entitlements (
  uid TEXT PRIMARY KEY,
  subscription TEXT,
  subscription_status TEXT,
  subscription_type TEXT,
  premium_source TEXT,
  premium_plan TEXT,
  stripe_customer_id TEXT,
  stripe_subscription_id TEXT,
  stripe_price_id TEXT,
  current_period_end TIMESTAMPTZ,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_data JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS trypr.trips (
  owner_uid TEXT NOT NULL,
  trip_id TEXT NOT NULL,
  trip_name TEXT,
  destination_name TEXT,
  start_date TIMESTAMPTZ,
  end_date TIMESTAMPTZ,
  is_verified BOOLEAN NOT NULL DEFAULT FALSE,
  share_link_enabled BOOLEAN NOT NULL DEFAULT FALSE,
  itinerary_data JSONB,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_data JSONB NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (owner_uid, trip_id)
);

CREATE TABLE IF NOT EXISTS trypr.trip_shared_users (
  shared_entry_id TEXT PRIMARY KEY,
  owner_uid TEXT NOT NULL,
  trip_id TEXT NOT NULL,
  shared_uid TEXT,
  shared_email TEXT,
  created_at TIMESTAMPTZ,
  raw_data JSONB NOT NULL DEFAULT '{}'::jsonb,
  FOREIGN KEY (owner_uid, trip_id)
    REFERENCES trypr.trips(owner_uid, trip_id)
    ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS trypr.trip_share_inbox (
  recipient_uid TEXT NOT NULL,
  trip_id TEXT NOT NULL,
  owner_uid TEXT,
  trip_ref TEXT,
  trip_name TEXT,
  owner_name TEXT,
  created_at TIMESTAMPTZ,
  raw_data JSONB NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (recipient_uid, trip_id)
);

CREATE TABLE IF NOT EXISTS trypr.trip_join_requests (
  request_id TEXT PRIMARY KEY,
  owner_uid TEXT,
  requester_uid TEXT,
  requester_name TEXT,
  trip_id TEXT,
  trip_ref TEXT,
  status TEXT,
  created_at TIMESTAMPTZ,
  handled_at TIMESTAMPTZ,
  raw_data JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS trypr.friend_requests (
  owner_uid TEXT NOT NULL,
  request_id TEXT NOT NULL,
  from_uid TEXT,
  from_name TEXT,
  status TEXT,
  created_at TIMESTAMPTZ,
  handled_at TIMESTAMPTZ,
  raw_data JSONB NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (owner_uid, request_id)
);

CREATE TABLE IF NOT EXISTS trypr.trip_messages (
  owner_uid TEXT NOT NULL,
  trip_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  sender_uid TEXT,
  text TEXT,
  created_at TIMESTAMPTZ,
  raw_data JSONB NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (owner_uid, trip_id, message_id),
  FOREIGN KEY (owner_uid, trip_id)
    REFERENCES trypr.trips(owner_uid, trip_id)
    ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS trypr.trip_packing_items (
  owner_uid TEXT NOT NULL,
  trip_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  name TEXT,
  packed BOOLEAN,
  created_at TIMESTAMPTZ,
  raw_data JSONB NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (owner_uid, trip_id, item_id),
  FOREIGN KEY (owner_uid, trip_id)
    REFERENCES trypr.trips(owner_uid, trip_id)
    ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS trypr.trip_expenses (
  owner_uid TEXT NOT NULL,
  trip_id TEXT NOT NULL,
  expense_id TEXT NOT NULL,
  title TEXT,
  amount NUMERIC(12, 2),
  paid_by_uid TEXT,
  category TEXT,
  split_mode TEXT,
  created_by_uid TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_data JSONB NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (owner_uid, trip_id, expense_id),
  FOREIGN KEY (owner_uid, trip_id)
    REFERENCES trypr.trips(owner_uid, trip_id)
    ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS trypr.verified_trips (
  trip_id TEXT PRIMARY KEY,
  source_owner_uid TEXT,
  source_trip_id TEXT,
  title TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_data JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS trypr.admin_notes (
  admin_uid TEXT NOT NULL,
  note_id TEXT NOT NULL,
  note_text TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_data JSONB NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (admin_uid, note_id),
  FOREIGN KEY (admin_uid)
    REFERENCES trypr.admins(uid)
    ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS trypr.unlisted_pages (
  page_slug TEXT PRIMARY KEY,
  title TEXT,
  status TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_data JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS trypr.unlisted_page_responses (
  page_slug TEXT NOT NULL,
  response_id TEXT NOT NULL,
  submitted_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ,
  raw_data JSONB NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (page_slug, response_id),
  FOREIGN KEY (page_slug)
    REFERENCES trypr.unlisted_pages(page_slug)
    ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS trypr.firestore_collection_counts (
  collection_name TEXT PRIMARY KEY,
  doc_count BIGINT NOT NULL,
  captured_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- -----------------------------
-- REF PORTAL DOMAIN
-- -----------------------------
CREATE TABLE IF NOT EXISTS ref_portal.associations (
  association_id TEXT PRIMARY KEY,
  name TEXT,
  status TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_data JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS ref_portal.users (
  user_id TEXT PRIMARY KEY,
  association_id TEXT,
  email TEXT,
  display_name TEXT,
  role TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_data JSONB NOT NULL DEFAULT '{}'::jsonb,
  FOREIGN KEY (association_id)
    REFERENCES ref_portal.associations(association_id)
    ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS ref_portal.games (
  game_id TEXT PRIMARY KEY,
  association_id TEXT,
  game_date TIMESTAMPTZ,
  location TEXT,
  division TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_data JSONB NOT NULL DEFAULT '{}'::jsonb,
  FOREIGN KEY (association_id)
    REFERENCES ref_portal.associations(association_id)
    ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS ref_portal.assignments (
  assignment_id TEXT PRIMARY KEY,
  game_id TEXT,
  referee_uid TEXT,
  status ref_portal.assignment_status NOT NULL DEFAULT 'pending',
  expires_at TIMESTAMPTZ,
  assigned_at TIMESTAMPTZ,
  responded_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_data JSONB NOT NULL DEFAULT '{}'::jsonb,
  FOREIGN KEY (game_id)
    REFERENCES ref_portal.games(game_id)
    ON DELETE SET NULL,
  FOREIGN KEY (referee_uid)
    REFERENCES ref_portal.users(user_id)
    ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS ref_portal.availability (
  availability_id TEXT PRIMARY KEY,
  referee_uid TEXT,
  starts_at TIMESTAMPTZ,
  ends_at TIMESTAMPTZ,
  status TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_data JSONB NOT NULL DEFAULT '{}'::jsonb,
  FOREIGN KEY (referee_uid)
    REFERENCES ref_portal.users(user_id)
    ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS ref_portal.pickup_requests (
  pickup_request_id TEXT PRIMARY KEY,
  assignment_id TEXT,
  requester_uid TEXT,
  status TEXT,
  created_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ,
  raw_data JSONB NOT NULL DEFAULT '{}'::jsonb,
  FOREIGN KEY (assignment_id)
    REFERENCES ref_portal.assignments(assignment_id)
    ON DELETE SET NULL,
  FOREIGN KEY (requester_uid)
    REFERENCES ref_portal.users(user_id)
    ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS ref_portal.mail (
  mail_id TEXT PRIMARY KEY,
  recipient_email TEXT,
  subject TEXT,
  sent_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ,
  raw_data JSONB NOT NULL DEFAULT '{}'::jsonb
);

-- -----------------------------
-- PERFORMANCE INDEXES
-- -----------------------------
CREATE INDEX IF NOT EXISTS idx_trips_owner_updated
  ON trypr.trips (owner_uid, updated_at DESC);

CREATE INDEX IF NOT EXISTS idx_trip_messages_trip_created
  ON trypr.trip_messages (owner_uid, trip_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_trip_expenses_trip_created
  ON trypr.trip_expenses (owner_uid, trip_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_trip_join_requests_owner_status
  ON trypr.trip_join_requests (owner_uid, status);

CREATE INDEX IF NOT EXISTS idx_assignments_game_status
  ON ref_portal.assignments (game_id, status);

CREATE INDEX IF NOT EXISTS idx_assignments_expires_at
  ON ref_portal.assignments (expires_at);

COMMIT;
