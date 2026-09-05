//! JSON-RPC 2.0 over MCP Streamable HTTP, blocking (PRD-6 §4.4).
//!
//! ADR-002: a blocking `ureq` client, no tokio runtime inside the backend.
//! One session per `(backend, server OID, user OID)`; `initialize` once;
//! `Mcp-Session-Id` cached and echoed; re-initialize once on 404 or an
//! expired-session error, then give up with `08006`.

use crate::errors::{is_expired_session, McpError, McpResult};
use crate::sse::{self, Interrupts};
use serde_json::{json, Value};
use std::io::Read;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Newest protocol version this extension knows how to speak (PRD-6 §9 Q5: the
/// negotiated version is recorded on the session; PRD-7's catalog omits
/// surfaces a downgraded server cannot express).
pub const CLIENT_PROTOCOL_VERSION: &str = "2025-11-25";

pub const CLIENT_NAME: &str = "pg_mcp";
pub const CLIENT_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Bounded cap on a response body we buffer for the JSON fast path. A server
/// that sends more than this is treated as a transport failure rather than
/// being allowed to exhaust backend memory.
const MAX_JSON_BODY: u64 = 64 * 1024 * 1024;

/// Credential presented on the wire. Constructed only from a USER MAPPING.
#[derive(Clone)]
pub struct Bearer(String);

impl Bearer {
    pub fn new(token: String) -> Bearer {
        Bearer(token)
    }
    fn header(&self) -> String {
        format!("Bearer {}", self.0)
    }
}

// FR-6.11: a bearer token must never reach a log line, an error message or
// EXPLAIN output. Making Debug opaque removes the easiest accident.
impl std::fmt::Debug for Bearer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Bearer(<redacted>)")
    }
}

/// A negotiated MCP session against one foreign server, for one Postgres role.
///
/// Holds its own `ureq::Agent` so keep-alive connections (and the TLS
/// handshake behind them) are reused across the N calls FR-6.4 allows one
/// initialize to serve.
pub struct McpSession {
    pub url: String,
    pub session_id: Option<String>,
    pub protocol_version: String,
    pub server_info: Value,
    pub capabilities: Value,
    pub next_id: i64,
    pub initialized_at: Instant,
    /// Count of `initialize` round trips this session object has performed.
    /// FR-6.4 asserts this stays at 1 across N calls.
    pub initialize_count: u32,
    /// Server-initiated notifications observed in-flight (PRD-7 §4.10). Shared
    /// with the transport so the SSE reader can set flags mid-request.
    pub notifications: Arc<Notifications>,
    /// Connection pool + timeouts, created once when the session opens.
    agent: ureq::Agent,
}

/// Server-initiated notifications seen while draining an SSE stream.
///
/// PRD-7 §4.10: the extension only reads the stream during an in-flight
/// request, so observation is **best-effort** — a notification arriving
/// between statements is not seen, and TTL is the guarantee while this flag is
/// the optimization. Consumers (Track A's cache) poll
/// [`Notifications::take_tools_list_changed`] after request activity.
#[derive(Debug, Default)]
pub struct Notifications {
    tools_list_changed: AtomicBool,
}

impl Notifications {
    pub fn new() -> Notifications {
        Notifications::default()
    }

    /// Record a server-initiated notification frame. Unknown methods are
    /// ignored (they are skipped by the SSE reader anyway).
    pub fn observe(&self, frame: &Value) {
        if frame.get("method").and_then(Value::as_str) == Some("notifications/tools/list_changed") {
            self.tools_list_changed.store(true, Ordering::Release);
        }
    }

    /// Was `notifications/tools/list_changed` seen since the last take?
    /// Consuming read: the flag resets so one observation invalidates once.
    pub fn take_tools_list_changed(&self) -> bool {
        self.tools_list_changed.swap(false, Ordering::AcqRel)
    }

    /// Non-consuming peek.
    pub fn tools_list_changed(&self) -> bool {
        self.tools_list_changed.load(Ordering::Acquire)
    }
}

/// What the transport did with one HTTP exchange.
enum Wire {
    /// A JSON body; `Option<String>` is the `Mcp-Session-Id` response header.
    Json(Value, Option<String>),
    /// The server upgraded to `text/event-stream`; body still to be read.
    Sse(Box<dyn Read + Send>),
    /// 202 Accepted — the correct answer to a notification.
    Accepted,
    /// Session is unknown/expired; caller decides whether to re-initialize.
    SessionGone,
    Failed(McpError),
}

/// Everything the transport needs that does not live on the session.
pub struct Transport<'a, I: Interrupts> {
    pub timeout: Duration,
    pub bearer: Option<&'a Bearer>,
    pub interrupts: &'a I,
    /// Shared notification flags, set by the SSE reader while it skips
    /// server-initiated frames (PRD-7 §4.10). `None` in paths that never read
    /// a stream (notifications, tests).
    pub notifications: Option<Arc<Notifications>>,
}

impl McpSession {
    /// Perform `initialize` + `notifications/initialized` and return a session
    /// ready for requests (PRD-6 §4.4 step 1).
    pub fn open<I: Interrupts>(url: &str, transport: &Transport<'_, I>) -> McpResult<McpSession> {
        let mut session = McpSession {
            url: url.to_string(),
            session_id: None,
            protocol_version: CLIENT_PROTOCOL_VERSION.to_string(),
            server_info: Value::Null,
            capabilities: Value::Null,
            next_id: 1,
            initialized_at: Instant::now(),
            initialize_count: 0,
            notifications: Arc::new(Notifications::new()),
            agent: build_agent(transport.timeout),
        };
        session.initialize(transport)?;
        Ok(session)
    }

    fn initialize<I: Interrupts>(&mut self, transport: &Transport<'_, I>) -> McpResult<()> {
        let id = self.take_id();
        let body = json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": "initialize",
            "params": {
                "protocolVersion": CLIENT_PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": { "name": CLIENT_NAME, "version": CLIENT_VERSION },
            }
        });

        // The initialize request itself carries no session id (there is none
        // yet) and no MCP-Protocol-Version header (nothing negotiated yet).
        let (result, session_id) = self.exchange(&body, id, transport, None, false)?;

        self.session_id = session_id;
        self.protocol_version = result
            .get("protocolVersion")
            .and_then(Value::as_str)
            .unwrap_or(CLIENT_PROTOCOL_VERSION)
            .to_string();
        self.server_info = result.get("serverInfo").cloned().unwrap_or(Value::Null);
        self.capabilities = result.get("capabilities").cloned().unwrap_or(Value::Null);
        self.initialized_at = Instant::now();
        self.initialize_count += 1;

        // Complete the handshake. The plug answers 202 and the session becomes
        // usable; a failure here is fatal, the server will reject later calls.
        let note = json!({ "jsonrpc": "2.0", "method": "notifications/initialized" });
        self.notify(&note, transport)?;
        Ok(())
    }

    /// Issue a JSON-RPC request, re-initializing **once** if the server says the
    /// session is gone (PRD-6 §4.4 step 3, FR-6.6).
    pub fn request<I: Interrupts>(
        &mut self,
        method: &str,
        params: Value,
        transport: &Transport<'_, I>,
    ) -> McpResult<Value> {
        match self.try_request(method, &params, transport) {
            Ok(Some(value)) => Ok(value),
            Ok(None) => {
                // Session gone. Re-initialize once, retry once.
                self.session_id = None;
                self.initialize(transport)?;
                match self.try_request(method, &params, transport)? {
                    Some(value) => Ok(value),
                    None => Err(McpError::Transport(
                        "MCP session was rejected twice; giving up after one re-initialize"
                            .to_string(),
                    )),
                }
            }
            Err(e) => Err(e),
        }
    }

    /// `Ok(None)` means "session gone, caller may re-initialize once".
    fn try_request<I: Interrupts>(
        &mut self,
        method: &str,
        params: &Value,
        transport: &Transport<'_, I>,
    ) -> McpResult<Option<Value>> {
        let id = self.take_id();
        let body = json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params });

        match self.exchange_checked(&body, id, transport) {
            Ok(Some((value, _))) => Ok(Some(value)),
            Ok(None) => Ok(None),
            Err(e) => Err(e),
        }
    }

    fn notify<I: Interrupts>(&self, body: &Value, transport: &Transport<'_, I>) -> McpResult<()> {
        let request = self.build(body, transport, self.session_id.as_deref(), true);
        match dispatch(request, body, 0, transport) {
            Wire::Accepted | Wire::Json(_, _) => Ok(()),
            // A notification whose session is already gone is not worth a retry:
            // the next request re-initializes anyway.
            Wire::SessionGone => Ok(()),
            Wire::Sse(_) => Ok(()),
            Wire::Failed(e) => Err(e),
        }
    }

    /// `Ok(None)` means "session gone, caller may re-initialize once"
    /// (FR-6.6: HTTP 404, or a JSON-RPC error whose message says so).
    fn exchange_checked<I: Interrupts>(
        &self,
        body: &Value,
        id: i64,
        transport: &Transport<'_, I>,
    ) -> McpResult<Option<(Value, Option<String>)>> {
        let request = self.build(body, transport, self.session_id.as_deref(), true);
        match dispatch(request, body, id, transport) {
            Wire::Json(value, sid) => match finish(value, id) {
                Ok(result) => Ok(Some((result, sid))),
                Err(e) if is_expired_session(e.message()) => Ok(None),
                Err(e) => Err(e),
            },
            // The response headers are gone with the upgraded body; only
            // `initialize` captures a new session id, and it is answered on the
            // JSON fast path in practice.
            Wire::Sse(reader) => {
                let value = self.read_stream(reader, id, transport)?;
                finish(value, id).map(|result| Some((result, None)))
            }
            Wire::Accepted => Err(McpError::Transport(
                "MCP server accepted the request without answering it".to_string(),
            )),
            Wire::SessionGone => Ok(None),
            Wire::Failed(e) => Err(e),
        }
    }

    /// Exchange used by `initialize`, where a session-gone answer is fatal.
    fn exchange<I: Interrupts>(
        &self,
        body: &Value,
        id: i64,
        transport: &Transport<'_, I>,
        session_id: Option<&str>,
        send_protocol_version: bool,
    ) -> McpResult<(Value, Option<String>)> {
        let request = self.build(body, transport, session_id, send_protocol_version);
        match dispatch(request, body, id, transport) {
            Wire::Json(value, sid) => finish(value, id).map(|result| (result, sid)),
            Wire::Sse(reader) => {
                let value = self.read_stream(reader, id, transport)?;
                finish(value, id).map(|result| (result, None))
            }
            Wire::Accepted => Err(McpError::Transport(
                "MCP server did not answer initialize".to_string(),
            )),
            Wire::SessionGone => Err(McpError::Transport(
                "MCP server rejected the initialize request as an unknown session".to_string(),
            )),
            Wire::Failed(e) => Err(e),
        }
    }

    fn build<I: Interrupts>(
        &self,
        _body: &Value,
        transport: &Transport<'_, I>,
        session_id: Option<&str>,
        send_protocol_version: bool,
    ) -> ureq::Request {
        let mut req = self
            .agent
            .post(&self.url)
            .set("content-type", "application/json")
            // FR-6.7: both response shapes are acceptable on every request.
            .set("accept", "application/json, text/event-stream")
            .set("user-agent", &format!("{CLIENT_NAME}/{CLIENT_VERSION}"));

        if send_protocol_version {
            req = req.set("mcp-protocol-version", &self.protocol_version);
        }
        // FR-6.5: echo the session id on every non-initialize request.
        if let Some(sid) = session_id {
            req = req.set("mcp-session-id", sid);
        }
        if let Some(bearer) = transport.bearer {
            req = req.set("authorization", &bearer.header());
        }
        req
    }

    fn take_id(&mut self) -> i64 {
        let id = self.next_id;
        self.next_id += 1;
        id
    }

    /// Drain an SSE stream until our reply arrives, feeding every
    /// server-initiated frame to the shared notification flags (PRD-7 §4.10).
    fn read_stream<I: Interrupts>(
        &self,
        reader: Box<dyn Read + Send>,
        want_id: i64,
        transport: &Transport<'_, I>,
    ) -> McpResult<Value> {
        let notifications = transport.notifications.clone();
        sse::read_until_id_observed(
            reader,
            want_id,
            transport.timeout,
            transport.interrupts,
            &mut |frame| {
                if let Some(flags) = notifications.as_ref() {
                    flags.observe(frame);
                }
            },
        )
    }
}

// ── PRD-7 §6 step 7.10: cursor-following list helper ─────────────────────────

/// Runaway guard for `list_all`: a well-behaved server exhausts its cursors
/// in a handful of pages; this only exists so a cycling `nextCursor` fails
/// with `08006` instead of pinning the backend forever.
pub const MAX_LIST_PAGES: usize = 1_000;

/// One page's payload: the items array plus the `nextCursor` to follow.
pub fn page_items(result: &Value, array_key: &str) -> (Vec<Value>, Option<String>) {
    let items = result
        .get(array_key)
        .and_then(Value::as_array)
        .map(|a| a.clone())
        .unwrap_or_default();
    let next = result
        .get("nextCursor")
        .and_then(Value::as_str)
        .map(str::to_string);
    (items, next)
}

/// Follow a paginated MCP list method (`tools/list`, `prompts/list`,
/// `resources/list`, `resources/templates/list`) to exhaustion in one call
/// (FR-7.3), returning every item across all pages. A missing `array_key`
/// yields an empty vector (D5: a server that answers `null` yields an empty
/// table; a `-32601` error raises before this is consulted).
pub fn list_all<I: Interrupts>(
    session: &mut McpSession,
    method: &str,
    array_key: &str,
    mut params: Value,
    transport: &Transport<'_, I>,
) -> McpResult<Vec<Value>> {
    let mut items = Vec::new();
    let mut followed: Vec<String> = Vec::new();

    loop {
        if followed.len() >= MAX_LIST_PAGES {
            return Err(McpError::Transport(format!(
                "MCP list method \"{method}\" did not exhaust its cursor within {MAX_LIST_PAGES} pages"
            )));
        }

        let result = session.request(method, params.clone(), transport)?;
        let (page, next) = page_items(&result, array_key);
        items.extend(page);

        match next {
            None => return Ok(items),
            Some(cursor) => {
                // A cursor we have already followed means the server is
                // cycling: fail the scan rather than loop.
                if followed.contains(&cursor) {
                    return Err(McpError::Transport(format!(
                        "MCP list method \"{method}\" repeated pagination cursor"
                    )));
                }
                followed.push(cursor.clone());
                if let Some(obj) = params.as_object_mut() {
                    obj.insert("cursor".to_string(), Value::String(cursor));
                }
            }
        }
    }
}

/// Send one HTTP exchange and classify the answer.
fn dispatch<I: Interrupts>(
    request: ureq::Request,
    body: &Value,
    _id: i64,
    transport: &Transport<'_, I>,
) -> Wire {
    // FR-6.14: a check before we block, so a cancel already queued is honoured
    // rather than costing a full timeout.
    if let Err(e) = transport.interrupts.check() {
        return Wire::Failed(e);
    }

    let payload = match serde_json::to_vec(body) {
        Ok(v) => v,
        Err(e) => {
            return Wire::Failed(McpError::InvalidParams(format!(
                "could not encode request: {e}"
            )))
        }
    };

    let response = match request.send_bytes(&payload) {
        Ok(r) => r,
        Err(ureq::Error::Status(status, r)) => return classify_status(status, r),
        Err(ureq::Error::Transport(t)) => {
            // The transport error's Display can carry the request URL. The URL
            // is operator-supplied (SEC-4) and carries no credential, but the
            // token never appears here either way — it lives only in a header.
            return Wire::Failed(McpError::Transport(format!(
                "could not reach the MCP server: {}",
                transport_kind(&t)
            )));
        }
    };

    // 202 Accepted: the correct answer to a notification.
    if response.status() == 202 {
        return Wire::Accepted;
    }

    // FR-6.5: the server mints the session id on `initialize`; ureq's header
    // lookup is case-insensitive, matching the plug's `mcp-session-id`.
    let session_id = response.header("mcp-session-id").map(str::to_string);

    let content_type = response
        .header("content-type")
        .unwrap_or("")
        .to_ascii_lowercase();

    if content_type.contains("text/event-stream") {
        return Wire::Sse(Box::new(response.into_reader()));
    }

    let mut text = String::new();
    if let Err(e) = response
        .into_reader()
        .take(MAX_JSON_BODY)
        .read_to_string(&mut text)
    {
        return Wire::Failed(McpError::Transport(format!(
            "could not read the MCP response body: {:?}",
            e.kind()
        )));
    }

    match serde_json::from_str::<Value>(&text) {
        Ok(v) => Wire::Json(v, session_id),
        Err(_) => Wire::Failed(McpError::Transport(
            "MCP server returned a malformed JSON body".to_string(),
        )),
    }
}

/// One agent per session: the pool keeps keep-alive connections (and their TLS
/// handshakes) warm across the N calls one initialize serves. `timeout` is the
/// overall per-exchange budget (FR-6.12); connect gets the same value.
fn build_agent(timeout: Duration) -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(timeout)
        .timeout(timeout)
        .build()
}

/// Non-2xx HTTP. 404 means the session is unknown or expired (PRD-6 §4.4
/// step 3); everything else maps straight onto the §4.7 table. The error
/// response body is deliberately not read: no message we compose may echo
/// response material that could have reflected the credential (FR-6.11).
fn classify_status(status: u16, _response: ureq::Response) -> Wire {
    if status == 404 {
        return Wire::SessionGone;
    }
    Wire::Failed(McpError::from_http_status(status))
}

fn transport_kind(t: &ureq::Transport) -> String {
    // ureq's ErrorKind is a small stable enum; its Display is safe and does not
    // include headers.
    format!("{:?}", t.kind())
}

/// Turn a decoded JSON-RPC envelope into its `result`, or the mapped error.
fn finish(value: Value, id: i64) -> McpResult<Value> {
    if let Some((code, message)) = rpc_error(&value) {
        return Err(McpError::from_rpc(code, &message));
    }
    match value.get("result") {
        Some(result) => Ok(result.clone()),
        None => Err(McpError::Transport(format!(
            "MCP response for request {id} carried neither result nor error"
        ))),
    }
}

fn rpc_error(value: &Value) -> Option<(i64, String)> {
    let error = value.get("error")?;
    let code = error.get("code").and_then(Value::as_i64).unwrap_or(0);
    let message = error
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("MCP server returned an error")
        .to_string();
    Some((code, message))
}

/// Concatenate the `text` parts of a `CallToolResult.content` array.
/// `None` when the result carries no text content (PRD-6 §4.6).
pub fn text_content(result: &Value) -> Option<String> {
    let content = result.get("content")?.as_array()?;
    let mut parts: Vec<&str> = Vec::new();
    for item in content {
        if item.get("type").and_then(Value::as_str) == Some("text") {
            if let Some(text) = item.get("text").and_then(Value::as_str) {
                parts.push(text);
            }
        }
    }
    if parts.is_empty() {
        None
    } else {
        Some(parts.concat())
    }
}

/// Is this a `CallToolResult` with `isError: true`?
pub fn is_error_result(result: &Value) -> bool {
    result
        .get("isError")
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

#[cfg(any(test, feature = "pg_test"))]
#[pgrx::pg_schema]
mod tests {
    use super::*;

    #[pgrx::pg_test]
    fn bearer_never_prints_its_value() {
        let b = Bearer::new("SPIKE_CANARY_TOKEN".to_string());
        let rendered = format!("{b:?}");
        assert!(!rendered.contains("SPIKE_CANARY_TOKEN"));
        assert_eq!(rendered, "Bearer(<redacted>)");
    }

    #[pgrx::pg_test]
    fn bearer_header_shape() {
        assert_eq!(Bearer::new("abc".into()).header(), "Bearer abc");
    }

    #[pgrx::pg_test]
    fn finish_extracts_result_and_maps_errors() {
        let ok = json!({"jsonrpc":"2.0","id":1,"result":{"content":[]}});
        assert!(finish(ok, 1).is_ok());

        let err = json!({"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"bad args"}});
        let mapped = finish(err, 1).unwrap_err();
        assert_eq!(mapped.sqlstate(), "22023");
        assert_eq!(mapped.message(), "bad args");

        let neither = json!({"jsonrpc":"2.0","id":1});
        assert_eq!(finish(neither, 1).unwrap_err().sqlstate(), "08006");
    }

    #[pgrx::pg_test]
    fn text_content_concatenates_text_parts_only() {
        let result = json!({"content":[
            {"type":"text","text":"hi"},
            {"type":"image","data":"AAAA"},
            {"type":"text","text":"!"}
        ]});
        assert_eq!(text_content(&result).as_deref(), Some("hi!"));

        let no_text = json!({"content":[{"type":"image","data":"AAAA"}]});
        assert_eq!(text_content(&no_text), None);

        let empty = json!({"content":[]});
        assert_eq!(text_content(&empty), None);

        assert_eq!(text_content(&json!({})), None);
    }

    #[pgrx::pg_test]
    fn is_error_result_defaults_false() {
        assert!(is_error_result(&json!({"isError": true})));
        assert!(!is_error_result(&json!({"isError": false})));
        assert!(!is_error_result(&json!({"content": []})));
    }

    #[pgrx::pg_test]
    fn client_identity_is_the_crate_version() {
        assert_eq!(CLIENT_NAME, "pg_mcp");
        assert_eq!(CLIENT_VERSION, "0.3.0");
    }

    #[pgrx::pg_test]
    fn page_items_extracts_the_array_and_the_cursor() {
        let page = json!({"tools": [{"name": "a"}, {"name": "b"}], "nextCursor": "c2"});
        let (items, next) = page_items(&page, "tools");
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["name"], "a");
        assert_eq!(next.as_deref(), Some("c2"));

        let last = json!({"tools": [{"name": "c"}]});
        let (items, next) = page_items(&last, "tools");
        assert_eq!(items.len(), 1);
        assert_eq!(next, None);

        // A result without the key (or a null array) is an empty page, not an
        // error: D5 handles the "surface not implemented" case upstream.
        let (items, next) = page_items(&json!({"result": {}}), "tools");
        assert!(items.is_empty());
        assert_eq!(next, None);
    }

    #[pgrx::pg_test]
    fn list_changed_notification_is_observed_and_taken_once() {
        let flags = Notifications::new();
        assert!(!flags.tools_list_changed());

        flags.observe(&json!({
            "jsonrpc": "2.0",
            "method": "notifications/tools/list_changed",
            "params": {}
        }));
        assert!(flags.tools_list_changed());
        assert!(flags.take_tools_list_changed());
        assert!(!flags.tools_list_changed());
        assert!(!flags.take_tools_list_changed(), "take consumes");
    }

    #[pgrx::pg_test]
    fn other_notifications_are_ignored() {
        let flags = Notifications::new();
        for method in [
            "notifications/progress",
            "notifications/initialized",
            "notifications/resources/list_changed",
            "notifications/prompts/list_changed",
        ] {
            flags.observe(&json!({"jsonrpc": "2.0", "method": method}));
        }
        assert!(!flags.tools_list_changed());
        // Non-JSON-RPC shapes are ignored too.
        flags.observe(&json!({"result": {}}));
        assert!(!flags.tools_list_changed());
    }
}
