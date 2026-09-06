//! **Track A owns this file** (PRD-7 §6 step 7.3): the catalog tables
//! `server`, `tools`, `prompts`, `prompt_arguments`, `resources`,
//! `resource_templates`.
//!
//! Every handler fetches its list method through `client.rs::list_all`
//! (pagination cursors followed to exhaustion, FR-7.3) via the §4.10 cache in
//! `cache.rs`, buffers the projected rows in `begin_scan`, and streams them
//! out of a fully-buffered cursor. Quals on the pushed columns are applied as
//! **post-fetch row-count filters** (§4.2: MCP list methods have no
//! server-side filter; the full list is fetched once per cache period
//! regardless) using `Qual::matches_json` over the projected cells.
//!
//! D5, per table (FR-7.4): a backing list method answering `-32601` yields an
//! empty table — the error is swallowed *per method*, so sibling tables on the
//! same server keep working. Any other error (transport, auth, `-32602`, …)
//! fails the scan with its own SQLSTATE.
//!
//! The `server` table (§4.1) costs no list-method traffic: identity columns
//! come from the resolved foreign server (`name`, `url`, resolved `mode`),
//! handshake columns from the cached session (`protocol_version`,
//! `serverInfo`, `capabilities`, `session_id`), and `instructions` from the
//! cache's `initialize` slice — see `cache.rs`'s moduledoc for why that one
//! slice is fetched through a single `initialize` request per TTL period on
//! the existing session. No list method is ever called.

use crate::cache::{self, Slice};
use crate::client;
use crate::errors::{McpError, McpResult};
use crate::quals::Qual;
use crate::session;
use crate::tables::{
    empty_row, Cell, ForeignTable, Row, ScanContext, ScanCursor, TableContext, TableSpec,
};
use serde_json::{json, Value};
use std::sync::Arc;

// ── row construction helpers ────────────────────────────────────────────────

/// Store a cell under a column name, ignoring unknown names (the specs are
/// `&'static`, so a typo here would panic in tests rather than corrupt a row).
fn set(spec: &TableSpec, row: &mut Row, column: &str, cell: Option<Cell>) {
    if let Some(index) = spec.attno(column) {
        row[index - 1] = cell;
    }
}

/// `item[key]` as a text cell.
fn text_at(item: &Value, key: &str) -> Option<Cell> {
    item.get(key)
        .and_then(Value::as_str)
        .map(|s| Cell::Text(s.to_string()))
}

/// `item[key]` as a jsonb cell (absent or JSON null → SQL NULL).
fn json_at(item: &Value, key: &str) -> Option<Cell> {
    match item.get(key) {
        None | Some(Value::Null) => None,
        Some(v) => Some(Cell::Json(v.clone())),
    }
}

/// `item.annotations[hint]` as a boolean cell; NULL when absent (§4.2).
fn annotation(item: &Value, hint: &str) -> Option<Cell> {
    item.get("annotations")
        .and_then(|a| a.get(hint))
        .and_then(Value::as_bool)
        .map(Cell::Bool)
}

/// A JSON-RPC list item's field as a bool cell.
fn bool_at(item: &Value, key: &str) -> Option<Cell> {
    item.get(key).and_then(Value::as_bool).map(Cell::Bool)
}

/// A JSON-RPC list item's field as an int8 cell (`resources.size`).
fn int8_at(item: &Value, key: &str) -> Option<Cell> {
    item.get(key).and_then(Value::as_i64).map(Cell::Int8)
}

// ── projection per table (§4.1-§4.4, column-for-column) ─────────────────────

fn tools_row(spec: &TableSpec, item: &Value) -> Row {
    let mut row = empty_row(spec);
    set(spec, &mut row, "name", text_at(item, "name"));
    set(spec, &mut row, "title", text_at(item, "title"));
    set(spec, &mut row, "description", text_at(item, "description"));
    set(spec, &mut row, "input_schema", json_at(item, "inputSchema"));
    set(
        spec,
        &mut row,
        "output_schema",
        json_at(item, "outputSchema"),
    );
    set(spec, &mut row, "annotations", json_at(item, "annotations"));
    set(
        spec,
        &mut row,
        "read_only",
        annotation(item, "readOnlyHint"),
    );
    set(
        spec,
        &mut row,
        "destructive",
        annotation(item, "destructiveHint"),
    );
    set(
        spec,
        &mut row,
        "idempotent",
        annotation(item, "idempotentHint"),
    );
    set(
        spec,
        &mut row,
        "open_world",
        annotation(item, "openWorldHint"),
    );
    set(spec, &mut row, "meta", json_at(item, "_meta"));
    row
}

fn prompts_row(spec: &TableSpec, item: &Value) -> Row {
    let mut row = empty_row(spec);
    set(spec, &mut row, "name", text_at(item, "name"));
    set(spec, &mut row, "title", text_at(item, "title"));
    set(spec, &mut row, "description", text_at(item, "description"));
    set(spec, &mut row, "meta", json_at(item, "_meta"));
    row
}

/// §4.3: `prompt_arguments` is the flattened `.arguments[]` of each prompt,
/// `idx` counting from 0 within each prompt.
fn prompt_argument_rows(spec: &TableSpec, prompts: &[Value]) -> Vec<Row> {
    let mut rows = Vec::new();
    for prompt in prompts {
        let prompt_name = prompt.get("name").and_then(Value::as_str);
        let arguments = prompt
            .get("arguments")
            .and_then(Value::as_array)
            .map(|a| a.as_slice())
            .unwrap_or(&[]);
        for (idx, argument) in arguments.iter().enumerate() {
            let mut row = empty_row(spec);
            set(
                spec,
                &mut row,
                "prompt",
                prompt_name.map(|p| Cell::Text(p.to_string())),
            );
            set(spec, &mut row, "name", text_at(argument, "name"));
            set(
                spec,
                &mut row,
                "description",
                text_at(argument, "description"),
            );
            set(spec, &mut row, "required", bool_at(argument, "required"));
            set(spec, &mut row, "idx", Some(Cell::Int4(idx as i32)));
            rows.push(row);
        }
    }
    rows
}

fn resources_row(spec: &TableSpec, item: &Value) -> Row {
    let mut row = empty_row(spec);
    set(spec, &mut row, "uri", text_at(item, "uri"));
    set(spec, &mut row, "name", text_at(item, "name"));
    set(spec, &mut row, "title", text_at(item, "title"));
    set(spec, &mut row, "description", text_at(item, "description"));
    set(spec, &mut row, "mime_type", text_at(item, "mimeType"));
    set(spec, &mut row, "size", int8_at(item, "size"));
    set(spec, &mut row, "annotations", json_at(item, "annotations"));
    set(spec, &mut row, "meta", json_at(item, "_meta"));
    row
}

fn resource_templates_row(spec: &TableSpec, item: &Value) -> Row {
    let mut row = empty_row(spec);
    set(spec, &mut row, "uri_template", text_at(item, "uriTemplate"));
    set(spec, &mut row, "name", text_at(item, "name"));
    set(spec, &mut row, "title", text_at(item, "title"));
    set(spec, &mut row, "description", text_at(item, "description"));
    set(spec, &mut row, "mime_type", text_at(item, "mimeType"));
    set(spec, &mut row, "annotations", json_at(item, "annotations"));
    set(spec, &mut row, "meta", json_at(item, "_meta"));
    row
}

// ── post-fetch qual filters (§4.2: a row-count optimization only) ───────────

/// Apply the quals whose field is one of `pushed` columns as a post-fetch
/// filter over the projected rows. A row's cell is compared as JSON
/// (`Cell::as_json`), so a SQL NULL cell never satisfies an equality —
/// matching `Qual::matches_json`'s contract.
fn apply_post_filters(
    spec: &TableSpec,
    rows: Vec<Row>,
    quals: &[Qual],
    pushed: &[&str],
) -> Vec<Row> {
    let relevant: Vec<&Qual> = quals
        .iter()
        .filter(|q| pushed.contains(&q.field.as_str()) && q.is_supported())
        .collect();
    if relevant.is_empty() {
        return rows;
    }
    rows.into_iter()
        .filter(|row| {
            relevant.iter().all(|q| {
                let cell = spec
                    .attno(&q.field)
                    .and_then(|i| row[i - 1].as_ref())
                    .map(|c| c.as_json())
                    .unwrap_or(Value::Null);
                q.matches_json(&q.field, &cell)
            })
        })
        .collect()
}

// ── the shared fetch path (list methods through the cache) ──────────────────

/// Scope a cached list slice to one engine upstream (PRD-7.E: the read-path
/// half of `import.rs`'s `upstream` table option / FR-7.19).
///
/// The catalog cache always holds the *union* slice — one entry per
/// `(server, user, slice)` serves every upstream table on that server — so
/// scoping happens here, on the way out. `upstream` non-empty keeps only the
/// items whose `name` is prefixed `<upstream>.` and **strips the prefix**
/// (AC-7.13: a per-upstream schema's `tools` carries un-prefixed names).
/// The empty string is the engine-local slice: items whose `name` carries no
/// `<upstream>.` prefix (per `import.rs::upstreams_from_tool_names`'s
/// first-dot convention; a name-less item counts as engine-local). Scoping
/// keys on `name` only — the engine namespaces *tools* (ADR-007), and every
/// federated catalog item carries one.
fn scoped_items(upstream: &str, items: &[Value]) -> Vec<Value> {
    if upstream.is_empty() {
        return items
            .iter()
            .filter(|item| {
                item.get("name")
                    .and_then(Value::as_str)
                    .map(|n| !n.contains('.'))
                    .unwrap_or(true)
            })
            .cloned()
            .collect();
    }
    let prefix = format!("{upstream}.");
    items
        .iter()
        .filter_map(|item| {
            let name = item.get("name").and_then(Value::as_str)?;
            let local = name.strip_prefix(&prefix)?;
            let mut scoped = item.clone();
            scoped["name"] = Value::String(local.to_string());
            Some(scoped)
        })
        .collect()
}

/// Fetch one list method for `(server, user)` through the §4.10 cache.
///
/// When `poll_tools_flag` is set (the `tools` table only), a
/// `notifications/tools/list_changed` observed on any in-flight request drops
/// the cached `tools` slice first (§4.10: best-effort — TTL is the guarantee).
///
/// The table's own `cache_ttl_ms` OPTIONS entry (stamped by `mcp.import`,
/// PRD-7.E) overrides the server-level TTL for this table; the §4.10 cache
/// entry is shared, so the override decides *this table's* freshness check,
/// and `0` makes this table always refetch.
///
/// D5 / FR-7.4: `-32601` from the backing method maps to an empty item list,
/// which is then cached like any success; every other error propagates.
fn fetch_list(
    ctx: &TableContext,
    slice: Slice,
    method: &'static str,
    array_key: &'static str,
    poll_tools_flag: bool,
) -> McpResult<Arc<Vec<Value>>> {
    let (server_oid, user_oid) = ctx.cache_key();
    let ttl_ms = ctx
        .table_ttl_ms()
        .unwrap_or(ctx.resolved.options.cache_ttl_ms);

    session::with_session(&ctx.resolved, |sess, transport| {
        if poll_tools_flag && sess.notifications.take_tools_list_changed() {
            cache::drop_tools(server_oid, user_oid);
        }
        let items = cache::get_or_fetch(server_oid, user_oid, ttl_ms, slice, || {
            match client::list_all(sess, method, array_key, json!({}), transport) {
                Ok(items) => Ok(items),
                // D5 fail-open per table: the surface is not implemented on
                // this server, so the table is empty and its siblings
                // continue to work (FR-7.4).
                Err(McpError::MethodNotFound(_)) => Ok(Vec::new()),
                Err(e) => Err(e),
            }
        })?;
        // Upstream scoping (PRD-7.E) happens after the cache: the cached
        // slice is the union, each table projects its own view of it.
        Ok(match ctx.upstream() {
            Some(upstream) => Arc::new(scoped_items(upstream, &items)),
            None => items,
        })
    })
}

// ── the fully-buffered cursor ───────────────────────────────────────────────

struct RowsCursor {
    rows: Vec<Row>,
    position: usize,
}

impl RowsCursor {
    fn new(rows: Vec<Row>) -> RowsCursor {
        RowsCursor { rows, position: 0 }
    }
}

impl ScanCursor for RowsCursor {
    fn iter_scan(&mut self) -> McpResult<Option<Row>> {
        let row = self.rows.get(self.position).cloned();
        if row.is_some() {
            self.position += 1;
        }
        Ok(row)
    }

    fn re_scan(&mut self) -> McpResult<()> {
        self.position = 0;
        Ok(())
    }
}

// ── the six handlers ────────────────────────────────────────────────────────

/// §4.2 `tools`.
pub struct ToolsTable;

impl ForeignTable for ToolsTable {
    fn pushdown_columns(&self) -> &'static [&'static str] {
        &["name"]
    }

    fn begin_scan(&self, ctx: ScanContext) -> McpResult<Box<dyn ScanCursor>> {
        let spec = ctx.base.spec;
        let items = fetch_list(&ctx.base, Slice::Tools, "tools/list", "tools", true)?;
        let rows = apply_post_filters(
            spec,
            items.iter().map(|item| tools_row(spec, item)).collect(),
            &ctx.quals,
            self.pushdown_columns(),
        );
        Ok(Box::new(RowsCursor::new(rows)))
    }
}

/// §4.3 `prompts`.
pub struct PromptsTable;

impl ForeignTable for PromptsTable {
    fn pushdown_columns(&self) -> &'static [&'static str] {
        &["name"]
    }

    fn begin_scan(&self, ctx: ScanContext) -> McpResult<Box<dyn ScanCursor>> {
        let spec = ctx.base.spec;
        let items = fetch_list(&ctx.base, Slice::Prompts, "prompts/list", "prompts", false)?;
        let rows = apply_post_filters(
            spec,
            items.iter().map(|item| prompts_row(spec, item)).collect(),
            &ctx.quals,
            self.pushdown_columns(),
        );
        Ok(Box::new(RowsCursor::new(rows)))
    }
}

/// §4.3 `prompt_arguments` — the flattened `.arguments[]` of each prompt.
/// The `prompt = 'x'` qual filters after fetch (§4.3).
pub struct PromptArgumentsTable;

impl ForeignTable for PromptArgumentsTable {
    fn pushdown_columns(&self) -> &'static [&'static str] {
        &["prompt"]
    }

    fn begin_scan(&self, ctx: ScanContext) -> McpResult<Box<dyn ScanCursor>> {
        let spec = ctx.base.spec;
        let items = fetch_list(&ctx.base, Slice::Prompts, "prompts/list", "prompts", false)?;
        let rows = apply_post_filters(
            spec,
            prompt_argument_rows(spec, &items),
            &ctx.quals,
            self.pushdown_columns(),
        );
        Ok(Box::new(RowsCursor::new(rows)))
    }
}

/// §4.4 `resources`.
pub struct ResourcesTable;

impl ForeignTable for ResourcesTable {
    fn begin_scan(&self, ctx: ScanContext) -> McpResult<Box<dyn ScanCursor>> {
        let spec = ctx.base.spec;
        let items = fetch_list(
            &ctx.base,
            Slice::Resources,
            "resources/list",
            "resources",
            false,
        )?;
        let rows: Vec<Row> = items.iter().map(|item| resources_row(spec, item)).collect();
        Ok(Box::new(RowsCursor::new(rows)))
    }
}

/// §4.4 `resource_templates`.
pub struct ResourceTemplatesTable;

impl ForeignTable for ResourceTemplatesTable {
    fn begin_scan(&self, ctx: ScanContext) -> McpResult<Box<dyn ScanCursor>> {
        let spec = ctx.base.spec;
        let items = fetch_list(
            &ctx.base,
            Slice::ResourceTemplates,
            "resources/templates/list",
            "resourceTemplates",
            false,
        )?;
        let rows: Vec<Row> = items
            .iter()
            .map(|item| resource_templates_row(spec, item))
            .collect();
        Ok(Box::new(RowsCursor::new(rows)))
    }
}

/// The `&'static` handler instances the registry points at.
pub static SERVER_TABLE: ServerTable = ServerTable;
pub static TOOLS_TABLE: ToolsTable = ToolsTable;
pub static PROMPTS_TABLE: PromptsTable = PromptsTable;
pub static PROMPT_ARGUMENTS_TABLE: PromptArgumentsTable = PromptArgumentsTable;
pub static RESOURCES_TABLE: ResourcesTable = ResourcesTable;
pub static RESOURCE_TEMPLATES_TABLE: ResourceTemplatesTable = ResourceTemplatesTable;

/// §4.1 `server` — exactly one row of server identity. No quals, no list
/// methods; everything comes from the resolved server, the cached session and
/// the cached `initialize` slice (see the moduledoc).
pub struct ServerTable;

/// The resolved `mode` for §4.1: the option verbatim when pinned; `auto`
/// resolves to `generic` (ADR-007: generic mode is retained and is the
/// fallback; SQL-mode probing against an engine lands with PRD-11).
fn resolved_mode(mode: crate::options::Mode) -> &'static str {
    match mode {
        crate::options::Mode::Generic | crate::options::Mode::Auto => "generic",
        crate::options::Mode::Sql => "sql",
    }
}

impl ForeignTable for ServerTable {
    fn begin_scan(&self, ctx: ScanContext) -> McpResult<Box<dyn ScanCursor>> {
        let spec = ctx.base.spec;
        let mut row = empty_row(spec);
        set(
            spec,
            &mut row,
            "name",
            Some(Cell::Text(ctx.base.server_name.clone())),
        );
        set(
            spec,
            &mut row,
            "url",
            Some(Cell::Text(ctx.base.resolved.options.url.clone())),
        );
        set(
            spec,
            &mut row,
            "mode",
            Some(Cell::Text(
                resolved_mode(ctx.base.resolved.options.mode).to_string(),
            )),
        );

        let (server_oid, user_oid) = ctx.base.cache_key();
        let ttl_ms = ctx
            .base
            .table_ttl_ms()
            .unwrap_or(ctx.base.resolved.options.cache_ttl_ms);
        let instructions = session::with_session(&ctx.base.resolved, |sess, transport| {
            set(
                spec,
                &mut row,
                "protocol_version",
                Some(Cell::Text(sess.protocol_version.clone())),
            );
            set(
                spec,
                &mut row,
                "server_name",
                text_at(&sess.server_info, "name"),
            );
            set(
                spec,
                &mut row,
                "server_version",
                text_at(&sess.server_info, "version"),
            );
            set(
                spec,
                &mut row,
                "capabilities",
                match sess.capabilities {
                    Value::Null => None,
                    ref v => Some(Cell::Json(v.clone())),
                },
            );
            set(
                spec,
                &mut row,
                "session_id",
                sess.session_id.as_ref().map(|sid| Cell::Text(sid.clone())),
            );

            // §4.10's `initialize` slice: one request per TTL period on the
            // existing session (see `cache.rs`'s moduledoc). Unlike the list
            // methods this is NOT fail-open — the handshake is the one thing a
            // session must be able to do, and a server answering -32601 here
            // is broken in a way D5 does not cover.
            let initialize =
                cache::get_or_fetch(server_oid, user_oid, ttl_ms, Slice::Initialize, || {
                    sess.request(
                        "initialize",
                        json!({
                            "protocolVersion": client::CLIENT_PROTOCOL_VERSION,
                            "capabilities": {},
                            "clientInfo": {
                                "name": client::CLIENT_NAME,
                                "version": client::CLIENT_VERSION,
                            }
                        }),
                        transport,
                    )
                    .map(|result| vec![result])
                })?;
            Ok(initialize
                .first()
                .and_then(|result| text_at(result, "instructions")))
        })?;
        set(spec, &mut row, "instructions", instructions);

        Ok(Box::new(RowsCursor::new(vec![row])))
    }
}

#[cfg(any(test, feature = "pg_test"))]
#[pgrx::pg_schema]
mod catalog_test {
    use super::*;
    use crate::cache::stub::{Reply, SseFrame, StubServer};
    use pgrx::prelude::*;
    use pgrx::JsonB;
    use std::collections::HashMap;

    const TOOLS_LIST: &str = "tools/list";
    const PROMPTS_LIST: &str = "prompts/list";

    fn map(entries: Vec<(&'static str, Reply)>) -> HashMap<String, Reply> {
        entries
            .into_iter()
            .map(|(k, v)| (k.to_string(), v))
            .collect()
    }

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

    fn count(stmt: &str) -> i64 {
        Spi::get_one::<i64>(stmt).unwrap().unwrap()
    }

    /// A fixture server: two tools (one fully-annotated, one minimal), one
    /// prompt with two arguments, one resource, one template, and a full
    /// initialize payload.
    fn fixture_replies() -> Vec<(&'static str, Reply)> {
        vec![
            (
                "initialize",
                Reply::Result(json!({
                    "protocolVersion": "2025-11-25",
                    "capabilities": {"tools": {"listChanged": true}},
                    "serverInfo": {"name": "fixture-server", "version": "1.2.3"},
                    "instructions": "be excellent to each other"
                })),
            ),
            (
                TOOLS_LIST,
                Reply::Result(json!({
                    "tools": [
                        {
                            "name": "echo",
                            "title": "Echo",
                            "description": "echoes",
                            "inputSchema": {"type": "object"},
                            "outputSchema": {"type": "string"},
                            "annotations": {
                                "readOnlyHint": true,
                                "destructiveHint": false
                            },
                            "_meta": {"owner": "fixture"}
                        },
                        {"name": "explode", "description": "fails"}
                    ]
                })),
            ),
            (
                PROMPTS_LIST,
                Reply::Result(json!({
                    "prompts": [
                        {
                            "name": "summarize",
                            "title": "Summarize",
                            "description": "summarizes",
                            "arguments": [
                                {"name": "text", "description": "the text", "required": true},
                                {"name": "style", "description": "tone", "required": false}
                            ],
                            "_meta": {"kind": "prompt"}
                        },
                        {"name": "bare"}
                    ]
                })),
            ),
            (
                "resources/list",
                Reply::Result(json!({
                    "resources": [
                        {
                            "uri": "file:///a.txt",
                            "name": "a",
                            "title": "A",
                            "description": "the a file",
                            "mimeType": "text/plain",
                            "size": 42,
                            "annotations": {"audience": ["user"]},
                            "_meta": {"rev": 7}
                        },
                        {"uri": "file:///b.bin"}
                    ]
                })),
            ),
            (
                "resources/templates/list",
                Reply::Result(json!({
                    "resourceTemplates": [
                        {
                            "uriTemplate": "file:///{path}",
                            "name": "files",
                            "description": "all the files",
                            "mimeType": "application/octet-stream",
                            "annotations": {"priority": 3},
                            "_meta": {"gen": 2}
                        }
                    ]
                })),
            ),
        ]
    }

    #[pgrx::pg_test]
    fn server_table_reports_the_handshake_and_identity() {
        cache::clear_all();
        let stub = StubServer::start(map(fixture_replies()), true);
        make_server("cat_server", &stub.url(), ", mode 'generic'");

        let row = Spi::get_one::<JsonB>("SELECT to_jsonb(s) FROM cat_server_s.server s")
            .unwrap()
            .unwrap();

        assert_eq!(
            row.0,
            json!({
                "name": "cat_server",
                "url": stub.url(),
                "mode": "generic",
                "protocol_version": "2025-11-25",
                "server_name": "fixture-server",
                "server_version": "1.2.3",
                "instructions": "be excellent to each other",
                "capabilities": {"tools": {"listChanged": true}},
                "session_id": "stub-session-1"
            })
        );

        // §4.1: exactly one row, and a second scan costs no new `initialize`
        // (the slice is cached; the session itself was reused).
        assert_eq!(count("SELECT count(*) FROM cat_server_s.server"), 1);
        assert_eq!(stub.hits("initialize"), 2, "handshake + cached slice only");
    }

    #[pgrx::pg_test]
    fn tools_table_maps_the_full_spec() {
        cache::clear_all();
        let stub = StubServer::start(map(fixture_replies()), false);
        make_server("cat_tools", &stub.url(), "");

        let echo = Spi::get_one::<JsonB>(
            "SELECT to_jsonb(t) FROM cat_tools_s.tools t WHERE t.name = 'echo'",
        )
        .unwrap()
        .unwrap();
        assert_eq!(
            echo.0,
            json!({
                "name": "echo",
                "title": "Echo",
                "description": "echoes",
                "input_schema": {"type": "object"},
                "output_schema": {"type": "string"},
                "annotations": {"readOnlyHint": true, "destructiveHint": false},
                "read_only": true,
                "destructive": false,
                "idempotent": null,
                "open_world": null,
                "meta": {"owner": "fixture"}
            })
        );

        let explode = Spi::get_one::<JsonB>(
            "SELECT to_jsonb(t) FROM cat_tools_s.tools t WHERE t.name = 'explode'",
        )
        .unwrap()
        .unwrap();
        // Minimal tool: every optional column is NULL (absent keys too).
        assert_eq!(explode.0["name"], "explode");
        assert_eq!(explode.0["title"], Value::Null);
        assert_eq!(explode.0["input_schema"], Value::Null);
        assert_eq!(explode.0["read_only"], Value::Null);
        assert_eq!(explode.0["meta"], Value::Null);
    }

    #[pgrx::pg_test]
    fn name_quals_filter_after_fetch_and_the_list_is_cached() {
        cache::clear_all();
        let stub = StubServer::start(map(fixture_replies()), false);
        make_server("cat_quals", &stub.url(), "");

        // §7.5 in miniature: several scans, ONE tools/list.
        assert_eq!(
            count("SELECT count(*) FROM cat_quals_s.tools WHERE name = 'echo'"),
            1
        );
        assert_eq!(
            count(
                "SELECT count(*) FROM cat_quals_s.tools WHERE name = ANY(ARRAY['echo','explode'])"
            ),
            2
        );
        assert_eq!(
            count("SELECT count(*) FROM cat_quals_s.tools WHERE name IN ('explode')"),
            1
        );
        assert_eq!(
            count("SELECT count(*) FROM cat_quals_s.tools WHERE name = 'nope'"),
            0
        );
        assert_eq!(
            stub.hits(TOOLS_LIST),
            1,
            "post-fetch filters are row-count optimizations over one cached list"
        );
    }

    #[pgrx::pg_test]
    fn cursor_following_exhausts_multi_page_lists() {
        // FR-7.3: one scan follows nextCursor to exhaustion.
        cache::clear_all();
        let mut replies = map(fixture_replies());
        replies.insert(
            TOOLS_LIST.to_string(),
            Reply::Sequence(vec![
                Reply::Result(json!({
                    "tools": [{"name": "page_one"}],
                    "nextCursor": "p2"
                })),
                Reply::Result(json!({
                    "tools": [{"name": "page_two_a"}, {"name": "page_two_b"}]
                })),
            ]),
        );
        let stub = StubServer::start(replies, false);
        make_server("cat_pages", &stub.url(), "");

        assert_eq!(count("SELECT count(*) FROM cat_pages_s.tools"), 3);
        assert_eq!(stub.hits(TOOLS_LIST), 2, "two pages, cached thereafter");
        assert_eq!(count("SELECT count(*) FROM cat_pages_s.tools"), 3);
        assert_eq!(stub.hits(TOOLS_LIST), 2);
    }

    #[pgrx::pg_test]
    fn method_not_found_is_fail_open_and_siblings_survive() {
        // FR-7.4 / D5: prompts/list answers -32601 ⇒ prompts and
        // prompt_arguments scan empty while tools/resources still work.
        cache::clear_all();
        let mut replies = map(fixture_replies());
        replies.insert(
            PROMPTS_LIST.to_string(),
            Reply::Error(-32601, "method not found".to_string()),
        );
        let stub = StubServer::start(replies, false);
        make_server("cat_d5", &stub.url(), "");

        assert_eq!(count("SELECT count(*) FROM cat_d5_s.prompts"), 0);
        assert_eq!(count("SELECT count(*) FROM cat_d5_s.prompt_arguments"), 0);
        assert_eq!(count("SELECT count(*) FROM cat_d5_s.tools"), 2);
        assert_eq!(count("SELECT count(*) FROM cat_d5_s.resources"), 2);
        assert_eq!(count("SELECT count(*) FROM cat_d5_s.resource_templates"), 1);
    }

    #[pgrx::pg_test]
    fn prompts_and_prompt_arguments_flatten_with_index() {
        cache::clear_all();
        let stub = StubServer::start(map(fixture_replies()), false);
        make_server("cat_prompts", &stub.url(), "");

        assert_eq!(count("SELECT count(*) FROM cat_prompts_s.prompts"), 2);

        let args = Spi::get_one::<JsonB>(
            "SELECT to_jsonb(a) FROM cat_prompts_s.prompt_arguments a
              WHERE a.prompt = 'summarize' AND a.idx = 0",
        )
        .unwrap()
        .unwrap();
        assert_eq!(
            args.0,
            json!({
                "prompt": "summarize",
                "name": "text",
                "description": "the text",
                "required": true,
                "idx": 0
            })
        );

        // The `prompt` qual filters after fetch; the bare prompt (no
        // arguments) contributes no rows; idx counts 0..n per prompt.
        assert_eq!(
            count("SELECT count(*) FROM cat_prompts_s.prompt_arguments WHERE prompt = 'summarize'"),
            2
        );
        assert_eq!(
            count("SELECT count(*) FROM cat_prompts_s.prompt_arguments"),
            2
        );
        assert_eq!(
            count(
                "SELECT count(*) FROM cat_prompts_s.prompt_arguments
                  WHERE prompt = 'summarize' AND required = false"
            ),
            1
        );
        assert_eq!(stub.hits(PROMPTS_LIST), 1, "both tables share one list");
    }

    #[pgrx::pg_test]
    fn resources_and_templates_map_mime_size_and_meta() {
        cache::clear_all();
        let stub = StubServer::start(map(fixture_replies()), false);
        make_server("cat_res", &stub.url(), "");

        let a = Spi::get_one::<JsonB>(
            "SELECT to_jsonb(r) FROM cat_res_s.resources r WHERE r.uri = 'file:///a.txt'",
        )
        .unwrap()
        .unwrap();
        assert_eq!(
            a.0,
            json!({
                "uri": "file:///a.txt",
                "name": "a",
                "title": "A",
                "description": "the a file",
                "mime_type": "text/plain",
                "size": 42,
                "annotations": {"audience": ["user"]},
                "meta": {"rev": 7}
            })
        );
        // Minimal resource: size is NULL, not 0.
        let b = Spi::get_one::<JsonB>(
            "SELECT to_jsonb(r) FROM cat_res_s.resources r WHERE r.uri = 'file:///b.bin'",
        )
        .unwrap()
        .unwrap();
        assert_eq!(b.0["size"], Value::Null);
        assert_eq!(b.0["mime_type"], Value::Null);

        let template =
            Spi::get_one::<JsonB>("SELECT to_jsonb(t) FROM cat_res_s.resource_templates t")
                .unwrap()
                .unwrap();
        assert_eq!(
            template.0,
            json!({
                "uri_template": "file:///{path}",
                "name": "files",
                "description": "all the files",
                "title": null,
                "mime_type": "application/octet-stream",
                "annotations": {"priority": 3},
                "meta": {"gen": 2}
            })
        );
    }

    #[pgrx::pg_test]
    fn short_ttl_refetches_and_zero_ttl_never_caches() {
        cache::clear_all();
        let stub = StubServer::start(map(fixture_replies()), false);
        make_server("cat_ttl", &stub.url(), ", cache_ttl_ms '80'");

        assert_eq!(count("SELECT count(*) FROM cat_ttl_s.tools"), 2);
        assert_eq!(stub.hits(TOOLS_LIST), 1);
        std::thread::sleep(std::time::Duration::from_millis(150));
        assert_eq!(count("SELECT count(*) FROM cat_ttl_s.tools"), 2);
        assert_eq!(stub.hits(TOOLS_LIST), 2, "TTL expired ⇒ refetch");

        // ttl = 0 disables caching entirely.
        let stub0 = StubServer::start(map(fixture_replies()), false);
        make_server("cat_ttl0", &stub0.url(), ", cache_ttl_ms '0'");
        assert_eq!(count("SELECT count(*) FROM cat_ttl0_s.tools"), 2);
        assert_eq!(count("SELECT count(*) FROM cat_ttl0_s.tools"), 2);
        assert_eq!(stub0.hits(TOOLS_LIST), 2, "no caching at ttl 0");
    }

    #[pgrx::pg_test]
    fn refresh_drops_the_catalog_cache_and_the_session() {
        cache::clear_all();
        let stub = StubServer::start(map(fixture_replies()), true);
        make_server("cat_refresh", &stub.url(), "");

        assert_eq!(count("SELECT count(*) FROM cat_refresh_s.tools"), 2);
        assert_eq!(stub.hits(TOOLS_LIST), 1);

        // One `server` scan caches the §4.10 `initialize` slice: handshake
        // (1) + slice fetch (2). (Only the `server` table fetches the slice;
        // list scans cost the handshake alone.)
        assert_eq!(count("SELECT count(*) FROM cat_refresh_s.server"), 1);
        assert_eq!(stub.hits("initialize"), 2);

        // §4.10: mcp.refresh drops the cache and the session, so the next
        // scan re-initializes and refetches.
        Spi::run("SELECT mcp.refresh('cat_refresh')").unwrap();
        assert_eq!(count("SELECT count(*) FROM cat_refresh_s.tools"), 2);
        assert_eq!(stub.hits(TOOLS_LIST), 2, "refresh dropped the cache");
        assert_eq!(count("SELECT count(*) FROM cat_refresh_s.server"), 1);
        assert_eq!(
            stub.hits("initialize"),
            4,
            "refresh dropped the session (handshake 3) and the cached \
             initialize slice (handshake 4)"
        );

        // A refresh against a server with nothing cached still succeeds.
        assert_eq!(
            Spi::get_one::<bool>("SELECT mcp.refresh('cat_refresh')")
                .unwrap()
                .unwrap(),
            true
        );
    }

    #[pgrx::pg_test]
    fn list_changed_notification_drops_the_cached_tools_slice() {
        // FR-7.15: the notification arrives in-flight on scan 2's SSE reply;
        // scan 3 observes the flag, drops the slice and refetches. (Scan 2
        // itself still returns the pre-notification rows — the observation is
        // best-effort, §4.10.)
        cache::clear_all();
        let tools_a = json!({"tools": [{"name": "tool_a"}]});
        let tools_b = json!({"tools": [{"name": "tool_b"}]});
        let replies = map(vec![
            (
                "initialize",
                Reply::Result(json!({
                    "protocolVersion": "2025-11-25",
                    "capabilities": {},
                    "serverInfo": {"name": "notify", "version": "0"}
                })),
            ),
            (
                TOOLS_LIST,
                Reply::Sequence(vec![
                    Reply::Result(tools_a.clone()),
                    Reply::Sse(vec![
                        SseFrame::Notify(json!({
                            "jsonrpc": "2.0",
                            "method": "notifications/tools/list_changed",
                            "params": {}
                        })),
                        SseFrame::Reply(tools_a.clone()),
                    ]),
                    Reply::Result(tools_b),
                ]),
            ),
        ]);
        let stub = StubServer::start(replies, false);
        make_server("cat_notify", &stub.url(), "");

        assert_eq!(
            count("SELECT count(*) FROM cat_notify_s.tools WHERE name = 'tool_a'"),
            1
        );
        // The notification is only observed on an IN-FLIGHT request, and a
        // plain second scan is a cache hit (no request, no observation), so
        // force the next request with `mcp.refresh`: scan 2 refetches, the
        // stub answers with the SSE frame carrying
        // notifications/tools/list_changed mid-stream.
        Spi::run("SELECT mcp.refresh('cat_notify')").unwrap();
        assert_eq!(count("SELECT count(*) FROM cat_notify_s.tools"), 1);
        assert_eq!(
            count("SELECT count(*) FROM cat_notify_s.tools WHERE name = 'tool_b'"),
            1,
            "the in-flight notification invalidated the stale slice"
        );
        assert_eq!(stub.hits(TOOLS_LIST), 3);
    }

    #[pgrx::pg_test]
    fn cross_role_cache_bleed_is_impossible() {
        // §7.4 AP-P3: role A's catalog is never served to role B. One stub
        // server answers different tool sets per bearer token; two roles with
        // two USER MAPPINGs (token_secret) query the same foreign server.
        cache::clear_all();
        // The stub answers per bearer token: A's token maps to A's
        // tool; B's token falls through the ByToken "" default to B's tool.
        let mut by_token = HashMap::new();
        by_token.insert(
            "secret_a".to_string(),
            Reply::Result(json!({"tools": [{"name": "tool_for_a"}]})),
        );
        by_token.insert(
            "".to_string(),
            Reply::Result(json!({"tools": [{"name": "tool_for_b"}]})),
        );
        let replies = map(vec![
            (
                "initialize",
                Reply::Result(json!({
                    "protocolVersion": "2025-11-25",
                    "capabilities": {},
                    "serverInfo": {"name": "ap3", "version": "0"}
                })),
            ),
            (TOOLS_LIST, Reply::ByToken(by_token)),
        ]);
        let stub = StubServer::start(replies, false);

        // Secrets for both roles.
        Spi::run("CREATE SCHEMA ap3_secrets").unwrap();
        Spi::run("CREATE TABLE ap3_secrets.tokens (role text, token text)").unwrap();
        Spi::run("INSERT INTO ap3_secrets.tokens VALUES ('ap3_role_a', 'secret_a'), ('ap3_role_b', 'secret_b')")
            .unwrap();
        Spi::run("CREATE ROLE ap3_role_a NOLOGIN").unwrap();
        Spi::run("CREATE ROLE ap3_role_b NOLOGIN").unwrap();
        for role in ["ap3_role_a", "ap3_role_b"] {
            Spi::run(&format!("GRANT USAGE ON SCHEMA ap3_secrets TO {role}")).unwrap();
            Spi::run(&format!("GRANT SELECT ON ap3_secrets.tokens TO {role}")).unwrap();
        }

        Spi::run(&format!(
            "CREATE SERVER ap3_srv FOREIGN DATA WRAPPER mcp_fdw
               OPTIONS (url '{}', auth 'bearer', timeout_ms '8000')",
            stub.url()
        ))
        .unwrap();
        for role in ["ap3_role_a", "ap3_role_b"] {
            Spi::run(&format!(
                "CREATE USER MAPPING FOR {role} SERVER ap3_srv
                   OPTIONS (token_secret 'ap3_secrets.tokens')"
            ))
            .unwrap();
        }
        Spi::run("CREATE SCHEMA ap3_s").unwrap();
        Spi::run("IMPORT FOREIGN SCHEMA mcp FROM SERVER ap3_srv INTO ap3_s").unwrap();
        for role in ["ap3_role_a", "ap3_role_b"] {
            Spi::run(&format!("GRANT USAGE ON SCHEMA ap3_s TO {role}")).unwrap();
            Spi::run("GRANT SELECT ON ALL TABLES IN SCHEMA ap3_s TO ap3_role_a").unwrap();
            Spi::run("GRANT SELECT ON ALL TABLES IN SCHEMA ap3_s TO ap3_role_b").unwrap();
        }

        // Role A populates the cache with its own principal's catalog.
        Spi::run("SET ROLE ap3_role_a").unwrap();
        assert_eq!(
            count("SELECT count(*) FROM ap3_s.tools WHERE name = 'tool_for_a'"),
            1
        );
        // Re-scan: served from A's cache, still A's rows.
        assert_eq!(count("SELECT count(*) FROM ap3_s.tools"), 1);

        // Role B must never see A's slice — it fetches (and caches) its own.
        Spi::run("SET ROLE ap3_role_b").unwrap();
        assert_eq!(
            count("SELECT count(*) FROM ap3_s.tools WHERE name = 'tool_for_a'"),
            0,
            "A's row is invisible to B"
        );
        assert_eq!(
            count("SELECT count(*) FROM ap3_s.tools WHERE name = 'tool_for_b'"),
            1
        );
        assert_eq!(count("SELECT count(*) FROM ap3_s.tools"), 1);

        // Back under A: still A's catalog (B's fetch did not overwrite it).
        Spi::run("SET ROLE ap3_role_a").unwrap();
        assert_eq!(
            count("SELECT count(*) FROM ap3_s.tools WHERE name = 'tool_for_a'"),
            1
        );
        assert_eq!(
            count("SELECT count(*) FROM ap3_s.tools WHERE name = 'tool_for_b'"),
            0
        );

        // One tools/list per role, never shared: exactly 2 total.
        assert_eq!(stub.hits(TOOLS_LIST), 2);
        Spi::run("RESET ROLE").unwrap();
    }

    #[pgrx::pg_test]
    fn an_unreachable_server_fails_the_scan_with_08006() {
        // D5 covers -32601; every other failure propagates with its own
        // SQLSTATE (FDW-path errors need the plpgsql EXCEPTION harness).
        cache::clear_all();
        Spi::run(
            "CREATE SERVER cat_dead FOREIGN DATA WRAPPER mcp_fdw
               OPTIONS (url 'http://127.0.0.1:1/mcp', auth 'none', timeout_ms '500')",
        )
        .unwrap();
        Spi::run("CREATE SCHEMA cat_dead_s").unwrap();
        Spi::run("IMPORT FOREIGN SCHEMA mcp FROM SERVER cat_dead INTO cat_dead_s").unwrap();

        let sql = r#"
            DO $probe$
            DECLARE got text;
            BEGIN
                BEGIN
                    EXECUTE $stmt$SELECT count(*) FROM cat_dead_s.tools$stmt$;
                    RAISE EXCEPTION 'NO_ERROR_RAISED';
                EXCEPTION WHEN OTHERS THEN got := SQLSTATE;
                END;
                IF got IS DISTINCT FROM '08006' THEN
                    RAISE EXCEPTION 'expected SQLSTATE 08006, got %', got;
                END IF;
            END
            $probe$;"#;
        Spi::run(sql).unwrap();
    }

    // ── PRD-7.E: the import OPTIONS read-path contract ──────────────────────

    /// `import.rs` stamps `upstream '<name>'` ('' = engine-local) and
    /// `cache_ttl_ms '<n>'` onto the foreign tables it creates; `fdw.rs`
    /// hands those options to [`TableContext`] and `fetch_list` consumes
    /// them. The probes below exercise that contract: the `scoped_items`
    /// units first, then the same at SQL level.

    fn tool_item(name: &str) -> Value {
        json!({"name": name})
    }

    #[pgrx::pg_test]
    fn a_named_upstream_keeps_only_its_prefixed_names_and_strips_the_prefix() {
        let items = vec![
            tool_item("alpha.echo"),
            tool_item("alpha.ping"),
            tool_item("beta.add"),
            tool_item("engine_status"),
        ];
        let scoped = scoped_items("alpha", &items);
        let names: Vec<&str> = scoped
            .iter()
            .filter_map(|i| i.get("name").and_then(Value::as_str))
            .collect();
        assert_eq!(names, vec!["echo", "ping"], "prefix stripped (AC-7.13)");
    }

    #[pgrx::pg_test]
    fn the_engine_local_slice_keeps_only_unprefixed_names() {
        let items = vec![
            tool_item("alpha.echo"),
            tool_item("beta.add"),
            tool_item("engine_status"),
        ];
        let scoped = scoped_items("", &items);
        let names: Vec<&str> = scoped
            .iter()
            .filter_map(|i| i.get("name").and_then(Value::as_str))
            .collect();
        assert_eq!(names, vec!["engine_status"]);
    }

    #[pgrx::pg_test]
    fn nameless_items_are_engine_local() {
        let items = vec![json!({"uri": "file:///x"}), tool_item("up.thing")];
        let local = scoped_items("", &items);
        assert_eq!(local.len(), 1, "a name-less item is engine-local");
        let up = scoped_items("up", &items);
        let names: Vec<&str> = up
            .iter()
            .filter_map(|i| i.get("name").and_then(Value::as_str))
            .collect();
        assert_eq!(
            names,
            vec!["thing"],
            "the uri-only item is not in any upstream slice"
        );
    }

    #[pgrx::pg_test]
    fn a_nested_prefix_belongs_to_its_first_segment() {
        // Matches `import.rs::upstreams_from_tool_names`'s first-dot rule.
        let items = vec![tool_item("weird.dotted.name"), tool_item("weird.plain")];
        let scoped = scoped_items("weird", &items);
        let names: Vec<&str> = scoped
            .iter()
            .filter_map(|i| i.get("name").and_then(Value::as_str))
            .collect();
        assert_eq!(names, vec!["dotted.name", "plain"]);
    }

    #[pgrx::pg_test]
    fn upstream_tables_scan_their_slice_at_sql_level() {
        // AC-7.13's read path: three foreign tables over one server —
        // the unfiltered union (default import), upstream 'alpha', and
        // upstream '' — each projecting its slice off ONE cached list.
        cache::clear_all();
        let tools = json!({"tools": [
            {"name": "alpha.echo"},
            {"name": "alpha.ping"},
            {"name": "beta.add"},
            {"name": "engine_status"}
        ]});
        let replies = map(vec![
            (
                "initialize",
                Reply::Result(json!({
                    "protocolVersion": "2025-11-25",
                    "capabilities": {},
                    "serverInfo": {"name": "sliced", "version": "0"}
                })),
            ),
            (TOOLS_LIST, Reply::Result(tools)),
        ]);
        let stub = StubServer::start(replies, false);
        Spi::run(&format!(
            "CREATE SERVER cat_slice FOREIGN DATA WRAPPER mcp_fdw
               OPTIONS (url '{}', auth 'none', timeout_ms '8000')",
            stub.url()
        ))
        .unwrap();
        Spi::run("CREATE SCHEMA cat_slice_s").unwrap();
        Spi::run(
            "IMPORT FOREIGN SCHEMA mcp LIMIT TO (tools) FROM SERVER cat_slice INTO cat_slice_s",
        )
        .unwrap();
        // The per-upstream shapes `import.rs::engine_statements` emits
        // against an engine, created here by hand against a plain server:
        // one schema per upstream, every table keeping its registry name.
        Spi::run("CREATE SCHEMA cat_slice_alpha").unwrap();
        Spi::run(
            "CREATE FOREIGN TABLE cat_slice_alpha.tools (name text)
                    SERVER cat_slice OPTIONS (upstream 'alpha')",
        )
        .unwrap();
        Spi::run("CREATE SCHEMA cat_slice_local").unwrap();
        Spi::run(
            "CREATE FOREIGN TABLE cat_slice_local.tools (name text)
                    SERVER cat_slice OPTIONS (upstream '')",
        )
        .unwrap();

        let names = |table: &str| -> Vec<String> {
            Spi::get_one::<String>(&format!(
                "SELECT string_agg(name, ',' ORDER BY name) FROM {table}"
            ))
            .unwrap()
            .unwrap()
            .split(',')
            .map(str::to_string)
            .collect()
        };
        assert_eq!(
            names("cat_slice_s.tools"),
            ["alpha.echo", "alpha.ping", "beta.add", "engine_status"]
        );
        assert_eq!(names("cat_slice_alpha.tools"), ["echo", "ping"]);
        assert_eq!(names("cat_slice_local.tools"), ["engine_status"]);

        // One cached union slice serves all three tables.
        assert_eq!(stub.hits(TOOLS_LIST), 1, "the union is cached once");
    }

    /// `cache_ttl_ms` on the *foreign table* (an `mcp.import` stamp) beats the
    /// server option: `0` makes one table always refetch while its sibling
    /// over the same server stays cached (PRD-7.E).
    #[pgrx::pg_test]
    fn the_table_cache_ttl_option_overrides_the_server_default() {
        cache::clear_all();
        let stub = StubServer::start(map(fixture_replies()), false);
        Spi::run(&format!(
            "CREATE SERVER cat_tto FOREIGN DATA WRAPPER mcp_fdw
               OPTIONS (url '{}', auth 'none', timeout_ms '8000')",
            stub.url()
        ))
        .unwrap();
        Spi::run("CREATE SCHEMA cat_tto_s").unwrap();
        Spi::run("IMPORT FOREIGN SCHEMA mcp LIMIT TO (tools) FROM SERVER cat_tto INTO cat_tto_s")
            .unwrap();
        // The per-table override shape `engine_statements` emits, by hand —
        // a dedicated schema, registry table name.
        Spi::run("CREATE SCHEMA cat_tto_zero").unwrap();
        Spi::run(
            "CREATE FOREIGN TABLE cat_tto_zero.tools (name text)
                    SERVER cat_tto OPTIONS (cache_ttl_ms '0')",
        )
        .unwrap();

        assert_eq!(count("SELECT count(*) FROM cat_tto_s.tools"), 2);
        assert_eq!(count("SELECT count(*) FROM cat_tto_zero.tools"), 2);
        assert_eq!(
            count("SELECT count(*) FROM cat_tto_zero.tools"),
            2,
            "second scan of the ttl-0 table"
        );
        assert_eq!(count("SELECT count(*) FROM cat_tto_s.tools"), 2);
        assert_eq!(
            stub.hits(TOOLS_LIST),
            3,
            "union cached once; the ttl-0 table refetched on both of its scans"
        );

        // A malformed table TTL falls back to the server default rather than
        // failing the scan (operator-written option, import only stamps
        // validated integers).
        Spi::run("CREATE SCHEMA cat_tto_junk").unwrap();
        Spi::run(
            "CREATE FOREIGN TABLE cat_tto_junk.tools (name text)
                    SERVER cat_tto OPTIONS (cache_ttl_ms 'soon')",
        )
        .unwrap();
        assert_eq!(count("SELECT count(*) FROM cat_tto_junk.tools"), 2);
        assert_eq!(stub.hits(TOOLS_LIST), 3, "served from the shared cache");
    }
}
