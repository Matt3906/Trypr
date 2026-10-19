-- Idempotent schema; applied at every backend start (see app/core/db.py).

CREATE TABLE IF NOT EXISTS accounts (
    uid           text PRIMARY KEY,
    email         text NOT NULL,
    password_hash text NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    last_login_at timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS accounts_email_lower_idx ON accounts (lower(email));

CREATE TABLE IF NOT EXISTS sessions (
    token_hash   text PRIMARY KEY,
    uid          text NOT NULL REFERENCES accounts(uid) ON DELETE CASCADE,
    created_at   timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL,
    last_used_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS sessions_uid_idx ON sessions (uid);
CREATE INDEX IF NOT EXISTS sessions_expires_idx ON sessions (expires_at);

CREATE TABLE IF NOT EXISTS password_resets (
    token_hash text PRIMARY KEY,
    uid        text NOT NULL REFERENCES accounts(uid) ON DELETE CASCADE,
    expires_at timestamptz NOT NULL,
    used_at    timestamptz
);

-- Firestore-style document store. `path` is e.g. users/<uid>/trips/<tripId>.
CREATE TABLE IF NOT EXISTS documents (
    path       text PRIMARY KEY,
    parent     text NOT NULL,          -- collection path: users/<uid>/trips
    coll       text NOT NULL,          -- last collection id: trips (for collection-group queries)
    id         text NOT NULL,
    data       jsonb NOT NULL DEFAULT '{}'::jsonb,
    rev        bigint NOT NULL DEFAULT 1,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS documents_parent_idx ON documents (parent);
CREATE INDEX IF NOT EXISTS documents_coll_idx ON documents (coll);
CREATE INDEX IF NOT EXISTS documents_join_tripref_idx
    ON documents ((data->>'tripRef')) WHERE parent = 'tripJoinRequests';
CREATE INDEX IF NOT EXISTS documents_ent_stripe_idx
    ON documents ((data->>'stripeCustomerId')) WHERE parent = 'userEntitlements';

CREATE TABLE IF NOT EXISTS files (
    path            text PRIMARY KEY,
    storage_key     text NOT NULL,
    content_type    text NOT NULL DEFAULT 'application/octet-stream',
    size            bigint NOT NULL DEFAULT 0,
    custom_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    uploaded_by     text,
    created_at      timestamptz NOT NULL DEFAULT now()
);
