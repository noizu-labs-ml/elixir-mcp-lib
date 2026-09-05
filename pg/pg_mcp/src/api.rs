//! The `mcp.*` SQL entry points (PRD-6 §4.6).
//!
//! All are `VOLATILE` and `PARALLEL UNSAFE`: they perform network I/O and must
//! not be pushed into parallel workers (§9 Q4 keeps `UNSAFE` for 0.4.0).

use crate::client;
use crate::errors::McpError;
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
        // PRD-6 §4.4 step 4 / FR-6.13: `true` reports "the refresh happened",
        // not "a session was present" — a caller refreshing a cold backend has
        // still achieved the requested state.
        true
    }

    /// Programmatic `IMPORT FOREIGN SCHEMA` (ADR-003). Declared here so the
    /// `mcp.*` surface is settled in one place; implemented in PRD-7 §4.11.
    /// FR-6.10: calling it before then raises `0A000`.
    #[pg_extern(volatile, parallel_unsafe, strict)]
    fn import(server: &str, schema: &str, opts: default!(Option<JsonB>, "'{}'::jsonb")) -> i32 {
        let _ = (server, schema, opts);
        McpError::NotImplemented(
            "mcp.import is declared in PRD-6 and implemented in PRD-7; \
             no catalog import is available in pg_mcp 0.1.0"
                .to_string(),
        )
        .raise()
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

// ── FDW handler + validator (FR-6.3) ─────────────────────────────────────────
//
// The SQL for these two is written by hand in lib.rs: `fdw_handler` and the
// `(text[], oid)` validator signature have no pgrx type mapping.

/// `mcp_fdw` handler. PRD-6 registers the FDW so `CREATE SERVER … FOREIGN DATA
/// WRAPPER mcp_fdw` and its option validation exist; the scan/modify routines
/// themselves arrive in PRD-7, so planning against a foreign table raises
/// `0A000` rather than crashing.
#[pg_guard]
#[no_mangle]
pub extern "C-unwind" fn mcp_fdw_handler(_fcinfo: pg_sys::FunctionCallInfo) -> pg_sys::Datum {
    McpError::NotImplemented(
        "pg_mcp 0.1.0 registers mcp_fdw for server and user-mapping options only; \
         foreign tables arrive in PRD-7"
            .to_string(),
    )
    .raise()
}

/// Postgres requires a `pg_finfo_<fn>` V1 record beside every C-exported
/// function; `#[pg_extern]` generates these for us, the hand-written handler
/// above carries its own.
#[no_mangle]
pub extern "C" fn pg_finfo_mcp_fdw_handler() -> &'static pg_sys::Pg_finfo_record {
    const V1: pg_sys::Pg_finfo_record = pg_sys::Pg_finfo_record { api_version: 1 };
    &V1
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
