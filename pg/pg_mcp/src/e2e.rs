//! **Track E owns this file** (PRD-7 §7.4-§7.5, §5 ACs): the cross-track
//! integration battery — anti-pattern regressions (AP-P1, AP-P2, AP-P4; AP-P3
//! lives in `catalog.rs`'s `cross_role_cache_bleed_is_impossible`), the §7.5
//! performance probes, and the acceptance criteria that span the four
//! implementation tracks (AC-7.8, AC-7.10, AC-7.11, and the engine ACs
//! AC-7.13 / AC-7.14).
//!
//! Engine-AC approach: the extension's entire engine integration runs over
//! the *generic* MCP surface — `mcp.import` with `all_upstreams 'true'`
//! derives the upstream list from the engine's `tools/list` namespacing
//! (`<upstream>.<tool>`; ADR-007), and per-upstream scans are plain catalog
//! scans scoped by the `upstream` OPTIONS entry. The probes below therefore
//! run against the in-crate stub serving that convention, which exercises the
//! full extension-side contract; a live-Elixir-engine run of the same probes
//! lands with PRD-10's e2e suite.
//!
//! AP-P1's structural half (no registry writes outside the audit path) is a
//! grep-level check in `run-tests.sh`, not a probe.

use crate::cache::stub::{Reply, StubServer};
use pgrx::prelude::*;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;

#[cfg(any(test, feature = "pg_test"))]
#[pgrx::pg_schema]
mod e2e_test {
    use super::*;
    use crate::cache;

    const TOOLS_LIST: &str = "tools/list";

    fn map(entries: Vec<(&str, Reply)>) -> HashMap<String, Reply> {
        entries
            .into_iter()
            .map(|(k, v)| (k.to_string(), v))
            .collect()
    }

    fn count(stmt: &str) -> i64 {
        Spi::get_one::<i64>(stmt).unwrap().unwrap()
    }

    /// Create a foreign server over the stub and import the full registry
    /// into `<name>_s`.
    fn make_server(name: &str, url: &str, extra_options: &str) {
        Spi::run(&format!(
            "CREATE SERVER {name} FOREIGN DATA WRAPPER mcp_fdw
               OPTIONS (url '{url}', auth 'none', timeout_ms '8000'{extra_options})"
        ))
        .unwrap();
        Spi::run(&format!("CREATE SCHEMA {name}_s")).unwrap();
        Spi::run(&format!(
            "IMPORT FOREIGN SCHEMA mcp FROM SERVER {name} INTO {name}_s"
        ))
        .unwrap();
    }

    /// Assert that `stmt` fails with SQLSTATE `want` (and, when given, a
    /// message containing `want_msg`), running inside a plpgsql EXCEPTION
    /// block: FDW-path errors longjmp straight to PostgreSQL's machinery and
    /// are not capturable as Rust `Result`s here (the frozen harness pattern,
    /// PRD-7 §7.3).
    fn expect_sqlstate(stmt: &str, want: &str, want_msg: Option<&str>) {
        let msg_check = match want_msg {
            Some(_) => " OR (got_msg IS NULL OR position(want_msg IN got_msg) = 0)",
            None => "",
        };
        let sql = format!(
            r#"
            DO $probe$
            DECLARE got text; got_msg text;
                    want text := '{want}'; want_msg text := '{want_msg}';
            BEGIN
                BEGIN
                    EXECUTE $stmt${stmt}$stmt$;
                    RAISE EXCEPTION 'NO_ERROR_RAISED';
                EXCEPTION WHEN OTHERS THEN
                    got := SQLSTATE; got_msg := SQLERRM;
                END;
                IF got IS DISTINCT FROM want{msg_check} THEN
                    RAISE EXCEPTION 'expected SQLSTATE % (message containing %), got % / %',
                        want, want_msg, got, got_msg;
                END IF;
            END
            $probe$;"#,
            want_msg = want_msg.unwrap_or(""),
        );
        Spi::run(&sql)
            .unwrap_or_else(|e| panic!("expect_sqlstate harness failed for {want}: {e:?}"));
    }

    /// The stub's `initialize` reply, common to every probe.
    fn init_reply(name: &str) -> Reply {
        Reply::Result(json!({
            "protocolVersion": "2025-11-25",
            "capabilities": {},
            "serverInfo": {"name": name, "version": "0"}
        }))
    }

    // ── §7.4 anti-pattern regressions ────────────────────────────────────────

    /// AP-P2: a SELECT mixing catalog, read-through and the tool_calls log —
    /// in one statement — must issue zero `tools/call`. The invocation path
    /// is INSERT-only (§4.7); the log SELECT does no network I/O at all.
    #[pgrx::pg_test]
    fn ap_p2_a_cross_table_select_issues_zero_tools_call() {
        cache::clear_all();
        let replies = map(vec![
            ("initialize", init_reply("ap-p2")),
            (
                TOOLS_LIST,
                Reply::Result(json!({"tools": [{"name": "echo"}]})),
            ),
            (
                "resources/list",
                Reply::Result(json!({"resources": [{"uri": "file:///a"}]})),
            ),
            (
                "resources/read",
                Reply::Result(json!({"contents": [
                    {"uri": "file:///a", "mimeType": "text/plain", "text": "alpha"}
                ]})),
            ),
        ]);
        let stub = StubServer::start(replies, false);
        make_server("e2_p2", &stub.url(), "");

        // One statement, three tables, three fetch strategies.
        let row = Spi::get_three::<i64, i64, i64>(
            "SELECT (SELECT count(*) FROM e2_p2_s.tools),
                    (SELECT count(*) FROM e2_p2_s.resource_contents
                      WHERE uri = 'file:///a'),
                    (SELECT count(*) FROM e2_p2_s.tool_calls)",
        )
        .unwrap();
        assert_eq!(row, (Some(1), Some(1), Some(0)));

        assert_eq!(
            stub.hits("tools/call"),
            0,
            "SELECT must never invoke (AP-P2)"
        );
    }

    /// AP-P1, dynamic half: no catalog table accepts INSERT — the extension's
    /// only writable surface is `tool_calls` (the audit/invocation path). The
    /// structural half (no `INSERT INTO` in crate sources outside that path)
    /// is asserted by `run-tests.sh`.
    #[pgrx::pg_test]
    fn ap_p1_catalog_tables_refuse_insert() {
        cache::clear_all();
        let replies = map(vec![
            ("initialize", init_reply("ap-p1")),
            (TOOLS_LIST, Reply::Result(json!({"tools": []}))),
        ]);
        let stub = StubServer::start(replies, false);
        make_server("e2_p1", &stub.url(), "");

        for table in [
            "server",
            "tools",
            "prompts",
            "prompt_arguments",
            "resources",
            "resource_templates",
            "resource_contents",
            "prompt_messages",
            "completions",
        ] {
            expect_sqlstate(
                &format!("INSERT INTO e2_p1_s.{table} DEFAULT VALUES"),
                "0A000",
                Some("tool_calls"),
            );
        }
        assert_eq!(stub.hits("tools/call"), 0);
    }

    /// AP-P4 (discovery oracle): a tool hidden from role B's principal is
    /// absent from B's `tools`, and invoking it by name returns the server's
    /// own invalid-params error — the same error an absent tool returns. The
    /// extension adds no "you lack permission" distinction of its own.
    #[pgrx::pg_test]
    fn ap_p4_a_hidden_tool_is_absent_and_invoking_it_has_no_permission_distinction() {
        cache::clear_all();
        // tools/list is per-token (B's principal cannot discover `hidden`);
        // tools/call answers per tool name, and `hidden` gets the SAME
        // invalid_params the unknown tools get.
        let tools_by_token = |hidden: bool| {
            let mut tools = vec![json!({"name": "echo"})];
            if hidden {
                tools.push(json!({"name": "hidden"}));
            }
            Reply::Result(json!({ "tools": tools }))
        };
        let mut by_token = HashMap::new();
        by_token.insert("tok_admin".to_string(), tools_by_token(true));
        by_token.insert("".to_string(), tools_by_token(false));

        let route: Arc<dyn Fn(&str, &Value) -> Reply + Send + Sync> =
            Arc::new(|method, params| match method {
                "tools/call" => {
                    let name = params
                        .pointer("/name")
                        .and_then(Value::as_str)
                        .unwrap_or("");
                    match name {
                        // `hidden` and a genuinely-absent tool get the same
                        // server-authored invalid_params: the server, not the
                        // extension, decides what an unauthorized caller sees.
                        "echo" => Reply::Result(json!({
                            "content": [{"type": "text", "text": "ok"}]
                        })),
                        _ => Reply::Error(-32602, "invalid arguments".to_string()),
                    }
                }
                _ => Reply::Error(-32601, "unexpected".to_string()),
            });

        let replies = map(vec![
            ("initialize", init_reply("ap-p4")),
            (TOOLS_LIST, Reply::ByToken(by_token)),
            ("tools/call", Reply::Route(route)),
        ]);
        let stub = StubServer::start(replies, false);

        // The limited principal: its token does not match the admin entry,
        // so the stub's ByToken "" default applies (no `hidden` in the list).
        Spi::run("CREATE SCHEMA e2_p4_secrets").unwrap();
        Spi::run("CREATE TABLE e2_p4_secrets.tokens (role text, token text)").unwrap();
        Spi::run("INSERT INTO e2_p4_secrets.tokens VALUES ('e2_p4_role', 'tok_limited')").unwrap();
        Spi::run("CREATE ROLE e2_p4_role NOLOGIN").unwrap();
        Spi::run("GRANT USAGE ON SCHEMA e2_p4_secrets TO e2_p4_role").unwrap();
        Spi::run("GRANT SELECT ON e2_p4_secrets.tokens TO e2_p4_role").unwrap();

        Spi::run(&format!(
            "CREATE SERVER e2_p4_srv FOREIGN DATA WRAPPER mcp_fdw
               OPTIONS (url '{}', auth 'bearer', timeout_ms '8000')",
            stub.url()
        ))
        .unwrap();
        Spi::run(
            "CREATE USER MAPPING FOR e2_p4_role SERVER e2_p4_srv
               OPTIONS (token_secret 'e2_p4_secrets.tokens')",
        )
        .unwrap();
        Spi::run("CREATE SCHEMA e2_p4_s").unwrap();
        Spi::run("IMPORT FOREIGN SCHEMA mcp FROM SERVER e2_p4_srv INTO e2_p4_s").unwrap();
        Spi::run("GRANT USAGE ON SCHEMA e2_p4_s TO e2_p4_role").unwrap();
        Spi::run("GRANT SELECT ON ALL TABLES IN SCHEMA e2_p4_s TO e2_p4_role").unwrap();
        Spi::run("GRANT INSERT ON e2_p4_s.tool_calls TO e2_p4_role").unwrap();

        Spi::run("SET ROLE e2_p4_role").unwrap();

        // Discovery: the hidden tool is simply not in B's catalog.
        assert_eq!(
            count("SELECT count(*) FROM e2_p4_s.tools WHERE name = 'hidden'"),
            0
        );
        assert_eq!(count("SELECT count(*) FROM e2_p4_s.tools"), 1);

        // Invocation by name: the server's own invalid_params, relayed. No
        // permission-flavored wording enters from the extension side.
        expect_sqlstate(
            "INSERT INTO e2_p4_s.tool_calls (tool) VALUES ('hidden')",
            "22023",
            Some("invalid arguments"),
        );
        // ...and the same is true of a tool that does not exist at all.
        expect_sqlstate(
            "INSERT INTO e2_p4_s.tool_calls (tool) VALUES ('also_absent')",
            "22023",
            Some("invalid arguments"),
        );

        Spi::run("RESET ROLE").unwrap();
    }

    // ── §7.5 performance ─────────────────────────────────────────────────────

    /// Catalog double-scan: two `SELECT * FROM tools` in one session cost one
    /// `tools/list` (§4.10 cache hit). Wall time is emitted as a NOTICE for
    /// the runner log.
    #[pgrx::pg_test]
    fn perf_catalog_double_scan_costs_one_tools_list() {
        cache::clear_all();
        let replies = map(vec![
            ("initialize", init_reply("perf-cat")),
            (
                TOOLS_LIST,
                Reply::Result(json!({"tools": [
                    {"name": "echo"}, {"name": "explode"}
                ]})),
            ),
        ]);
        let stub = StubServer::start(replies, false);
        make_server("e2_perf_cat", &stub.url(), "");

        let t0 = std::time::Instant::now();
        assert_eq!(count("SELECT count(*) FROM e2_perf_cat_s.tools"), 2);
        let cold = t0.elapsed();

        let t1 = std::time::Instant::now();
        assert_eq!(count("SELECT count(*) FROM e2_perf_cat_s.tools"), 2);
        let warm = t1.elapsed();

        assert_eq!(stub.hits(TOOLS_LIST), 1, "second scan is a cache hit");
        pgrx::notice!(
            "perf catalog: cold scan {:?}, cached scan {:?} (1 tools/list total)",
            cold,
            warm
        );
    }

    /// A 100-row `INSERT … SELECT` performs exactly 100 sequential
    /// `tools/call` requests (one per row, row order), with total wall time
    /// under 100 × the §7.5 S4 p99 budget (PRD-6: 250ms → 25s ceiling; the
    /// local stub runs orders of magnitude under it).
    #[pgrx::pg_test]
    fn perf_100_row_insert_select_is_exactly_100_sequential_tools_call() {
        cache::clear_all();
        let route: Arc<dyn Fn(&str, &Value) -> Reply + Send + Sync> =
            Arc::new(|method, _params| match method {
                "tools/call" => Reply::Result(json!({
                    "content": [{"type": "text", "text": "ok"}],
                    "structuredContent": {}
                })),
                _ => Reply::Error(-32601, "unexpected".to_string()),
            });
        let replies = map(vec![
            ("initialize", init_reply("perf-100")),
            ("tools/call", Reply::Route(route)),
        ]);
        let stub = StubServer::start(replies, false);
        make_server("e2_perf_100", &stub.url(), "");

        let t0 = std::time::Instant::now();
        Spi::run(
            "INSERT INTO e2_perf_100_s.tool_calls (tool)
             SELECT 'echo' FROM generate_series(1, 100)",
        )
        .unwrap();
        let elapsed = t0.elapsed();

        assert_eq!(
            stub.hits("tools/call"),
            100,
            "exactly one tools/call per inserted row"
        );
        // The in-memory log holds every call (1000-entry cap, §4.7).
        assert_eq!(count("SELECT count(*) FROM e2_perf_100_s.tool_calls"), 100);

        let ceiling = std::time::Duration::from_millis(100 * 250);
        assert!(
            elapsed < ceiling,
            "100 sequential calls took {elapsed:?}, over the 100 × 250ms p99 budget"
        );
        pgrx::notice!(
            "perf tool_calls: 100 sequential tools/call in {:?} (budget {:?})",
            elapsed,
            ceiling
        );
    }

    // ── AC-7.8 / AC-7.10 / AC-7.11 ───────────────────────────────────────────

    /// AC-7.1 in harness form: `SELECT count(*) FROM mcp.tools` equals the
    /// fixture's direct `tools/list` length as the same principal. Also the
    /// `server`-table parity the tracks asked to see: its `instructions`
    /// slice behaves like any §4.10 catalog slice — identical on a second
    /// scan, fetched once per TTL period, never re-handshaking.
    #[pgrx::pg_test]
    fn ac_7_1_tools_count_parity_and_the_initialize_slice_caches() {
        cache::clear_all();
        const FIXTURE_TOOLS: usize = 3;
        let instructions = "be excellent to each other";
        let replies = map(vec![
            (
                "initialize",
                Reply::Result(json!({
                    "protocolVersion": "2025-11-25",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "parity", "version": "1"},
                    "instructions": instructions
                })),
            ),
            (
                TOOLS_LIST,
                Reply::Result(json!({"tools": [
                    {"name": "t1"}, {"name": "t2"}, {"name": "t3"}
                ]})),
            ),
        ]);
        let stub = StubServer::start(replies, false);
        make_server("e2_parity", &stub.url(), "");

        assert_eq!(
            count("SELECT count(*) FROM e2_parity_s.tools"),
            FIXTURE_TOOLS as i64,
            "mcp.tools row count == direct tools/list length"
        );

        let first: Option<String> =
            Spi::get_one("SELECT instructions FROM e2_parity_s.server").unwrap();
        let second: Option<String> =
            Spi::get_one("SELECT instructions FROM e2_parity_s.server").unwrap();
        assert_eq!(first.as_deref(), Some(instructions));
        assert_eq!(first, second, "the initialize slice serves scan 2");
        assert_eq!(
            stub.hits("initialize"),
            2,
            "one handshake + one cached slice fetch across two server scans"
        );
        assert_eq!(stub.hits(TOOLS_LIST), 1);
    }

    /// AC-7.8: two roles, two USER MAPPINGs, one foreign server — different
    /// row counts in `mcp.tools` (the server answers per principal token).
    #[pgrx::pg_test]
    fn ac_7_8_two_roles_two_mappings_different_row_counts() {
        cache::clear_all();
        let mut by_token = HashMap::new();
        by_token.insert(
            "tok_a".to_string(),
            Reply::Result(json!({"tools": [
                {"name": "a_one"}, {"name": "a_two"}
            ]})),
        );
        by_token.insert(
            "".to_string(),
            Reply::Result(json!({"tools": [{"name": "b_one"}]})),
        );
        let replies = map(vec![
            ("initialize", init_reply("ac-7-8")),
            (TOOLS_LIST, Reply::ByToken(by_token)),
        ]);
        let stub = StubServer::start(replies, false);

        Spi::run("CREATE SCHEMA e2_78_secrets").unwrap();
        Spi::run("CREATE TABLE e2_78_secrets.tokens (role text, token text)").unwrap();
        Spi::run(
            "INSERT INTO e2_78_secrets.tokens VALUES ('e2_78_a', 'tok_a'), ('e2_78_b', 'tok_b')",
        )
        .unwrap();
        for role in ["e2_78_a", "e2_78_b"] {
            Spi::run(&format!("CREATE ROLE {role} NOLOGIN")).unwrap();
            Spi::run(&format!("GRANT USAGE ON SCHEMA e2_78_secrets TO {role}")).unwrap();
            Spi::run(&format!("GRANT SELECT ON e2_78_secrets.tokens TO {role}")).unwrap();
        }

        Spi::run(&format!(
            "CREATE SERVER e2_78_srv FOREIGN DATA WRAPPER mcp_fdw
               OPTIONS (url '{}', auth 'bearer', timeout_ms '8000')",
            stub.url()
        ))
        .unwrap();
        for role in ["e2_78_a", "e2_78_b"] {
            Spi::run(&format!(
                "CREATE USER MAPPING FOR {role} SERVER e2_78_srv
                   OPTIONS (token_secret 'e2_78_secrets.tokens')"
            ))
            .unwrap();
        }
        Spi::run("CREATE SCHEMA e2_78_s").unwrap();
        Spi::run("IMPORT FOREIGN SCHEMA mcp FROM SERVER e2_78_srv INTO e2_78_s").unwrap();
        for role in ["e2_78_a", "e2_78_b"] {
            Spi::run(&format!("GRANT USAGE ON SCHEMA e2_78_s TO {role}")).unwrap();
            Spi::run("GRANT SELECT ON ALL TABLES IN SCHEMA e2_78_s TO e2_78_a").unwrap();
            Spi::run("GRANT SELECT ON ALL TABLES IN SCHEMA e2_78_s TO e2_78_b").unwrap();
        }

        Spi::run("SET ROLE e2_78_a").unwrap();
        assert_eq!(count("SELECT count(*) FROM e2_78_s.tools"), 2);
        Spi::run("SET ROLE e2_78_b").unwrap();
        assert_eq!(count("SELECT count(*) FROM e2_78_s.tools"), 1);
        assert_eq!(stub.hits(TOOLS_LIST), 2, "one tools/list per principal");
        Spi::run("RESET ROLE").unwrap();
    }

    /// AC-7.10: EXPLAIN (VERBOSE) over a read-through table shows the `uri`
    /// qual as pushed down — absent from the local re-check Filter — and
    /// never leaks the endpoint or token into the plan text.
    #[pgrx::pg_test]
    fn ac_7_10_explain_verbose_shows_pushed_qual_and_no_token() {
        cache::clear_all();
        let replies = map(vec![
            ("initialize", init_reply("ac-7-10")),
            (TOOLS_LIST, Reply::Result(json!({"tools": []}))),
        ]);
        let stub = StubServer::start(replies, false);
        make_server("e2_710", &stub.url(), "");

        // EXPLAIN ONLY: the handler never runs (no network I/O at all). The
        // plan is captured in full through a plpgsql wrapper — a bare
        // `EXPLAIN` over SPI surfaces one row per line and we want to assert
        // against all of them.
        Spi::run(
            "CREATE FUNCTION pg_temp.e2_710_plan() RETURNS SETOF text LANGUAGE plpgsql AS $fn$
               BEGIN
                 RETURN QUERY EXPLAIN (VERBOSE)
                   SELECT * FROM e2_710_s.resource_contents WHERE uri = 'x';
               END $fn$;",
        )
        .unwrap();
        let plan = Spi::get_one::<String>(
            "SELECT string_agg(line, E'\\n') FROM pg_temp.e2_710_plan() AS line",
        )
        .unwrap()
        .unwrap_or_default();

        assert!(plan.contains("Foreign Scan"), "plan text:\n{plan}");
        assert!(
            !plan.contains("Filter:"),
            "the uri qual was not left for local re-check:\n{plan}"
        );
        for secret in ["127.0.0.1", "token", "Bearer"] {
            assert!(
                !plan
                    .to_ascii_lowercase()
                    .contains(&secret.to_ascii_lowercase()),
                "plan leaks `{secret}`:\n{plan}"
            );
        }
    }

    /// AC-7.11: the server dying mid-scan (here: dropping the connection
    /// between pagination pages) yields `08006` on that statement, and a
    /// later statement succeeds without operator intervention.
    #[pgrx::pg_test]
    fn ac_7_11_kill_mid_scan_yields_08006_then_recovers() {
        cache::clear_all();
        let replies = map(vec![
            ("initialize", init_reply("ac-7-11")),
            (
                TOOLS_LIST,
                Reply::Sequence(vec![
                    // Page one arrives, announces a next cursor…
                    Reply::Result(json!({
                        "tools": [{"name": "page_one"}],
                        "nextCursor": "p2"
                    })),
                    // …then the server dies mid-scan.
                    Reply::Disconnect,
                    // …and comes back.
                    Reply::Result(json!({
                        "tools": [{"name": "page_one"}, {"name": "page_two"}]
                    })),
                ]),
            ),
        ]);
        let stub = StubServer::start(replies, false);
        make_server("e2_711", &stub.url(), "");

        expect_sqlstate("SELECT count(*) FROM e2_711_s.tools", "08006", None);
        // The next statement succeeds — no refresh, no re-CREATE, nothing.
        assert_eq!(count("SELECT count(*) FROM e2_711_s.tools"), 2);
    }

    // ── AC-7.13 / AC-7.14: the engine convention ─────────────────────────────
    //
    // Against the in-crate stub serving the engine's `<upstream>.<tool>`
    // namespacing; see the module docs for why this is the full extension-side
    // contract (the live-engine run is PRD-10's).

    /// The engine fixture: two healthy upstreams' tools plus one
    /// engine-local tool, over the `<upstream>.<tool>` convention. The
    /// prefixes are parameterized because the import derives schema names
    /// from them and every probe shares one database.
    fn engine_stub(prefix_a: &str, prefix_b: &str) -> StubServer {
        let tools = json!({"tools": [
            {"name": format!("{prefix_a}.echo")},
            {"name": format!("{prefix_a}.ping")},
            {"name": format!("{prefix_b}.add")},
            {"name": "engine_status"}
        ]});
        let replies = map(vec![
            ("initialize", init_reply("engine")),
            (TOOLS_LIST, Reply::Result(tools)),
        ]);
        StubServer::start(replies, false)
    }

    /// AC-7.13: `all_upstreams 'true'` against a two-upstream engine creates
    /// one schema per upstream plus the engine's own; each upstream schema's
    /// `tools` carries that upstream's tools with the prefix stripped.
    #[pgrx::pg_test]
    fn ac_7_13_all_upstreams_import_creates_per_upstream_schemas_with_unprefixed_names() {
        cache::clear_all();
        let stub = engine_stub("alpha", "beta");
        Spi::run(&format!(
            "CREATE SERVER e2_eng FOREIGN DATA WRAPPER mcp_fdw
               OPTIONS (url '{}', auth 'none', timeout_ms '8000')",
            stub.url()
        ))
        .unwrap();
        Spi::run("CREATE SCHEMA e2_eng_local").unwrap();

        let created = Spi::get_one::<i32>(
            "SELECT mcp.import('e2_eng', 'e2_eng_local', '{\"all_upstreams\": true}')",
        )
        .unwrap();
        // 2 × (1 CREATE SCHEMA + 8 federated tables) + the engine's own 10.
        assert_eq!(created, Some(28));

        // Three schemas: two upstreams plus the engine's own.
        assert_eq!(
            count(
                "SELECT count(*) FROM pg_namespace
                  WHERE nspname IN ('alpha', 'beta', 'e2_eng_local')"
            ),
            3
        );

        // Each upstream's tools, un-prefixed.
        let names = |schema: &str| -> Vec<String> {
            Spi::get_one::<String>(&format!(
                "SELECT string_agg(name, ',' ORDER BY name) FROM {schema}.tools"
            ))
            .unwrap()
            .unwrap()
            .split(',')
            .map(str::to_string)
            .collect()
        };
        assert_eq!(names("alpha"), ["echo", "ping"]);
        assert_eq!(names("beta"), ["add"]);

        // Engine-local tables are not duplicated into upstream schemas.
        assert_eq!(
            count(
                "SELECT count(*) FROM pg_class c
                     JOIN pg_namespace n ON n.oid = c.relnamespace
                    WHERE n.nspname = 'alpha' AND c.relname IN ('server', 'tool_calls')"
            ),
            0
        );
    }

    /// AC-7.14: a `SELECT` on the engine's catalog returns the union of its
    /// upstreams' tools, **prefixed**, and a down upstream contributes zero
    /// rows without failing the scan (PRD-11 D5).
    ///
    /// Two faces, per §4.11: a *default* import reads the fully-qualified
    /// union through unscoped foreign tables, while the `all_upstreams`
    /// layout's engine-local schema (`upstream ''`) carries only the
    /// engine-local tools. A `down` upstream is simply absent from the
    /// union — its slice table scans as zero rows, not an error.
    #[pgrx::pg_test]
    fn ac_7_14_engine_tools_is_the_prefixed_union_and_a_down_upstream_scans_empty() {
        cache::clear_all();
        // Distinct prefixes: the all_upstreams import below creates schemas
        // named for them, and every probe shares one database.
        let stub = engine_stub("gamma", "delta");
        Spi::run(&format!(
            "CREATE SERVER e2_eng2 FOREIGN DATA WRAPPER mcp_fdw
               OPTIONS (url '{}', auth 'none', timeout_ms '8000')",
            stub.url()
        ))
        .unwrap();

        // Default import: unscoped tables over the engine = prefixed union.
        Spi::run("CREATE SCHEMA e2_eng2_union").unwrap();
        Spi::run("SELECT mcp.import('e2_eng2', 'e2_eng2_union')").unwrap();
        let names: Vec<String> = Spi::get_one::<String>(
            "SELECT string_agg(name, ',' ORDER BY name) FROM e2_eng2_union.tools",
        )
        .unwrap()
        .unwrap()
        .split(',')
        .map(str::to_string)
        .collect();
        assert_eq!(
            names,
            ["delta.add", "engine_status", "gamma.echo", "gamma.ping"]
        );

        // all_upstreams layout: the engine-local schema's own `tools` holds
        // only the engine-local tools (upstream '' slice).
        Spi::run("CREATE SCHEMA e2_eng2_local").unwrap();
        Spi::run("SELECT mcp.import('e2_eng2', 'e2_eng2_local', '{\"all_upstreams\": true}')")
            .unwrap();
        let local: Vec<String> = Spi::get_one::<String>(
            "SELECT string_agg(name, ',' ORDER BY name) FROM e2_eng2_local.tools",
        )
        .unwrap()
        .unwrap()
        .split(',')
        .map(str::to_string)
        .collect();
        assert_eq!(local, ["engine_status"]);

        // A `down` upstream's slice table (the way an earlier import against
        // a healthy engine would have left it) scans as zero rows — the
        // union no longer carries any `down.` names, and that is not an error.
        Spi::run("CREATE SCHEMA e2_eng2_down").unwrap();
        Spi::run(
            "CREATE FOREIGN TABLE e2_eng2_down.tools (name text)
               SERVER e2_eng2 OPTIONS (upstream 'down')",
        )
        .unwrap();
        assert_eq!(count("SELECT count(*) FROM e2_eng2_down.tools"), 0);
    }

    /// Default-import safety: `all_upstreams 'true'` against a server with NO
    /// prefixed tools creates only the engine's own schema — nothing is
    /// created implicitly (FR-7.19 / Q6a).
    #[pgrx::pg_test]
    fn import_all_upstreams_without_prefixed_tools_creates_nothing_implicit() {
        cache::clear_all();
        let replies = map(vec![
            ("initialize", init_reply("no-upstreams")),
            (
                TOOLS_LIST,
                Reply::Result(json!({"tools": [{"name": "plain_tool"}]})),
            ),
        ]);
        let stub = StubServer::start(replies, false);
        Spi::run(&format!(
            "CREATE SERVER e2_eng3 FOREIGN DATA WRAPPER mcp_fdw
               OPTIONS (url '{}', auth 'none', timeout_ms '8000')",
            stub.url()
        ))
        .unwrap();
        Spi::run("CREATE SCHEMA e2_eng3_local").unwrap();

        let created = Spi::get_one::<i32>(
            "SELECT mcp.import('e2_eng3', 'e2_eng3_local', '{\"all_upstreams\": true}')",
        )
        .unwrap();
        assert_eq!(created, Some(10), "only the engine's own tables");
        assert_eq!(
            count("SELECT count(*) FROM pg_namespace WHERE nspname = 'e2_eng3_local'"),
            1
        );
    }
}
