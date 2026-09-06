//! The `mcp.*` SQL entry points (PRD-6 §4.6).
//!
//! All are `VOLATILE` and `PARALLEL UNSAFE`: they perform network I/O and must
//! not be pushed into parallel workers (§9 Q4 keeps `UNSAFE` for 0.4.0).

use crate::client;
use crate::codegen;
use crate::errors::McpError;
use crate::import::{self, ImportOptions, TableFilter};
use crate::options::{ServerOptions, UserMappingOptions};
use crate::session::{self, params_object, split_validator_options};
use pgrx::pg_sys::Oid;
use pgrx::prelude::*;
use pgrx::JsonB;
use serde_json::{json, Value};

/// `on_error` accepts exactly `'raise'` (default) and `'return'` (FR-6.16).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum OnError {
    Raise,
    Return,
}

impl OnError {
    fn parse(raw: &str) -> OnError {
        match raw {
            "raise" => OnError::Raise,
            "return" => OnError::Return,
            other => McpError::InvalidOption(format!(
                "invalid value for on_error: \"{other}\" (expected 'raise' or 'return')"
            ))
            .raise(),
        }
    }
}

/// One `tools/call`, honouring `on_error`.
fn call_tool_inner(server: &str, tool: &str, args: Option<JsonB>, on_error: &str) -> Value {
    let on_error = OnError::parse(on_error);
    let arguments = params_object(args.map(|a| a.0));

    let params = json!({ "name": tool, "arguments": arguments });
    let result = request(server, "tools/call", params);

    if client::is_error_result(&result) && on_error == OnError::Raise {
        // ADR-003: a *function* raises on isError by default; a table never
        // does (PRD-7 §4.7). The tool's own text is the message.
        let detail = client::text_content(&result)
            .unwrap_or_else(|| format!("tool \"{tool}\" returned an error result"));
        McpError::ToolError(detail).raise();
    }

    result
}

/// Shared request path: resolve the server + credential, then run on the cached
/// session. Any `McpError` becomes an `ereport(ERROR)` with its SQLSTATE.
fn request(server: &str, method: &str, params: Value) -> Value {
    let resolved = match session::resolve(server) {
        Ok(r) => r,
        Err(e) => e.raise(),
    };

    let outcome = session::with_session(&resolved, |session, transport| {
        session.request(method, params, transport)
    });

    match outcome {
        Ok(value) => value,
        Err(e) => e.raise(),
    }
}

/// The effective `tools/list` for the calling principal (D1/D2), fetched
/// fresh — generation and per-tool import always re-read; they never serve a
/// cached schema (AP-P7).
fn fetch_tools_fresh(server: &str) -> Vec<Value> {
    let resolved = match session::resolve(server) {
        Ok(r) => r,
        Err(e) => e.raise(),
    };
    let outcome = session::with_session(&resolved, |session, transport| {
        client::list_all(session, "tools/list", "tools", json!({}), transport)
    });
    match outcome {
        Ok(items) => items,
        Err(e) => e.raise(),
    }
}

/// The engine's enabled upstreams, derived from its `tools/list` namespacing
/// convention (`<upstream>.<tool>`; ADR-007). Sorted and deduplicated. Only
/// used by `mcp.import` with `all_upstreams 'true'`.
fn discover_upstreams(server: &str) -> Vec<String> {
    let items = fetch_tools_fresh(server);
    let names = items
        .iter()
        .filter_map(|tool| tool.get("name"))
        .filter_map(Value::as_str);
    import::upstreams_from_tool_names(names)
}

/// Run the PRD-8 per-tool generation for `server`/`schema`: plan against a
/// fresh `tools/list`, execute the DDL through SPI in the caller's
/// transaction, and record every created object in `mcp.generated` (§4.6).
/// Warnings from the planner (FR-8.7's promotion list, skips) surface as
/// PostgreSQL WARNINGs.
fn generate_per_tool(
    server: &str,
    schema: &str,
    options: &ImportOptions,
) -> (usize, Vec<String>, usize) {
    let tools = fetch_tools_fresh(server);
    let (statements, plan) = match import::per_tool_plan(server, schema, &tools, options) {
        Ok(v) => v,
        Err(e) => e.raise(),
    };

    // D5: skips surface as warnings, never fail the batch; FR-8.7's
    // promotion warning rides the same channel.
    for warning in &plan.warnings {
        emit_warning(warning);
    }
    if !plan.skipped.is_empty() {
        emit_warning(&format!(
            "skipped {} tool(s) with unmappable schemas: {}",
            plan.skipped.len(),
            plan.skipped.join(", ")
        ));
    }

    // Per-upstream schemas come into existence on demand (FR-8.17); the
    // main target schema must already exist (ordinary CREATE permission
    // applies either way).
    if options.per_upstream_schema {
        for target in plan.tools.iter().map(|t| t.schema.as_str()).collect::<std::collections::HashSet<_>>() {
            if target != schema {
                if let Err(e) = Spi::run(&format!(
                    "CREATE SCHEMA IF NOT EXISTS {}",
                    crate::codegen::table::quote_ident(target)
                )) {
                    McpError::Internal(format!("CREATE SCHEMA failed: {e}")).raise();
                }
            }
        }
    }

    let mut created = 0;
    for statement in &statements {
        if let Err(e) = Spi::run(statement) {
            McpError::Internal(format!("per-tool DDL failed: {e}")).raise();
        }
        created += 1;
    }
    for tool in &plan.tools {
        for (kind, name) in owned_rows(tool) {
            if let Err(e) = codegen::registry::record(
                server,
                &codegen::registry::OwnedObject {
                    kind: kind.to_string(),
                    name,
                    schema: tool.schema.clone(),
                    tool: tool.tool_name.clone(),
                },
            ) {
                e.raise();
            }
        }
    }
    (plan.tools.len(), plan.skipped, created)
}

fn emit_warning(message: &str) {
    ereport!(
        PgLogLevel::WARNING,
        PgSqlErrorCode::ERRCODE_SUCCESSFUL_COMPLETION,
        message.to_string()
    );
}

/// The `(kind, name)` rows a planned tool owns in `mcp.generated`, in
/// generation order (table, function, view — drops reverse it).
fn owned_rows(tool: &codegen::PlannedTool) -> Vec<(&'static str, String)> {
    let mut rows = vec![(
        codegen::registry::KIND_TABLE,
        codegen::table::table_name(tool),
    )];
    rows.push((
        codegen::registry::KIND_FUNCTION,
        tool.sql_name.clone(),
    ));
    if codegen::view::create_view(tool).is_some() {
        rows.push((
            codegen::registry::KIND_VIEW,
            codegen::table::view_name(tool),
        ));
    }
    rows
}

// ── §4.6 SQL functions ───────────────────────────────────────────────────────

#[pg_schema]
mod mcp {
    use super::*;

    /// Invoke a tool. Returns the full `CallToolResult` as jsonb.
    ///
    /// Not `STRICT`: `args` and `on_error` carry defaults, and a NULL `args`
    /// means `{}` rather than a NULL result.
    #[pg_extern(volatile, parallel_unsafe)]
    fn call_tool(
        server: &str,
        tool: &str,
        args: default!(Option<JsonB>, "'{}'::jsonb"),
        on_error: default!(&str, "'raise'"),
    ) -> JsonB {
        JsonB(call_tool_inner(server, tool, args, on_error))
    }

    /// Concatenated text content of a tool result; NULL when the result carries
    /// no text content.
    #[pg_extern(volatile, parallel_unsafe)]
    fn call_tool_text(
        server: &str,
        tool: &str,
        args: default!(Option<JsonB>, "'{}'::jsonb"),
        on_error: default!(&str, "'raise'"),
    ) -> Option<String> {
        let result = call_tool_inner(server, tool, args, on_error);
        client::text_content(&result)
    }

    /// `prompts/get`.
    #[pg_extern(volatile, parallel_unsafe, strict)]
    fn get_prompt(
        server: &str,
        prompt: &str,
        args: default!(Option<JsonB>, "'{}'::jsonb"),
    ) -> JsonB {
        let arguments = params_object(args.map(|a| a.0));
        JsonB(request(
            server,
            "prompts/get",
            json!({ "name": prompt, "arguments": arguments }),
        ))
    }

    /// `resources/read`.
    #[pg_extern(volatile, parallel_unsafe, strict)]
    fn read_resource(server: &str, uri: &str) -> JsonB {
        JsonB(request(server, "resources/read", json!({ "uri": uri })))
    }

    /// `completion/complete`.
    #[pg_extern(volatile, parallel_unsafe, strict)]
    fn complete(server: &str, r#ref: JsonB, argument_name: &str, argument_value: &str) -> JsonB {
        JsonB(request(
            server,
            "completion/complete",
            json!({
                "ref": r#ref.0,
                "argument": { "name": argument_name, "value": argument_value }
            }),
        ))
    }

    /// Drop the cached session for this backend + foreign server (FR-6.13).
    /// An unknown server name raises `42704`.
    #[pg_extern(volatile, parallel_unsafe, strict)]
    fn refresh(server: &str) -> bool {
        let (server_oid, _) = match session::lookup_foreign_server(server) {
            Ok(v) => v,
            Err(e) => e.raise(),
        };
        session::drop_session(server_oid, session::current_user_oid());
        // PRD-7 §4.10: refresh drops the catalog cache along with the session.
        crate::cache::drop(server_oid, session::current_user_oid());
        // PRD-8 §4.6: refresh never regenerates (regeneration is explicit
        // DDL), but it tells the operator when generated objects exist so
        // re-running mcp.generate_functions stays their decision (FR-8.18).
        match codegen::registry::schemas_for(server) {
            Ok(schemas) if !schemas.is_empty() => ereport!(
                PgLogLevel::NOTICE,
                PgSqlErrorCode::ERRCODE_SUCCESSFUL_COMPLETION,
                format!(
                    "server \"{server}\" has generated per-tool objects in schema(s) {}; \
                     if its tools changed, re-run mcp.generate_functions",
                    schemas.join(", ")
                )
            ),
            _ => {}
        }
        // PRD-6 §4.4 step 4 / FR-6.13: `true` reports "the refresh happened",
        // not "a session was present" — a caller refreshing a cold backend has
        // still achieved the requested state.
        true
    }

    /// Programmatic `IMPORT FOREIGN SCHEMA` (ADR-003, PRD-7 §4.11). Shares the
    /// DDL projection with the FDW callback's `import_foreign_schema` and
    /// returns the count of objects created. The remote schema is fixed
    /// (`mcp`); the same import options as the SQL statement apply, with
    /// `all_upstreams 'true'` producing the FR-7.19 per-upstream engine
    /// layout. A failing CREATE propagates the ordinary Postgres error — the
    /// builder emits no `IF NOT EXISTS` and no `DROP` (§4.11 re-import
    /// safety); nothing is created implicitly beyond what it names.
    ///
    /// The DDL runs through SPI in the caller's transaction and permission
    /// context: `USAGE` on the server plus `CREATE` on the target schema(s) is
    /// enforced by Postgres itself, and a rollback discards everything the
    /// import created.
    #[pg_extern(volatile, parallel_unsafe, strict)]
    fn import(server: &str, schema: &str, opts: default!(Option<JsonB>, "'{}'::jsonb")) -> i32 {
        // An unknown server is 42704, consistent with every other entry point.
        if let Err(e) = session::lookup_foreign_server(server) {
            e.raise();
        }
        let options = match ImportOptions::parse(&opts.map(|o| o.0).unwrap_or(Value::Null)) {
            Ok(o) => o,
            Err(e) => e.raise(),
        };

        let statements = if options.all_upstreams {
            // FR-7.19: discover the enabled upstreams over the generic MCP
            // surface — the engine namespaces its union as `<upstream>.<tool>`
            // in `tools/list` (ADR-007).
            let upstreams = discover_upstreams(server);
            import::engine_statements(server, schema, &options, &upstreams)
        } else {
            import::statements_with(server, schema, &TableFilter::All, &options)
        };
        // FR-8.14: `per_tool 'true'` generates the §4.2-§4.4 per-tool objects
        // alongside the generic tables, with `mcp.generated` bookkeeping
        // (§4.6) so regeneration owns exactly what this import created.
        let per_tool_generated = if options.per_tool {
            let (count, _, _) = generate_per_tool(server, schema, &options);
            count
        } else {
            0
        };

        let mut created: i32 = 0;
        for statement in &statements {
            // A failing CREATE longjmps straight out of SPI with the real
            // PostgreSQL error (SQLSTATE intact); the internal-error mapping
            // below is only reachable for SPI harness failures.
            if let Err(e) = Spi::run(statement) {
                McpError::Internal(format!("import DDL failed: {e}")).raise();
            }
            created += 1;
        }
        created + per_tool_generated as i32
    }

    /// PRD-8 §4.6 (FR-8.12): generate (or regenerate) the per-tool objects
    /// for `server` into `schema`. Idempotent and destructive-in-scope: the
    /// objects this extension previously created in the target schema(s)
    /// (recorded in `mcp.generated`) are dropped `RESTRICT` and recreated
    /// from a *fresh* `tools/list` (D1 — regeneration re-reads, never
    /// patches). Returns `(generated, skipped, skipped_tools)`; a skipped
    /// tool never fails the batch (D5). Runs as the invoking role, over that
    /// role's `USER MAPPING` and its own effective tool list (D2, FR-8.16).
    ///
    /// Options mirror the import options (§4.6): `invoke_on_select`
    /// ('read_only' | 'all' | 'none'), `prefix`, `per_upstream_schema`,
    /// `cache_ttl_ms`. `per_tool` is accepted (and implied).
    #[pg_extern(volatile, parallel_unsafe, strict)]
    fn generate_functions(
        server: &str,
        schema: &str,
        opts: default!(Option<JsonB>, "'{}'::jsonb"),
    ) -> TableIterator<
        'static,
        (
            name!(generated, i32),
            name!(skipped, i32),
            name!(skipped_tools, Vec<Option<String>>),
        ),
    > {
        if let Err(e) = session::lookup_foreign_server(server) {
            e.raise();
        }
        let mut options = match ImportOptions::parse(&opts.map(|o| o.0).unwrap_or(Value::Null)) {
            Ok(o) => o,
            Err(e) => e.raise(),
        };
        options.per_tool = true;

        // Regeneration first: drop what this extension owns in every schema
        // it previously generated into for this server (the target schema,
        // plus any upstream schemas under per_upstream_schema). RESTRICT
        // failures propagate and abort the caller's transaction whole
        // (AC-8.11: nothing half-dropped).
        let mut drop_schemas = vec![schema.to_string()];
        match codegen::registry::schemas_for(server) {
            Ok(schemas) => {
                for s in schemas {
                    if options.per_upstream_schema && !drop_schemas.contains(&s) {
                        drop_schemas.push(s);
                    }
                }
            }
            Err(e) => e.raise(),
        }
        for target in &drop_schemas {
            if let Err(e) = codegen::registry::drop_owned(server, target) {
                e.raise();
            }
        }

        let (generated, skipped, _) = generate_per_tool(server, schema, &options);
        let skipped_tools: Vec<Option<String>> =
            skipped.iter().map(|s| Some(s.clone())).collect();
        TableIterator::once((generated as i32, skipped.len() as i32, skipped_tools))
    }

    // ── diagnostics used by the spike harness ────────────────────────────────

    /// How many `initialize` round trips the cached session for `server` has
    /// performed in this backend. NULL when no session is cached. Backs the
    /// FR-6.4 "exactly one initialize" assertion.
    #[pg_extern(volatile, parallel_unsafe, strict)]
    fn session_initialize_count(server: &str) -> Option<i32> {
        let (server_oid, _) = match session::lookup_foreign_server(server) {
            Ok(v) => v,
            Err(e) => e.raise(),
        };
        session::initialize_count(server_oid, session::current_user_oid()).map(|n| n as i32)
    }

    /// Number of MCP sessions cached in this backend.
    #[pg_extern(volatile, parallel_unsafe)]
    fn session_count() -> i32 {
        session::session_count() as i32
    }

    /// The negotiated protocol version and server info for the cached session.
    /// NULL when no session is cached.
    #[pg_extern(volatile, parallel_unsafe, strict)]
    fn session_info(server: &str) -> Option<JsonB> {
        let (server_oid, _) = match session::lookup_foreign_server(server) {
            Ok(v) => v,
            Err(e) => e.raise(),
        };
        session::with_cached_session(server_oid, session::current_user_oid(), |s| {
            JsonB(json!({
                "url": s.url,
                "protocolVersion": s.protocol_version,
                "serverInfo": s.server_info,
                "capabilities": s.capabilities,
                "hasSessionId": s.session_id.is_some(),
                "initializeCount": s.initialize_count,
            }))
        })
    }
}

/// The `mcp_fdw` validator itself, registered directly as a C function
/// (`mcp.mcp_fdw_validator(text[], oid) RETURNS void`). PostgreSQL invokes it
/// through `OidFunctionCall2` at `CREATE FOREIGN DATA WRAPPER`/`CREATE SERVER`/
/// `CREATE USER MAPPING` time, and that call path rejects a NULL result — so it
/// must be a C function (pgrx returns a non-null void Datum), never a
/// `RETURNS void` SQL-language wrapper (whose SELECTed void value is NULL).
#[pg_extern(name = "mcp_fdw_validator")]
fn mcp_fdw_validator(options: Vec<Option<String>>, catalog: Oid) {
    let parsed = split_validator_options(options);

    let outcome = match session::validator_catalog(catalog) {
        session::ValidatorCatalog::ForeignServer => ServerOptions::parse(&parsed).map(|_| ()),
        session::ValidatorCatalog::UserMapping => UserMappingOptions::parse(&parsed).map(|_| ()),
        session::ValidatorCatalog::ForeignDataWrapper => {
            // `CREATE FOREIGN DATA WRAPPER mcp_fdw` takes no options of its own.
            if parsed.is_empty() {
                Ok(())
            } else {
                Err(McpError::InvalidOption(format!(
                    "invalid option \"{}\" for the mcp_fdw foreign data wrapper (it takes none)",
                    parsed[0].0
                )))
            }
        }
        // Foreign tables and columns are PRD-7's surface.
        session::ValidatorCatalog::Other => Ok(()),
    };

    if let Err(e) = outcome {
        e.raise();
    }
}

#[cfg(any(test, feature = "pg_test"))]
#[pgrx::pg_schema]
mod tests {
    use super::*;
    use crate::tables;

    /// A loopback server with `auth 'none'`: no user mapping, and no network
    /// I/O unless a test deliberately forces it (port 1 refuses instantly).
    fn make_server(name: &str, url: &str) {
        Spi::run(&format!(
            "CREATE SERVER {name} FOREIGN DATA WRAPPER mcp_fdw
               OPTIONS (url '{url}', auth 'none', timeout_ms '1000')"
        ))
        .unwrap();
    }

    fn foreign_table_count(schema: &str) -> i64 {
        Spi::get_one::<i64>(&format!(
            "SELECT count(*) FROM pg_class c
               JOIN pg_namespace nsp ON nsp.oid = c.relnamespace
              WHERE nsp.nspname = '{schema}' AND c.relkind = 'f'"
        ))
        .unwrap()
        .unwrap()
    }

    /// Assert that `stmt` fails with SQLSTATE `want`. On this runner an
    /// fmgr-called function's error longjmps straight to PostgreSQL's error
    /// machinery and is NOT captured by `Spi::run(..).unwrap_err()`, so the
    /// statement runs inside a plpgsql `EXCEPTION` block instead: the SQLSTATE
    /// is compared in SQL, where nothing can escape. (Same harness as
    /// `fdw.rs`'s probes.)
    fn expect_sqlstate(stmt: &str, want: &str) {
        let sql = format!(
            r#"
            DO $probe$
            DECLARE got text;
            BEGIN
                BEGIN
                    EXECUTE $stmt${stmt}$stmt$;
                    RAISE EXCEPTION 'NO_ERROR_RAISED';
                EXCEPTION WHEN OTHERS THEN got := SQLSTATE;
                END;
                IF got IS DISTINCT FROM '{want}' THEN
                    RAISE EXCEPTION 'expected SQLSTATE {want}, got %', got;
                END IF;
            END
            $probe$;"#
        );
        Spi::run(&sql)
            .unwrap_or_else(|e| panic!("expect_sqlstate harness failed for {want}: {e:?}"));
    }

    #[pg_test]
    fn import_returns_the_count_and_creates_the_tables() {
        make_server("imp_srv", "http://127.0.0.1:1/mcp");
        Spi::run("CREATE SCHEMA imp_a").unwrap();

        let n = Spi::get_one::<i32>("SELECT mcp.import('imp_srv','imp_a')").unwrap();
        assert_eq!(n, Some(10));
        assert_eq!(foreign_table_count("imp_a"), 10);

        // The created tables are the registry's, column for column (the
        // `tools` probe also proves the foreign tables are usable).
        let cols = Spi::get_one::<i64>(
            "SELECT count(*) FROM information_schema.columns
              WHERE table_schema = 'imp_a' AND table_name = 'tools'",
        )
        .unwrap();
        let expected = tables::REGISTRY
            .iter()
            .find(|e| e.spec.name == "tools")
            .unwrap()
            .spec
            .columns
            .len() as i64;
        assert_eq!(cols, Some(expected));
    }

    /// PG18 regression probe: each returned List cell must survive until
    /// PostgreSQL consumes it (the callback pstrdup's; see `fdw.rs`). Two
    /// imports in one backend, then a third that *fails* mid-list, all without
    /// corrupting the strings Postgres reads back.
    #[pg_test]
    fn import_twice_in_one_backend_and_once_more_failing() {
        make_server("imp_twice", "http://127.0.0.1:1/mcp");
        Spi::run("CREATE SCHEMA imp_b1").unwrap();
        Spi::run("CREATE SCHEMA imp_b2").unwrap();

        assert_eq!(
            Spi::get_one::<i32>("SELECT mcp.import('imp_twice','imp_b1')").unwrap(),
            Some(10)
        );
        assert_eq!(
            Spi::get_one::<i32>("SELECT mcp.import('imp_twice','imp_b2')").unwrap(),
            Some(10)
        );
        assert_eq!(foreign_table_count("imp_b1"), 10);
        assert_eq!(foreign_table_count("imp_b2"), 10);

        // Re-import into an occupied schema: the plain CREATE fails in the
        // ordinary Postgres way (duplicate table, no DROP in the builder).
        expect_sqlstate("SELECT mcp.import('imp_twice','imp_b1')", "42P07");
    }

    #[pg_test]
    fn import_cache_ttl_option_is_visible_in_the_catalog() {
        make_server("imp_ttl", "http://127.0.0.1:1/mcp");
        Spi::run("CREATE SCHEMA imp_c").unwrap();
        let n =
            Spi::get_one::<i32>("SELECT mcp.import('imp_ttl','imp_c','{\"cache_ttl_ms\": 5000}')")
                .unwrap();
        assert_eq!(n, Some(10));

        let with_ttl = Spi::get_one::<i64>(
            "SELECT count(*) FROM pg_foreign_table ft
               JOIN pg_class c ON c.oid = ft.ftrelid
               JOIN pg_namespace nsp ON nsp.oid = c.relnamespace
              WHERE nsp.nspname = 'imp_c'
                AND ft.ftoptions @> ARRAY['cache_ttl_ms=5000']",
        )
        .unwrap();
        assert_eq!(with_ttl, Some(10));
    }

    #[pg_test]
    fn import_rejects_bad_options() {
        make_server("imp_bad", "http://127.0.0.1:1/mcp");
        Spi::run("CREATE SCHEMA imp_d").unwrap();

        expect_sqlstate(
            "SELECT mcp.import('imp_bad','imp_d','{\"cache_ttl_ms\": -1}')",
            "22023",
        );
        expect_sqlstate(
            "SELECT mcp.import('imp_bad','imp_d','{\"nope\": 1}')",
            "22023",
        );
        // A PRD-8 option is honored now: `per_tool` needs a reachable server
        // (the tools/list for D1), so against this dead endpoint it is 08006
        // — still nothing created implicitly. (The live per-tool import is
        // probed by the codegen module's SQL-level suite.)
        expect_sqlstate(
            "SELECT mcp.import('imp_bad','imp_d','{\"per_tool\": true}')",
            "08006",
        );

        // Nothing was created by any of the failed calls.
        assert_eq!(foreign_table_count("imp_d"), 0);
    }

    #[pg_test]
    fn import_unknown_server_raises_42704() {
        expect_sqlstate("SELECT mcp.import('nope','imp_e')", "42704");
    }

    /// FR-7.19's upstream discovery goes over the wire (the engine's
    /// `tools/list`); against a dead engine the import fails as a transport
    /// error (§4.9: `08006`) and creates nothing implicitly. The live-engine
    /// layout e2e (AC-7.13) is Track E's.
    #[pg_test]
    fn import_all_upstreams_needs_a_reachable_engine() {
        make_server("imp_engine", "http://127.0.0.1:1/mcp");
        Spi::run("CREATE SCHEMA imp_f").unwrap();

        expect_sqlstate(
            "SELECT mcp.import('imp_engine','imp_f','{\"all_upstreams\": true}')",
            "08006",
        );
        assert_eq!(foreign_table_count("imp_f"), 0, "nothing implicit");
    }
}
