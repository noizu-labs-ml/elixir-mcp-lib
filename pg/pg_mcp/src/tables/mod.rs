//! The foreign-table registry — **the interface freeze** for PRD-7's four
//! implementation tracks (§6 step 7.2).
//!
//! Three things are pinned here and must not drift without a PRD:
//!
//! 1. **`TableSpec`** — every `mcp_fdw` table's name and exact column list
//!    (name, PostgreSQL type, source strategy), transcribed from PRD-7
//!    §4.1-§4.7. `IMPORT FOREIGN SCHEMA` and the FDW planner both read this;
//!    `SELECT * FROM mcp.tools` must agree with `tools/list` column-for-column.
//! 2. **The scan/modify traits** — the surface the four tracks implement. The
//!    shape mirrors the ADR-002 architecture (`begin_scan` → cursor with
//!    `iter_scan` / `re_scan`; `end_scan` = `Drop`; `begin_modify` → session
//!    with `insert`), with *all* `pg_sys` types kept out: a track writes plain
//!    Rust against [`ScanContext`] / [`ModifyContext`] and returns [`Row`]s.
//! 3. **The registry** — name → spec → handler. Every table is registered
//!    with a real handler as of PRD-7's tracks A-D (the [`StubTable`]
//!    placeholder — scans empty, refuses INSERT — remains as the tripwire
//!    the `stub_handlers_*` tests exercise should a handler ever revert).
//!    A track owns its table's *handler* only: the `handler:` line in
//!    [`REGISTRY`] points at the track's `&'static dyn ForeignTable`. Specs,
//!    traits and this file otherwise stay as-is.
//!
//! File ownership: `tables/catalog.rs` (Track A), `tables/readthrough.rs`
//! (Track B), `tables/tool_calls.rs` (Track C), plus `cache.rs` (Track A) and
//! `import.rs` (Track D) hold the implementations. Everything below is the
//! contract they code against.
//!
//! `unsafe` never appears here (FR-6.1): the `pg_sys` boundary lives in
//! `fdw.rs`, which converts between `TupleTableSlot`s and [`Cell`]s.

pub mod catalog;
pub mod per_tool;
pub mod readthrough;
pub mod tool_calls;

use crate::errors::{McpError, McpResult};
use crate::quals::Qual;
use crate::session;
use pgrx::pg_sys;
use serde_json::Value;

// ── column model ─────────────────────────────────────────────────────────────

/// PostgreSQL type of a registry column. The FDW boundary uses [`ColumnType::oid`]
/// for slot writes and `import.rs` uses [`ColumnType::sql_name`] for DDL.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColumnType {
    Text,
    Jsonb,
    Boolean,
    Int4,
    Int8,
    Bytea,
    Uuid,
    TimestampTz,
    /// PRD-8 §4.1: JSON Schema `number` → `double precision`.
    Float8,
    /// PRD-8 §4.1: `"type":"string","format":"date"` → `date`.
    Date,
}

impl ColumnType {
    pub const fn oid(self) -> pg_sys::Oid {
        match self {
            ColumnType::Text => pg_sys::TEXTOID,
            ColumnType::Jsonb => pg_sys::JSONBOID,
            ColumnType::Boolean => pg_sys::BOOLOID,
            ColumnType::Int4 => pg_sys::INT4OID,
            ColumnType::Int8 => pg_sys::INT8OID,
            ColumnType::Bytea => pg_sys::BYTEAOID,
            ColumnType::Uuid => pg_sys::UUIDOID,
            ColumnType::TimestampTz => pg_sys::TIMESTAMPTZOID,
            ColumnType::Float8 => pg_sys::FLOAT8OID,
            ColumnType::Date => pg_sys::DATEOID,
        }
    }

    /// The SQL spelling `IMPORT FOREIGN SCHEMA` emits.
    pub const fn sql_name(self) -> &'static str {
        match self {
            ColumnType::Text => "text",
            ColumnType::Jsonb => "jsonb",
            ColumnType::Boolean => "boolean",
            ColumnType::Int4 => "integer",
            ColumnType::Int8 => "bigint",
            ColumnType::Bytea => "bytea",
            ColumnType::Uuid => "uuid",
            ColumnType::TimestampTz => "timestamptz",
            ColumnType::Float8 => "double precision",
            ColumnType::Date => "date",
        }
    }
}

/// Where a column's value comes from (PRD-7 §4.1-§4.7 "Source" column).
/// Documentary: the tracks use it to structure their fetch code, and the
/// anti-pattern tests (§7.4 AP-P1) rely on the list/read-through split.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    /// The foreign server's own identity (name, url, mode, session id).
    ServerIdentity,
    /// The `initialize` handshake result.
    Initialize,
    /// A paginated MCP list method; the argument is the method name.
    List(&'static str),
    /// One request per row key; the argument is the method name.
    ReadThrough(&'static str),
    /// Produced by `INSERT INTO tool_calls ... RETURNING` (`tools/call`).
    Invocation,
    /// Filled by the extension itself (call log metadata, audit columns).
    Local,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ColumnSpec {
    pub name: &'static str,
    pub pg_type: ColumnType,
    pub source: Source,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TableSpec {
    /// Canonical table name: the `IMPORT FOREIGN SCHEMA` name *and* the name
    /// the FDW resolves a foreign table by. Renaming a foreign table in
    /// Postgres detaches it from its handler (documented in `fdw.rs`).
    pub name: &'static str,
    pub columns: &'static [ColumnSpec],
}

impl TableSpec {
    pub fn arity(&self) -> usize {
        self.columns.len()
    }

    /// 1-based `AttrNumber` for a column name, or `None` when unknown.
    pub fn attno(&self, column: &str) -> Option<usize> {
        self.columns
            .iter()
            .position(|c| c.name == column)
            .map(|i| i + 1)
    }

    pub fn column(&self, index: usize) -> Option<&'static ColumnSpec> {
        self.columns.get(index)
    }
}

// ── row model ────────────────────────────────────────────────────────────────

/// One typed cell. Variants cover every type in §4.1-§4.7; the pg_sys
/// conversion (Datum in, Datum out) lives in `fdw.rs`.
#[derive(Debug, Clone, PartialEq)]
pub enum Cell {
    Text(String),
    Json(Value),
    Bool(bool),
    Int4(i32),
    Int8(i64),
    Bytea(Vec<u8>),
    Uuid([u8; 16]),
    /// Microseconds since the PostgreSQL epoch (2000-01-01), as `TimestampTz`.
    TimestampTz(i64),
    /// PRD-8 §4.1: a `double precision` cell (`number` schema properties).
    Float8(f64),
    /// PRD-8 §4.1: a `date` cell, carried as its wire text and converted by
    /// `date_in` at the slot boundary (`fdw.rs`).
    Date(String),
}

impl Cell {
    /// JSON projection for qual post-filtering (`PRD-7 §4.2`: pushed `=` /
    /// `= ANY` quals are applied as row-count filters inside the extension).
    pub fn as_json(&self) -> Value {
        match self {
            Cell::Text(s) => Value::String(s.clone()),
            Cell::Json(v) => v.clone(),
            Cell::Bool(b) => Value::Bool(*b),
            Cell::Int4(i) => Value::from(*i),
            Cell::Int8(i) => Value::from(*i),
            Cell::Float8(f) => serde_json::Number::from_f64(*f)
                .map(Value::Number)
                .unwrap_or(Value::Null),
            Cell::Date(d) => Value::String(d.clone()),
            // Binary and time values never appear in a supported qual shape
            // (see `quals.rs::is_qual_primitive`); project them as null so a
            // stray qual can never spuriously match.
            Cell::Bytea(_) | Cell::Uuid(_) | Cell::TimestampTz(_) => Value::Null,
        }
    }
}

/// One row, cell-for-cell aligned with its `TableSpec.columns` (`None` = NULL).
pub type Row = Vec<Option<Cell>>;

/// Build an all-NULL row for `spec`.
pub fn empty_row(spec: &TableSpec) -> Row {
    vec![None; spec.arity()]
}

/// The input side of `INSERT INTO mcp.tool_calls (tool, arguments) ...`
/// (§4.7): the values the caller supplied, looked up by column name. Columns
/// the caller skipped are `None`; PRD-7 §4.7 says output columns supplied on
/// input are ignored, so `tool_calls.rs` overwrites them.
pub struct InsertRow {
    spec: &'static TableSpec,
    cells: Row,
}

impl InsertRow {
    pub fn new(spec: &'static TableSpec, cells: Row) -> InsertRow {
        InsertRow { spec, cells }
    }

    pub fn value(&self, column: &str) -> Option<&Cell> {
        let idx = self.spec.attno(column)? - 1;
        self.cells.get(idx)?.as_ref()
    }
}

// ── contexts (everything a track needs, nothing pg_sys) ─────────────────────

/// Shared per-station context: which table, which server, whose credentials.
/// Resolved once per statement by `fdw.rs` (D3: nothing captured at build
/// time; FR-7.18: a role without a USER MAPPING fails here, before any table
/// code runs).
pub struct TableContext {
    pub spec: &'static TableSpec,
    /// Foreign server name, for `errdetail` (`raise_ctx`) and per-server logic.
    pub server_name: String,
    /// Catalog-resolved server options + the calling role's credential.
    pub resolved: session::Resolved,
    /// The foreign table's own OPTIONS (PRD-7.E cross-track contract with
    /// `import.rs`): `upstream` scopes the table to one engine upstream's
    /// slice of the catalog (`''` = the engine-local slice; absent = the
    /// unfiltered union) and `cache_ttl_ms` overrides the §4.10 server cache
    /// TTL for this table. Read by the catalog handlers (`tables/catalog.rs`);
    /// an empty vec is the default import's shape.
    pub table_options: Vec<(String, String)>,
}

impl TableContext {
    /// Cache key for Track A's catalog cache (ADR-004: the user OID is part of
    /// the key; the backend PID is implicit — process-local).
    pub fn cache_key(&self) -> (pg_sys::Oid, pg_sys::Oid) {
        (self.resolved.server_oid, self.resolved.user_oid)
    }

    /// The value of one foreign-table OPTIONS entry, if present.
    pub fn table_option(&self, key: &str) -> Option<&str> {
        self.table_options
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
    }

    /// The §4.10 per-table cache TTL override (`cache_ttl_ms` table option,
    /// stamped by `mcp.import`). `None` = use the server option default. A
    /// malformed value falls back to the default rather than failing the scan:
    /// the import path only stamps validated integers, and a hand-written
    /// `ALTER FOREIGN TABLE ... OPTIONS` with junk is an operator error the
    /// server-level TTL safely absorbs.
    pub fn table_ttl_ms(&self) -> Option<u64> {
        self.table_option(crate::import::TABLE_OPTION_CACHE_TTL_MS)
            .and_then(|v| v.trim().parse().ok())
    }

    /// The `upstream` slice marker (`import.rs`'s engine layout): `Some("")`
    /// is the engine-local slice, `Some(name)` scopes the table to that
    /// upstream, `None` is the unfiltered union (default import).
    pub fn upstream(&self) -> Option<&str> {
        self.table_option(crate::import::TABLE_OPTION_UPSTREAM)
    }
}

/// Scan context: [`TableContext`] plus the pushed-down quals (only columns the
/// handler declares in [`ForeignTable::pushdown_columns`] are present; every
/// other restriction stays in Postgres for re-checking).
pub struct ScanContext {
    pub base: TableContext,
    pub quals: Vec<Qual>,
}

impl ScanContext {
    /// Helper for read-through tables (Tracks B): the distinct values a qual
    /// restricts `column` to, in qual order.
    pub fn restricted_values(&self, column: &str) -> Vec<Value> {
        self.quals
            .iter()
            .filter(|q| q.field == column)
            .flat_map(|q| q.restricted_values().into_iter().cloned())
            .collect()
    }
}

/// Modify context. Only `tool_calls` accepts inserts; every other table's
/// `begin_modify` is the trait default and raises `0A000`.
pub type ModifyContext = TableContext;

// ── the frozen trait surface ─────────────────────────────────────────────────

/// One in-progress scan. `end_scan` is `Drop`: `fdw.rs` frees the cursor when
/// the executor ends (or errors out of) the scan, so a cursor holding an MCP
/// session resource releases it on every exit path.
pub trait ScanCursor: Send {
    /// Next row, or `None` when exhausted. Full `spec.arity()` width, aligned
    /// to `spec.columns`.
    fn iter_scan(&mut self) -> McpResult<Option<Row>>;

    /// Restart the scan from the beginning. Called by the executor when a node
    /// above re-runs the scan; the default is "nothing to unwind", which is
    /// correct for fully-buffered cursors.
    fn re_scan(&mut self) -> McpResult<()> {
        Ok(())
    }
}

/// One in-progress modify session (`tool_calls` only). Dropped by `fdw.rs` at
/// `end_modify`; the audit SPI write commits with the caller's transaction.
pub trait ModifySession: Send {
    /// Perform exactly one `tools/call` for this row and return the full-width
    /// result row (FR-7.9). `isError: true` is a row, never an error (FR-7.10).
    fn insert(&mut self, input: &InsertRow) -> McpResult<Row>;
}

/// Per-table handler. One `&'static dyn ForeignTable` per registry entry.
pub trait ForeignTable: Sync {
    /// Columns whose `=` / `= ANY` / `IN` quals this handler genuinely applies
    /// (post-fetch or request-shaping). Only quals on these columns are pushed
    /// down at plan time; everything else stays in Postgres. The default —
    /// none — is what the stub handlers ship with, so the frozen foundation
    /// never claims a pushdown it does not perform.
    fn pushdown_columns(&self) -> &'static [&'static str] {
        &[]
    }

    /// `begin_foreign_scan`: open the cursor. Catalog tables fetch their list
    /// methods here (through the cache); read-through tables validate their
    /// required quals here (`0A000` naming the missing column, §4.5-§4.6).
    fn begin_scan(&self, ctx: ScanContext) -> McpResult<Box<dyn ScanCursor>>;

    /// `begin_foreign_modify`. Only `tool_calls` overrides this.
    fn begin_modify(&self, _ctx: ModifyContext) -> McpResult<Box<dyn ModifySession>> {
        Err(McpError::FeatureNotSupported(
            "INSERT is only supported on mcp.tool_calls (PRD-7 §4.7)".to_string(),
        ))
    }
}

// ── stub handlers (replaced by the tracks, one registry line at a time) ─────

/// Compile-clean placeholder: scans as empty, never does I/O, refuses INSERT.
/// `SELECT * FROM mcp.tools` returns zero rows with this handler installed —
/// which is the foundation's acceptance bar — while every PRD-6 behaviour
/// stays untouched.
struct StubTable;

struct EmptyCursor;

impl ScanCursor for EmptyCursor {
    fn iter_scan(&mut self) -> McpResult<Option<Row>> {
        Ok(None)
    }
}

impl ForeignTable for StubTable {
    fn begin_scan(&self, _ctx: ScanContext) -> McpResult<Box<dyn ScanCursor>> {
        Ok(Box::new(EmptyCursor))
    }
}

/// The one stub instance every table is registered with.
static STUB_TABLE: StubTable = StubTable;

// Track B's read-through handlers (PRD-7 §6 step 7.4).
static RESOURCE_CONTENTS_TABLE: readthrough::ResourceContentsTable =
    readthrough::ResourceContentsTable;
static PROMPT_MESSAGES_TABLE: readthrough::PromptMessagesTable = readthrough::PromptMessagesTable;
static COMPLETIONS_TABLE: readthrough::CompletionsTable = readthrough::CompletionsTable;

#[cfg(any(test, feature = "pg_test"))]
fn test_resolved() -> crate::session::Resolved {
    crate::session::Resolved {
        server_oid: pg_sys::Oid::INVALID,
        user_oid: pg_sys::Oid::INVALID,
        options: crate::options::ServerOptions::parse(&[
            ("url".to_string(), "http://127.0.0.1:1/mcp".to_string()),
            ("auth".to_string(), "none".to_string()),
        ])
        .unwrap(),
        bearer: None,
    }
}

// ── the registry (PRD-7 §4.1-§4.7, transcribed verbatim) ────────────────────

static SERVER_SPEC: TableSpec = TableSpec {
    name: "server",
    columns: &[
        ColumnSpec {
            name: "name",
            pg_type: ColumnType::Text,
            source: Source::ServerIdentity,
        },
        ColumnSpec {
            name: "url",
            pg_type: ColumnType::Text,
            source: Source::ServerIdentity,
        },
        ColumnSpec {
            name: "protocol_version",
            pg_type: ColumnType::Text,
            source: Source::Initialize,
        },
        ColumnSpec {
            name: "server_name",
            pg_type: ColumnType::Text,
            source: Source::Initialize,
        },
        ColumnSpec {
            name: "server_version",
            pg_type: ColumnType::Text,
            source: Source::Initialize,
        },
        ColumnSpec {
            name: "instructions",
            pg_type: ColumnType::Text,
            source: Source::Initialize,
        },
        ColumnSpec {
            name: "capabilities",
            pg_type: ColumnType::Jsonb,
            source: Source::Initialize,
        },
        ColumnSpec {
            name: "mode",
            pg_type: ColumnType::Text,
            source: Source::ServerIdentity,
        },
        ColumnSpec {
            name: "session_id",
            pg_type: ColumnType::Text,
            source: Source::ServerIdentity,
        },
    ],
};

static TOOLS_SPEC: TableSpec = TableSpec {
    name: "tools",
    columns: &[
        ColumnSpec {
            name: "name",
            pg_type: ColumnType::Text,
            source: Source::List("tools/list"),
        },
        ColumnSpec {
            name: "title",
            pg_type: ColumnType::Text,
            source: Source::List("tools/list"),
        },
        ColumnSpec {
            name: "description",
            pg_type: ColumnType::Text,
            source: Source::List("tools/list"),
        },
        ColumnSpec {
            name: "input_schema",
            pg_type: ColumnType::Jsonb,
            source: Source::List("tools/list"),
        },
        ColumnSpec {
            name: "output_schema",
            pg_type: ColumnType::Jsonb,
            source: Source::List("tools/list"),
        },
        ColumnSpec {
            name: "annotations",
            pg_type: ColumnType::Jsonb,
            source: Source::List("tools/list"),
        },
        ColumnSpec {
            name: "read_only",
            pg_type: ColumnType::Boolean,
            source: Source::List("tools/list"),
        },
        ColumnSpec {
            name: "destructive",
            pg_type: ColumnType::Boolean,
            source: Source::List("tools/list"),
        },
        ColumnSpec {
            name: "idempotent",
            pg_type: ColumnType::Boolean,
            source: Source::List("tools/list"),
        },
        ColumnSpec {
            name: "open_world",
            pg_type: ColumnType::Boolean,
            source: Source::List("tools/list"),
        },
        ColumnSpec {
            name: "meta",
            pg_type: ColumnType::Jsonb,
            source: Source::List("tools/list"),
        },
    ],
};

static PROMPTS_SPEC: TableSpec = TableSpec {
    name: "prompts",
    columns: &[
        ColumnSpec {
            name: "name",
            pg_type: ColumnType::Text,
            source: Source::List("prompts/list"),
        },
        ColumnSpec {
            name: "title",
            pg_type: ColumnType::Text,
            source: Source::List("prompts/list"),
        },
        ColumnSpec {
            name: "description",
            pg_type: ColumnType::Text,
            source: Source::List("prompts/list"),
        },
        ColumnSpec {
            name: "meta",
            pg_type: ColumnType::Jsonb,
            source: Source::List("prompts/list"),
        },
    ],
};

static PROMPT_ARGUMENTS_SPEC: TableSpec = TableSpec {
    name: "prompt_arguments",
    columns: &[
        ColumnSpec {
            name: "prompt",
            pg_type: ColumnType::Text,
            source: Source::List("prompts/list"),
        },
        ColumnSpec {
            name: "name",
            pg_type: ColumnType::Text,
            source: Source::List("prompts/list"),
        },
        ColumnSpec {
            name: "description",
            pg_type: ColumnType::Text,
            source: Source::List("prompts/list"),
        },
        ColumnSpec {
            name: "required",
            pg_type: ColumnType::Boolean,
            source: Source::List("prompts/list"),
        },
        ColumnSpec {
            name: "idx",
            pg_type: ColumnType::Int4,
            source: Source::List("prompts/list"),
        },
    ],
};

static RESOURCES_SPEC: TableSpec = TableSpec {
    name: "resources",
    columns: &[
        ColumnSpec {
            name: "uri",
            pg_type: ColumnType::Text,
            source: Source::List("resources/list"),
        },
        ColumnSpec {
            name: "name",
            pg_type: ColumnType::Text,
            source: Source::List("resources/list"),
        },
        ColumnSpec {
            name: "title",
            pg_type: ColumnType::Text,
            source: Source::List("resources/list"),
        },
        ColumnSpec {
            name: "description",
            pg_type: ColumnType::Text,
            source: Source::List("resources/list"),
        },
        ColumnSpec {
            name: "mime_type",
            pg_type: ColumnType::Text,
            source: Source::List("resources/list"),
        },
        ColumnSpec {
            name: "size",
            pg_type: ColumnType::Int8,
            source: Source::List("resources/list"),
        },
        ColumnSpec {
            name: "annotations",
            pg_type: ColumnType::Jsonb,
            source: Source::List("resources/list"),
        },
        ColumnSpec {
            name: "meta",
            pg_type: ColumnType::Jsonb,
            source: Source::List("resources/list"),
        },
    ],
};

static RESOURCE_TEMPLATES_SPEC: TableSpec = TableSpec {
    name: "resource_templates",
    columns: &[
        ColumnSpec {
            name: "uri_template",
            pg_type: ColumnType::Text,
            source: Source::List("resources/templates/list"),
        },
        ColumnSpec {
            name: "name",
            pg_type: ColumnType::Text,
            source: Source::List("resources/templates/list"),
        },
        ColumnSpec {
            name: "title",
            pg_type: ColumnType::Text,
            source: Source::List("resources/templates/list"),
        },
        ColumnSpec {
            name: "description",
            pg_type: ColumnType::Text,
            source: Source::List("resources/templates/list"),
        },
        ColumnSpec {
            name: "mime_type",
            pg_type: ColumnType::Text,
            source: Source::List("resources/templates/list"),
        },
        ColumnSpec {
            name: "annotations",
            pg_type: ColumnType::Jsonb,
            source: Source::List("resources/templates/list"),
        },
        ColumnSpec {
            name: "meta",
            pg_type: ColumnType::Jsonb,
            source: Source::List("resources/templates/list"),
        },
    ],
};

static RESOURCE_CONTENTS_SPEC: TableSpec = TableSpec {
    name: "resource_contents",
    columns: &[
        ColumnSpec {
            name: "uri",
            pg_type: ColumnType::Text,
            source: Source::ReadThrough("resources/read"),
        },
        ColumnSpec {
            name: "idx",
            pg_type: ColumnType::Int4,
            source: Source::ReadThrough("resources/read"),
        },
        ColumnSpec {
            name: "mime_type",
            pg_type: ColumnType::Text,
            source: Source::ReadThrough("resources/read"),
        },
        ColumnSpec {
            name: "text",
            pg_type: ColumnType::Text,
            source: Source::ReadThrough("resources/read"),
        },
        ColumnSpec {
            name: "blob",
            pg_type: ColumnType::Bytea,
            source: Source::ReadThrough("resources/read"),
        },
        ColumnSpec {
            name: "meta",
            pg_type: ColumnType::Jsonb,
            source: Source::ReadThrough("resources/read"),
        },
    ],
};

static PROMPT_MESSAGES_SPEC: TableSpec = TableSpec {
    name: "prompt_messages",
    columns: &[
        ColumnSpec {
            name: "prompt",
            pg_type: ColumnType::Text,
            source: Source::ReadThrough("prompts/get"),
        },
        ColumnSpec {
            name: "arguments",
            pg_type: ColumnType::Jsonb,
            source: Source::ReadThrough("prompts/get"),
        },
        ColumnSpec {
            name: "idx",
            pg_type: ColumnType::Int4,
            source: Source::ReadThrough("prompts/get"),
        },
        ColumnSpec {
            name: "role",
            pg_type: ColumnType::Text,
            source: Source::ReadThrough("prompts/get"),
        },
        ColumnSpec {
            name: "content_type",
            pg_type: ColumnType::Text,
            source: Source::ReadThrough("prompts/get"),
        },
        ColumnSpec {
            name: "text",
            pg_type: ColumnType::Text,
            source: Source::ReadThrough("prompts/get"),
        },
        ColumnSpec {
            name: "content",
            pg_type: ColumnType::Jsonb,
            source: Source::ReadThrough("prompts/get"),
        },
        ColumnSpec {
            name: "description",
            pg_type: ColumnType::Text,
            source: Source::ReadThrough("prompts/get"),
        },
    ],
};

static COMPLETIONS_SPEC: TableSpec = TableSpec {
    name: "completions",
    columns: &[
        ColumnSpec {
            name: "ref",
            pg_type: ColumnType::Jsonb,
            source: Source::ReadThrough("completion/complete"),
        },
        ColumnSpec {
            name: "argument_name",
            pg_type: ColumnType::Text,
            source: Source::ReadThrough("completion/complete"),
        },
        ColumnSpec {
            name: "argument_value",
            pg_type: ColumnType::Text,
            source: Source::ReadThrough("completion/complete"),
        },
        ColumnSpec {
            name: "value",
            pg_type: ColumnType::Text,
            source: Source::ReadThrough("completion/complete"),
        },
        ColumnSpec {
            name: "idx",
            pg_type: ColumnType::Int4,
            source: Source::ReadThrough("completion/complete"),
        },
        ColumnSpec {
            name: "total",
            pg_type: ColumnType::Int4,
            source: Source::ReadThrough("completion/complete"),
        },
        ColumnSpec {
            name: "has_more",
            pg_type: ColumnType::Boolean,
            source: Source::ReadThrough("completion/complete"),
        },
    ],
};

static TOOL_CALLS_SPEC: TableSpec = TableSpec {
    name: "tool_calls",
    columns: &[
        ColumnSpec {
            name: "id",
            pg_type: ColumnType::Uuid,
            source: Source::Local,
        },
        ColumnSpec {
            name: "tool",
            pg_type: ColumnType::Text,
            source: Source::Invocation,
        },
        ColumnSpec {
            name: "arguments",
            pg_type: ColumnType::Jsonb,
            source: Source::Invocation,
        },
        ColumnSpec {
            name: "content",
            pg_type: ColumnType::Jsonb,
            source: Source::Invocation,
        },
        ColumnSpec {
            name: "structured",
            pg_type: ColumnType::Jsonb,
            source: Source::Invocation,
        },
        ColumnSpec {
            name: "is_error",
            pg_type: ColumnType::Boolean,
            source: Source::Invocation,
        },
        ColumnSpec {
            name: "error",
            pg_type: ColumnType::Jsonb,
            source: Source::Invocation,
        },
        ColumnSpec {
            name: "called_at",
            pg_type: ColumnType::TimestampTz,
            source: Source::Local,
        },
        ColumnSpec {
            name: "duration_ms",
            pg_type: ColumnType::Int4,
            source: Source::Local,
        },
    ],
};

/// One registry row: the spec plus its handler. The `handler:` column is the
/// single extension point — Tracks A/B/C repoint it; nothing else changes.
pub struct TableEntry {
    pub spec: &'static TableSpec,
    pub handler: &'static dyn ForeignTable,
}

pub static REGISTRY: &[TableEntry] = &[
    TableEntry {
        spec: &SERVER_SPEC,
        handler: &catalog::SERVER_TABLE,
    },
    TableEntry {
        spec: &TOOLS_SPEC,
        handler: &catalog::TOOLS_TABLE,
    },
    TableEntry {
        spec: &PROMPTS_SPEC,
        handler: &catalog::PROMPTS_TABLE,
    },
    TableEntry {
        spec: &PROMPT_ARGUMENTS_SPEC,
        handler: &catalog::PROMPT_ARGUMENTS_TABLE,
    },
    TableEntry {
        spec: &RESOURCES_SPEC,
        handler: &catalog::RESOURCES_TABLE,
    },
    TableEntry {
        spec: &RESOURCE_TEMPLATES_SPEC,
        handler: &catalog::RESOURCE_TEMPLATES_TABLE,
    },
    TableEntry {
        spec: &RESOURCE_CONTENTS_SPEC,
        handler: &RESOURCE_CONTENTS_TABLE,
    },
    TableEntry {
        spec: &PROMPT_MESSAGES_SPEC,
        handler: &PROMPT_MESSAGES_TABLE,
    },
    TableEntry {
        spec: &COMPLETIONS_SPEC,
        handler: &COMPLETIONS_TABLE,
    },
    // Track C owns this handler (PRD-7 §4.7-§4.8).
    TableEntry {
        spec: &TOOL_CALLS_SPEC,
        handler: &crate::tables::tool_calls::TOOL_CALLS_TABLE,
    },
];

/// Registry lookup by canonical table name.
pub fn find(name: &str) -> Option<&'static TableEntry> {
    REGISTRY.iter().find(|e| e.spec.name == name)
}

#[cfg(any(test, feature = "pg_test"))]
#[pgrx::pg_schema]
mod tests {
    use super::*;

    /// PRD-7 §4.1-§4.7: the ten registered tables, exactly these names.
    #[pgrx::pg_test]
    fn registry_holds_exactly_the_prd_tables() {
        let names: Vec<&str> = REGISTRY.iter().map(|e| e.spec.name).collect();
        assert_eq!(
            names,
            vec![
                "server",
                "tools",
                "prompts",
                "prompt_arguments",
                "resources",
                "resource_templates",
                "resource_contents",
                "prompt_messages",
                "completions",
                "tool_calls",
            ]
        );
    }

    #[pgrx::pg_test]
    fn column_names_are_unique_and_non_empty_per_table() {
        for entry in REGISTRY {
            let mut seen = std::collections::HashSet::new();
            for col in entry.spec.columns {
                assert!(
                    !col.name.is_empty(),
                    "{}: empty column name",
                    entry.spec.name
                );
                assert!(
                    seen.insert(col.name),
                    "{}: duplicate column {}",
                    entry.spec.name,
                    col.name
                );
                assert!(entry.spec.attno(col.name).is_some());
            }
            assert_eq!(entry.spec.arity(), entry.spec.columns.len());
        }
    }

    #[pgrx::pg_test]
    fn tool_tables_carry_their_prd_columns_and_types() {
        let tools = find("tools").unwrap().spec;
        assert_eq!(tools.arity(), 11);
        assert_eq!(tools.attno("name"), Some(1));
        assert_eq!(tools.attno("input_schema"), Some(4));
        assert_eq!(tools.attno("read_only"), Some(7));
        assert_eq!(tools.column(6).unwrap().pg_type, ColumnType::Boolean);
        assert_eq!(tools.column(10).unwrap().pg_type, ColumnType::Jsonb);

        let calls = find("tool_calls").unwrap().spec;
        assert_eq!(calls.arity(), 9);
        assert_eq!(calls.column(0).unwrap().pg_type, ColumnType::Uuid);
        assert_eq!(calls.attno("tool"), Some(2));
        assert_eq!(calls.attno("arguments"), Some(3));
        assert_eq!(calls.attno("is_error"), Some(6));
        assert_eq!(calls.attno("duration_ms"), Some(9));
        assert_eq!(calls.column(7).unwrap().pg_type, ColumnType::TimestampTz);

        // §4.6: `idx` not `position` (ADR-003 reserved-word rule).
        assert!(find("resource_contents")
            .unwrap()
            .spec
            .attno("idx")
            .is_some());
    }

    #[pgrx::pg_test]
    fn type_oids_agree_with_the_sql_spelling() {
        for entry in REGISTRY {
            for col in entry.spec.columns {
                match (col.pg_type.oid(), col.pg_type.sql_name()) {
                    (t, "text") => assert_eq!(t, pg_sys::TEXTOID),
                    (t, "jsonb") => assert_eq!(t, pg_sys::JSONBOID),
                    (t, "boolean") => assert_eq!(t, pg_sys::BOOLOID),
                    (t, "integer") => assert_eq!(t, pg_sys::INT4OID),
                    (t, "bigint") => assert_eq!(t, pg_sys::INT8OID),
                    (t, "bytea") => assert_eq!(t, pg_sys::BYTEAOID),
                    (t, "uuid") => assert_eq!(t, pg_sys::UUIDOID),
                    (t, "timestamptz") => assert_eq!(t, pg_sys::TIMESTAMPTZOID),
                    (t, "double precision") => assert_eq!(t, pg_sys::FLOAT8OID),
                    (t, "date") => assert_eq!(t, pg_sys::DATEOID),
                    _ => unreachable!(),
                }
            }
        }
    }

    #[pgrx::pg_test]
    fn unknown_table_names_do_not_resolve() {
        assert!(find("nope").is_none());
        assert!(find("TOOL_CALLS").is_none(), "lookups are case-sensitive");
    }

    #[pgrx::pg_test]
    fn stub_handlers_scan_as_empty_and_refuse_inserts() {
        // §6 step 7.2, updated as tracks land: the assertions below hold for
        // tables still served by `StubTable`. All ten are real now; the loop
        // is kept as a tripwire for any table that ever reverts to the stub.
        for entry in REGISTRY {
            if !is_stub_handler(entry.handler) {
                continue;
            }
            let ctx = ScanContext {
                base: TableContext {
                    spec: entry.spec,
                    server_name: "test".to_string(),
                    // Unresolved credentials are fine: the stub does no I/O,
                    // which is exactly the property the foundation freeze
                    // depends on (`SELECT * FROM mcp.tools` = 0 rows).
                    resolved: test_resolved(),
                    table_options: vec![],
                },
                quals: vec![],
            };
            let mut cursor = entry.handler.begin_scan(ctx).unwrap();
            assert!(
                cursor.iter_scan().unwrap().is_none(),
                "{}: stub must scan as empty",
                entry.spec.name
            );

            let mctx = TableContext {
                spec: entry.spec,
                server_name: "test".to_string(),
                resolved: test_resolved(),
                table_options: vec![],
            };
            let outcome = entry.handler.begin_modify(mctx);
            assert!(
                outcome.is_err(),
                "{}: stub must refuse INSERT",
                entry.spec.name
            );
            let err = outcome.err().unwrap();
            assert_eq!(
                err.sqlstate(),
                "0A000",
                "{}: INSERT refused with 0A000",
                entry.spec.name
            );
        }
    }

    #[pgrx::pg_test]
    fn stub_handlers_declare_no_pushdown() {
        // The foundation never claims a pushdown it does not perform. (Real
        // handlers declare their own; `catalog.rs` asserts ToolsTable's,
        // `tool_calls.rs` its log-filter columns.)
        for entry in REGISTRY {
            if !is_stub_handler(entry.handler) {
                continue;
            }
            assert!(entry.handler.pushdown_columns().is_empty());
        }
    }

    /// Track B's pushdown claims match exactly the qual columns the PRD
    /// gives those tables (§4.4-§4.6).
    #[pgrx::pg_test]
    fn track_b_handlers_declare_exactly_their_prd_pushdown_columns() {
        let expected: &[(&str, &[&str])] = &[
            ("resource_contents", &["uri"]),
            ("prompt_messages", &["prompt", "arguments"]),
            ("completions", &["ref", "argument_name", "argument_value"]),
        ];
        for (table, columns) in expected {
            let entry = find(table).unwrap();
            let mut declared = entry.handler.pushdown_columns().to_vec();
            declared.sort_unstable();
            let mut want = columns.to_vec();
            want.sort_unstable();
            assert_eq!(declared, want, "{table}: pushdown columns");
        }
    }

    /// Identity check: is this entry still served by the compile-clean stub?
    /// Fat-pointer equality works here because both sides are `&'static` to
    /// the very same `STUB_TABLE` static.
    fn is_stub_handler(handler: &'static dyn ForeignTable) -> bool {
        std::ptr::eq(
            handler as *const dyn ForeignTable as *const (),
            &STUB_TABLE as &dyn ForeignTable as *const dyn ForeignTable as *const (),
        )
    }

    #[pgrx::pg_test]
    fn insert_row_reads_by_column_name() {
        let spec = find("tool_calls").unwrap().spec;
        let mut cells = empty_row(spec);
        cells[spec.attno("tool").unwrap() - 1] = Some(Cell::Text("echo".into()));
        let input = InsertRow::new(spec, cells);
        assert_eq!(input.value("tool"), Some(&Cell::Text("echo".into())));
        assert_eq!(input.value("arguments"), None);
        assert!(input.value("no_such_column").is_none());
    }
}
