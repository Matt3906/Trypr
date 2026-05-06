INSERT INTO ref_portal.users (
    user_id,
    association_id,
    email,
    display_name,
    role,
    created_at,
    updated_at,
    raw_data
)
VALUES (
    '8uLD9vTSmXZ2V7553RjvqbOURzC2',
    NULL,
    'matthewgockiewicz@gmail.com',
    'Matthew Gockiewicz',
    'admin',
    NOW(),
    NOW(),
    '{"seeded_by":"tmp_seed_ref_portal_admin.sql","source":"local_auth_bridge_debug"}'::jsonb
)
ON CONFLICT (user_id)
DO UPDATE SET
    email = EXCLUDED.email,
    display_name = EXCLUDED.display_name,
    role = 'admin',
    updated_at = NOW(),
    raw_data = COALESCE(ref_portal.users.raw_data, '{}'::jsonb) || EXCLUDED.raw_data;