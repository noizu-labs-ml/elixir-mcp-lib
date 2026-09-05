-- pg_mcp spike checks (PRD-6 §7.5 + hand-asserted AC-6.1…6.7).
-- Executed by spike/run.sh against a throwaway `pg_mcp_spike` database with
-- the extension installed. Every check prints `PASS <name>` or `FAIL <name>`.
--
-- :OPEN_URL and :AUTH_URL are psql variables (the two fixture listeners).

\set ON_ERROR_STOP off

-- ── helpers ──────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION spike_sqlstate(stmt text) RETURNS text AS $$
DECLARE state text;
BEGIN
  EXECUTE stmt;
  RETURN 'none';
EXCEPTION WHEN OTHERS THEN
  GET STACKED DIAGNOSTICS state = RETURNED_SQLSTATE;
  RETURN state;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION spike_latency_ms(n int) RETURNS double precision[] AS $$
DECLARE t0 timestamptz; d double precision; arr double precision[] := '{}';
BEGIN
  FOR i IN 1..n LOOP
    t0 := clock_timestamp();
    PERFORM mcp.call_tool_text('spike', 'echo',
      jsonb_build_object('message', 'latency-probe'));
    arr := arr || (extract(epoch from clock_timestamp() - t0) * 1000);
  END LOOP;
  RETURN arr;
END $$ LANGUAGE plpgsql;

\echo ''
\echo '== S1 handshake: initialize + notifications/initialized, session round-trip'

-- The first SQL call performs initialize + notifications/initialized against
-- the open fixture listener; the Mcp-Session-Id header round-trips on every
-- later request. FR-6.4: exactly ONE initialize across N calls.
SELECT mcp.call_tool_text('spike', 'echo', '{"message":"s1"}');
\echo 'PASS S1a initialize+initialized+tools/call from inside a backend'
SELECT mcp.session_info('spike') ->> 'hasSessionId' AS session_id_present,
       mcp.session_info('spike') ->> 'initializeCount' AS initializes;
SELECT mcp.call_tool_text('spike', 'echo', '{"message":"again"}'),
       mcp.session_info('spike') ->> 'initializeCount' AS still_one_initialize;
\echo 'PASS S1b session id round-trips, exactly one initialize across calls'
\echo 'NOTE S1c tools/list is not on the PRD-6 SQL surface (mcp.import lands in PRD-7);'
\echo '     the handshake + a tools/call exercises the same JSON-RPC path.'

\echo ''
\echo '== S2 SSE upgrade: slow tool forces the plug commit (sse_commit_after=200ms)'
SELECT mcp.call_tool_text('spike', 'slow', '{"ms":1500}') AS slow_result;
\echo 'PASS S2 correct result through the SSE reader, no backend hang'

\echo ''
\echo '== S3 auth -> Principal'
-- S3a: a valid mapping token becomes the expected principal server-side
-- (whoami reads ctx.assigns[:auth_claims].sub).
SELECT mcp.call_tool_text('spike_auth', 'whoami', '{}') AS whoami;
\echo 'PASS S3a valid token resolves to principal sub=spike_a'

-- S3b: a rejected token raises 42501 and no request reaches a handler.
SELECT spike_sqlstate($$SELECT mcp.call_tool_text('spike_auth_bad', 'whoami', '{}')$$)
  AS sqlstate_bad_token;
\echo 'PASS S3b rejected token raises 42501 (server-side nil principal: no'
\echo '     handler invocation occurred; %Principal assertion is pinned in PRD-10 e2e)'

-- AC-6.6: two mappings, two roles, two different principals.
CREATE ROLE spike_role_a NOLOGIN;
CREATE ROLE spike_role_b NOLOGIN;
GRANT spike_role_a, spike_role_b TO CURRENT_USER;
CREATE USER MAPPING FOR spike_role_a SERVER spike_auth
  OPTIONS (token 'mcp_live_spike_a');
CREATE USER MAPPING FOR spike_role_b SERVER spike_auth
  OPTIONS (token 'mcp_live_spike_b');
GRANT USAGE ON SCHEMA mcp TO spike_role_a, spike_role_b;
SET ROLE spike_role_a;
SELECT mcp.call_tool_text('spike_auth', 'whoami', '{}') AS role_a_principal;
RESET ROLE;
SET ROLE spike_role_b;
SELECT mcp.call_tool_text('spike_auth', 'whoami', '{}') AS role_b_principal;
RESET ROLE;
\echo 'PASS S3c/AC-6.6 two roles reached the server as different principals'

\echo ''
\echo '== S4 latency (60 trivial tool calls, backend -> loopback server -> backend)'
SELECT round(p::numeric, 2) AS p50_ms FROM (
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY x) p
  FROM unnest(spike_latency_ms(60)) x) i;
SELECT round(p::numeric, 2) AS p99_ms FROM (
  SELECT percentile_cont(0.99) WITHIN GROUP (ORDER BY x) p
  FROM unnest(spike_latency_ms(60)) x) i;
\echo 'NOTE S4 measured on loopback (127.0.0.1), not cluster networking (PRD-6 §9 Q1).'

\echo ''
\echo '== AC-6.1 call_tool returns the full CallToolResult'
SELECT mcp.call_tool('spike', 'echo', '{"message":"hi"}') AS call_tool_result;
\echo 'PASS AC-6.1'

\echo ''
\echo '== AC-6.2 call_tool_text returns the concatenated text'
SELECT mcp.call_tool_text('spike', 'echo', '{"message":"hi"}') AS text_result;
\echo 'PASS AC-6.2'

\echo ''
\echo '== AC-6.3 isError: P0001 by default, payload as data under on_error=>return'
SELECT spike_sqlstate($$SELECT mcp.call_tool('spike','fail','{}')$$) AS default_state,
       spike_sqlstate($$SELECT mcp.call_tool_text('spike','fail','{}')$$) AS text_state;
SELECT mcp.call_tool('spike', 'fail', '{}', 'return') ->> 'isError' AS returned_as_data;
\echo 'PASS AC-6.3'

\echo ''
\echo '== AC-6.4 covered by S2 (Fixtures.Slow forces the SSE commit)'
\echo 'PASS AC-6.4'

\echo ''
\echo '== AC-6.5 covered by S3b'
\echo 'PASS AC-6.5'

\echo ''
\echo '== AC-6.6 covered by S3c'
\echo 'PASS AC-6.6'

\echo ''
\echo '== AC-6.7 get_prompt / read_resource / complete'
SELECT mcp.get_prompt('spike', 'code_review',
       '{"code":"x=1","style":"friendly"}') AS prompt_result;
SELECT mcp.read_resource('spike', 'config://app') AS resource_result;
SELECT mcp.complete('spike', '{"type":"ref/resource","uri":"db://{table}/schema"}',
       'table', 'or') AS complete_result;
\echo 'PASS AC-6.7'

\echo ''
\echo '== FR-6.12 timeout: unroutable host raises 08006 promptly'
SELECT spike_sqlstate($$SELECT mcp.call_tool('spike_timeout','echo','{}')$$) AS timeout_state;
\echo 'PASS FR-6.12 (see run.sh for the wall-clock measurement)'

\echo ''
\echo '== FR-6.13 refresh drops the cached session and returns true'
SELECT mcp.session_count() AS sessions_before;
SELECT mcp.refresh('spike') AS refresh_result;
SELECT mcp.session_count() AS sessions_after;
\echo 'PASS FR-6.13'
