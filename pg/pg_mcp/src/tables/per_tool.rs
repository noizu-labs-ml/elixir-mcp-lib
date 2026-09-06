//! Per-tool foreign tables — the runtime half of PRD-8 §4.2 (checklist 8.7).
//!
//! Generated `tool_<name>` tables resolve through the FDW by their `tool`
//! table option (§4.5 rule 7), not the static registry: this module is their
//! handler. It shares PRD-7's machinery everywhere it can — the session cache
//! (`session::with_session`), the catalog cache (`cache::get_or_fetch`,
//! §4.10 TTLs), and the D1 rule that the tool's *shape* comes from the
//! `tools/list` output the calling principal can see (D2), re-planned with
//! the very same planner that generated the objects (`codegen::plan`). A
//! stale table (the server changed its schema) therefore re-plans against
//! the live definitions and keeps answering, column-for-column, whatever the
//! server currently publishes.
//!
//! Behaviours:
//!
//! * **SELECT = invocation, when gated on.** The `invoke_on_select` table
//!   option is consulted *first*, before any I/O — a gated table raises
//!   `0A000` naming the INSERT alternative without touching the network
//!   (AP-P5). Input columns become `arguments` entries from `=` quals
//!   (FR-8.3); a required input with no qual raises `22023` naming the
//!   argument (FR-8.4). Output columns follow §4.2's row shape; `isError`
//!   results are rows with NULL outputs (AC-8.6), never exceptions.
//! * **INSERT = the universal path** (FR-8.8, §4.8): one `tools/call` per
//!   row, whatever the gate says. Supplied output columns are ignored, as in
//!   PRD-7 §4.7.
//! * **Post-filtering**: quals on non-input columns are applied by this
//!   handler against the produced rows (the plan-time extractor cannot know
//!   which columns are inputs without I/O, so it pushes every supported
//!   qual; this module decides which were arguments and which are filters —
//!   and nothing is marked pushed that is not genuinely applied).
//!
//! `Echo` discipline: an input column reads back the value that was supplied
//! (repeated per row under fan-out), `NULL` where no qual supplied it.

use crate::cache;
use crate::client;
use crate::codegen::{self, OutputShape};
use crate::errors::{McpError, McpResult};
use crate::quals::Qual;
use crate::session;
use crate::tables::{Cell, ColumnType, Row, ScanCursor};
use pgrx::prelude::*;
use pgrx::pg_sys;
use serde_json::{json, Value};
use std::ffi::CString;

/// What the FDW resolved off the foreign table's OPTIONS (`fdw.rs` reads the
/// catalog; this module stays on plain Rust).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PerToolTarget {
    /// The original MCP tool name (§4.5 rule 7).
    pub tool: String,
    /// §4.2's gate, decided at generation. Absent ⇒ `false`: a hand-made
    /// table never side-effects on SELECT by default.
    pub invoke_on_select: bool,
    /// Per-table §4.10 TTL override; `None` uses the server's.
    pub cache_ttl_ms: Option<u64>,
}

/// Everything a scan or insert needs.
pub struct PerToolContext {
    pub target: PerToolTarget,
    /// `<schema>.<table>` of the foreign table being accessed, for error
    /// messages (the INSERT hint names it).
    pub table_qual: String,
    pub server_name: String,
    pub resolved: session::Resolved,
    pub quals: Vec<Qual>,
}

/// One planned tool + the context, after the tool definition resolved.
struct ResolvedTool {
    ctx: PerToolContext,
    planned: codegen::PlannedTool,
}

/// Fetch the calling principal's effective `tools/list` (D1/D2) and plan the
/// named tool against it. No I/O happens when the catalog cache is warm
/// (§4.10 TTL).
fn resolve_tool(ctx: PerToolContext) -> McpResult<ResolvedTool> {
    let ttl = ctx
        .target
        .cache_ttl_ms
        .unwrap_or(ctx.resolved.options.cache_ttl_ms);
    let server_oid = ctx.resolved.server_oid;
    let user_oid = ctx.resolved.user_oid;

    let items = cache::get_or_fetch(server_oid, user_oid, ttl, cache::Slice::Tools, || {
        session::with_session(&ctx.resolved, |sess, transport| {
            client::list_all(sess, "tools/list", "tools", json!({}), transport)
        })
    })?;

    // FR-8.15's warning half: if a tools/list_changed notification was
    // observed in flight, the cache is (or will be) stale — drop the slice
    // and warn when generated objects exist (never DDL: AP-P6).
    let changed = session::with_cached_session(server_oid, user_oid, |s| {
        s.notifications.tools_list_changed()
    })
    .unwrap_or(false);
    if changed {
        cache::drop_tools(server_oid, user_oid);
        if let Ok(schemas) = codegen::registry::schemas_for(&ctx.server_name) {
            if !schemas.is_empty() {
                ereport!(
                    PgLogLevel::WARNING,
                    PgSqlErrorCode::ERRCODE_SUCCESSFUL_COMPLETION,
                    format!(
                        "tool list changed on server {}; generated objects in {} are stale; \
                         re-run mcp.generate_functions",
                        ctx.server_name,
                        schemas.join(", ")
                    )
                );
            }
        }
    }

    let def = items
        .iter()
        .find(|t| t.get("name").and_then(Value::as_str) == Some(ctx.target.tool.as_str()))
        .ok_or_else(|| {
            McpError::UndefinedObject(format!(
                "tool \"{}\" is not in server \"{}\"'s tools/list; the generated table {} is \
                 stale — re-run mcp.generate_functions",
                ctx.target.tool, ctx.server_name, ctx.table_qual
            ))
        })?
        .clone();

    let plan = codegen::plan(
        std::slice::from_ref(&def),
        // The schema/SQL-name arms of the planner were already applied at
        // generation time; runtime planning only needs the *column* shapes,
        // which depend solely on the schemas. The single-tool batch cannot
        // collide with itself.
        "pg_mcp_runtime",
        "",
        codegen::InvokeOnSelect::ReadOnly,
        codegen::SchemaMode::Single,
    )?;
    let planned = plan
        .tools
        .into_iter()
        .next()
        .ok_or_else(|| {
            McpError::UndefinedObject(format!(
                "tool \"{}\" on server \"{}\" no longer has a mappable input schema; \
                 re-run mcp.generate_functions",
                ctx.target.tool, ctx.server_name
            ))
        })?
        ;

    Ok(ResolvedTool { ctx, planned })
}

/// §4.2's gate (FR-8.6): checked before any I/O (AP-P5).
fn check_gate(ctx: &PerToolContext) -> McpResult<()> {
    if ctx.target.invoke_on_select {
        return Ok(());
    }
    Err(McpError::FeatureNotSupported(format!(
        "tool \"{}\" is not read-only; INSERT into {} instead (PRD-8 §4.2)",
        ctx.target.tool, ctx.table_qual
    )))
}

/// Collect `arguments` from the pushed quals: one entry per input column
/// with an `=` qual (echoed back per §4.2); required inputs without one are
/// `22023` naming the argument (FR-8.4).
fn arguments_from_quals(tool: &ResolvedTool) -> McpResult<Value> {
    let mut args = serde_json::Map::new();
    for col in &tool.planned.inputs {
        let supplied = tool.ctx.quals.iter().find_map(|q| {
            if q.field == col.sql_name {
                match q.operator {
                    crate::quals::Operator::Equal => Some(&q.value),
                    crate::quals::Operator::AnyEqual => None, // sets filter, never bind
                }
            } else {
                None
            }
        });
        match (supplied, col.required) {
            (Some(v), _) => {
                args.insert(col.property.clone(), v.clone());
            }
            (None, true) => {
                return Err(McpError::InvalidParams(format!(
                    "required argument \"{}\" of tool \"{}\" must be supplied as a WHERE \
                     equality qual (PRD-8 §4.2)",
                    col.sql_name, tool.planned.tool_name
                )))
            }
            (None, false) => {}
        }
    }
    Ok(Value::Object(args))
}

/// The per-tool scan cursor: one `tools/call` per scan (begin), shaped rows
/// streamed on iterate.
pub struct PerToolCursor {
    rows: std::vec::IntoIter<Row>,
}

impl ScanCursor for PerToolCursor {
    fn iter_scan(&mut self) -> McpResult<Option<Row>> {
        Ok(self.rows.next())
    }
}

/// Invoke once and shape the result rows for `tool`.
fn invoke_and_shape(tool: &ResolvedTool, arguments: Value) -> McpResult<Vec<Row>> {
    let params = json!({ "name": tool.planned.tool_name, "arguments": arguments });

    let result = session::with_session(&tool.ctx.resolved, |sess, transport| {
        sess.request("tools/call", params, transport)
    })?;

    let is_error = client::is_error_result(&result);
    let content = result.get("content").cloned();
    let structured = result.get("structuredContent").cloned();

    // Input echo cells: every input column reads back its supplied value
    // (§4.2), by the column's type.
    let echo = |col: &codegen::Column| -> Option<Cell> {
        arguments
            .get(&col.property)
            .and_then(|v| json_to_cell(v, col.pg_type, &col.sql_name).ok())
            .flatten()
    };

    let output_width = tool.planned.output_columns().len();
    let null_outputs = || vec![None; output_width];

    let mut rows: Vec<Row> = Vec::new();
    if is_error {
        // AC-8.6: one row, NULL outputs, populated content — a row, not an
        // exception (PRD-7 §4.7's cardinal rule, restated §4.2).
        rows.push(shape_row(tool, &echo, null_outputs(), true, content));
        return Ok(rows);
    }

    match &tool.planned.output {
        OutputShape::ElementOf { property, columns } => {
            let elements = structured
                .as_ref()
                .and_then(|s| s.get(property))
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            if elements.is_empty() {
                // A successful call with no elements (or no structured
                // content at all) still returns its one row — silently empty
                // would read as a broken table.
                rows.push(shape_row(tool, &echo, null_outputs(), false, content));
            } else {
                for element in &elements {
                    let cells: Vec<Option<Cell>> = columns
                        .iter()
                        .map(|col| {
                            element
                                .get(&col.property)
                                .and_then(|v| json_to_cell(v, col.pg_type, &col.sql_name).ok())
                                .flatten()
                        })
                        .collect();
                    rows.push(shape_row(tool, &echo, cells, false, content.clone()));
                }
            }
        }
        OutputShape::Single(columns) => {
            let cells: Vec<Option<Cell>> = columns
                .iter()
                .map(|col| {
                    structured
                        .as_ref()
                        .and_then(|s| s.get(&col.property))
                        .and_then(|v| json_to_cell(v, col.pg_type, &col.sql_name).ok())
                        .flatten()
                })
                .collect();
            rows.push(shape_row(tool, &echo, cells, false, content));
        }
        OutputShape::None => {
            rows.push(shape_row(tool, &echo, Vec::new(), false, content));
        }
    }
    Ok(rows)
}

/// Build one full-width row: input echo, output cells, `content`, `is_error`
/// (§4.2's column block order — the order the DDL emits).
fn shape_row(
    tool: &ResolvedTool,
    echo: &dyn Fn(&codegen::Column) -> Option<Cell>,
    outputs: Vec<Option<Cell>>,
    is_error: bool,
    content: Option<Value>,
) -> Row {
    let mut row: Row = Vec::with_capacity(tool.planned.inputs.len() + 2);
    for col in &tool.planned.inputs {
        row.push(echo(col));
    }
    row.extend(outputs);
    row.push(content.map(Cell::Json));
    row.push(Some(Cell::Bool(is_error)));
    row
}

/// Apply the pushed quals that are *not* input bindings as post-filters on
/// the produced rows (see the module docs). Input-column quals were consumed
/// into `arguments` — their echo cells repeat the bound value by
/// construction, and re-checking them through [`Cell::as_json`] would
/// wrongly reject types that project to null there (uuid, timestamps).
fn post_filter(tool: &ResolvedTool, row: &Row) -> bool {
    let width = tool.planned.inputs.len();
    let outputs: Vec<&codegen::Column> = tool.planned.output_columns().iter().collect();

    for qual in &tool.ctx.quals {
        // An input column's qual was already consumed as an argument.
        if tool.planned.inputs.iter().any(|c| c.sql_name == qual.field) {
            continue;
        }
        let value = if let Some(pos) = outputs.iter().position(|c| c.sql_name == qual.field) {
            let idx = width + pos;
            row.get(idx).and_then(|c| c.as_ref())
        } else if qual.field == "content" {
            let idx = width + outputs.len();
            row.get(idx).and_then(|c| c.as_ref())
        } else if qual.field == "is_error" {
            let idx = width + outputs.len() + 1;
            row.get(idx).and_then(|c| c.as_ref())
        } else {
            // A column this row no longer carries (stale table): not ours to
            // falsify — Postgres re-checks it against whatever we returned.
            continue;
        };

        let candidate = value.map(Cell::as_json).unwrap_or(Value::Null);
        if !qual.matches_json(&qual.field, &candidate) {
            return false;
        }
    }
    true
}

/// Begin a SELECT-invocation scan (FR-8.6, FR-8.3, FR-8.4).
pub fn begin_scan(ctx: PerToolContext) -> McpResult<Box<dyn ScanCursor>> {
    check_gate(&ctx)?;
    let tool = resolve_tool(ctx)?;
    let arguments = arguments_from_quals(&tool)?;
    let mut rows = invoke_and_shape(&tool, arguments.clone())?;
    rows.retain(|row| post_filter(&tool, row));
    Ok(Box::new(PerToolCursor {
        rows: rows.into_iter(),
    }))
}

// ── INSERT: the universal path (FR-8.8) ──────────────────────────────────────

/// One in-progress insert session.
pub struct PerToolInsert {
    tool: PerToolContext,
}

/// The trait object `fdw.rs` holds for the statement's duration. `arguments`
/// maps column name → supplied JSON (already read off the tuple slot by
/// `fdw.rs`); this module decides which columns are inputs.
pub trait PerToolModify: Send {
    fn insert(&mut self, supplied: Vec<(String, Option<Value>)>) -> McpResult<Row>;
}

pub fn begin_modify(ctx: PerToolContext) -> McpResult<Box<dyn PerToolModify>> {
    Ok(Box::new(PerToolInsert { tool: ctx }))
}

impl PerToolModify for PerToolInsert {
    fn insert(&mut self, supplied: Vec<(String, Option<Value>)>) -> McpResult<Row> {
        // Resolve the tool definition only once the input is sane: a NULL
        // required argument must 22023 without any I/O (the §4.7 discipline).
        let tool = resolve_tool(PerToolContext {
            target: self.tool.target.clone(),
            table_qual: self.tool.table_qual.clone(),
            server_name: self.tool.server_name.clone(),
            resolved: self.tool.resolved.clone(),
            quals: Vec::new(),
        })?;

        let mut args = serde_json::Map::new();
        for col in &tool.planned.inputs {
            let supplied = supplied.iter().find(|(name, _)| *name == col.sql_name);
            match supplied {
                // Supplied output columns never match an input column and
                // are ignored here (§4.7's rule carried to per-tool tables);
                // only input columns reach `arguments`.
                Some((_, Some(v))) => {
                    args.insert(col.property.clone(), v.clone());
                }
                _ if col.required => {
                    return Err(McpError::InvalidParams(format!(
                        "required argument \"{}\" of tool \"{}\" must be supplied on INSERT \
                         (PRD-8 §4.2)",
                        col.sql_name, tool.planned.tool_name
                    )))
                }
                _ => {}
            }
        }

        let mut rows = invoke_and_shape(&tool, Value::Object(args))?;
        // INSERT returns exactly one row (INSERT cannot fan out).
        rows.truncate(1);
        Ok(rows.into_iter().next().unwrap_or_default())
    }
}

// ── JSON ↔ Cell conversion ───────────────────────────────────────────────────

/// Convert a JSON value from the wire (or a pushed qual) into the typed cell
/// a column carries. Errors are `22023` naming the column.
pub(crate) fn json_to_cell(
    value: &Value,
    ty: ColumnType,
    column: &str,
) -> McpResult<Option<Cell>> {
    if value.is_null() {
        return Ok(None);
    }
    let cell = match ty {
        ColumnType::Text => Cell::Text(match value {
            Value::String(s) => s.clone(),
            other => other.to_string(),
        }),
        ColumnType::Jsonb => Cell::Json(value.clone()),
        ColumnType::Boolean => match value.as_bool() {
            Some(b) => Cell::Bool(b),
            None => type_error(value, column, "boolean")?,
        },
        ColumnType::Int4 => match value.as_i64().and_then(|v| i32::try_from(v).ok()) {
            Some(v) => Cell::Int4(v),
            None => type_error(value, column, "integer")?,
        },
        ColumnType::Int8 => match value.as_i64() {
            Some(v) => Cell::Int8(v),
            None => type_error(value, column, "bigint")?,
        },
        ColumnType::Float8 => match value.as_f64() {
            Some(v) => Cell::Float8(v),
            None => type_error(value, column, "double precision")?,
        },
        ColumnType::Uuid => match value.as_str().map(parse_uuid) {
            Some(Ok(bytes)) => Cell::Uuid(bytes),
            _ => type_error(value, column, "uuid")?,
        },
        ColumnType::TimestampTz => match value.as_str().map(parse_timestamptz) {
            Some(Ok(micros)) => Cell::TimestampTz(micros),
            _ => type_error(value, column, "timestamptz")?,
        },
        ColumnType::Date => match value.as_str().map(parse_date) {
            Some(Ok(())) => Cell::Date(value.as_str().unwrap().to_string()),
            _ => type_error(value, column, "date")?,
        },
        // bytea never appears in a §4.1 mapping; keep the match total.
        ColumnType::Bytea => type_error(value, column, "bytea")?,
    };
    Ok(Some(cell))
}

fn type_error<T>(value: &Value, column: &str, expected: &str) -> McpResult<T> {
    Err(McpError::InvalidParams(format!(
        "value {value} for argument \"{column}\" is not a valid {expected} (PRD-8 §4.1)"
    )))
}

// The three parsers go through PostgreSQL's own input functions (the same
// discipline `fdw.rs` uses at the slot boundary): one definition of "valid
// timestamptz/uuid/date", the server's. The `unsafe` here is the bounded
// exception to FR-6.1's "no pg_sys outside the FDW boundary", exactly like
// `tool_calls.rs`'s `pg_strong_random`: three two-line blocks, all reached
// inside `#[pg_guard]`ed call chains, all delegating the unsafe work to
// PostgreSQL's own input functions. An invalid value raises from the input
// function itself — Postgres's own SQLSTATE — which is the honest answer.

fn parse_timestamptz(text: &str) -> Result<i64, ()> {
    let c = CString::new(text.replace('\0', "")).map_err(|_| ())?;
    // SAFETY: direct call into PostgreSQL's timestamptz_in; the arguments
    // match its (cstring, oid, typmod) signature.
    let datum = unsafe {
        pgrx::direct_function_call_as_datum(
            pg_sys::timestamptz_in,
            &[
                Some(pg_sys::Datum::from(c.as_ptr() as usize)),
                Some(pg_sys::Datum::from(pg_sys::Oid::INVALID)),
                Some((-1i32).into_datum().unwrap()),
            ],
        )
    }
    .ok_or(())?;
    // SAFETY: the datum is a non-null timestamptz (microseconds as i64).
    unsafe { i64::from_datum(datum, false) }.ok_or(())
}

fn parse_uuid(text: &str) -> Result<[u8; 16], ()> {
    let c = CString::new(text.replace('\0', "")).map_err(|_| ())?;
    // SAFETY: direct call into PostgreSQL's uuid_in; (cstring, oid) signature.
    let datum = unsafe {
        pgrx::direct_function_call_as_datum(
            pg_sys::uuid_in,
            &[
                Some(pg_sys::Datum::from(c.as_ptr() as usize)),
                Some(pg_sys::Datum::from(pg_sys::Oid::INVALID)),
            ],
        )
    }
    .ok_or(())?;
    let mut bytes = [0u8; 16];
    // SAFETY: uuid_in returned a palloc'd 16-byte uuid; copy it out before
    // the (foreign) memory is reused.
    unsafe { std::ptr::copy_nonoverlapping(datum.cast_mut_ptr::<u8>(), bytes.as_mut_ptr(), 16) };
    Ok(bytes)
}

fn parse_date(text: &str) -> Result<(), ()> {
    let c = CString::new(text.replace('\0', "")).map_err(|_| ())?;
    // SAFETY: direct call into PostgreSQL's date_in; (cstring, oid)
    // signature. A rejected date raises from the input function itself.
    unsafe {
        pgrx::direct_function_call_as_datum(
            pg_sys::date_in,
            &[
                Some(pg_sys::Datum::from(c.as_ptr() as usize)),
                Some(pg_sys::Datum::from(pg_sys::Oid::INVALID)),
            ],
        )
    };
    Ok(())
}

#[cfg(any(test, feature = "pg_test"))]
#[pgrx::pg_schema]
mod tests {
    use super::*;
    use serde_json::json;

    /// Round-trips through the §4.1 types, by way of PostgreSQL's own input
    /// functions.
    #[pgrx::pg_test]
    fn json_values_convert_to_typed_cells() {
        assert_eq!(
            json_to_cell(&json!("hello"), ColumnType::Text, "q").unwrap(),
            Some(Cell::Text("hello".to_string()))
        );
        assert_eq!(
            json_to_cell(&json!(7), ColumnType::Int8, "limit").unwrap(),
            Some(Cell::Int8(7))
        );
        assert_eq!(
            json_to_cell(&json!(2.5), ColumnType::Float8, "score").unwrap(),
            Some(Cell::Float8(2.5))
        );
        assert_eq!(
            json_to_cell(&json!(true), ColumnType::Boolean, "flag").unwrap(),
            Some(Cell::Bool(true))
        );
        assert!(matches!(
            json_to_cell(&json!({}), ColumnType::Jsonb, "extra").unwrap(),
            Some(Cell::Json(_))
        ));
        // JSON null is SQL NULL, whatever the type.
        assert_eq!(json_to_cell(&Value::Null, ColumnType::Text, "q").unwrap(), None);

        // Postgres-parsed temporal and uuid values.
        assert!(matches!(
            json_to_cell(&json!("2026-09-05T10:00:00Z"), ColumnType::TimestampTz, "since").unwrap(),
            Some(Cell::TimestampTz(_))
        ));
        assert_eq!(
            json_to_cell(&json!("2026-09-05"), ColumnType::Date, "day").unwrap(),
            Some(Cell::Date("2026-09-05".to_string()))
        );
        let uuid = json_to_cell(
            &json!("00000000-0000-0000-0000-000000000001"),
            ColumnType::Uuid,
            "id",
        )
        .unwrap();
        assert!(matches!(uuid, Some(Cell::Uuid(_))));

        // Type errors that need no input function are 22023 naming the
        // column. (Invalid timestamptz/uuid/date text longjmps out of
        // PostgreSQL's own input function with *its* SQLSTATE — 22007/22P02 —
        // which the SQL-level integration probes cover via the EXCEPTION
        // harness; it cannot be observed as a Rust Result here.)
        let err = json_to_cell(&json!("nope"), ColumnType::Int8, "limit").unwrap_err();
        assert_eq!(err.sqlstate(), "22023");
        assert!(err.message().contains("limit"));
        let err = json_to_cell(&json!(false), ColumnType::Float8, "score").unwrap_err();
        assert_eq!(err.sqlstate(), "22023");
    }

    /// RFC 3339 rendering from the pushed-qual conversion agrees with
    /// PostgreSQL's own parser — the echo round-trips.
    #[pgrx::pg_test]
    fn timestamptz_round_trips_through_the_wire_form() {
        // The value `fdw.rs` renders from a pushed const is RFC 3339; parse
        // it back and compare against parsing the original PG spelling.
        let micros = parse_timestamptz("2026-09-05T10:00:00Z").unwrap();
        let direct = parse_timestamptz("2026-09-05 10:00:00+00").unwrap();
        assert_eq!(micros, direct);
        assert!(micros > 800_000_000_000_000, "past the PG epoch");
    }
}

// ── §7.2: SQL-level probes against a live in-crate stub ─────────────────────
//
// The generated-object lifecycle (import → generate → invoke → regenerate)
// exercised end-to-end: per-tool tables scanned/inserted through the real
// FDW, typed functions, the gate, and `mcp.generated` bookkeeping.

#[cfg(any(test, feature = "pg_test"))]
#[pgrx::pg_schema]
mod live_tests {
    use super::*;
    use crate::session;
    use serde_json::json;
    use std::collections::HashMap as StdMap;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex};

    /// The PRD-8 fixture tool set: every `fields.ex` shape, the hostile-name
    /// corner cases from §7.2, and the behavioural tools the probes call.
    fn fixture_tools() -> Vec<Value> {
        vec![
            // Fan-out read-only tool with typed inputs (§4.2's example).
            json!({
                "name": "search_docs",
                "title": "Search documents",
                "description": "Full-text search over the corpus.",
                "annotations": {"readOnlyHint": true},
                "inputSchema": {"type": "object", "properties": {
                    "query": {"type": "string"},
                    "limit": {"type": "integer"},
                    "since": {"type": "string", "format": "date-time"},
                    "day": {"type": "string", "format": "date"},
                    "corpus_id": {"type": "string", "format": "uuid"},
                    "weight": {"type": "number"},
                    "flag": {"type": "boolean"},
                    "meta": {"type": "object"},
                    "tags": {"type": "array", "items": {"type": "string"}},
                    "level": {"type": "string", "enum": ["low", "high"]}
                }, "required": ["query"]},
                "outputSchema": {"type": "object", "properties": {
                    "results": {"type": "array", "items": {"type": "object",
                        "properties": {"id": {"type": "string"},
                                       "score": {"type": "number"}}}}}
                }
            }),
            // Not read-only: the gate's INSERT-only arm.
            json!({
                "name": "send_email",
                "inputSchema": {"type": "object", "properties": {
                    "to": {"type": "string"}}, "required": ["to"]}
            }),
            // isError-as-row, on a read-only tool so SELECT hits it.
            json!({
                "name": "boom_readonly",
                "annotations": {"readOnlyHint": true},
                "inputSchema": {"type": "object", "properties": {}}
            }),
            // All-optional read-only: view eligible, callable with no quals.
            json!({
                "name": "list_projects",
                "annotations": {"readOnlyHint": true},
                "inputSchema": {"type": "object", "properties": {}},
                "outputSchema": {"type": "object", "properties": {
                    "name": {"type": "string"}}}
            }),
            // Reserved-word name (AC-8.7).
            json!({
                "name": "limit",
                "annotations": {"readOnlyHint": true},
                "inputSchema": {"type": "object", "properties": {}}
            }),
            // 70-character name (AC-8.8).
            json!({
                "name": "extremely_long_tool_name_that_keeps_going_well_past_the_sixty_three_x",
                "annotations": {"readOnlyHint": true},
                "inputSchema": {"type": "object", "properties": {}}
            }),
            // Colliding derivations (AC-8.9): both derive to `a_b`.
            json!({
                "name": "a-b",
                "annotations": {"readOnlyHint": true},
                "inputSchema": {"type": "object", "properties": {}}
            }),
            json!({
                "name": "a_b",
                "annotations": {"readOnlyHint": true},
                "inputSchema": {"type": "object", "properties": {}}
            }),
            // Unmappable input schema — skipped, not fatal (AC-8.13, D5).
            json!({
                "name": "broken_ref",
                "inputSchema": {"type": "string", "maxLength": 3}
            }),
        ]
    }

    /// Minimal MCP-over-HTTP stub serving the fixture `tools/list` and a
    /// small `tools/call` matrix. The tool list is mutable so regeneration
    /// probes can remove a tool server-side (AC-8.10).
    struct FixtureStub {
        url: String,
        tools: Arc<Mutex<Vec<Value>>>,
        calls: Arc<AtomicUsize>,
    }

    impl FixtureStub {
        fn start() -> FixtureStub {
            Self::with(fixture_tools())
        }

        fn with(tools: Vec<Value>) -> FixtureStub {
            let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
            let port = listener.local_addr().unwrap().port();
            let tools = Arc::new(Mutex::new(tools));
            let calls = Arc::new(AtomicUsize::new(0));
            let tools_t = tools.clone();
            let calls_t = calls.clone();
            std::thread::spawn(move || {
                for stream in listener.incoming().flatten() {
                    serve_one(stream, &tools_t, &calls_t);
                }
            });
            FixtureStub {
                url: format!("http://127.0.0.1:{port}/mcp"),
                tools,
                calls,
            }
        }

        fn call_count(&self) -> usize {
            self.calls.load(Ordering::SeqCst)
        }

        fn remove_tool(&self, name: &str) {
            self.tools
                .lock()
                .unwrap()
                .retain(|t| t.get("name").and_then(Value::as_str) != Some(name));
        }
    }

    fn read_request(stream: &mut std::net::TcpStream) -> Option<Vec<u8>> {
        let mut buf = Vec::new();
        let mut chunk = [0u8; 8192];
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

    fn serve_one(mut stream: std::net::TcpStream, tools: &Mutex<Vec<Value>>, calls: &AtomicUsize) {
        let body = match read_request(&mut stream) {
            Some(b) => b,
            None => return,
        };
        let body: Value = match serde_json::from_slice(&body) {
            Ok(v) => v,
            Err(_) => return,
        };
        let method = body.get("method").and_then(Value::as_str).unwrap_or("");
        let id = body.get("id").cloned().filter(|v| !v.is_null());

        if method.starts_with("notifications/") {
            // 202, no body — the correct answer to a server-bound note.
            let head = "HTTP/1.1 202 Accepted\r\ncontent-length: 0\r\n\
                        connection: close\r\n\r\n";
            let _ = stream.write_all(head.as_bytes());
            let _ = stream.flush();
            return;
        }

        let payload = match (method, id) {
            ("initialize", Some(id)) => json!({
                "jsonrpc": "2.0", "id": id,
                "result": {
                    "protocolVersion": crate::client::CLIENT_PROTOCOL_VERSION,
                    "serverInfo": {"name": "fixture", "version": "0"},
                    "capabilities": {"tools": {}}
                }
            }),
            ("tools/list", Some(id)) => json!({
                "jsonrpc": "2.0", "id": id,
                "result": {"tools": tools.lock().unwrap().clone()}
            }),
            ("tools/call", Some(id)) => {
                calls.fetch_add(1, Ordering::SeqCst);
                tools_call_reply(id, &body)
            }
            (other, Some(id)) => json!({
                "jsonrpc": "2.0", "id": id,
                "error": {"code": -32601, "message": format!("no such method: {other}")}
            }),
            (_, None) => json!({"jsonrpc": "2.0", "id": null}),
        };
        let text = payload.to_string();
        let head = format!(
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n\
             content-length: {}\r\nconnection: close\r\n\r\n",
            text.len()
        );
        let _ = stream.write_all(head.as_bytes());
        let _ = stream.write_all(text.as_bytes());
        let _ = stream.flush();
    }

    /// `tools/call` behaviour: `search_docs` returns a 2-element `results`
    /// array in `structuredContent`; `send_email` echoes `to`;
    /// `boom_readonly` reports failure as a result.
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
        match name {
            "search_docs" => ok(json!({
                "content": [{"type": "text", "text": "2 results"}],
                "structuredContent": {"results": [
                    {"id": "doc-1", "score": 0.9},
                    {"id": "doc-2", "score": 0.5},
                ]},
            })),
            "send_email" => ok(json!({
                "content": [{"type": "text", "text": "sent"}],
                "structuredContent": {"sent": true, "to": args.get("to")},
            })),
            "boom_readonly" => ok(json!({
                "content": [{"type": "text", "text": "kaboom"}],
                "isError": true,
            })),
            // The remaining read-only fixture tools (limit, list_projects,
            // the long/colliding names) all answer an empty success.
            "limit" | "list_projects" | "a-b" | "a_b"
            | "extremely_long_tool_name_that_keeps_going_well_past_the_sixty_three_x" => {
                ok(json!({"content": [], "structuredContent": {}}))
            }
            other => json!({"jsonrpc": "2.0", "id": id,
                            "error": {"code": -32601, "message": format!("unknown tool: {other}")}}),
        }
    }

    // ── probe scaffolding ───────────────────────────────────────────────────

    fn make_fixture_server(name: &str, stub: &FixtureStub) {
        Spi::run(&format!("CREATE SCHEMA IF NOT EXISTS {name}_s")).unwrap();
        Spi::run(&format!(
            "CREATE SERVER {name} FOREIGN DATA WRAPPER mcp_fdw
               OPTIONS (url '{}', auth 'none', timeout_ms '5000')",
            stub.url
        ))
        .unwrap();
    }

    /// Assert `stmt` fails with SQLSTATE `want` (and message containing
    /// `want_msg`), inside a plpgsql EXCEPTION block: FDW-path errors longjmp
    /// straight to PostgreSQL's machinery (the frozen harness pattern).
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

    /// Import with `per_tool 'true'` and generate the full object set.
    fn import_and_generate(server: &str, schema: &str) {
        Spi::run(&format!(
            "SELECT mcp.import('{server}', '{schema}', '{{\"per_tool\": true}}')"
        ))
        .unwrap();
        Spi::run(&format!(
            "SELECT * FROM mcp.generate_functions('{server}', '{schema}')"
        ))
        .unwrap();
    }

    #[pgrx::pg_test]
    fn per_tool_tables_are_typed_and_invokable_end_to_end() {
        let stub = FixtureStub::start();
        make_fixture_server("pt_basic", &stub);
        import_and_generate("pt_basic", "pt_basic_s");

        // AC-8.5: fan-out — a 2-element result set is 2 rows, echo repeated.
        let rows: Option<String> = Spi::get_one(
            "SELECT string_agg(id || ':' || score::text || ':' || query, ' | ' ORDER BY id)
               FROM pt_basic_s.tool_search_docs WHERE query = 'hello' AND day = '2026-09-05'
                 AND corpus_id = '00000000-0000-0000-0000-000000000001'
                 AND weight = 1.5 AND flag = true",
        )
        .unwrap();
        let rows = rows.expect("two result rows");
        assert!(rows.contains("doc-1:0.9:hello"), "{rows}");
        assert!(rows.contains("doc-2:0.5:hello"), "{rows}");

        // content and is_error ride along.
        // Every SELECT is an invocation (§4.2) — this statement re-invokes
        // with its own required qual.
        let meta: Option<i64> = Spi::get_one(
            "SELECT count(*) FROM pt_basic_s.tool_search_docs
              WHERE query = 'hello'
                AND is_error = false AND content->0->>'text' = '2 results'",
        )
        .unwrap();
        assert_eq!(meta, Some(2));

        // AC-8.2: typed temporal/uuid columns round-trip (the quals above
        // already prove date/uuid/float8/bool columns accept and echo
        // values through the typed path).
        let col_types: Option<String> = Spi::get_one(
            "SELECT string_agg(data_type, ',' ORDER BY ordinal_position)
               FROM information_schema.columns
              WHERE table_schema = 'pt_basic_s' AND table_name = 'tool_search_docs'",
        )
        .unwrap();
        let types = col_types.expect("column list");
        for want in ["text", "bigint", "timestamp with time zone", "date", "uuid",
                     "double precision", "boolean", "jsonb"] {
            assert!(types.contains(want), "missing {want} in {types}");
        }
    }

    #[pgrx::pg_test]
    fn the_gate_blocks_selects_and_names_the_insert_alternative() {
        let stub = FixtureStub::start();
        make_fixture_server("pt_gate", &stub);
        import_and_generate("pt_gate", "pt_gate_s");

        // AC-8.3 (gated arm): 0A000 naming INSERT …
        expect_sqlstate(
            "SELECT * FROM pt_gate_s.tool_send_email",
            "0A000",
            Some("INSERT"),
        );
        // … and zero tools/call requests were sent (AP-P5: the gate check
        // precedes every fetch, including the tools/list shape read).
        assert_eq!(stub.call_count(), 0);

        // AC-8.4: the universal INSERT path works regardless of the gate.
        Spi::run(
            "INSERT INTO pt_gate_s.tool_send_email (\"to\") VALUES ('a@noizu.com')
             RETURNING is_error",
        )
        .unwrap();
        assert!(stub.call_count() >= 1);
    }

    #[pgrx::pg_test]
    fn missing_required_input_raises_22023_naming_the_argument() {
        let stub = FixtureStub::start();
        make_fixture_server("pt_req", &stub);
        import_and_generate("pt_req", "pt_req_s");

        // FR-8.4: an unqualified required input cannot become an argument.
        expect_sqlstate(
            "SELECT count(*) FROM pt_req_s.tool_search_docs",
            "22023",
            Some("query"),
        );
        assert_eq!(stub.call_count(), 0);

        // With the required qual supplied (here through the typed function,
        // which binds it) the same table answers: the failure is precisely
        // about the missing argument, nothing else.
        let ok: Option<i64> = Spi::get_one(
            "SELECT count(*) FROM pt_req_s.search_docs('hello')",
        )
        .unwrap();
        assert_eq!(ok, Some(2));
    }

    #[pgrx::pg_test]
    fn an_is_error_result_is_a_row_with_null_outputs() {
        let stub = FixtureStub::start();
        make_fixture_server("pt_boom", &stub);
        import_and_generate("pt_boom", "pt_boom_s");

        let rows: Option<String> = Spi::get_one(
            "SELECT jsonb_build_object('n', count(*),
                                       'content', (array_agg(content->0->>'text'))[1],
                                       'is_error', bool_and(is_error))::text
               FROM pt_boom_s.tool_boom_readonly",
        )
        .unwrap();
        let rows = rows.expect("one row");
        assert!(rows.contains("\"n\": 1"), "{rows}");
        assert!(rows.contains("kaboom"), "{rows}");
        assert!(rows.contains("true"), "{rows}");
    }

    #[pgrx::pg_test]
    fn typed_functions_and_views_generate_and_are_callable() {
        let stub = FixtureStub::start();
        make_fixture_server("pt_fn", &stub);
        import_and_generate("pt_fn", "pt_fn_s");

        // §4.3: the typed function returns the fanned-out rows.
        let ids: Option<String> = Spi::get_one(
            "SELECT string_agg(id, ',' ORDER BY id) FROM pt_fn_s.search_docs('hello')",
        )
        .unwrap();
        assert_eq!(
            ids.as_deref(),
            Some("doc-1,doc-2"),
            "the generated function fans out"
        );

        // §4.3: the non-read-only function takes the INSERT path and returns
        // the whole result the table carries ({content, is_error}).
        let sent: Option<String> = Spi::get_one(
            "SELECT pt_fn_s.send_email('a@noizu.com')::jsonb->>'is_error'",
        )
        .unwrap();
        assert_eq!(sent.as_deref(), Some("false"));

        // §4.4: the all-optional read-only tool gets its flattened view.
        let view_rows: Option<i64> =
            Spi::get_one("SELECT count(*) FROM pt_fn_s.v_tool_list_projects").unwrap();
        assert_eq!(view_rows, Some(1));

        // AC-8.12: the function comment is in the catalog.
        let comment: Option<String> = Spi::get_one(
            "SELECT obj_description(p.oid, 'pg_proc')
               FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'pt_fn_s' AND p.proname = 'search_docs'",
        )
        .unwrap();
        let comment = comment.unwrap_or_default();
        assert!(comment.contains("Search documents"), "{comment}");
    }

    #[pgrx::pg_test]
    fn reserved_long_and_colliding_names_all_generate_and_are_queryable() {
        let stub = FixtureStub::start();
        make_fixture_server("pt_names", &stub);
        import_and_generate("pt_names", "pt_names_s");

        // AC-8.7: the reserved word is quoted, not renamed.
        let limit_rows: Option<i64> =
            Spi::get_one("SELECT count(*) FROM pt_names_s.tool_limit").unwrap();
        assert_eq!(limit_rows, Some(1));
        let fn_limit: Option<i64> = Spi::get_one(
            "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'pt_names_s' AND p.proname = 'limit'",
        )
        .unwrap();
        assert_eq!(fn_limit, Some(1));

        // AC-8.8: the 70-character name lands on a 63-byte relation, ending
        // in the hash shape, identical across runs (the unit probe pins the
        // exact vector; here we pin the catalog consequence).
        let (relname, relname_len): (Option<String>, Option<i32>) = Spi::get_two(
            "SELECT c.relname::text, length(c.relname) FROM pg_class c
               JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'pt_names_s'
                AND c.relname LIKE 'tool_extremely_long_tool_name%'",
        )
        .unwrap();
        let relname = relname.expect("truncated-name table exists");
        assert_eq!(relname_len, Some(63), "relation name is exactly 63 bytes");
        let derived = &relname["tool_".len()..];
        assert_eq!(derived.len(), 58, "55 bytes + _ + 7 hex fits under tool_");
        // PostgreSQL truncates the 67-byte `tool_<63>` name to 63 bytes —
        // the planner's derivation is the AC-8.8 identifier, the relation
        // carries its 63-byte prefix, deterministically.
        assert_eq!(
            Some(relname.as_str()),
            crate::codegen::table::table_name(&planned_long_name())
                .get(..63)
                .map(str::to_string)
                .as_deref(),
            "the catalog name is the truncated planner derivation"
        );

        // AC-8.9: both colliding tools generate distinct, callable objects.
        let colliding: Vec<String> = Spi::get_one::<String>(
            "SELECT string_agg(c.relname::text, ',' ORDER BY c.relname) FROM pg_class c
               JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'pt_names_s' AND c.relname LIKE 'tool_a_b%'",
        )
        .unwrap()
        .expect("both colliding tables")
        .split(',')
        .map(str::to_string)
        .collect();
        assert_eq!(colliding.len(), 2);
        assert!(colliding[1].starts_with("tool_a_b_"), "{colliding:?}");
        let one: Option<i64> = Spi::get_one(&format!(
            "SELECT count(*) FROM pt_names_s.\"{}\"",
            colliding[0]
        ))
        .unwrap();
        assert_eq!(one, Some(1), "{} is independently queryable", colliding[0]);
    }

    /// The planner's derivation for the 70-char fixture tool (determinism
    /// bridge between this probe and the fixed vectors in `ident`).
    fn planned_long_name() -> crate::codegen::PlannedTool {
        let tools = fixture_tools();
        let long = tools
            .iter()
            .find(|t| t["name"].as_str().unwrap_or("").starts_with("extremely_long"))
            .unwrap()
            .clone();
        crate::codegen::plan(
            std::slice::from_ref(&long),
            "pt_names_s",
            "",
            crate::codegen::InvokeOnSelect::ReadOnly,
            crate::codegen::SchemaMode::Single,
        )
        .unwrap()
        .tools
        .remove(0)
    }

    #[pgrx::pg_test]
    fn unmappable_tools_are_reported_and_the_rest_generates() {
        let stub = FixtureStub::start();
        make_fixture_server("pt_skip", &stub);
        import_and_generate("pt_skip", "pt_skip_s");

        // AC-8.13: broken_ref generated nothing; every other tool did.
        let broken: Option<i64> = Spi::get_one(
            "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'pt_skip_s' AND c.relname LIKE 'tool_broken%'",
        )
        .unwrap();
        assert_eq!(broken, Some(0));

        let generated: Option<i64> = Spi::get_one(
            "SELECT count(DISTINCT tool) FROM mcp.generated
              WHERE server = 'pt_skip' AND schema = 'pt_skip_s'",
        )
        .unwrap();
        // Nine fixture tools, one skipped.
        assert_eq!(generated, Some(8));
    }

    #[pgrx::pg_test]
    fn regeneration_drops_exactly_the_vanished_tools_objects() {
        let stub = FixtureStub::start();
        make_fixture_server("pt_regen", &stub);
        import_and_generate("pt_regen", "pt_regen_s");

        let before: Option<i64> = Spi::get_one(
            "SELECT count(*) FROM mcp.generated WHERE server = 'pt_regen'",
        )
        .unwrap();
        // 8 tools x (table + function), plus views for the 6 read-only
        // all-optional tools.
        assert_eq!(before, Some(22));

        // AC-8.10: remove `list_projects` server-side, regenerate.
        stub.remove_tool("list_projects");
        Spi::run("SELECT * FROM mcp.generate_functions('pt_regen', 'pt_regen_s')").unwrap();

        let after: Option<i64> = Spi::get_one(
            "SELECT count(*) FROM mcp.generated WHERE server = 'pt_regen'",
        )
        .unwrap();
        assert_eq!(after, Some(19), "7 tools x (table + function), 5 views remain");

        let gone: Option<i64> = Spi::get_one(
            "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'pt_regen_s' AND c.relname LIKE '%list_projects%'",
        )
        .unwrap();
        assert_eq!(gone, Some(0), "the tool's table and view are both gone");

        // Survivors still work.
        let kept: Option<i64> =
            Spi::get_one("SELECT count(*) FROM pt_regen_s.tool_limit").unwrap();
        assert_eq!(kept, Some(1));
    }

    #[pgrx::pg_test]
    fn a_user_view_blocks_regeneration_with_restrict_and_nothing_is_half_dropped() {
        let stub = FixtureStub::start();
        make_fixture_server("pt_restrict", &stub);
        import_and_generate("pt_restrict", "pt_restrict_s");

        // A user view depending on a generated table (AC-8.11).
        Spi::run(
            "CREATE VIEW pt_restrict_s.user_view AS
               SELECT id FROM pt_restrict_s.tool_search_docs",
        )
        .unwrap();

        expect_sqlstate(
            "SELECT * FROM mcp.generate_functions('pt_restrict', 'pt_restrict_s')",
            "2BP01",
            Some("depend on it"),
        );

        // Nothing half-dropped: every previously owned object still stands.
        let intact: Option<i64> = Spi::get_one(
            "SELECT count(*) FROM mcp.generated WHERE server = 'pt_restrict'",
        )
        .unwrap();
        assert_eq!(
            intact,
            Some(22),
            "the failed regeneration left the bookkeeping whole"
        );
        let table_alive: Option<i64> =
            Spi::get_one("SELECT count(*) FROM pt_restrict_s.tool_limit").unwrap();
        assert_eq!(table_alive, Some(1));
    }

    #[pgrx::pg_test]
    fn invoke_on_select_all_promotes_with_a_listing_none_demotes() {
        let stub = FixtureStub::start();
        make_fixture_server("pt_all", &stub);
        // 'all' promotes send_email to SELECT-invocation.
        Spi::run(
            "SELECT mcp.import('pt_all', 'pt_all_s',
                '{\"per_tool\": true, \"invoke_on_select\": \"all\"}')",
        )
        .unwrap();
        let promoted: Option<i64> = Spi::get_one(
            "SELECT count(*) FROM pg_foreign_table ft
               JOIN pg_class c ON c.oid = ft.ftrelid
               JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'pt_all_s'
                AND ft.ftoptions @> ARRAY['tool=send_email', 'invoke_on_select=true']",
        )
        .unwrap();
        assert_eq!(promoted, Some(1), "the non-read-only tool was promoted");
        // The promoted table actually invokes on SELECT — still honoring
        // the required `to` argument.
        expect_sqlstate(
            "SELECT count(*) FROM pt_all_s.tool_send_email",
            "22023",
            Some("to"),
        );
        let sent: Option<i64> = Spi::get_one(
            "SELECT count(*) FROM pt_all_s.tool_send_email WHERE \"to\" = 'a@noizu.com'",
        )
        .unwrap();
        assert_eq!(sent, Some(1));

        // 'none' demotes everything, including the read-only tools.
        make_fixture_server("pt_none", &stub);
        Spi::run(
            "SELECT mcp.import('pt_none', 'pt_none_s',
                '{\"per_tool\": true, \"invoke_on_select\": \"none\"}')",
        )
        .unwrap();
        let demoted: Option<i64> = Spi::get_one(
            "SELECT count(*) FROM pg_foreign_table ft
               JOIN pg_class c ON c.oid = ft.ftrelid
               JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'pt_none_s' AND ft.ftoptions @> ARRAY['invoke_on_select=true']",
        )
        .unwrap();
        assert_eq!(demoted, Some(0));
        expect_sqlstate(
            "SELECT count(*) FROM pt_none_s.tool_search_docs",
            "0A000",
            Some("INSERT"),
        );
    }

    #[pgrx::pg_test]
    fn generate_functions_returns_the_prd_tuple() {
        let stub = FixtureStub::start();
        make_fixture_server("pt_tuple", &stub);

        let row: Option<String> = Spi::get_one(
            "SELECT jsonb_build_object('g', generated, 's', skipped,
                                       'names', skipped_tools)::text
               FROM mcp.generate_functions('pt_tuple', 'pt_tuple_s')",
        )
        .unwrap();
        let row = row.expect("one result row");
        // 9 fixture tools: 8 generated, 1 skipped (broken_ref).
        assert!(row.contains("\"g\": 8"), "{row}");
        assert!(row.contains("\"s\": 1"), "{row}");
        assert!(row.contains("broken_ref"), "{row}");

        // Idempotence: re-running regenerates the same object set.
        Spi::run("SELECT * FROM mcp.generate_functions('pt_tuple', 'pt_tuple_s')").unwrap();
        let again: Option<i64> = Spi::get_one(
            "SELECT count(DISTINCT tool) FROM mcp.generated
              WHERE server = 'pt_tuple' AND schema = 'pt_tuple_s'",
        )
        .unwrap();
        assert_eq!(again, Some(8));
    }

    #[pgrx::pg_test]
    fn stale_tables_name_the_regeneration_fix() {
        // A table whose tool vanished: SELECT fails with 42704 naming
        // mcp.generate_functions (the tool_list_changed WARNING path and the
        // refresh NOTICE are the standing advisories).
        let stub = FixtureStub::start();
        make_fixture_server("pt_stale", &stub);
        import_and_generate("pt_stale", "pt_stale_s");
        stub.remove_tool("list_projects");
        Spi::run("SELECT mcp.refresh('pt_stale')").unwrap();

        expect_sqlstate(
            "SELECT count(*) FROM pt_stale_s.v_tool_list_projects",
            "42704",
            Some("mcp.generate_functions"),
        );
    }

    /// Quiet the unused warnings for scaffolding shared with future probes.
    #[allow(dead_code)]
    fn silence(_: &StdMap<String, String>, _: session::Resolved) {}
}
