-- Run against the GAME database with psql --single-transaction -v ON_ERROR_STOP=1.
-- Supabase Auth users must already have been imported with their original UUIDs.
-- Back up the game database and stop API writers before applying this script.
-- Rerunning is safe. A source/target collision aborts without merging accounts.
LOCK TABLE users IN SHARE ROW EXCLUSIVE MODE;

DO $migration$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM users source
        JOIN users target ON target.auth_subject = source.auth_subject
        WHERE source.auth_issuer = 'https://kagtrtnjflgkqlvgrjnk.supabase.co/auth/v1'
          AND target.auth_issuer = 'https://wqtzzjkyepawuuvsaijk.supabase.co/auth/v1'
    ) THEN
        RAISE EXCEPTION 'Singapore identity collision: review existing accounts before migrating';
    END IF;
END $migration$;

UPDATE users
SET auth_issuer = 'https://wqtzzjkyepawuuvsaijk.supabase.co/auth/v1'
WHERE auth_issuer = 'https://kagtrtnjflgkqlvgrjnk.supabase.co/auth/v1';
