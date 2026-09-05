//! **Track A owns this file** (PRD-7 §6 step 7.6): the catalog cache, §4.10.
//!
//! One cache per `(backend, foreign server OID, user OID)` — the backend PID
//! is implicit (process-local map), and the user OID is in the key so two
//! roles never share a catalog (ADR-004, §7.4 AP-P3).
//!
//! Contents: parsed `tools/list`, `prompts/list`, `resources/list`,
//! `resources/templates/list` and the `initialize` result. TTL from the
//! server's `cache_ttl_ms` option (default 60s, `0` disables). Dropped by
//! `mcp.refresh/1`; the `tools` slice drops immediately when the SSE reader
//! observes `notifications/tools/list_changed` (see `client.rs`'s
//! notification flag — best-effort, TTL is the guarantee). Read-through
//! tables are never cached.
//!
//! ## The two staleness contracts (§4.10, documented as required there)
//!
//! **TTL is the guarantee.** A catalog slice is at most `cache_ttl_ms` old:
//! past that, the next scan refetches. `cache_ttl_ms = 0` disables the cache
//! entirely, so every scan refetches.
//!
//! **The notification is the optimization.** The extension only reads the SSE
//! stream while a request is in flight, so a `notifications/tools/list_changed`
//! arriving between statements is not seen. One that arrives *during* a
//! request lands on the session's shared [`crate::client::Notifications`]
//! flags; the next `tools` scan polls that flag, and if it was set, drops the
//! cached `tools` slice and refetches. This makes the common "tools changed
//! while I was querying" case fresh immediately rather than up to a TTL late.
//!
//! ## The `initialize` slice
//!
//! `client.rs` keeps the handshake result it needs on the session
//! (`protocolVersion`, `serverInfo`, `capabilities`) but deliberately drops
//! `instructions`, which only the `server` table (§4.1) surfaces. That slice
//! is cached here: the first `server` scan per TTL period issues one
//! `initialize` request on the *existing* session (no new session is opened;
//! the answer's session id header is discarded by the transport) and the
//! result is cached like any other slice. `mcp.refresh/1` drops it with
//! everything else.
//!
//! Read-through tables (`resource_contents`, `prompt_messages`,
//! `completions`) never consult this cache — the only entry points are
//! `get_or_fetch`/`drop_tools`/`drop`, and none of them is on the read-through
//! path (§4.10, AP-P1: lists live here, per-call reads do not).

use crate::errors::McpResult;
use pgrx::pg_sys;
use serde_json::Value;
use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Which slice of the catalog an entry holds (§4.10's five cached payloads).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Slice {
    Tools,
    Prompts,
    Resources,
    ResourceTemplates,
    /// The full `initialize` result — `instructions` is the field the session
    /// object does not carry (see the moduledoc).
    Initialize,
}

struct Entry {
    fetched_at: Instant,
    items: Arc<Vec<Value>>,
}

/// Per-`(server, user)` slice store.
#[derive(Default)]
struct ServerCache {
    entries: HashMap<Slice, Entry>,
}

thread_local! {
    /// `(foreign server OID, user OID)` → slices. Process-local: the backend
    /// PID is implicit, exactly like `session.rs`'s session map.
    static CACHES: RefCell<HashMap<(pg_sys::Oid, pg_sys::Oid), ServerCache>> =
        RefCell::new(HashMap::new());
}

/// Consult the cache for `slice`, fetching through `fetch` on a miss or on
/// TTL expiry, and cache the result when `ttl_ms > 0`.
///
/// `ttl_ms == 0` disables caching (§4.10): `fetch` runs on every call and
/// nothing is stored. Errors from `fetch` propagate and are never cached —
/// D5's `-32601` → empty-table mapping happens in the caller *before* this
/// returns, so fail-open results are cached like any other success.
pub fn get_or_fetch(
    server_oid: pg_sys::Oid,
    user_oid: pg_sys::Oid,
    ttl_ms: u64,
    slice: Slice,
    fetch: impl FnOnce() -> McpResult<Vec<Value>>,
) -> McpResult<Arc<Vec<Value>>> {
    if ttl_ms == 0 {
        return fetch().map(Arc::new);
    }

    // Fast path (a shared read, no borrow held across the fetch).
    let ttl = Duration::from_millis(ttl_ms);
    let hit = CACHES.with(|caches| {
        caches
            .borrow()
            .get(&(server_oid, user_oid))
            .and_then(|server| server.entries.get(&slice))
            .filter(|entry| entry.fetched_at.elapsed() < ttl)
            .map(|entry| Arc::clone(&entry.items))
    });
    if let Some(items) = hit {
        return Ok(items);
    }

    // Miss: fetch with no lock held (the fetch performs network I/O and can
    // re-enter SQL), then store.
    let items = Arc::new(fetch()?);
    CACHES.with(|caches| {
        caches
            .borrow_mut()
            .entry((server_oid, user_oid))
            .or_default()
            .entries
            .insert(
                slice,
                Entry {
                    fetched_at: Instant::now(),
                    items: Arc::clone(&items),
                },
            );
    });
    Ok(items)
}

/// Drop the cached `tools` slice for `(server, user)` — called when the SSE
/// reader observed `notifications/tools/list_changed` in flight (§4.10;
/// best-effort, see the moduledoc). Returns whether a slice existed.
pub fn drop_tools(server_oid: pg_sys::Oid, user_oid: pg_sys::Oid) -> bool {
    CACHES.with(|caches| {
        caches
            .borrow_mut()
            .get_mut(&(server_oid, user_oid))
            .map(|server| server.entries.remove(&Slice::Tools).is_some())
            .unwrap_or(false)
    })
}

/// Drop every cached slice for `(server, user)` — the `mcp.refresh/1` path
/// (§4.10: refresh drops the cache *and* the session; the session half lives
/// in `api.rs::refresh`). Returns whether anything was cached.
pub fn drop(server_oid: pg_sys::Oid, user_oid: pg_sys::Oid) -> bool {
    CACHES.with(|caches| {
        caches
            .borrow_mut()
            .remove(&(server_oid, user_oid))
            .is_some_and(|server| !server.entries.is_empty())
    })
}

/// How many slices are cached for `(server, user)` right now (test hook).
#[cfg(any(test, feature = "pg_test"))]
pub fn slice_count(server_oid: pg_sys::Oid, user_oid: pg_sys::Oid) -> usize {
    CACHES.with(|caches| {
        caches
            .borrow()
            .get(&(server_oid, user_oid))
            .map(|s| s.entries.len())
            .unwrap_or(0)
    })
}

/// Test/diagnostic hook: drop every cached slice in this backend.
#[cfg(any(test, feature = "pg_test"))]
pub fn clear_all() {
    CACHES.with(|caches| caches.borrow_mut().clear());
}

#[cfg(any(test, feature = "pg_test"))]
#[pgrx::pg_schema]
mod cache_test {
    use super::*;
    use crate::errors::McpError;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn counting_fetch(
        counter: &AtomicUsize,
        items: Vec<Value>,
    ) -> impl FnOnce() -> McpResult<Vec<Value>> + '_ {
        move || {
            counter.fetch_add(1, Ordering::SeqCst);
            Ok(items.clone())
        }
    }

    #[pgrx::pg_test]
    fn cache_hit_within_ttl_and_refetch_after_expiry() {
        clear_all();
        let server = pg_sys::Oid::from(0x00C0_FE01u32);
        let user = pg_sys::Oid::from(0x00C0_F002u32);
        let fetches = AtomicUsize::new(0);

        let first = get_or_fetch(
            server,
            user,
            80,
            Slice::Tools,
            counting_fetch(&fetches, vec![serde_json::json!({"name": "a"})]),
        )
        .unwrap();
        let second = get_or_fetch(
            server,
            user,
            80,
            Slice::Tools,
            counting_fetch(&fetches, vec![serde_json::json!({"name": "a"})]),
        )
        .unwrap();
        // Same cached allocation, and the fetch ran exactly once.
        assert!(Arc::ptr_eq(&first, &second));
        assert_eq!(fetches.load(Ordering::SeqCst), 1);

        std::thread::sleep(Duration::from_millis(150));
        let _third = get_or_fetch(
            server,
            user,
            80,
            Slice::Tools,
            counting_fetch(&fetches, vec![serde_json::json!({"name": "a"})]),
        )
        .unwrap();
        assert_eq!(fetches.load(Ordering::SeqCst), 2, "TTL expiry refetches");
    }

    #[pgrx::pg_test]
    fn per_user_isolation_two_roles_never_share_entries() {
        // ADR-004 / §7.4 AP-P3 at the cache level: two user OIDs on the same
        // server get independent slices, and each sees its own principal's
        // catalog — never the other role's rows.
        clear_all();
        let server = pg_sys::Oid::from(0x00C0_FE03u32);
        let role_a = pg_sys::Oid::from(0x00C0_F004u32);
        let role_b = pg_sys::Oid::from(0x00C0_F005u32);
        let fetches = AtomicUsize::new(0);

        let for_a = get_or_fetch(
            server,
            role_a,
            60_000,
            Slice::Tools,
            counting_fetch(&fetches, vec![serde_json::json!({"name": "tool_for_a"})]),
        )
        .unwrap();
        let for_b = get_or_fetch(
            server,
            role_b,
            60_000,
            Slice::Tools,
            counting_fetch(&fetches, vec![serde_json::json!({"name": "tool_for_b"})]),
        )
        .unwrap();

        assert_eq!(for_a[0]["name"], "tool_for_a");
        assert_eq!(for_b[0]["name"], "tool_for_b");
        assert!(!Arc::ptr_eq(&for_a, &for_b));
        assert_eq!(fetches.load(Ordering::SeqCst), 2, "no cross-role hit");
        assert_eq!(slice_count(server, role_a), 1);
        assert_eq!(slice_count(server, role_b), 1);

        // And a later scan under A still gets A's rows, not B's.
        let again = get_or_fetch(server, role_a, 60_000, Slice::Tools, || {
            panic!("role A must be served from its own cache entry")
        })
        .unwrap();
        assert_eq!(again[0]["name"], "tool_for_a");
    }

    #[pgrx::pg_test]
    fn drop_clears_every_slice_and_refetches() {
        clear_all();
        let server = pg_sys::Oid::from(0x00C0_FE06u32);
        let user = pg_sys::Oid::from(0x00C0_F007u32);
        let fetches = AtomicUsize::new(0);

        for slice in [Slice::Tools, Slice::Prompts, Slice::Initialize] {
            get_or_fetch(
                server,
                user,
                60_000,
                slice,
                counting_fetch(&fetches, vec![]),
            )
            .unwrap();
        }
        assert_eq!(slice_count(server, user), 3);

        assert!(drop(server, user), "refresh reports a cache existed");
        assert_eq!(slice_count(server, user), 0);
        assert!(!drop(server, user), "second refresh reports nothing");

        get_or_fetch(
            server,
            user,
            60_000,
            Slice::Tools,
            counting_fetch(&fetches, vec![]),
        )
        .unwrap();
        assert_eq!(fetches.load(Ordering::SeqCst), 4, "everything refetches");
    }

    #[pgrx::pg_test]
    fn drop_tools_only_drops_the_tools_slice() {
        clear_all();
        let server = pg_sys::Oid::from(0x00C0_FE08u32);
        let user = pg_sys::Oid::from(0x00C0_F009u32);
        let fetches = AtomicUsize::new(0);

        get_or_fetch(
            server,
            user,
            60_000,
            Slice::Tools,
            counting_fetch(&fetches, vec![]),
        )
        .unwrap();
        get_or_fetch(
            server,
            user,
            60_000,
            Slice::Prompts,
            counting_fetch(&fetches, vec![]),
        )
        .unwrap();

        assert!(drop_tools(server, user));
        assert!(!drop_tools(server, user), "second take is a no-op");
        assert_eq!(slice_count(server, user), 1, "prompts survives");

        get_or_fetch(
            server,
            user,
            60_000,
            Slice::Tools,
            counting_fetch(&fetches, vec![]),
        )
        .unwrap();
        assert_eq!(fetches.load(Ordering::SeqCst), 3);
    }

    #[pgrx::pg_test]
    fn ttl_zero_disables_caching() {
        clear_all();
        let server = pg_sys::Oid::from(0x00C0_FE0Au32);
        let user = pg_sys::Oid::from(0x00C0_F00Bu32);
        let fetches = AtomicUsize::new(0);

        for _ in 0..3 {
            let items = get_or_fetch(
                server,
                user,
                0,
                Slice::Tools,
                counting_fetch(&fetches, vec![serde_json::json!({"name": "a"})]),
            )
            .unwrap();
            assert_eq!(items.len(), 1);
        }
        assert_eq!(fetches.load(Ordering::SeqCst), 3, "every scan fetches");
        assert_eq!(slice_count(server, user), 0, "nothing is stored");
    }

    #[pgrx::pg_test]
    fn fetch_errors_are_never_cached() {
        clear_all();
        let server = pg_sys::Oid::from(0x00C0_FE0Cu32);
        let user = pg_sys::Oid::from(0x00C0_F00Du32);

        let err = get_or_fetch(server, user, 60_000, Slice::Resources, || {
            Err(McpError::Transport("server unreachable".to_string()))
        })
        .unwrap_err();
        assert_eq!(err.sqlstate(), "08006");
        assert_eq!(slice_count(server, user), 0, "errors are not cached");

        // The next call fetches fresh rather than replaying the failure.
        let fetches = AtomicUsize::new(0);
        get_or_fetch(
            server,
            user,
            60_000,
            Slice::Resources,
            counting_fetch(&fetches, vec![]),
        )
        .unwrap();
        assert_eq!(fetches.load(Ordering::SeqCst), 1);
    }
}

// ── the in-crate HTTP stub (shared by Track A's SQL-level tests) ─────────────
//
// A single-threaded MCP server on an ephemeral loopback port, speaking just
// enough HTTP/1.1 for `client.rs`'s ureq transport: read one request per
// connection, answer from a per-method table, close. Lives under `pg_test` so
// it never ships in a release build.

#[cfg(any(test, feature = "pg_test"))]
pub mod stub {
    use serde_json::{json, Value};
    use std::collections::HashMap;
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    /// What a configured method answers with.
    pub enum Reply {
        /// The same JSON-RPC `result` every time.
        Result(Value),
        /// A JSON-RPC `error`.
        Error(i64, String),
        /// Answers each successive request with the next entry; the last one
        /// repeats. Used for multi-page cursors and SSE one-shots.
        Sequence(Vec<Reply>),
        /// Picked by the request's bearer token (AP-P3: differing tool sets
        /// per principal). Falls back to the `""` entry when unset.
        ByToken(HashMap<String, Reply>),
        /// Routed by the request's method *and params* — the escape hatch for
        /// probes that must branch per tool name or arguments (PRD-7.E:
        /// AP-P4's hidden-tool reply). The closure returns a plain `Reply`,
        /// which is then flattened like any other.
        Route(std::sync::Arc<dyn Fn(&str, &Value) -> Reply + Send + Sync>),
        /// Close the connection without answering anything (PRD-7.E AC-7.11:
        /// a server dying mid-request is a transport failure, `08006`).
        Disconnect,
        /// An `text/event-stream` reply: notification frames plus the final
        /// reply frame (the stub fills in the request id).
        Sse(Vec<SseFrame>),
    }

    /// One SSE `data:` frame.
    #[derive(Clone)]
    pub enum SseFrame {
        /// A server-initiated notification (no id).
        Notify(Value),
        /// The reply to the in-flight request; the stub echoes its id.
        Reply(Value),
    }

    struct Inner {
        replies: HashMap<String, Reply>,
        counters: Mutex<HashMap<String, usize>>,
        hits: Mutex<Vec<String>>,
        session_header: bool,
        shutdown: AtomicBool,
    }

    /// A running stub MCP server. Drop it (or let the test end) to stop it.
    pub struct StubServer {
        pub port: u16,
        inner: Arc<Inner>,
        thread: Option<std::thread::JoinHandle<()>>,
    }

    impl StubServer {
        pub fn start(replies: HashMap<String, Reply>, session_header: bool) -> StubServer {
            let listener = TcpListener::bind("127.0.0.1:0").expect("stub bind");
            let port = listener.local_addr().expect("stub addr").port();
            listener.set_nonblocking(true).expect("stub nonblocking");

            let inner = Arc::new(Inner {
                replies,
                counters: Mutex::new(HashMap::new()),
                hits: Mutex::new(Vec::new()),
                session_header,
                shutdown: AtomicBool::new(false),
            });

            let thread_inner = Arc::clone(&inner);
            let thread = std::thread::spawn(move || {
                while !thread_inner.shutdown.load(Ordering::Acquire) {
                    match listener.accept() {
                        Ok((stream, _)) => {
                            let _ = Self::handle(&thread_inner, stream);
                        }
                        Err(_) => std::thread::sleep(Duration::from_millis(5)),
                    }
                }
            });

            StubServer {
                port,
                inner,
                thread: Some(thread),
            }
        }

        pub fn url(&self) -> String {
            format!("http://127.0.0.1:{}/mcp", self.port)
        }

        /// How many requests named `method` have arrived.
        pub fn hits(&self, method: &str) -> usize {
            self.inner
                .hits
                .lock()
                .unwrap()
                .iter()
                .filter(|m| m == &method)
                .count()
        }

        /// Every request method in arrival order.
        pub fn all_hits(&self) -> Vec<String> {
            self.inner.hits.lock().unwrap().clone()
        }

        fn handle(inner: &Inner, mut stream: TcpStream) -> std::io::Result<()> {
            stream.set_nonblocking(false)?;

            let mut buf: Vec<u8> = Vec::new();
            let mut chunk = [0u8; 4096];
            let header_end = loop {
                match stream.read(&mut chunk) {
                    Ok(0) => return Ok(()),
                    Ok(n) => {
                        buf.extend_from_slice(&chunk[..n]);
                        if let Some(pos) = find(&buf, b"\r\n\r\n") {
                            break pos + 4;
                        }
                        if buf.len() > 4 << 20 {
                            return Ok(());
                        }
                    }
                    Err(_) => return Ok(()),
                }
            };

            let head = String::from_utf8_lossy(&buf[..header_end]).to_string();
            let mut content_length = 0usize;
            let mut token: Option<String> = None;
            for line in head.split("\r\n").skip(1) {
                if let Some((name, value)) = line.split_once(':') {
                    let name = name.trim().to_ascii_lowercase();
                    let value = value.trim();
                    if name == "content-length" {
                        content_length = value.parse().unwrap_or(0);
                    } else if name == "authorization" {
                        token = value
                            .strip_prefix("Bearer ")
                            .map(str::to_string)
                            .or(Some(value.to_string()));
                    }
                }
            }

            let mut body = buf[header_end..].to_vec();
            while body.len() < content_length {
                match stream.read(&mut chunk) {
                    Ok(0) => break,
                    Ok(n) => body.extend_from_slice(&chunk[..n]),
                    Err(_) => break,
                }
            }

            let request: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
            let method = request
                .get("method")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            let id = request.get("id").and_then(Value::as_i64).unwrap_or(0);
            let params = request.get("params").cloned().unwrap_or(Value::Null);
            inner.hits.lock().unwrap().push(method.clone());

            let mut counters = inner.counters.lock().unwrap();
            let flat = match inner.replies.get(&method) {
                Some(reply) => Self::flatten(reply, &mut counters, &method, &token, &params),
                None => Flat::Error(-32601, "stub has no reply configured".to_string()),
            };
            drop(counters);

            // Kill the connection mid-request: the client sees a read
            // failure, not an HTTP error (AC-7.11).
            let flat = match flat {
                Flat::Disconnect => return Ok(()),
                other => other,
            };
            let answer = match flat {
                Flat::Result(result) => Answer::Json(
                    json!({"jsonrpc": "2.0", "id": id, "result": result}).to_string(),
                    inner.session_header && method == "initialize",
                ),
                Flat::Error(code, message) => Answer::Json(
                    json!({
                        "jsonrpc": "2.0",
                        "id": id,
                        "error": {"code": code, "message": message}
                    })
                    .to_string(),
                    false,
                ),
                Flat::Sse(frames) => {
                    let mut data = Vec::new();
                    for frame in frames {
                        match frame {
                            SseFrame::Notify(v) => data.push(format!("data: {v}\n\n")),
                            SseFrame::Reply(v) => data.push(format!(
                                "data: {}\n\n",
                                json!({"jsonrpc": "2.0", "id": id, "result": v})
                            )),
                        }
                    }
                    Answer::Sse(data)
                }
                // Returned early above.
                Flat::Disconnect => unreachable!(),
            };

            let wire = match answer {
                Answer::Json(body, session_header) => {
                    let extra = if session_header {
                        "\r\nmcp-session-id: stub-session-1"
                    } else {
                        ""
                    };
                    format!(
                        "HTTP/1.1 200 OK\r\ncontent-type: application/json{extra}\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                        body.len()
                    )
                }
                Answer::Sse(frames) => format!(
                    "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n{}",
                    frames.concat()
                ),
            };
            stream.write_all(wire.as_bytes())?;
            stream.flush()
        }

        /// Collapse the configured reply (following at most one `Sequence` or
        /// `ByToken` level) into the concrete answer.
        fn flatten(
            reply: &Reply,
            counters: &mut HashMap<String, usize>,
            method: &str,
            token: &Option<String>,
            params: &Value,
        ) -> Flat {
            match reply {
                Reply::Result(v) => Flat::Result(v.clone()),
                Reply::Error(code, message) => Flat::Error(*code, message.clone()),
                Reply::Sse(frames) => Flat::Sse(frames.clone()),
                Reply::Disconnect => Flat::Disconnect,
                Reply::Route(route) => {
                    let inner = route(method, params);
                    Self::flatten(&inner, counters, method, token, params)
                }
                Reply::Sequence(list) => {
                    let slot = counters.entry(method.to_string()).or_insert(0);
                    let index = (*slot).min(list.len().saturating_sub(1));
                    *slot += 1;
                    match list.get(index) {
                        Some(next) => Self::flatten(next, counters, method, token, params),
                        None => Flat::Error(-32603, "stub sequence is empty".to_string()),
                    }
                }
                Reply::ByToken(map) => {
                    let key = token.clone().unwrap_or_default();
                    match map.get(&key).or_else(|| map.get("")) {
                        Some(next) => Self::flatten(next, counters, method, token, params),
                        None => Flat::Error(-32603, "no stub reply for token".to_string()),
                    }
                }
            }
        }
    }

    impl Drop for StubServer {
        fn drop(&mut self) {
            self.inner.shutdown.store(true, Ordering::Release);
            if let Some(thread) = self.thread.take() {
                let _ = thread.join();
            }
        }
    }

    /// The concrete answer a configured reply collapses to.
    enum Flat {
        Result(Value),
        Error(i64, String),
        Sse(Vec<SseFrame>),
        Disconnect,
    }

    enum Answer {
        Json(String, bool),
        Sse(Vec<String>),
    }

    fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
        haystack
            .windows(needle.len())
            .position(|window| window == needle)
    }
}
