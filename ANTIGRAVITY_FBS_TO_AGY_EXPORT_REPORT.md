# fbs-to-agy-export Migration Report

Generated: 2026-04-15
Project: trypr-5ee47
Target region: northamerica-northeast1 (CA-TORONTO-1)

## 1) CLI and environment status

- Google Cloud CLI installed: yes (Google Cloud SDK 565.0.0)
- Firebase CLI installed: yes (15.10.1)
- gcloud authenticated account: matthewgockiewicz@gmail.com
- gcloud active project: trypr-5ee47
- gcloud default run region: northamerica-northeast1
- gcloud default functions region: northamerica-northeast1
- firebase active project: trypr-5ee47

## 2) Antigravity command availability

Requested command `@fbs-to-agy-export` was not found in this local environment as an installed shell command/package.

Equivalent export analysis was completed directly from source and rules files:
- functions/index.js
- firestore.rules
- lib/**/*.dart

## 3) Cloud Functions inventory and Cloud Run refactor targets

Current HTTP/callable functions in functions/index.js:

1. routeProxy (HTTP)
2. overpassProxy (HTTP)
3. createStripeCheckoutSession (callable)
4. createStripeBillingPortal (callable)
5. stripeWebhook (HTTP)
6. aiSuggest (callable)

Recommended Cloud Run services:

1. edge-routing-api
- Move routeProxy and overpassProxy into one HTTP Cloud Run service.
- Keep request/response schema stable to reduce app changes.
- Add rate limits and Cloud Armor at load balancer edge.

2. billing-api
- Move createStripeCheckoutSession, createStripeBillingPortal, stripeWebhook into one Cloud Run service.
- Replace callable invocation with authenticated HTTPS endpoints.
- Store Stripe secrets in Secret Manager.

3. ai-api
- Move aiSuggest into dedicated Cloud Run service.
- Keep Vertex AI access through IAM service account.
- Preserve fallback behavior and strict JSON response validation.

Migration priority (recommended):
- High: stripeWebhook, createStripeCheckoutSession, createStripeBillingPortal
- Medium: aiSuggest
- Medium: routeProxy, overpassProxy

## 4) Firestore collections and PostgreSQL refactor scope

Observed top-level collections:

- users
- admins
- userEntitlements
- publicUsers
- verifiedTrips
- tripJoinRequests
- unlistedPages
- refAssigner_associations
- refAssigner_users
- refAssigner_games
- refAssigner_assignments
- refAssigner_availability
- refAssigner_pickupRequests
- refAssigner_mail

Observed subcollections/doc patterns:

- users/{uid}/trips
- users/{uid}/sharedTrips
- users/{uid}/friendRequests
- users/{uid}/trips/{tripId}/messages
- users/{uid}/trips/{tripId}/packing
- users/{uid}/trips/{tripId}/expenses
- admins/{uid}/notes
- unlistedPages/{pageSlug}/responses
- userEntitlements/{uid}

Recommended PostgreSQL table mapping:

Core identity and profile
- users
- public_users
- admins
- user_entitlements

Trips and collaboration
- trips
- trip_shared_users
- trip_share_inbox (from sharedTrips)
- trip_join_requests
- friend_requests

Trip activity sub-entities
- trip_messages
- trip_packing_items
- trip_expenses

Content/admin
- verified_trips
- admin_notes
- unlisted_pages
- unlisted_page_responses

RefAssigner domain
- ref_assigner_associations
- ref_assigner_users
- ref_assigner_games
- ref_assigner_assignments
- ref_assigner_availability
- ref_assigner_pickup_requests
- ref_assigner_mail

## 5) Data modeling notes for Cloud SQL

- Replace nested subcollections with relational foreign keys.
- Add composite indexes for frequent filters (owner_uid, trip_id, created_at).
- Preserve canonical UID values from Firebase Auth as varchar columns.
- Add row-level access in application layer (or PostgreSQL RLS if desired).
- Keep audit columns on all mutable tables: created_at, updated_at, created_by_uid, updated_by_uid.

## 6) Region and latency requirements

Configured region defaults are Toronto:
- Cloud Run: northamerica-northeast1
- Cloud Functions (legacy default): northamerica-northeast1

For Cloud SQL PostgreSQL creation, use:
- region: northamerica-northeast1
- zonal or regional HA based on SLA/cost target

## 7) Immediate next execution steps

1. Export Firestore data for migration staging.
2. Provision Cloud SQL (PostgreSQL) in northamerica-northeast1.
3. Build initial schema + migration jobs for users/trips/entitlements first.
4. Deploy billing-api Cloud Run service and cut over Stripe traffic.
5. Deploy ai-api and edge-routing-api; update Flutter endpoints.
6. Disable Firebase callable endpoints after parity verification.
