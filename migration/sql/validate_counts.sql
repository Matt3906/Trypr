-- Compare Firestore counts (captured by migrate_to_sql.py)
-- against PostgreSQL table counts for 1:1 validation.

WITH pg_counts AS (
  SELECT 'users'::text AS collection_name, COUNT(*)::bigint AS postgres_count FROM trypr.users
  UNION ALL SELECT 'admins', COUNT(*) FROM trypr.admins
  UNION ALL SELECT 'userEntitlements', COUNT(*) FROM trypr.user_entitlements
  UNION ALL SELECT 'publicUsers', COUNT(*) FROM trypr.public_users
  UNION ALL SELECT 'verifiedTrips', COUNT(*) FROM trypr.verified_trips
  UNION ALL SELECT 'tripJoinRequests', COUNT(*) FROM trypr.trip_join_requests
  UNION ALL SELECT 'unlistedPages', COUNT(*) FROM trypr.unlisted_pages
  UNION ALL SELECT 'unlistedPages.responses', COUNT(*) FROM trypr.unlisted_page_responses
  UNION ALL SELECT 'users.trips', COUNT(*) FROM trypr.trips
  UNION ALL SELECT 'users.sharedTrips', COUNT(*) FROM trypr.trip_share_inbox
  UNION ALL SELECT 'users.friendRequests', COUNT(*) FROM trypr.friend_requests
  UNION ALL SELECT 'users.trips.messages', COUNT(*) FROM trypr.trip_messages
  UNION ALL SELECT 'users.trips.packing', COUNT(*) FROM trypr.trip_packing_items
  UNION ALL SELECT 'users.trips.expenses', COUNT(*) FROM trypr.trip_expenses
  UNION ALL SELECT 'admins.notes', COUNT(*) FROM trypr.admin_notes
  UNION ALL SELECT 'refAssigner_associations', COUNT(*) FROM ref_portal.associations
  UNION ALL SELECT 'refAssigner_users', COUNT(*) FROM ref_portal.users
  UNION ALL SELECT 'refAssigner_games', COUNT(*) FROM ref_portal.games
  UNION ALL SELECT 'refAssigner_assignments', COUNT(*) FROM ref_portal.assignments
  UNION ALL SELECT 'refAssigner_availability', COUNT(*) FROM ref_portal.availability
  UNION ALL SELECT 'refAssigner_pickupRequests', COUNT(*) FROM ref_portal.pickup_requests
  UNION ALL SELECT 'refAssigner_mail', COUNT(*) FROM ref_portal.mail
),
comparison AS (
  SELECT
    COALESCE(fs.collection_name, pg.collection_name) AS collection_name,
    COALESCE(fs.doc_count, 0) AS firestore_count,
    COALESCE(pg.postgres_count, 0) AS postgres_count,
    COALESCE(pg.postgres_count, 0) - COALESCE(fs.doc_count, 0) AS delta
  FROM trypr.firestore_collection_counts fs
  FULL OUTER JOIN pg_counts pg
    ON pg.collection_name = fs.collection_name
)
SELECT
  collection_name,
  firestore_count,
  postgres_count,
  delta,
  CASE WHEN delta = 0 THEN 'MATCH' ELSE 'MISMATCH' END AS integrity_status
FROM comparison
ORDER BY collection_name;

-- Optional quick status summary.
SELECT
  COUNT(*) FILTER (WHERE delta = 0) AS matched_collections,
  COUNT(*) FILTER (WHERE delta <> 0) AS mismatched_collections
FROM (
  SELECT
    COALESCE(pg.postgres_count, 0) - COALESCE(fs.doc_count, 0) AS delta
  FROM trypr.firestore_collection_counts fs
  FULL OUTER JOIN (
    SELECT 'users'::text AS collection_name, COUNT(*)::bigint AS postgres_count FROM trypr.users
    UNION ALL SELECT 'admins', COUNT(*) FROM trypr.admins
    UNION ALL SELECT 'userEntitlements', COUNT(*) FROM trypr.user_entitlements
    UNION ALL SELECT 'publicUsers', COUNT(*) FROM trypr.public_users
    UNION ALL SELECT 'verifiedTrips', COUNT(*) FROM trypr.verified_trips
    UNION ALL SELECT 'tripJoinRequests', COUNT(*) FROM trypr.trip_join_requests
    UNION ALL SELECT 'unlistedPages', COUNT(*) FROM trypr.unlisted_pages
    UNION ALL SELECT 'unlistedPages.responses', COUNT(*) FROM trypr.unlisted_page_responses
    UNION ALL SELECT 'users.trips', COUNT(*) FROM trypr.trips
    UNION ALL SELECT 'users.sharedTrips', COUNT(*) FROM trypr.trip_share_inbox
    UNION ALL SELECT 'users.friendRequests', COUNT(*) FROM trypr.friend_requests
    UNION ALL SELECT 'users.trips.messages', COUNT(*) FROM trypr.trip_messages
    UNION ALL SELECT 'users.trips.packing', COUNT(*) FROM trypr.trip_packing_items
    UNION ALL SELECT 'users.trips.expenses', COUNT(*) FROM trypr.trip_expenses
    UNION ALL SELECT 'admins.notes', COUNT(*) FROM trypr.admin_notes
    UNION ALL SELECT 'refAssigner_associations', COUNT(*) FROM ref_portal.associations
    UNION ALL SELECT 'refAssigner_users', COUNT(*) FROM ref_portal.users
    UNION ALL SELECT 'refAssigner_games', COUNT(*) FROM ref_portal.games
    UNION ALL SELECT 'refAssigner_assignments', COUNT(*) FROM ref_portal.assignments
    UNION ALL SELECT 'refAssigner_availability', COUNT(*) FROM ref_portal.availability
    UNION ALL SELECT 'refAssigner_pickupRequests', COUNT(*) FROM ref_portal.pickup_requests
    UNION ALL SELECT 'refAssigner_mail', COUNT(*) FROM ref_portal.mail
  ) pg ON pg.collection_name = fs.collection_name
) q;
