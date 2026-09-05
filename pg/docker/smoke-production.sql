-- pg_mcp image smoke test — PRODUCTION profile (PRD-10 §7.5, FR-10.3).
--
-- Everything in smoke.sql, plus: every extension the pinned
-- docker.io/noizu/timescaledb-ha-with-age base must keep shipping still
-- creates successfully in the same database as pg_mcp. Run this only against
-- an image built on the Noizu base — stock postgres:17 has none of these.
--
-- SESSION ORDER MATTERS: timescaledb must be the first statement of its
-- session (it is on the base's shared_preload_libraries, and Postgres refuses
-- a CREATE EXTENSION for it mid-session with "already been loaded with
-- another version"). CI therefore runs TWO psql invocations:
--
--   psql -X -c "CREATE EXTENSION timescaledb;"                      # session 1
--   psql -X -v ON_ERROR_STOP=1 < smoke-production.sql               # session 2

CREATE EXTENSION pg_mcp;

CREATE EXTENSION age;
CREATE EXTENSION vector;
CREATE EXTENSION pgcrypto;
CREATE EXTENSION citext;
CREATE EXTENSION "uuid-ossp";
CREATE EXTENSION cube;
CREATE EXTENSION pg_trgm;
CREATE EXTENSION earthdistance;

-- AC-10.2: the mcp.* functions exist and resolve server names.
DO $$
BEGIN
    PERFORM mcp.refresh('definitely_not_a_server');
    RAISE EXCEPTION 'SMOKE FAIL: mcp.refresh on an unknown server did not raise';
EXCEPTION
    WHEN undefined_object THEN NULL;  -- 42704: exactly what we want
END
$$;
