//! **Track B owns this file** (PRD-7 §6 step 7.4): the read-through tables
//! `resource_contents`, `prompt_messages`, `completions`.
//!
//! One [`ForeignTable`] per table against the frozen surface in `tables/mod.rs`:
//!
//! * `resource_contents` (§4.4): `uri` `=` / `= ANY` / `IN` quals become one
//!   `resources/read` per distinct URI, results unioned with `idx` numbering
//!   each `contents` array. Unqualified scans fall back to every URI from
//!   `resources/list`, capped by `max_unqualified_reads` (`0` ⇒ `0A000` with
//!   the §4.4 message, exceeding ⇒ `54023` naming the cap).
//! * `prompt_messages` (§4.5): a `prompt` qual is required (`0A000` naming the
//!   column otherwise); an optional `arguments` jsonb equality qual narrows
//!   `prompts/get`, defaulting to `{}`.
//! * `completions` (§4.6): `ref`, `argument_name` and `argument_value` quals
//!   are all required; any missing one raises `0A000` naming the column.
//!
//! ## Shape
//!
//! Every read-through scan **fully buffers its rows inside `begin_scan`**: the
//! MCP calls happen there, and `iter_scan` replays the buffer. This keeps
//! error handling in one place (below) and makes `iter_scan` infallible.
//!
//! ## Errors
//!
//! All failures go through the §4.9 map via [`McpError::raise_ctx`], whose
//! `errdetail` names the foreign server and the MCP method that failed — never
//! the token (FR-6.11, FR-7.17). `fdw.rs`'s scan wrapper reports a bare
//! `raise()`, so Track B raises *inside* the handler where the method name is
//! known; `begin_scan` therefore never returns `Err`.
//!
//! ## Q3 decision (blob decode)
//!
//! PRD-7 §9 Q3 asks whether `resource_contents.blob` should stay base64
//! `text` rather than decode. The column type is declared `bytea`, so **the
//! extension decodes base64 to bytes, as written**; surfacing the base64
//! alphabet through a `bytea` column would corrupt every consumer. A block
//! whose `blob` is not valid base64 raises `22023` naming the URI (the
//! closest §4.9 row: the server sent an invalid parameter-shaped value).
//!
//! Read-through results are **never cached** (§4.10): every scan goes straight
//! to the foreign server through the session layer.

use crate::client::list_all;
use crate::errors::{McpError, McpResult};
use crate::quals::Qual;
use crate::session;
use crate::tables::{Cell, ForeignTable, Row, ScanContext, ScanCursor, TableSpec};
use serde_json::{json, Value};

// ── qual → request keys ──────────────────────────────────────────────────────

/// The distinct values the pushed quals constrain `column` to, honoring the
/// AND between them: `Equal` values and `= ANY` sets all intersect. Deduped,
/// qual order preserved.
///
/// * `None` — no qual touched `column` at all (the caller decides what an
///   unqualified scan means: fallback, or a required-qual error).
/// * `Some(values)` — the scan is constrained to exactly these values; an
///   empty vec (`uri = ANY(ARRAY[]::text[])`) is a legitimate "matches
///   nothing" restriction and must produce zero rows without any request.
fn restricted(quals: &[Qual], column: &str) -> Option<Vec<Value>> {
    let mut acc: Option<Vec<Value>> = None;
    for qual in quals.iter().filter(|q| q.field == column) {
        let set: Vec<Value> = qual.restricted_values().into_iter().cloned().collect();
        acc = Some(match acc {
            None => set,
            Some(prev) => prev.into_iter().filter(|v| set.contains(v)).collect(),
        });
    }
    acc.map(dedupe)
}

/// Order-preserving dedupe (qual sets are tiny; linear contains is fine).
fn dedupe(values: Vec<Value>) -> Vec<Value> {
    let mut out: Vec<Value> = Vec::with_capacity(values.len());
    for v in values {
        if !out.contains(&v) {
            out.push(v);
        }
    }
    out
}

// ── error context ────────────────────────────────────────────────────────────

/// An [`McpError`] plus the MCP method whose execution (or refusal) produced
/// it, so the raise site can build the §4.9 `errdetail`.
#[derive(Debug)]
struct CtxError {
    e: McpError,
    method: &'static str,
}

impl CtxError {
    fn new(e: McpError, method: &'static str) -> CtxError {
        CtxError { e, method }
    }

    fn feature(message: String, method: &'static str) -> CtxError {
        CtxError::new(McpError::FeatureNotSupported(message), method)
    }
}

// ── buffered cursor ──────────────────────────────────────────────────────────

/// Fully-buffered cursor: `begin_scan` fetched everything, `iter_scan` replays.
struct BufferedCursor {
    rows: Vec<Row>,
    pos: usize,
}

impl BufferedCursor {
    fn new(rows: Vec<Row>) -> BufferedCursor {
        BufferedCursor { rows, pos: 0 }
    }
}

impl ScanCursor for BufferedCursor {
    fn iter_scan(&mut self) -> McpResult<Option<Row>> {
        Ok(if self.pos < self.rows.len() {
            self.pos += 1;
            Some(self.rows[self.pos - 1].clone())
        } else {
            None
        })
    }

    fn re_scan(&mut self) -> McpResult<()> {
        self.pos = 0;
        Ok(())
    }
}

// ── row helpers ──────────────────────────────────────────────────────────────

/// Set one column of a full-width row by name.
fn put(spec: &TableSpec, row: &mut Row, column: &str, cell: Cell) {
    if let Some(attno) = spec.attno(column) {
        row[attno - 1] = Some(cell);
    }
}

fn text_of(value: &Value) -> Option<String> {
    value.as_str().map(str::to_string)
}

// ── resource_contents (§4.4) ─────────────────────────────────────────────────

pub struct ResourceContentsTable;

/// The §4.4 message for an unqualified scan at the default cap, verbatim.
const UNQUALIFIED_RESOURCE_CONTENTS: &str =
    "unqualified scan of mcp.resource_contents requires a uri qual or max_unqualified_reads > 0";

impl ForeignTable for ResourceContentsTable {
    fn pushdown_columns(&self) -> &'static [&'static str] {
        &["uri"]
    }

    fn begin_scan(&self, ctx: ScanContext) -> McpResult<Box<dyn ScanCursor>> {
        let server = ctx.base.server_name.clone();
        match resource_contents_rows(&ctx) {
            Ok(rows) => Ok(Box::new(BufferedCursor::new(rows))),
            Err(failed) => failed.e.raise_ctx(&server, failed.method),
        }
    }
}

/// `resources/list` every URI and cap the fan-out (`max_unqualified_reads`),
/// or refuse with the §4.4 wording when the cap is `0`.
fn unqualified_uris(ctx: &ScanContext) -> Result<Vec<String>, CtxError> {
    let cap = ctx.base.resolved.options.max_unqualified_reads;
    if cap == 0 {
        return Err(CtxError::feature(
            UNQUALIFIED_RESOURCE_CONTENTS.to_string(),
            "resources/list",
        ));
    }

    let items = session::with_session(&ctx.base.resolved, |sess, transport| {
        list_all(sess, "resources/list", "resources", json!({}), transport)
    })
    .map_err(|e| CtxError::new(e, "resources/list"))?;

    let uris: Vec<String> = items
        .iter()
        .filter_map(|item| item.get("uri").and_then(Value::as_str).map(str::to_string))
        .collect();

    // The cap bounds the number of `resources/read` calls this scan would
    // issue, which is the distinct URI count.
    let distinct = dedupe(uris.into_iter().map(Value::String).collect())
        .into_iter()
        .filter_map(|v| text_of(&v))
        .collect::<Vec<String>>();
    if distinct.len() as i64 > cap {
        return Err(CtxError::new(
            McpError::TooManyArguments(format!(
                "unqualified scan of mcp.resource_contents would read {} distinct URIs, \
                 exceeding max_unqualified_reads = {cap}",
                distinct.len()
            )),
            "resources/read",
        ));
    }
    Ok(distinct)
}

fn resource_contents_rows(ctx: &ScanContext) -> Result<Vec<Row>, CtxError> {
    let spec = ctx.base.spec;

    // No uri qual at all → capped fallback (§4.4); `Some(empty)` (an
    // `= ANY(ARRAY[])` restriction) matches nothing and issues no requests.
    let uris: Vec<String> = match restricted(&ctx.quals, "uri") {
        None => unqualified_uris(ctx)?,
        Some(values) => values.into_iter().filter_map(|v| text_of(&v)).collect(),
    };

    let mut rows: Vec<Row> = Vec::new();
    for uri in uris {
        let result = session::with_session(&ctx.base.resolved, |sess, transport| {
            sess.request("resources/read", json!({ "uri": uri }), transport)
        })
        .map_err(|e| CtxError::new(e, "resources/read"))?;

        let contents = result
            .get("contents")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        for (idx, content) in contents.iter().enumerate() {
            rows.push(resource_content_row(spec, &uri, idx, content)?);
        }
    }
    Ok(rows)
}

/// One `contents` entry → one row. `text` blocks fill `text`; `blob` blocks
/// are base64-decoded into `bytea` (see the Q3 decision in the module docs).
fn resource_content_row(
    spec: &'static TableSpec,
    uri: &str,
    idx: usize,
    content: &Value,
) -> Result<Row, CtxError> {
    let mut row: Row = vec![None; spec.arity()];
    put(spec, &mut row, "uri", Cell::Text(uri.to_string()));
    put(spec, &mut row, "idx", Cell::Int4(idx as i32));
    if let Some(mime) = content.get("mimeType").and_then(Value::as_str) {
        put(spec, &mut row, "mime_type", Cell::Text(mime.to_string()));
    }
    if let Some(text) = content.get("text").and_then(Value::as_str) {
        put(spec, &mut row, "text", Cell::Text(text.to_string()));
    }
    if let Some(blob) = content.get("blob").and_then(Value::as_str) {
        let bytes = base64_decode(blob).ok_or_else(|| {
            CtxError::new(
                McpError::InvalidParams(format!(
                    "resource_contents: the server's blob for uri \"{uri}\" is not valid base64"
                )),
                "resources/read",
            )
        })?;
        put(spec, &mut row, "blob", Cell::Bytea(bytes));
    }
    if let Some(meta) = content.get("_meta").filter(|m| !m.is_null()) {
        put(spec, &mut row, "meta", Cell::Json(meta.clone()));
    }
    Ok(row)
}

// ── prompt_messages (§4.5) ───────────────────────────────────────────────────

pub struct PromptMessagesTable;

impl ForeignTable for PromptMessagesTable {
    fn pushdown_columns(&self) -> &'static [&'static str] {
        &["prompt", "arguments"]
    }

    fn begin_scan(&self, ctx: ScanContext) -> McpResult<Box<dyn ScanCursor>> {
        let server = ctx.base.server_name.clone();
        match prompt_messages_rows(&ctx) {
            Ok(rows) => Ok(Box::new(BufferedCursor::new(rows))),
            Err(failed) => failed.e.raise_ctx(&server, failed.method),
        }
    }
}

fn prompt_messages_rows(ctx: &ScanContext) -> Result<Vec<Row>, CtxError> {
    let spec = ctx.base.spec;

    // `prompt` is required (§4.5). A present-but-empty restriction (`= ANY of
    // nothing`) simply matches nothing; a *missing* qual is the 0A000 case.
    let prompts = match restricted(&ctx.quals, "prompt") {
        None => {
            return Err(CtxError::feature(
                "mcp.prompt_messages requires a prompt = '...' qual (PRD-7 §4.5)".to_string(),
                "prompts/get",
            ))
        }
        Some(values) => values,
    };

    // `arguments` is an optional jsonb equality qual, defaulting to `{}`.
    let argument_sets = match restricted(&ctx.quals, "arguments") {
        None => vec![json!({})],
        Some(values) => values,
    };

    let mut rows: Vec<Row> = Vec::new();
    for prompt in &prompts {
        let name = match text_of(prompt) {
            Some(n) => n,
            None => continue,
        };
        for arguments in &argument_sets {
            let result = session::with_session(&ctx.base.resolved, |sess, transport| {
                sess.request(
                    "prompts/get",
                    json!({
                        "name": name,
                        "arguments": session::params_object(Some(arguments.clone())),
                    }),
                    transport,
                )
            })
            .map_err(|e| CtxError::new(e, "prompts/get"))?;

            let description = result
                .get("description")
                .and_then(Value::as_str)
                .map(str::to_string);
            let messages = result
                .get("messages")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            for (idx, message) in messages.iter().enumerate() {
                let content = message.get("content").cloned().unwrap_or(Value::Null);
                let mut row: Row = vec![None; spec.arity()];
                put(spec, &mut row, "prompt", Cell::Text(name.clone()));
                put(spec, &mut row, "arguments", Cell::Json(arguments.clone()));
                put(spec, &mut row, "idx", Cell::Int4(idx as i32));
                if let Some(role) = message.get("role").and_then(Value::as_str) {
                    put(spec, &mut row, "role", Cell::Text(role.to_string()));
                }
                if let Some(content_type) = content.get("type").and_then(Value::as_str) {
                    put(
                        spec,
                        &mut row,
                        "content_type",
                        Cell::Text(content_type.to_string()),
                    );
                }
                if let Some(text) = content.get("text").and_then(Value::as_str) {
                    put(spec, &mut row, "text", Cell::Text(text.to_string()));
                }
                if !content.is_null() {
                    put(spec, &mut row, "content", Cell::Json(content.clone()));
                }
                if let Some(description) = &description {
                    put(
                        spec,
                        &mut row,
                        "description",
                        Cell::Text(description.clone()),
                    );
                }
                rows.push(row);
            }
        }
    }
    Ok(rows)
}

// ── completions (§4.6) ───────────────────────────────────────────────────────

pub struct CompletionsTable;

impl ForeignTable for CompletionsTable {
    fn pushdown_columns(&self) -> &'static [&'static str] {
        &["ref", "argument_name", "argument_value"]
    }

    fn begin_scan(&self, ctx: ScanContext) -> McpResult<Box<dyn ScanCursor>> {
        let server = ctx.base.server_name.clone();
        match completions_rows(&ctx) {
            Ok(rows) => Ok(Box::new(BufferedCursor::new(rows))),
            Err(failed) => failed.e.raise_ctx(&server, failed.method),
        }
    }
}

/// The three qual-required columns, in the order the error names them.
const COMPLETION_REQUIRED: &[&str] = &["ref", "argument_name", "argument_value"];

fn completions_rows(ctx: &ScanContext) -> Result<Vec<Row>, CtxError> {
    let spec = ctx.base.spec;

    let mut restricted_cols: Vec<Vec<Value>> = Vec::new();
    for column in COMPLETION_REQUIRED {
        match restricted(&ctx.quals, column) {
            None => {
                return Err(CtxError::feature(
                    format!("mcp.completions requires a {column} = qual (PRD-7 §4.6)"),
                    "completion/complete",
                ))
            }
            // `''` for "all" is an ordinary string value; whatever the quals
            // restrict the column to is what we request.
            Some(values) => restricted_cols.push(values),
        }
    }
    let (refs, names, values) = (
        restricted_cols[0].clone(),
        restricted_cols[1].clone(),
        restricted_cols[2].clone(),
    );

    // One `completion/complete` per distinct (ref, name, value) combination.
    // The common case is one of each; multiple distinct values (from `= ANY`
    // quals, which pushdown legitimately claims) fan out correctly.
    let mut rows: Vec<Row> = Vec::new();
    for ref_ in &refs {
        for name in &names {
            for value in &values {
                let (name, value) = match (text_of(name), text_of(value)) {
                    (Some(n), Some(v)) => (n, v),
                    _ => continue,
                };
                let result = session::with_session(&ctx.base.resolved, |sess, transport| {
                    sess.request(
                        "completion/complete",
                        json!({
                            "ref": ref_,
                            "argument": { "name": name, "value": value },
                        }),
                        transport,
                    )
                })
                .map_err(|e| CtxError::new(e, "completion/complete"))?;

                let completion = result.get("completion").cloned().unwrap_or(Value::Null);
                let candidates = completion
                    .get("values")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                let total = completion.get("total").and_then(Value::as_i64);
                let has_more = completion.get("hasMore").and_then(Value::as_bool);
                for (idx, candidate) in candidates.iter().enumerate() {
                    let mut row: Row = vec![None; spec.arity()];
                    put(spec, &mut row, "ref", Cell::Json(ref_.clone()));
                    put(spec, &mut row, "argument_name", Cell::Text(name.clone()));
                    put(spec, &mut row, "argument_value", Cell::Text(value.clone()));
                    if let Some(text) = candidate.as_str() {
                        put(spec, &mut row, "value", Cell::Text(text.to_string()));
                    }
                    put(spec, &mut row, "idx", Cell::Int4(idx as i32));
                    if let Some(total) = total {
                        put(spec, &mut row, "total", Cell::Int4(total as i32));
                    }
                    if let Some(has_more) = has_more {
                        put(spec, &mut row, "has_more", Cell::Bool(has_more));
                    }
                    rows.push(row);
                }
            }
        }
    }
    Ok(rows)
}

// ── base64 (RFC 4648 standard alphabet) ──────────────────────────────────────

/// Decode standard base64. Lenient about surrounding whitespace and about
/// explicit padding; rejects characters outside the alphabet and impossible
/// group lengths. No external crate: the decoder is ~25 lines and the only
/// base64 the extension needs (Q3).
fn base64_decode(input: &str) -> Option<Vec<u8>> {
    fn value_of(byte: u8) -> Option<u32> {
        match byte {
            b'A'..=b'Z' => Some((byte - b'A') as u32),
            b'a'..=b'z' => Some((byte - b'a') as u32 + 26),
            b'0'..=b'9' => Some((byte - b'0') as u32 + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }

    let stripped: Vec<u8> = input
        .bytes()
        .filter(|b| !b" \t\r\n".contains(b))
        .take_while(|&b| b != b'=')
        .collect();

    let mut out = Vec::with_capacity(stripped.len() * 3 / 4 + 3);
    for chunk in stripped.chunks(4) {
        if chunk.len() == 1 {
            return None; // a lone sextet cannot encode a byte
        }
        let mut acc: u32 = 0;
        for (i, &b) in chunk.iter().enumerate() {
            acc |= value_of(b)? << (18 - 6 * i);
        }
        out.push((acc >> 16) as u8);
        if chunk.len() > 2 {
            out.push((acc >> 8) as u8);
        }
        if chunk.len() > 3 {
            out.push(acc as u8);
        }
    }
    Some(out)
}

// ── tests ────────────────────────────────────────────────────────────────────

#[cfg(any(test, feature = "pg_test"))]
mod stub {
    //! A minimal in-crate MCP-over-HTTP stub: one loopback `TcpListener` on an
    //! OS-assigned port answering JSON-RPC POSTs from a route closure, and
    //! recording every request method it saw. This is the counting oracle the
    //! AP-P2 regression (zero `tools/call` during SELECT) is asserted against.

    use serde_json::{json, Value};
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    /// What the route table answers for one request.
    pub enum Reply {
        Result(Value),
        Error(i64, String),
        Accepted,
    }

    pub struct StubServer {
        pub url: String,
        pub hits: Arc<Mutex<Vec<String>>>,
        stop: Arc<AtomicBool>,
    }

    impl StubServer {
        pub fn start<F>(routes: F) -> StubServer
        where
            F: Fn(&str, &Value) -> Reply + Send + Sync + 'static,
        {
            let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
            listener.set_nonblocking(true).expect("nonblocking");
            let port = listener.local_addr().unwrap().port();
            let hits = Arc::new(Mutex::new(Vec::new()));
            let stop = Arc::new(AtomicBool::new(false));

            let routes = Arc::new(routes);
            let hits_thread = Arc::clone(&hits);
            let stop_thread = Arc::clone(&stop);
            std::thread::spawn(move || {
                while !stop_thread.load(Ordering::Relaxed) {
                    match listener.accept() {
                        Ok((stream, _)) => handle(stream, &routes, &hits_thread),
                        Err(_) => std::thread::sleep(Duration::from_millis(20)),
                    }
                }
            });

            StubServer {
                url: format!("http://127.0.0.1:{port}/mcp"),
                hits,
                stop,
            }
        }

        /// How many requests the stub saw for one method.
        pub fn count(&self, method: &str) -> usize {
            self.hits
                .lock()
                .unwrap()
                .iter()
                .filter(|m| m.as_str() == method)
                .count()
        }
    }

    impl Drop for StubServer {
        fn drop(&mut self) {
            self.stop.store(true, Ordering::Relaxed);
        }
    }

    fn handle<F: Fn(&str, &Value) -> Reply>(
        mut stream: TcpStream,
        routes: &Arc<F>,
        hits: &Mutex<Vec<String>>,
    ) {
        let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
        let mut buf: Vec<u8> = Vec::new();
        let mut chunk = [0u8; 4096];

        // Read to the end of the headers.
        let header_end = loop {
            if let Some(pos) = find(&buf, b"\r\n\r\n") {
                break pos + 4;
            }
            match stream.read(&mut chunk) {
                Ok(0) | Err(_) => return,
                Ok(n) => buf.extend_from_slice(&chunk[..n]),
            }
        };

        // Read the body to its declared length.
        let header_text = String::from_utf8_lossy(&buf[..header_end]).to_ascii_lowercase();
        let content_length: usize = header_text
            .lines()
            .find_map(|line| line.strip_prefix("content-length:"))
            .and_then(|v| v.trim().parse().ok())
            .unwrap_or(0);
        while buf.len() < header_end + content_length {
            match stream.read(&mut chunk) {
                Ok(0) | Err(_) => break,
                Ok(n) => buf.extend_from_slice(&chunk[..n]),
            }
        }

        let request: Value = serde_json::from_slice(&buf[header_end..]).unwrap_or(Value::Null);
        let method = request
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let id = request.get("id").cloned();
        hits.lock().unwrap().push(method.clone());

        // Server-initiated notifications are answered 202 and never routed.
        if method.starts_with("notifications/") {
            let _ = respond(&mut stream, 202, &Vec::new());
            return;
        }

        let params = request.get("params").cloned().unwrap_or(json!({}));
        let reply = routes(&method, &params);
        if let Reply::Accepted = reply {
            let _ = respond(&mut stream, 202, &Vec::new());
            return;
        }

        let body = match (id, reply) {
            (Some(id), Reply::Result(v)) => json!({ "jsonrpc": "2.0", "id": id, "result": v }),
            (Some(id), Reply::Error(code, message)) => json!({
                "jsonrpc": "2.0", "id": id,
                "error": { "code": code, "message": message }
            }),
            (None, Reply::Result(v)) => json!({ "jsonrpc": "2.0", "result": v }),
            (None, Reply::Error(code, message)) => json!({
                "jsonrpc": "2.0",
                "error": { "code": code, "message": message }
            }),
            (_, Reply::Accepted) => unreachable!(),
        };
        let body = serde_json::to_vec(&body).unwrap();
        let _ = respond(&mut stream, 200, &body);
    }

    fn respond(stream: &mut TcpStream, status: u16, body: &[u8]) -> std::io::Result<()> {
        let head = format!(
            "HTTP/1.1 {status} OK\r\ncontent-type: application/json\r\n\
             content-length: {}\r\nconnection: close\r\n\r\n",
            body.len()
        );
        stream.write_all(head.as_bytes())?;
        stream.write_all(body)
    }

    fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
        haystack
            .windows(needle.len())
            .position(|window| window == needle)
    }
}

#[cfg(any(test, feature = "pg_test"))]
#[pgrx::pg_schema]
mod tests {
    use super::stub::{Reply, StubServer};
    use super::*;
    use crate::options::ServerOptions;
    use crate::quals::Qual;
    use pgrx::prelude::Spi;
    use serde_json::{json, Value};
    use std::sync::{Arc, Mutex};

    /// A `Resolved` aimed at the stub, valid without any catalog access
    /// (`with_session` never consults the catalog; only `resolve` does).
    fn resolved_for(url: &str) -> session::Resolved {
        session::Resolved {
            server_oid: pgrx::pg_sys::Oid::INVALID,
            user_oid: session::current_user_oid(),
            options: ServerOptions::parse(&[
                ("url".to_string(), url.to_string()),
                ("auth".to_string(), "none".to_string()),
            ])
            .unwrap(),
            bearer: None,
        }
    }

    fn ctx_for(entry_name: &str, resolved: session::Resolved, quals: Vec<Qual>) -> ScanContext {
        let entry = crate::tables::find(entry_name).unwrap();
        ScanContext {
            base: crate::tables::TableContext {
                spec: entry.spec,
                server_name: "stub".to_string(),
                resolved,
                table_options: vec![],
            },
            quals,
        }
    }

    fn eq(column: &str, value: Value) -> Qual {
        Qual::equal(column, value)
    }

    fn rows_of(entry_name: &str, resolved: session::Resolved, quals: Vec<Qual>) -> Vec<Row> {
        let entry = crate::tables::find(entry_name).unwrap();
        match entry
            .handler
            .begin_scan(ctx_for(entry_name, resolved, quals))
        {
            Ok(mut cursor) => {
                let mut rows = Vec::new();
                while let Some(row) = cursor.iter_scan().unwrap() {
                    rows.push(row);
                }
                rows
            }
            Err(_) => panic!("begin_scan raised through ereport; use the SQL probes for errors"),
        }
    }

    fn cell<'a>(spec: &'static crate::tables::TableSpec, row: &'a Row, column: &str) -> &'a Cell {
        row[spec.attno(column).unwrap() - 1]
            .as_ref()
            .unwrap_or_else(|| panic!("column {column} was NULL"))
    }

    /// The fixture MCP server: initialize handshake plus per-test routes.
    fn stub_with<F>(routes: F) -> StubServer
    where
        F: Fn(&str, &Value) -> Reply + Send + Sync + 'static,
    {
        StubServer::start(move |method, params| match method {
            "initialize" => Reply::Result(json!({
                "protocolVersion": "2025-03-26",
                "serverInfo": { "name": "stub", "version": "0.0.0" },
                "capabilities": {},
            })),
            "notifications/initialized" => Reply::Accepted,
            _ => routes(method, params),
        })
    }

    // ── pure helpers ─────────────────────────────────────────────────────────

    #[pgrx::pg_test]
    fn restricted_intersects_and_dedupes() {
        let quals = vec![
            eq("uri", json!("a")),
            Qual::any_equal("uri", vec![json!("a"), json!("b")]),
        ];
        assert_eq!(
            restricted(&quals, "uri"),
            Some(vec![json!("a")]),
            "AND of = and = ANY intersects"
        );

        let disjoint = vec![eq("uri", json!("a")), eq("uri", json!("b"))];
        assert_eq!(
            restricted(&disjoint, "uri"),
            Some(vec![]),
            "contradictory Equal quals match nothing"
        );

        let dupes = vec![Qual::any_equal(
            "uri",
            vec![json!("a"), json!("a"), json!("b")],
        )];
        assert_eq!(
            restricted(&dupes, "uri"),
            Some(vec![json!("a"), json!("b")]),
            "duplicate set members dedupe"
        );

        let none = vec![eq("prompt", json!("x"))];
        assert_eq!(restricted(&none, "uri"), None, "no qual on the column");

        let empty = vec![Qual::any_equal("uri", vec![])];
        assert_eq!(
            restricted(&empty, "uri"),
            Some(vec![]),
            "empty ANY is a matches-nothing restriction, not absence"
        );
    }

    #[pgrx::pg_test]
    fn base64_decode_round_trips() {
        assert_eq!(base64_decode(""), Some(Vec::new()));
        assert_eq!(base64_decode("aGVsbG8="), Some(b"hello".to_vec()));
        assert_eq!(base64_decode("aGVsbG8h"), Some(b"hello!".to_vec()));
        assert_eq!(base64_decode("aGVsbG8hIQ=="), Some(b"hello!!".to_vec()));
        // Whitespace and missing padding are tolerated.
        assert_eq!(base64_decode("aGVs\nbG8="), Some(b"hello".to_vec()));
        assert_eq!(base64_decode("aGVsbG8"), Some(b"hello".to_vec()));
        // Alphabet violations and impossible group lengths are rejected.
        assert_eq!(base64_decode("a$b="), None);
        assert_eq!(base64_decode("a"), None);
    }

    // ── resource_contents ────────────────────────────────────────────────────

    #[pgrx::pg_test]
    fn resource_contents_reads_once_per_distinct_uri() {
        let stub = stub_with(|method, params| match method {
            "resources/read" => {
                let uri = params["uri"].as_str().unwrap_or_default();
                if uri == "file:///a" {
                    Reply::Result(json!({ "contents": [
                        { "uri": "file:///a", "mimeType": "text/plain", "text": "alpha" },
                        { "uri": "file:///a", "mimeType": "application/octet-stream",
                          "blob": "AAEC" },
                    ]}))
                } else {
                    Reply::Result(json!({ "contents": [
                        { "uri": "file:///b", "mimeType": "text/plain", "text": "beta" },
                    ]}))
                }
            }
            _ => Reply::Error(-32601, "unexpected".into()),
        });

        // `uri = ANY(ARRAY['file:///a','file:///a','file:///b'])`: duplicates
        // dedupe to two reads (AC-7.4's shape).
        let quals = vec![Qual::any_equal(
            "uri",
            vec![json!("file:///a"), json!("file:///a"), json!("file:///b")],
        )];
        let rows = rows_of("resource_contents", resolved_for(&stub.url), quals);

        assert_eq!(stub.count("resources/read"), 2, "one read per distinct uri");
        assert_eq!(
            stub.count("resources/list"),
            0,
            "qualified scan never lists"
        );
        assert_eq!(rows.len(), 3, "2 contents for a + 1 for b");

        let spec = crate::tables::find("resource_contents").unwrap().spec;
        let (first, blob, last) = (&rows[0], &rows[1], &rows[2]);
        assert_eq!(cell(spec, first, "uri"), &Cell::Text("file:///a".into()));
        assert_eq!(cell(spec, first, "idx"), &Cell::Int4(0));
        assert_eq!(
            cell(spec, first, "mime_type"),
            &Cell::Text("text/plain".into())
        );
        assert_eq!(cell(spec, first, "text"), &Cell::Text("alpha".into()));
        assert!(
            first[spec.attno("blob").unwrap() - 1].is_none(),
            "text row has no blob"
        );

        assert_eq!(cell(spec, blob, "idx"), &Cell::Int4(1));
        assert_eq!(
            cell(spec, blob, "blob"),
            &Cell::Bytea(vec![0x00, 0x01, 0x02]),
            "blob base64-decodes to bytea (Q3)"
        );
        assert!(
            blob[spec.attno("text").unwrap() - 1].is_none(),
            "blob row has no text"
        );

        assert_eq!(cell(spec, last, "uri"), &Cell::Text("file:///b".into()));
        assert_eq!(cell(spec, last, "idx"), &Cell::Int4(0));
    }

    #[pgrx::pg_test]
    fn resource_contents_meta_and_empty_any() {
        let stub = stub_with(|method, _| match method {
            "resources/read" => Reply::Result(json!({ "contents": [
                { "uri": "file:///a", "mimeType": "text/plain", "text": "x",
                  "_meta": { "tag": "t" } },
            ]})),
            _ => Reply::Error(-32601, "unexpected".into()),
        });
        let resolved = resolved_for(&stub.url);

        // `uri = ANY(ARRAY[]::text[])` is a real restriction: zero rows, no I/O.
        let rows = rows_of(
            "resource_contents",
            resolved_for(&stub.url),
            vec![Qual::any_equal("uri", vec![])],
        );
        assert!(rows.is_empty());
        assert_eq!(stub.count("resources/read"), 0);

        let rows = rows_of(
            "resource_contents",
            resolved,
            vec![eq("uri", json!("file:///a"))],
        );
        let spec = crate::tables::find("resource_contents").unwrap().spec;
        assert_eq!(rows.len(), 1);
        assert_eq!(
            cell(spec, &rows[0], "meta"),
            &Cell::Json(json!({ "tag": "t" })),
            "_meta surfaces as jsonb"
        );
    }

    #[pgrx::pg_test]
    fn unqualified_resource_contents_cap_zero_message_is_verbatim() {
        // The cap-0 refusal happens before any I/O, so an unreachable URL is
        // fine — the error must fire first.
        let resolved = resolved_for("http://127.0.0.1:1/mcp");
        let ctx = ctx_for("resource_contents", resolved, vec![]);
        let err = resource_contents_rows(&ctx).err().expect("cap 0 refuses");
        assert_eq!(err.e.sqlstate(), "0A000");
        assert_eq!(
            err.e.message(),
            "unqualified scan of mcp.resource_contents requires a uri qual or max_unqualified_reads > 0",
            "the §4.4 message, verbatim"
        );
        assert_eq!(err.method, "resources/list");
    }

    #[pgrx::pg_test]
    fn unqualified_resource_contents_honors_the_cap_boundary() {
        let uris = json!({ "resources": [
            { "uri": "file:///a" }, { "uri": "file:///b" },
        ]});
        let stub = stub_with(move |method, _| match method {
            "resources/list" => Reply::Result(uris.clone()),
            "resources/read" => Reply::Result(json!({ "contents": [
                { "uri": "file:///x", "mimeType": "text/plain", "text": "t" },
            ]})),
            _ => Reply::Error(-32601, "unexpected".into()),
        });

        let mut resolved = resolved_for(&stub.url);
        resolved.options.max_unqualified_reads = 2;

        // At the cap (2 reads for 2 URIs) the scan succeeds and unions rows.
        let rows = rows_of("resource_contents", resolved, vec![]);
        assert_eq!(stub.count("resources/list"), 1);
        assert_eq!(stub.count("resources/read"), 2, "one read per listed uri");
        assert_eq!(rows.len(), 2);

        // One over the cap refuses with 54023 naming the cap.
        let mut resolved = resolved_for(&stub.url);
        resolved.options.max_unqualified_reads = 1;
        let ctx = ctx_for("resource_contents", resolved, vec![]);
        let err = resource_contents_rows(&ctx)
            .err()
            .expect("over cap refuses");
        assert_eq!(err.e.sqlstate(), "54023");
        assert!(
            err.e.message().contains("max_unqualified_reads = 1"),
            "error names the cap: {}",
            err.e.message()
        );
    }

    // ── prompt_messages ──────────────────────────────────────────────────────

    #[pgrx::pg_test]
    fn prompt_messages_requires_a_prompt_qual() {
        let resolved = resolved_for("http://127.0.0.1:1/mcp");
        let ctx = ctx_for("prompt_messages", resolved, vec![]);
        let err = prompt_messages_rows(&ctx).err().expect("no prompt qual");
        assert_eq!(err.e.sqlstate(), "0A000");
        assert!(
            err.e.message().contains("prompt"),
            "error names the missing column: {}",
            err.e.message()
        );
        assert_eq!(err.method, "prompts/get");

        // A present-but-empty restriction is not the missing case: zero rows.
        let ctx = ctx_for(
            "prompt_messages",
            resolved_for("http://127.0.0.1:1/mcp"),
            vec![Qual::any_equal("prompt", vec![])],
        );
        assert!(prompt_messages_rows(&ctx).unwrap().is_empty());
    }

    #[pgrx::pg_test]
    fn prompt_messages_returns_messages_in_order() {
        let seen = Params::new();
        let seen_clone = seen.clone();
        let stub = stub_with(move |method, params| match method {
            "prompts/get" => {
                seen_clone.record(params.clone());
                let name = params["name"].as_str().unwrap_or_default();
                let args = &params["arguments"];
                if name == "summarize" && args == &json!({ "style": "terse" }) {
                    Reply::Result(json!({
                        "description": "Summarize tersely",
                        "messages": [
                            { "role": "user",
                              "content": { "type": "text", "text": "summarize this" } },
                            { "role": "assistant",
                              "content": { "type": "text", "text": "ok" } },
                        ],
                    }))
                } else {
                    Reply::Result(json!({ "messages": [] }))
                }
            }
            _ => Reply::Error(-32601, "unexpected".into()),
        });

        let rows = rows_of(
            "prompt_messages",
            resolved_for(&stub.url),
            vec![
                eq("prompt", json!("summarize")),
                eq("arguments", json!({ "style": "terse" })),
            ],
        );

        assert_eq!(stub.count("prompts/get"), 1);
        let spec = crate::tables::find("prompt_messages").unwrap().spec;
        assert_eq!(rows.len(), 2);

        let requests = seen.requests();
        assert_eq!(
            requests[0],
            json!({ "name": "summarize", "arguments": { "style": "terse" } }),
            "the qual values shape the prompts/get params"
        );

        for (idx, row) in rows.iter().enumerate() {
            assert_eq!(cell(spec, row, "idx"), &Cell::Int4(idx as i32));
            assert_eq!(cell(spec, row, "prompt"), &Cell::Text("summarize".into()));
            assert_eq!(
                cell(spec, row, "arguments"),
                &Cell::Json(json!({ "style": "terse" }))
            );
            assert_eq!(
                cell(spec, row, "description"),
                &Cell::Text("Summarize tersely".into()),
                "the prompt's own description repeats on every row"
            );
        }
        assert_eq!(cell(spec, &rows[0], "role"), &Cell::Text("user".into()));
        assert_eq!(
            cell(spec, &rows[0], "content_type"),
            &Cell::Text("text".into())
        );
        assert_eq!(
            cell(spec, &rows[0], "text"),
            &Cell::Text("summarize this".into())
        );
        assert_eq!(
            cell(spec, &rows[0], "content"),
            &Cell::Json(json!({ "type": "text", "text": "summarize this" })),
            "the full content block"
        );
        assert_eq!(
            cell(spec, &rows[1], "role"),
            &Cell::Text("assistant".into())
        );
    }

    #[pgrx::pg_test]
    fn prompt_messages_defaults_arguments_to_empty_object() {
        let seen = Params::new();
        let seen_clone = seen.clone();
        let stub = stub_with(move |method, params| {
            if method == "prompts/get" {
                seen_clone.record(params.clone());
            }
            Reply::Result(json!({ "messages": [] }))
        });

        let rows = rows_of(
            "prompt_messages",
            resolved_for(&stub.url),
            vec![eq("prompt", json!("summarize"))],
        );
        assert!(rows.is_empty());
        assert_eq!(
            seen.requests()[0]["arguments"],
            json!({}),
            "missing arguments qual defaults to the empty object"
        );
    }

    // ── completions ──────────────────────────────────────────────────────────

    #[pgrx::pg_test]
    fn completions_names_each_missing_qual() {
        let cases: Vec<(Vec<Qual>, &str)> = vec![
            (vec![], "ref"),
            (
                vec![eq("ref", json!({ "type": "ref/prompt", "name": "s" }))],
                "argument_name",
            ),
            (
                vec![
                    eq("ref", json!({ "type": "ref/prompt", "name": "s" })),
                    eq("argument_name", json!("topic")),
                ],
                "argument_value",
            ),
        ];
        for (quals, missing) in cases {
            let ctx = ctx_for("completions", resolved_for("http://127.0.0.1:1/mcp"), quals);
            let err = completions_rows(&ctx).err().expect("missing required qual");
            assert_eq!(err.e.sqlstate(), "0A000", "case for {missing}");
            assert!(
                err.e.message().contains(missing),
                "error names the missing column {missing}: {}",
                err.e.message()
            );
            assert_eq!(err.method, "completion/complete");
        }

        // A present-but-empty restriction is zero rows, not an error.
        let ctx = ctx_for(
            "completions",
            resolved_for("http://127.0.0.1:1/mcp"),
            vec![
                eq("ref", json!({ "type": "ref/prompt", "name": "s" })),
                eq("argument_name", json!("topic")),
                Qual::any_equal("argument_value", vec![]),
            ],
        );
        assert!(completions_rows(&ctx).unwrap().is_empty());
    }

    #[pgrx::pg_test]
    fn completions_returns_candidates_with_idx_total_has_more() {
        let seen = Params::new();
        let seen_clone = seen.clone();
        let stub = stub_with(move |method, params| {
            if method == "completion/complete" {
                seen_clone.record(params.clone());
                let value = params["argument"]["value"].as_str().unwrap_or_default();
                return Reply::Result(json!({
                    "completion": {
                        "values": [format!("{value}-1"), format!("{value}-2")],
                        "total": 2,
                        "hasMore": false,
                    }
                }));
            }
            Reply::Error(-32601, "unexpected".into())
        });

        let ref_ = json!({ "type": "ref/prompt", "name": "summarize" });
        let rows = rows_of(
            "completions",
            resolved_for(&stub.url),
            vec![
                eq("ref", ref_.clone()),
                eq("argument_name", json!("topic")),
                eq("argument_value", json!("")), // '' = "all"
            ],
        );

        assert_eq!(stub.count("completion/complete"), 1);
        assert_eq!(
            seen.requests()[0],
            json!({
                "ref": ref_,
                "argument": { "name": "topic", "value": "" },
            }),
            "the three quals shape the completion/complete params"
        );

        let spec = crate::tables::find("completions").unwrap().spec;
        assert_eq!(rows.len(), 2);
        for (idx, row) in rows.iter().enumerate() {
            assert_eq!(cell(spec, row, "idx"), &Cell::Int4(idx as i32));
            assert_eq!(cell(spec, row, "total"), &Cell::Int4(2));
            assert_eq!(cell(spec, row, "has_more"), &Cell::Bool(false));
            assert_eq!(
                cell(spec, row, "argument_name"),
                &Cell::Text("topic".into())
            );
            assert_eq!(cell(spec, row, "argument_value"), &Cell::Text("".into()));
            assert_eq!(cell(spec, row, "ref"), &Cell::Json(ref_.clone()));
        }
        assert_eq!(cell(spec, &rows[0], "value"), &Cell::Text("-1".into()));
        assert_eq!(cell(spec, &rows[1], "value"), &Cell::Text("-2".into()));
    }

    // ── SQL-level probes (FDW path, plpgsql EXCEPTION harness) ──────────────

    /// Assert that `stmt` fails with SQLSTATE `want` (and, when given, that the
    /// message contains `needle`). Errors raised inside FDW executor callbacks
    /// longjmp straight to PostgreSQL's error machinery and are NOT captured by
    /// pgrx's `Spi::run(..).unwrap_err()` on this runner, so the statement runs
    /// inside a plpgsql `EXCEPTION` block: the SQLSTATE and message are
    /// compared in SQL, where nothing can escape. (Same pattern as fdw.rs.)
    fn expect_sqlstate(stmt: &str, want: &str, needle: Option<&str>) {
        let needle_clause = match needle {
            Some(n) => {
                let escaped = n.replace('\'', "''");
                format!("AND got_msg LIKE '%{escaped}%'",)
            }
            None => String::new(),
        };
        let sql = format!(
            r#"
            DO $probe$
            DECLARE got text; got_msg text;
            BEGIN
                BEGIN
                    EXECUTE $stmt${stmt}$stmt$;
                    RAISE EXCEPTION 'NO_ERROR_RAISED';
                EXCEPTION WHEN OTHERS THEN
                    GET STACKED DIAGNOSTICS got = RETURNED_SQLSTATE,
                                             got_msg = MESSAGE_TEXT;
                END;
                IF got IS DISTINCT FROM '{want}' {needle_clause} THEN
                    RAISE EXCEPTION 'expected SQLSTATE {want}% got % (%)', '{needle_sql}', got, got_msg;
                END IF;
            END
            $probe$;"#,
            needle_sql = needle.unwrap_or(""),
        );
        Spi::run(&sql)
            .unwrap_or_else(|e| panic!("expect_sqlstate harness failed for {want}: {e:?}"));
    }

    fn make_server_with_stub(
        prefix: &str,
        stub: &StubServer,
        extra: &[(&str, &str)],
    ) -> (String, String) {
        let server = format!("rtb_{prefix}");
        let schema = format!("rtb_{prefix}_s");
        let mut options = format!("url '{}', auth 'none', timeout_ms '10000'", stub.url);
        for (k, v) in extra {
            options.push_str(&format!(", {k} '{v}'"));
        }
        Spi::run(&format!(
            "CREATE SERVER {server} FOREIGN DATA WRAPPER mcp_fdw OPTIONS ({options})"
        ))
        .unwrap();
        Spi::run(&format!("CREATE SCHEMA {schema}")).unwrap();
        Spi::run(&format!(
            "IMPORT FOREIGN SCHEMA mcp FROM SERVER {server} INTO {schema}"
        ))
        .unwrap();
        (server, schema)
    }

    /// AP-P2: a SELECT over each Track B table issues zero `tools/call`
    /// requests — counted at the stub, around full FDW-path scans.
    #[pgrx::pg_test]
    fn ap_p2_scans_issue_zero_tools_call_requests() {
        let stub = stub_with(|method, _| match method {
            "resources/list" => Reply::Result(json!({ "resources": [
                { "uri": "file:///a" },
            ]})),
            "resources/read" => Reply::Result(json!({ "contents": [
                { "uri": "file:///a", "text": "x" },
            ]})),
            "prompts/get" => Reply::Result(json!({ "messages": [
                { "role": "user", "content": { "type": "text", "text": "hi" } },
            ]})),
            "completion/complete" => Reply::Result(json!({ "completion": {
                "values": ["v"], "total": 1, "hasMore": false,
            }})),
            "tools/call" => Reply::Result(json!({ "content": [], "isError": false })),
            _ => Reply::Error(-32601, "unexpected".into()),
        });

        let (server, schema) =
            make_server_with_stub("app2", &stub, &[("max_unqualified_reads", "5")]);

        Spi::run(&format!("SELECT count(*) FROM {schema}.resource_contents")).unwrap();
        Spi::run(&format!(
            "SELECT count(*) FROM {schema}.prompt_messages WHERE prompt = 'summarize'"
        ))
        .unwrap();
        Spi::run(&format!(
            "SELECT count(*) FROM {schema}.completions
              WHERE ref = '{{\"type\":\"ref/prompt\",\"name\":\"s\"}}'
                AND argument_name = 'topic' AND argument_value = ''"
        ))
        .unwrap();

        assert_eq!(
            stub.count("tools/call"),
            0,
            "AP-P2: reads, never invocations"
        );
        assert!(stub.count("resources/read") > 0);
        assert_eq!(stub.count("prompts/get"), 1);
        assert_eq!(stub.count("completion/complete"), 1);
        let _ = server;
    }

    #[pgrx::pg_test]
    fn unqualified_resource_contents_scan_raises_0a000_via_fdw() {
        // AC-7.5, through the full planner → begin_scan chain.
        let stub = stub_with(|method, _| match method {
            "resources/list" => Reply::Result(json!({ "resources": [
                { "uri": "file:///a" }, { "uri": "file:///b" },
            ]})),
            _ => Reply::Error(-32601, "unexpected".into()),
        });
        let (_server, schema) = make_server_with_stub("capzero", &stub, &[]);
        expect_sqlstate(
            &format!("SELECT * FROM {schema}.resource_contents"),
            "0A000",
            Some("max_unqualified_reads"),
        );
        // The refusal happens before any list request.
        assert_eq!(stub.count("resources/list"), 0);
    }

    #[pgrx::pg_test]
    fn resource_contents_fanout_over_cap_raises_54023_via_fdw() {
        let stub = stub_with(|method, _| match method {
            "resources/list" => Reply::Result(json!({ "resources": [
                { "uri": "file:///a" }, { "uri": "file:///b" },
            ]})),
            _ => Reply::Error(-32601, "unexpected".into()),
        });
        let (_server, schema) =
            make_server_with_stub("capone", &stub, &[("max_unqualified_reads", "1")]);
        expect_sqlstate(
            &format!("SELECT * FROM {schema}.resource_contents"),
            "54023",
            Some("max_unqualified_reads = 1"),
        );
    }

    #[pgrx::pg_test]
    fn unqualified_resource_contents_at_cap_scans_via_fdw() {
        // Cap boundary from the FDW path: 2 URIs, cap 2 → rows, no error.
        let stub = stub_with(|method, _| match method {
            "resources/list" => Reply::Result(json!({ "resources": [
                { "uri": "file:///a" }, { "uri": "file:///b" },
            ]})),
            "resources/read" => Reply::Result(json!({ "contents": [
                { "uri": "file:///r", "mimeType": "text/plain", "text": "t" },
            ]})),
            _ => Reply::Error(-32601, "unexpected".into()),
        });
        let (_server, schema) =
            make_server_with_stub("captop", &stub, &[("max_unqualified_reads", "2")]);
        let n = Spi::get_one::<i64>(&format!("SELECT count(*) FROM {schema}.resource_contents"))
            .unwrap();
        assert_eq!(n, Some(2));
        assert_eq!(stub.count("resources/read"), 2);
    }

    #[pgrx::pg_test]
    fn missing_quals_raise_0a000_via_fdw() {
        let stub = stub_with(|_, _| Reply::Result(json!({})));
        let (_server, schema) = make_server_with_stub("quals", &stub, &[]);

        expect_sqlstate(
            &format!("SELECT * FROM {schema}.prompt_messages"),
            "0A000",
            Some("prompt"),
        );
        expect_sqlstate(
            &format!("SELECT * FROM {schema}.completions"),
            "0A000",
            Some("ref"),
        );
        expect_sqlstate(
            &format!(
                "SELECT * FROM {schema}.completions
                  WHERE ref = '{{\"type\":\"ref/prompt\",\"name\":\"s\"}}'"
            ),
            "0A000",
            Some("argument_name"),
        );
        expect_sqlstate(
            &format!(
                "SELECT * FROM {schema}.completions
                  WHERE ref = '{{\"type\":\"ref/prompt\",\"name\":\"s\"}}'
                    AND argument_name = 'topic'"
            ),
            "0A000",
            Some("argument_value"),
        );
        // The refusals happen before any request.
        assert_eq!(stub.count("prompts/get"), 0);
        assert_eq!(stub.count("completion/complete"), 0);
    }

    #[pgrx::pg_test]
    fn read_through_errors_carry_server_and_method_in_detail() {
        // A read-through call the stub refuses with -32601 maps to 0A000 (§4.9),
        // and the errdetail names the server and the method — never a token.
        let stub = stub_with(|method, _| match method {
            "resources/read" => Reply::Error(-32601, "no such resource".into()),
            _ => Reply::Error(-32601, "unexpected".into()),
        });
        let (server, schema) = make_server_with_stub("mnf", &stub, &[]);
        let probe = format!("rtb_check_detail_{server}");
        let sql = format!(
            r#"
            DO $probe$
            DECLARE got text; got_detail text;
            BEGIN
                BEGIN
                    EXECUTE $stmt$SELECT * FROM {schema}.resource_contents WHERE uri = 'file:///a'$stmt$;
                    RAISE EXCEPTION 'NO_ERROR_RAISED';
                EXCEPTION WHEN OTHERS THEN
                    GET STACKED DIAGNOSTICS got = RETURNED_SQLSTATE,
                                             got_detail = PG_EXCEPTION_DETAIL;
                END;
                IF got IS DISTINCT FROM '0A000' THEN
                    RAISE EXCEPTION 'expected 0A000, got %', got;
                END IF;
                IF got_detail NOT LIKE '%foreign server "%{server}%"%' OR
                   got_detail NOT LIKE '%resources/read%' THEN
                    RAISE EXCEPTION 'errdetail missing server/method: %', got_detail;
                END IF;
                IF got_detail LIKE '%token%' THEN
                    RAISE EXCEPTION 'errdetail must never mention a token: %', got_detail;
                END IF;
            END
            $probe$;"#
        );
        let _ = probe;
        Spi::run(&sql).unwrap_or_else(|e| panic!("errdetail probe failed: {e:?}"));
    }

    /// Shared holder so stub routes can record request params for
    /// assertions (the closure moves into the stub thread).
    #[derive(Clone)]
    struct Params(Arc<Mutex<Vec<Value>>>);

    impl Params {
        fn new() -> Params {
            Params(Arc::new(Mutex::new(Vec::new())))
        }
        fn record(&self, v: Value) {
            self.0.lock().unwrap().push(v);
        }
        fn requests(&self) -> Vec<Value> {
            self.0.lock().unwrap().clone()
        }
    }
}
