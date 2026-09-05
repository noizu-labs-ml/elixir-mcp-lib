-- pg_mcp image smoke test — base-agnostic half (PRD-10 §7.5).
--
-- Proves: the .so loads, the control/SQL files are found, and the mcp.*
-- functions resolve server names (an unknown server MUST raise SQLSTATE
-- 42704, undefined_object — that failure mode catches a PG_MAJOR mismatch,
-- a missing .so, a wrong install path, or an ABI break against the base).
--
-- Run with:  docker exec -i <container> psql -U postgres -v ON_ERROR_STOP=1 < smoke.sql
-- Any unexpected SQLSTATE (or a missing one) fails with a non-zero exit.
--
-- The full §7.5 battery that also re-creates every pre-existing base
-- extension lives in smoke-production.sql (pinned Noizu base only).

CREATE EXTENSION pg_mcp;

-- AC-10.2: mcp.refresh exists, resolves the server name, and rejects an
-- unknown one with 42704. Inside a DO block so the expected error proves the
-- assertion instead of aborting the script.
DO $$
BEGIN
    PERFORM mcp.refresh('definitely_not_a_server');
    RAISE EXCEPTION 'SMOKE FAIL: mcp.refresh on an unknown server did not raise';
EXCEPTION
    WHEN undefined_object THEN NULL;  -- 42704: exactly what we want
END
$$;
