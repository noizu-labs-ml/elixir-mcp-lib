//! `tool_calls` — invocation and the per-backend call log (PRD-7 §4.7, §4.8;
//! PRD-7 §6 step 7.5, Track C).
//!
//! Three behaviours, all against the frozen surface in `tables/mod.rs`:
//!
//! * **INSERT** (§4.7, FR-7.9/FR-7.10): exactly one `tools/call` per inserted
//!   row, in row order. Input honors only `tool` and `arguments` (default
//!   `{}`); every output column is filled in the returned tuple. The cardinal
//!   rule: `isError: true` is a *row* (`is_error = true`, the tool's own
//!   content, `error = NULL`), never an exception — a multi-row insert
//!   survives one failing tool. Protocol-level failures (`-32602`, `-32601`,
//!   transport) raise per §4.9, and `tool` NULL raises `23502`.
//! * **SELECT** (FR-7.11): this backend's in-memory log for this foreign
//!   server — newest first, capped at 1000 entries, *no network I/O*. `tool =`
//!   and `id =` quals filter the log (only quals Postgres actually hands the
//!   handler; `id` constants are not yet extracted by the frozen planner hook,
//!   so those quals stay local and Postgres re-checks them — same answer).
//! * **Audit** (§4.8, FR-7.13): with `audit_table 'schema.table'` set on the
//!   server, each completed call is SPI-inserted into that table in the same
//!   transaction as the foreign INSERT, so a rollback discards both. The
//!   table's shape is validated at first write (`42804` naming the offending
//!   column); the extension never creates the table.
//!
//! The log is keyed `(server OID, user OID)` — backend-local like the session
//! cache (ADR-004) — so two servers, or two roles, never see each other's
//! calls (`tool_calls_log_test`).
//!
//! `unsafe` appears only in the UUID generator's `pg_strong_random` call
//! (FR-6.1 keeps `pg_sys` out of the tables elsewhere; a bounded, audited
//! exception here avoids a new crate dependency).

use crate::errors::{McpError, McpResult};
use crate::quals::{Operator, Qual};
use crate::session;
use crate::tables::{
    Cell, ForeignTable, InsertRow, ModifyContext, ModifySession, Row, ScanContext, ScanCursor,
    TableSpec,
};
use pgrx::pg_sys;
use pgrx::prelude::Spi;
use serde_json::{json, Value};
use std::cell::RefCell;
use std::collections::{HashMap, VecDeque};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

// ── the call log ─────────────────────────────────────────────────────────────

/// §4.7: the in-memory log holds at most this many completed calls per
/// `(server, user)`, newest first on read.
pub const LOG_CAP: usize = 1000;

/// PostgreSQL's epoch (2000-01-01) in Unix microseconds, for `called_at`.
const PG_EPOCH_UNIX_MICROS: i64 = 946_684_800_000_000;

/// One completed `tools/call`: what SELECT on `tool_calls` returns (§4.7) and
/// what the audit table stores (§4.8).
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct CallRecord {
    id: [u8; 16],
    tool: String,
    arguments: Value,
    content: Option<Value>,
    structured: Option<Value>,
    is_error: bool,
    /// Always `None` for a completed call: FR-7.10 makes tool failures rows
    /// and everything else raises before a record is built.
    error: Option<Value>,
    /// Microseconds since the PostgreSQL epoch.
    called_at: i64,
    duration_ms: i32,
}

thread_local! {
    /// Backend-local, per-`(server OID, user OID)` call log. Newest at the
    /// *back* (append on completion); reads reverse.
    static CALL_LOGS: RefCell<HashMap<session::SessionKey, VecDeque<CallRecord>>> =
        RefCell::new(HashMap::new());
}

/// Microseconds since the PostgreSQL epoch, right now.
fn now_pg_micros() -> i64 {
    let unix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_micros() as i64)
        .unwrap_or(0);
    unix - PG_EPOCH_UNIX_MICROS
}

/// RFC-4122 v4 UUID from PostgreSQL's strong random source.
fn uuid_v4() -> [u8; 16] {
    let mut bytes = [0u8; 16];
    let ok = unsafe { pg_sys::pg_strong_random(bytes.as_mut_ptr().cast(), bytes.len()) };
    if !ok {
        // pg_strong_random failing means the platform entropy source is
        // broken; a low-entropy id then trades audit precision for not
        // failing the caller's statement. Version/variant bits still mark it.
        let now = now_pg_micros() as u128;
        bytes[..16].copy_from_slice(&now.to_be_bytes());
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC-4122 variant
    bytes
}

fn uuid_hex(bytes: &[u8; 16]) -> String {
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

/// Append a completed call to this backend's log for `key`, enforcing the
/// 1000-entry cap (oldest dropped). Shared by the INSERT path and the log
/// unit tests.
pub(crate) fn record(key: session::SessionKey, rec: CallRecord) {
    CALL_LOGS.with(|logs| {
        let mut logs = logs.borrow_mut();
        let log = logs.entry(key).or_default();
        log.push_back(rec);
        while log.len() > LOG_CAP {
            log.pop_front();
        }
    });
}

/// Snapshot one server's log, newest first.
fn snapshot(key: session::SessionKey) -> Vec<CallRecord> {
    CALL_LOGS.with(|logs| {
        logs.borrow()
            .get(&key)
            .map(|log| log.iter().rev().cloned().collect())
            .unwrap_or_default()
    })
}

/// Test hooks: log length / clear, without going through a foreign insert.
#[cfg(any(test, feature = "pg_test"))]
pub(crate) fn log_len(key: session::SessionKey) -> usize {
    CALL_LOGS.with(|logs| logs.borrow().get(&key).map(|l| l.len()).unwrap_or(0))
}

#[cfg(any(test, feature = "pg_test"))]
pub(crate) fn clear_log(key: session::SessionKey) {
    CALL_LOGS.with(|logs| logs.borrow_mut().remove(&key));
}

// ── rows ─────────────────────────────────────────────────────────────────────

/// A record as a full-width `tool_calls` row (§4.7 column order).
fn row_from_record(spec: &'static TableSpec, rec: &CallRecord) -> Row {
    debug_assert_eq!(spec.arity(), 9, "tool_calls spec drift");
    vec![
        Some(Cell::Uuid(rec.id)),
        Some(Cell::Text(rec.tool.clone())),
        Some(Cell::Json(rec.arguments.clone())),
        rec.content.clone().map(Cell::Json),
        rec.structured.clone().map(Cell::Json),
        Some(Cell::Bool(rec.is_error)),
        rec.error.clone().map(Cell::Json),
        Some(Cell::TimestampTz(rec.called_at)),
        Some(Cell::Int4(rec.duration_ms)),
    ]
}

// ── SELECT: the log scan (no network I/O, FR-7.11 / AP-P2) ──────────────────

struct LogCursor {
    rows: std::vec::IntoIter<Row>,
}

impl ScanCursor for LogCursor {
    fn iter_scan(&mut self) -> McpResult<Option<Row>> {
        Ok(self.rows.next())
    }
}

/// Apply the pushed `tool` / `id` quals to one log entry. Only quals the
/// planner actually pushed arrive here; everything else is re-checked by
/// Postgres against the rows we return.
fn log_entry_matches(quals: &[Qual], rec: &CallRecord) -> bool {
    quals.iter().all(|q| {
        let candidate: Value = match q.field.as_str() {
            "tool" => Value::String(rec.tool.clone()),
            "id" => Value::String(uuid_hex(&rec.id)),
            _ => return true, // another column's qual is not ours to falsify
        };
        match q.operator {
            Operator::Equal => q.value == candidate,
            Operator::AnyEqual => q
                .value
                .as_array()
                .map(|items| items.contains(&candidate))
                .unwrap_or(false),
        }
    })
}

// ── INSERT: one tools/call per row (§4.7, FR-7.9/FR-7.10) ────────────────────

struct ToolCallsSession {
    ctx: ModifyContext,
}

impl ModifySession for ToolCallsSession {
    fn insert(&mut self, input: &InsertRow) -> McpResult<Row> {
        // §4.7: `tool` is NOT NULL on insert; anything else on the input side
        // is ignored, and `arguments` defaults to `{}`.
        let tool = match input.value("tool") {
            Some(Cell::Text(tool)) => tool.clone(),
            Some(other) => {
                return Err(McpError::Internal(format!(
                    "column \"tool\" arrived as {other:?}; expected text"
                )))
            }
            None => {
                return Err(McpError::NotNullViolation(
                    "null value in column \"tool\" of relation \"tool_calls\": \
                     a call names a tool (PRD-7 §4.7)"
                        .to_string(),
                ))
            }
        };
        let arguments = match input.value("arguments") {
            Some(Cell::Json(v)) => v.clone(),
            _ => json!({}),
        };

        let spec = self.ctx.spec;
        let key = self.ctx.cache_key();

        let called_at = now_pg_micros();
        let started = Instant::now();
        let params = json!({ "name": tool, "arguments": arguments });

        // One `tools/call` per row, on this (server, user)'s session. The
        // session cache (PRD-6 §4.4) means a multi-row insert reuses the
        // initialize handshake across rows.
        let outcome = session::with_session(&self.ctx.resolved, |sess, transport| {
            sess.request("tools/call", params, transport)
        });
        let duration_ms = i32::try_from(started.elapsed().as_millis()).unwrap_or(i32::MAX);

        // The cardinal rule (FR-7.10): a tool that reports failure is a row,
        // not an exception. Only *protocol-level* failures (§4.9: -32602,
        // -32601, transport, …) raise, and they raise with `errdetail` naming
        // the server and `tools/call` via `fdw.rs`'s `raise_ctx`.
        let result = outcome?;

        let rec = CallRecord {
            id: uuid_v4(),
            tool,
            arguments,
            content: result.get("content").cloned(),
            structured: result.get("structuredContent").cloned(),
            is_error: crate::client::is_error_result(&result),
            error: None,
            called_at,
            duration_ms,
        };

        // The log and the audit append happen for every *completed* call —
        // including `isError: true` rows.
        record(key, rec.clone());
        self.audit_append(&rec)?;

        Ok(row_from_record(spec, &rec))
    }
}

impl ToolCallsSession {
    /// §4.8: append the completed call to the operator-supplied audit table,
    /// in the caller's transaction. No-op when `audit_table` is unset.
    fn audit_append(&self, rec: &CallRecord) -> McpResult<()> {
        let Some(target) = self.ctx.resolved.options.audit_table.as_deref() else {
            return Ok(());
        };
        // parse_audit_table validated `schema.table` with plain identifiers.
        let (schema, table) = target.split_once('.').ok_or_else(|| {
            McpError::Internal(format!("audit_table \"{target}\" lost its qualification"))
        })?;

        validate_audit_shape(schema, table)?;

        let sql = format!(
            "INSERT INTO \"{schema_q}\".\"{table_q}\" \
             (id, server, role_name, tool, arguments, content, structured, \
              is_error, error, called_at, duration_ms) \
             VALUES ('{id}'::uuid, {server}, current_user, {tool}, {arguments}, \
             {content}, {structured}, {is_error}, {error}, \
             '2000-01-01 00:00:00+00'::timestamptz + {called_at} * interval '1 microsecond', \
             {duration_ms})",
            schema_q = sql_ident(schema),
            table_q = sql_ident(table),
            id = uuid_hex(&rec.id),
            server = sql_literal(&self.ctx.server_name),
            tool = sql_literal(&rec.tool),
            arguments = sql_jsonb(&rec.arguments),
            content = sql_jsonb_opt(rec.content.as_ref()),
            structured = sql_jsonb_opt(rec.structured.as_ref()),
            is_error = if rec.is_error { "TRUE" } else { "FALSE" },
            error = sql_jsonb_opt(rec.error.as_ref()),
            called_at = rec.called_at,
            duration_ms = rec.duration_ms,
        );

        Spi::run(&sql).map_err(|e| {
            // Shape already validated; anything here is an environment
            // failure (privileges, constraint) and fails the caller's
            // statement — an unaudited completed call must not pass silently.
            McpError::Internal(format!("audit insert into \"{target}\" failed: {e}"))
        })?;
        Ok(())
    }
}

/// §4.8: confirm the audit table's columns exist with the expected types
/// *before* writing, so a shape mismatch raises `42804` naming the column
/// rather than leaking a driver error mid-write. Never creates the table.
fn validate_audit_shape(schema: &str, table: &str) -> McpResult<()> {
    /// (column, exact `format_type` output) for the §4.8 shape.
    const EXPECTED: &[(&str, &str)] = &[
        ("id", "uuid"),
        ("server", "text"),
        ("role_name", "name"),
        ("tool", "text"),
        ("arguments", "jsonb"),
        ("content", "jsonb"),
        ("structured", "jsonb"),
        ("is_error", "boolean"),
        ("error", "jsonb"),
        ("called_at", "timestamp with time zone"),
        ("duration_ms", "integer"),
    ];

    let qualified = format!("{}.{}", sql_ident(schema), sql_ident(table));
    let exists: Option<String> = Spi::get_one(&format!("SELECT to_regclass('{qualified}')::text"))
        .map_err(|e| McpError::Internal(format!("audit lookup failed: {e}")))?;
    if exists.is_none() {
        // Not a shape mismatch in the strict sense, but the same operator
        // action fixes it, the extension still refuses to create anything,
        // and the write refuses at first use as §4.8 requires.
        return Err(McpError::DatatypeMismatch(format!(
            "audit table {qualified} does not exist; the extension never creates it — \
             create it with the shape from PRD-7 §4.8 (first column: id uuid)"
        )));
    }

    let sql = format!(
        "SELECT jsonb_object_agg(a.attname::text, format_type(a.atttypid, a.atttypmod)::text)::text
           FROM pg_attribute a
           JOIN pg_class c ON c.oid = a.attrelid
           JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = {schema_lit} AND c.relname = {table_lit}
            AND a.attnum > 0 AND NOT a.attisdropped",
        schema_lit = sql_literal(schema),
        table_lit = sql_literal(table),
    );

    let listing: Option<String> =
        Spi::get_one(&sql).map_err(|e| McpError::Internal(format!("audit lookup failed: {e}")))?;
    let found: HashMap<String, String> = match listing {
        Some(raw) => serde_json::from_str(&raw).map_err(|e| {
            McpError::Internal(format!("audit column listing was not valid json: {e}"))
        })?,
        None => HashMap::new(),
    };

    for (column, want) in EXPECTED {
        match found.get(*column) {
            None => {
                return Err(McpError::DatatypeMismatch(format!(
                    "audit table \"{}.{}\" is missing column \"{}\" (expected {}); \
                     the extension never alters the table (PRD-7 §4.8)",
                    schema, table, column, want
                )))
            }
            Some(have) if *have != *want => {
                return Err(McpError::DatatypeMismatch(format!(
                    "audit table \"{}.{}\" column \"{}\" is {}, expected {}; \
                     the extension never alters the table (PRD-7 §4.8)",
                    schema, table, column, have, want
                )))
            }
            Some(_) => {}
        }
    }
    Ok(())
}

/// A string literal for inline SQL: NUL-stripped (text cannot carry it) and
/// single-quote-doubled.
fn sql_literal(value: &str) -> String {
    let clean = value.replace('\0', "");
    format!("'{}'", clean.replace('\'', "''"))
}

/// A schema/table identifier, quote-escaped.
fn sql_ident(value: &str) -> String {
    value.replace('"', "\"\"")
}

/// A jsonb literal, or SQL NULL.
fn sql_jsonb(value: &Value) -> String {
    format!("{}::jsonb", sql_literal(&value.to_string()))
}

fn sql_jsonb_opt(value: Option<&Value>) -> String {
    match value {
        Some(v) => sql_jsonb(v),
        None => "NULL".to_string(),
    }
}

// ── the handler ──────────────────────────────────────────────────────────────

/// The `tool_calls` registry handler (Track C); pointed at from
/// `tables/mod.rs::REGISTRY`.
pub(crate) static TOOL_CALLS_TABLE: ToolCallsTable = ToolCallsTable;

pub(crate) struct ToolCallsTable;

impl ForeignTable for ToolCallsTable {
    /// `tool =` and `id =` quals filter the in-memory log (§4.7). `id`
    /// constants are not extracted by the frozen planner hook yet
    /// (`fdw.rs::const_to_json` has no UUID arm), so those quals remain
    /// local and Postgres re-checks them; declaring the column here is
    /// still true — quals that do arrive are genuinely applied.
    fn pushdown_columns(&self) -> &'static [&'static str] {
        &["tool", "id"]
    }

    fn begin_scan(&self, ctx: ScanContext) -> McpResult<Box<dyn ScanCursor>> {
        // FR-7.11: pure memory. Nothing here touches the session cache or
        // the network — AP-P2 counts the stub server's hits to prove it.
        let key = ctx.base.cache_key();
        let rows: Vec<Row> = snapshot(key)
            .iter()
            .filter(|rec| log_entry_matches(&ctx.quals, rec))
            .map(|rec| row_from_record(ctx.base.spec, rec))
            .collect();
        Ok(Box::new(LogCursor {
            rows: rows.into_iter(),
        }))
    }

    fn begin_modify(&self, ctx: ModifyContext) -> McpResult<Box<dyn ModifySession>> {
        Ok(Box::new(ToolCallsSession { ctx }))
    }
}

// ── tests (PRD-7 §7.1 `tool_calls_log_test`, §7.2 stub integration) ─────────

#[cfg(any(test, feature = "pg_test"))]
#[pgrx::pg_schema]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    // ── §7.1: the in-memory log ─────────────────────────────────────────────

    fn rec(seed: u64) -> CallRecord {
        let mut id = [0u8; 16];
        id[8..].copy_from_slice(&seed.to_be_bytes());
        CallRecord {
            id,
            tool: format!("tool_{seed}"),
            arguments: json!({}),
            content: None,
            structured: None,
            is_error: false,
            error: None,
            called_at: seed as i64,
            duration_ms: 1,
        }
    }

    /// §7.1 `tool_calls_log_test`: the 1000-entry cap and newest-first reads.
    #[pgrx::pg_test]
    fn tool_calls_log_is_capped_at_1000_and_newest_first() {
        let key = (
            pg_sys::Oid::from_u32(0x7C00_0001),
            pg_sys::Oid::from_u32(42),
        );
        clear_log(key);

        for seed in 0..1010u64 {
            record(key, rec(seed));
        }
        assert_eq!(log_len(key), 1000, "the log caps at 1000 entries");

        let snap = snapshot(key);
        assert_eq!(snap.len(), 1000);
        // Newest first: the last recorded entry leads; the oldest 10 fell off.
        assert_eq!(snap[0].tool, "tool_1009");
        assert_eq!(snap[1].tool, "tool_1008");
        assert_eq!(snap[999].tool, "tool_10", "oldest surviving entry is #10");
    }

    /// §7.1 `tool_calls_log_test`: per-server (and per-user) partitioning.
    #[pgrx::pg_test]
    fn tool_calls_log_partitions_per_server_and_user() {
        let server_a = pg_sys::Oid::from_u32(0x7C00_000A);
        let server_b = pg_sys::Oid::from_u32(0x7C00_000B);
        let user1 = pg_sys::Oid::from_u32(1);
        let user2 = pg_sys::Oid::from_u32(2);

        clear_log((server_a, user1));
        clear_log((server_b, user1));
        clear_log((server_a, user2));

        record((server_a, user1), rec(1));
        record((server_a, user1), rec(2));
        record((server_b, user1), rec(3));
        record((server_a, user2), rec(4));

        assert_eq!(log_len((server_a, user1)), 2);
        assert_eq!(log_len((server_b, user1)), 1);
        assert_eq!(log_len((server_a, user2)), 1);
        // A server's log never bleeds into a sibling's.
        assert_eq!(snapshot((server_b, user1))[0].tool, "tool_3");
        assert_eq!(snapshot((server_a, user2))[0].tool, "tool_4");
    }

    #[pgrx::pg_test]
    fn log_qual_filter_matches_tool_and_id() {
        let r = rec(7);
        assert!(log_entry_matches(&[], &r));
        assert!(log_entry_matches(
            &[Qual::equal("tool", json!("tool_7"))],
            &r
        ));
        assert!(!log_entry_matches(
            &[Qual::equal("tool", json!("tool_8"))],
            &r
        ));
        assert!(log_entry_matches(
            &[Qual::equal("id", json!(uuid_hex(&r.id)))],
            &r
        ));
        assert!(log_entry_matches(
            &[Qual::any_equal("tool", vec![json!("x"), json!("tool_7")])],
            &r
        ));
        // A qual on an unknown column never falsifies the entry.
        assert!(log_entry_matches(&[Qual::equal("bogus", json!("x"))], &r));
    }

    #[pgrx::pg_test]
    fn uuids_are_v4_and_unique() {
        let a = uuid_v4();
        let b = uuid_v4();
        assert_ne!(a, b);
        assert_eq!(a[6] >> 4, 0x4, "version nibble");
        assert_eq!(a[8] >> 6, 0b10, "RFC-4122 variant");
        assert_eq!(uuid_hex(&a).len(), 36);
    }

    #[pgrx::pg_test]
    fn now_pg_micros_is_past_the_pg_epoch_by_decades() {
        // 2026 ≈ 8.4e8 seconds after 2000-01-01.
        assert!(now_pg_micros() > 800_000_000_000_000);
    }

    // ── §7.2: the in-crate HTTP stub ────────────────────────────────────────

    /// Minimal MCP-over-HTTP stub: answers `initialize`, `notifications/*`
    /// and `tools/call`, counting every request it serves. One request per
    /// connection (`Connection: close`) keeps the hit count exact.
    struct StubServer {
        url: String,
        hits: Arc<AtomicUsize>,
    }

    impl StubServer {
        fn start() -> StubServer {
            let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
            let port = listener.local_addr().unwrap().port();
            let hits = Arc::new(AtomicUsize::new(0));
            let hits_in_thread = hits.clone();
            std::thread::spawn(move || {
                for stream in listener.incoming().flatten() {
                    if serve_one(stream, &hits_in_thread).is_err() {
                        continue;
                    }
                }
            });
            StubServer {
                url: format!("http://127.0.0.1:{port}/mcp"),
                hits,
            }
        }

        fn hits(&self) -> usize {
            self.hits.load(Ordering::SeqCst)
        }
    }

    fn read_request(stream: &mut std::net::TcpStream) -> Option<Vec<u8>> {
        let mut buf = Vec::new();
        let mut chunk = [0u8; 4096];
        let header_end = loop {
            let n = stream.read(&mut chunk).ok()?;
            if n == 0 {
                return None;
            }
            buf.extend_from_slice(&chunk[..n]);
            if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                break pos + 4;
            }
            if buf.len() > 1 << 20 {
                return None;
            }
        };
        let headers = String::from_utf8_lossy(&buf[..header_end]).to_ascii_lowercase();
        let len: usize = headers
            .lines()
            .find_map(|l| l.strip_prefix("content-length:"))
            .and_then(|v| v.trim().parse().ok())
            .unwrap_or(0);
        while buf.len() < header_end + len {
            let n = stream.read(&mut chunk).ok()?;
            if n == 0 {
                break;
            }
            buf.extend_from_slice(&chunk[..n]);
        }
        Some(buf[header_end..].to_vec())
    }

    fn serve_one(mut stream: std::net::TcpStream, hits: &AtomicUsize) -> std::io::Result<()> {
        let body = match read_request(&mut stream) {
            Some(b) => b,
            None => return Ok(()),
        };
        hits.fetch_add(1, Ordering::SeqCst);

        let body: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
        let method = body.get("method").and_then(Value::as_str).unwrap_or("");
        let id = body.get("id").cloned().filter(|v| !v.is_null());

        // Server-initiated notifications get 202 and no body.
        if method.starts_with("notifications/") {
            return write_http(&mut stream, 202, b"");
        }

        let payload = match (method, id) {
            ("initialize", Some(id)) => json!({
                "jsonrpc": "2.0", "id": id,
                "result": {
                    "protocolVersion": crate::client::CLIENT_PROTOCOL_VERSION,
                    "serverInfo": {"name": "stub", "version": "0"},
                    "capabilities": {"tools": {}}
                }
            }),
            ("tools/call", Some(id)) => tools_call_reply(id, &body),
            (other, Some(id)) => json!({
                "jsonrpc": "2.0", "id": id,
                "error": {"code": -32601, "message": format!("no such method: {other}")}
            }),
            (_, None) => json!({"jsonrpc": "2.0", "id": null}),
        };
        write_http(&mut stream, 200, payload.to_string().as_bytes())
    }

    /// `tools/call` behaviour matrix. Echo returns the caller's `message` as
    /// text and its full arguments as `structuredContent`; `boom` reports
    /// failure *as a result* (isError: true); `not_found` / `bad_args` are
    /// protocol-level failures (-32601 / -32602).
    fn tools_call_reply(id: Value, body: &Value) -> Value {
        let name = body
            .pointer("/params/name")
            .and_then(Value::as_str)
            .unwrap_or("");
        let args = body
            .pointer("/params/arguments")
            .cloned()
            .unwrap_or(json!({}));
        let ok = |result: Value| json!({"jsonrpc": "2.0", "id": id, "result": result});
        let err = |code: i64, msg: &str| json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": msg}});
        match name {
            "echo" => ok(json!({
                "content": [{"type": "text",
                             "text": args.get("message").cloned().unwrap_or(json!({})).to_string()}],
                "structuredContent": args,
            })),
            "boom" => ok(json!({
                "content": [{"type": "text", "text": "kaboom"}],
                "isError": true,
            })),
            "not_found" => err(-32601, "method \"tools/call\" has no such tool"),
            "bad_args" => err(-32602, "invalid arguments"),
            other => err(-32601, &format!("unknown tool: {other}")),
        }
    }

    fn write_http(
        stream: &mut std::net::TcpStream,
        status: u16,
        body: &[u8],
    ) -> std::io::Result<()> {
        let head = format!(
            "HTTP/1.1 {status} OK\r\ncontent-type: application/json\r\n\
             content-length: {}\r\nconnection: close\r\n\r\n",
            body.len()
        );
        stream.write_all(head.as_bytes())?;
        stream.write_all(body)?;
        stream.flush()
    }

    // ── probe scaffolding ───────────────────────────────────────────────────

    const STUB_SERVER_SQL: &str = "CREATE SERVER {name} FOREIGN DATA WRAPPER mcp_fdw
           OPTIONS (url '{url}', auth 'none', timeout_ms '5000'{extra})";

    fn make_server(name: &str, stub: &StubServer, extra_options: &str) {
        Spi::run(&format!("CREATE SCHEMA IF NOT EXISTS {name}_s")).unwrap();
        let sql = STUB_SERVER_SQL
            .replace("{name}", name)
            .replace("{url}", &stub.url)
            .replace("{extra}", extra_options);
        Spi::run(&sql).unwrap();
        Spi::run(&format!(
            "IMPORT FOREIGN SCHEMA mcp LIMIT TO (tool_calls) FROM SERVER {name} INTO {name}_s"
        ))
        .unwrap();
    }

    fn audit_ddl(name: &str, columns: &str) {
        Spi::run(&format!("CREATE SCHEMA IF NOT EXISTS {name}_audit")).unwrap();
        Spi::run(&format!("CREATE TABLE {name}_audit.tool_calls ({columns})")).unwrap();
    }

    const AUDIT_SHAPE: &str = "id uuid PRIMARY KEY, server text NOT NULL, \
         role_name name NOT NULL, tool text NOT NULL, arguments jsonb, \
         content jsonb, structured jsonb, is_error boolean, error jsonb, \
         called_at timestamptz, duration_ms integer";

    /// Assert that `stmt` fails with SQLSTATE `want` (and, when given, a
    /// message containing `want_msg`), running inside a plpgsql EXCEPTION
    /// block: FDW-path errors longjmp straight to PostgreSQL's machinery and
    /// are not capturable as Rust `Result`s here (the frozen `fdw.rs`
    /// harness pattern, PRD-7 §7.3).
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

    // ── INSERT semantics (§4.7, FR-7.9) ─────────────────────────────────────

    #[pgrx::pg_test]
    fn insert_performs_one_tools_call_and_fills_every_output_column() {
        let stub = StubServer::start();
        make_server("tc_basic", &stub, "");

        Spi::run(
            "INSERT INTO tc_basic_s.tool_calls (tool, arguments)
             VALUES ('echo', '{\"message\":\"hi\"}')",
        )
        .unwrap();

        let fresh_id: Option<bool> = Spi::get_one(
            "SELECT id::text <> '00000000-0000-0000-0000-000000000000'
               FROM tc_basic_s.tool_calls",
        )
        .unwrap();
        assert_eq!(fresh_id, Some(true), "id is extension-generated");
        let is_error: Option<bool> =
            Spi::get_one("SELECT is_error FROM tc_basic_s.tool_calls").unwrap();
        assert_eq!(is_error, Some(false));

        // Content is the tool's own text; structured content echoes arguments.
        let content: Option<String> =
            Spi::get_one("SELECT content->0->>'text' FROM tc_basic_s.tool_calls").unwrap();
        assert_eq!(content.as_deref(), Some("\"hi\""));
        let structured: Option<String> =
            Spi::get_one("SELECT structured->>'message' FROM tc_basic_s.tool_calls").unwrap();
        assert_eq!(structured.as_deref(), Some("hi"));
        let meta: Option<i64> = Spi::get_one(
            "SELECT count(*) FROM tc_basic_s.tool_calls
              WHERE called_at IS NOT NULL AND error IS NULL AND duration_ms IS NOT NULL",
        )
        .unwrap();
        assert_eq!(meta, Some(1));

        // Exactly the requests the statement implies: initialize,
        // notifications/initialized, one tools/call.
        assert_eq!(stub.hits(), 3);
    }

    #[pgrx::pg_test]
    fn arguments_defaults_to_empty_and_output_columns_on_input_are_ignored() {
        let stub = StubServer::start();
        make_server("tc_defaults", &stub, "");

        // No `arguments`, plus every output column supplied: all ignored,
        // nothing errors (§4.7).
        Spi::run(
            "INSERT INTO tc_defaults_s.tool_calls
               (tool, id, content, structured, is_error, error, called_at, duration_ms)
             VALUES ('echo', '00000000-0000-0000-0000-000000000000',
                     '[]', '[]', true, '{}', now(), 999)",
        )
        .unwrap();

        // The echo stub renders missing `message` as `{}` — i.e. the default
        // arguments object reached the tool.
        let text: Option<String> =
            Spi::get_one("SELECT content->0->>'text' FROM tc_defaults_s.tool_calls").unwrap();
        assert_eq!(text.as_deref(), Some("{}"));
        // Overwritten outputs: is_error false, fresh id.
        let is_error: Option<bool> =
            Spi::get_one("SELECT is_error FROM tc_defaults_s.tool_calls").unwrap();
        assert_eq!(is_error, Some(false));
        let fresh_id: Option<bool> = Spi::get_one(
            "SELECT id::text <> '00000000-0000-0000-0000-000000000000'
               FROM tc_defaults_s.tool_calls",
        )
        .unwrap();
        assert_eq!(fresh_id, Some(true));
    }

    /// The cardinal rule (FR-7.10, AC-7.3): `boom` mid-statement yields a
    /// row, and the multi-row INSERT succeeds end to end.
    #[pgrx::pg_test]
    fn a_failing_tool_mid_statement_is_a_row_not_an_exception() {
        let stub = StubServer::start();
        make_server("tc_multirow", &stub, "");

        // RETURNING shows the three outcomes in row order.
        let returned: Option<String> = Spi::get_one(
            "WITH ins AS (
               INSERT INTO tc_multirow_s.tool_calls (tool)
               VALUES ('echo'), ('boom'), ('echo')
               RETURNING tool, is_error
             ) SELECT jsonb_agg(jsonb_build_object('t', tool, 'e', is_error))::text FROM ins",
        )
        .unwrap();
        let returned: Value =
            serde_json::from_str(&returned.expect("RETURNING produced rows")).unwrap();
        let returned: Vec<(String, bool)> = returned
            .as_array()
            .unwrap()
            .iter()
            .map(|o| {
                (
                    o["t"].as_str().unwrap().to_string(),
                    o["e"].as_bool().unwrap(),
                )
            })
            .collect();
        assert_eq!(
            returned,
            vec![
                ("echo".to_string(), false),
                ("boom".to_string(), true),
                ("echo".to_string(), false),
            ]
        );

        // Log order (newest first) mirrors the insert, with `boom` carrying
        // the tool's own error content and a NULL `error` column.
        let tools: Option<String> = Spi::get_one(
            "SELECT array_agg(tool || ':' || is_error::text)::text FROM tc_multirow_s.tool_calls",
        )
        .unwrap();
        assert_eq!(tools.as_deref(), Some("{echo:false,boom:true,echo:false}"));
        let boom_content: Option<String> =
            Spi::get_one("SELECT content->0->>'text' FROM tc_multirow_s.tool_calls WHERE is_error")
                .unwrap();
        assert_eq!(boom_content.as_deref(), Some("kaboom"));
        let boom_error: Option<i64> = Spi::get_one(
            "SELECT count(*) FROM tc_multirow_s.tool_calls WHERE is_error AND error IS NOT NULL",
        )
        .unwrap();
        assert_eq!(boom_error, Some(0), "error stays NULL on isError rows");
    }

    #[pgrx::pg_test]
    fn tool_null_raises_23502() {
        let stub = StubServer::start();
        make_server("tc_null", &stub, "");
        expect_sqlstate(
            "INSERT INTO tc_null_s.tool_calls (tool) VALUES (NULL)",
            "23502",
            None,
        );
        // An omitted `tool` is the same violation.
        expect_sqlstate(
            "INSERT INTO tc_null_s.tool_calls (arguments) VALUES ('{}')",
            "23502",
            None,
        );
        assert_eq!(stub.hits(), 0, "no request is sent for a NULL tool");
    }

    #[pgrx::pg_test]
    fn protocol_failures_raise_per_4_9() {
        let stub = StubServer::start();
        make_server("tc_proto", &stub, "");

        // -32601 from the wire → 0A000, errdetail naming the method …
        expect_sqlstate(
            "INSERT INTO tc_proto_s.tool_calls (tool) VALUES ('not_found')",
            "0A000",
            Some("tools/call"),
        );
        // … and -32602 → 22023.
        expect_sqlstate(
            "INSERT INTO tc_proto_s.tool_calls (tool) VALUES ('bad_args')",
            "22023",
            None,
        );

        // Failed calls are not completed calls: the log stays empty.
        // Requests seen: initialize + note + call, then call (session reuse).
        assert_eq!(stub.hits(), 4);
        let logged: Option<i64> =
            Spi::get_one("SELECT count(*) FROM tc_proto_s.tool_calls").unwrap();
        assert_eq!(logged, Some(0));
    }

    // ── SELECT semantics (FR-7.11, AP-P2) ───────────────────────────────────

    #[pgrx::pg_test]
    fn select_reads_the_log_with_zero_network_io() {
        let stub = StubServer::start();
        make_server("tc_appp2", &stub, "");

        Spi::run(
            "INSERT INTO tc_appp2_s.tool_calls (tool, arguments)
             VALUES ('echo', '{}'), ('echo', '{}'), ('boom', '{}')",
        )
        .unwrap();
        let after_insert = stub.hits();

        // AP-P2: SELECT — qualified and not — issues zero network requests.
        let echo_rows: Option<i64> =
            Spi::get_one("SELECT count(*) FROM tc_appp2_s.tool_calls WHERE tool = 'echo'").unwrap();
        assert_eq!(echo_rows, Some(2));
        let all_rows: Option<i64> =
            Spi::get_one("SELECT count(*) FROM tc_appp2_s.tool_calls").unwrap();
        assert_eq!(all_rows, Some(3));
        assert_eq!(
            stub.hits(),
            after_insert,
            "SELECT on tool_calls must not touch the network (AP-P2)"
        );

        // A restriction Postgres re-checks locally answers correctly too.
        let no_match: Option<i64> =
            Spi::get_one("SELECT count(*) FROM tc_appp2_s.tool_calls WHERE tool = 'nope'").unwrap();
        assert_eq!(no_match, Some(0));
        assert_eq!(stub.hits(), after_insert);
    }

    #[pgrx::pg_test]
    fn select_before_any_insert_scans_empty_and_never_connects() {
        let stub = StubServer::start();
        make_server("tc_fresh", &stub, "");
        let rows: Option<i64> = Spi::get_one("SELECT count(*) FROM tc_fresh_s.tool_calls").unwrap();
        assert_eq!(rows, Some(0));
        assert_eq!(stub.hits(), 0, "no session is opened by a bare SELECT");
    }

    #[pgrx::pg_test]
    fn update_and_delete_on_tool_calls_still_raise_0a000() {
        let stub = StubServer::start();
        make_server("tc_writes", &stub, "");
        expect_sqlstate(
            "UPDATE tc_writes_s.tool_calls SET tool = 'x'",
            "0A000",
            None,
        );
        expect_sqlstate("DELETE FROM tc_writes_s.tool_calls", "0A000", None);
        assert_eq!(stub.hits(), 0);
    }

    // ── Audit (§4.8, FR-7.13) ───────────────────────────────────────────────

    #[pgrx::pg_test]
    fn audit_appends_completed_calls_transactionally() {
        let stub = StubServer::start();
        audit_ddl("tc_audok", AUDIT_SHAPE);
        make_server(
            "tc_audok",
            &stub,
            ", audit_table 'tc_audok_audit.tool_calls'",
        );

        Spi::run("INSERT INTO tc_audok_s.tool_calls (tool) VALUES ('echo'), ('boom')").unwrap();

        let audited: Option<i64> = Spi::get_one(
            "SELECT count(*) FROM tc_audok_audit.tool_calls
              WHERE is_error AND error IS NULL AND content->0->>'text' = 'kaboom'",
        )
        .unwrap();
        assert_eq!(audited, Some(1), "the isError call is audited as a row");
        let total: Option<i64> =
            Spi::get_one("SELECT count(*) FROM tc_audok_audit.tool_calls").unwrap();
        assert_eq!(total, Some(2), "both completed calls audited");

        // role_name is the calling role; server is the foreign server's name.
        let role: Option<i64> = Spi::get_one(
            "SELECT count(*) FROM tc_audok_audit.tool_calls WHERE role_name = current_user",
        )
        .unwrap();
        assert_eq!(role, Some(2));
        let server: Option<String> =
            Spi::get_one("SELECT DISTINCT server FROM tc_audok_audit.tool_calls").unwrap();
        assert_eq!(server.as_deref(), Some("tc_audok"));

        // A rollback discards the audit row along with the caller's work
        // (FR-7.13): the subtransaction's foreign insert and audit append
        // both abort. The in-memory log is diagnostic and deliberately not
        // transactional.
        Spi::run(
            r#"
            DO $probe$
            BEGIN
                BEGIN
                    INSERT INTO tc_audok_s.tool_calls (tool) VALUES ('echo');
                    RAISE EXCEPTION 'force_rollback';
                EXCEPTION WHEN OTHERS THEN NULL;
                END;
            END
            $probe$;"#,
        )
        .unwrap();

        let after: Option<i64> =
            Spi::get_one("SELECT count(*) FROM tc_audok_audit.tool_calls").unwrap();
        assert_eq!(after, Some(2), "the rolled-back call left no audit row");
    }

    #[pgrx::pg_test]
    fn audit_shape_mismatch_raises_42804_naming_the_column() {
        let stub = StubServer::start();
        // Missing a column from the §4.8 shape.
        audit_ddl(
            "tc_audshort",
            &AUDIT_SHAPE.replace("structured jsonb, ", ""),
        );
        make_server(
            "tc_audshort",
            &stub,
            ", audit_table 'tc_audshort_audit.tool_calls'",
        );

        expect_sqlstate(
            "INSERT INTO tc_audshort_s.tool_calls (tool) VALUES ('echo')",
            "42804",
            Some("structured"),
        );
        let rows: Option<i64> =
            Spi::get_one("SELECT count(*) FROM tc_audshort_audit.tool_calls").unwrap();
        assert_eq!(rows, Some(0), "a refused shape writes nothing");

        // A wrong *type* is the same failure, naming the column.
        audit_ddl(
            "tc_audtype",
            &AUDIT_SHAPE.replace("is_error boolean", "is_error text"),
        );
        make_server(
            "tc_audtype",
            &stub,
            ", audit_table 'tc_audtype_audit.tool_calls'",
        );
        expect_sqlstate(
            "INSERT INTO tc_audtype_s.tool_calls (tool) VALUES ('echo')",
            "42804",
            Some("is_error"),
        );

        // A table that does not exist at all is refused, never created.
        make_server(
            "tc_audabsent",
            &stub,
            ", audit_table 'tc_audabsent_audit.missing'",
        );
        expect_sqlstate(
            "INSERT INTO tc_audabsent_s.tool_calls (tool) VALUES ('echo')",
            "42804",
            Some("does not exist"),
        );
        let created: Option<i64> = Spi::get_one(
            "SELECT count(*) FROM pg_class c
               JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'tc_audabsent_audit'",
        )
        .unwrap();
        assert_eq!(created, Some(0), "the extension never creates the table");
    }

    #[pgrx::pg_test]
    fn audit_is_off_by_default() {
        let stub = StubServer::start();
        make_server("tc_noaudit", &stub, "");
        // No audit_table option: the insert simply succeeds; had the handler
        // misread the option this would have failed shape validation.
        Spi::run("INSERT INTO tc_noaudit_s.tool_calls (tool) VALUES ('echo')").unwrap();
        assert_eq!(stub.hits(), 3);
    }
}
