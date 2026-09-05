//! Backend-local MCP session cache + credential resolution (PRD-6 §4.4, §4.3).
//!
//! One session per `(backend PID, foreign server OID, user OID)`; the map is
//! process-local, so it dies with the backend and needs no `on_proc_exit` hook
//! beyond dropping the `ureq` agents, which own no OS resources across a fork.
//!
//! This is the only module besides the `GetUserMapping` call site that uses
//! `unsafe` (FR-6.1).

use crate::client::{Bearer, McpSession, Transport};
use crate::errors::{McpError, McpResult};
use crate::options::{AuthMode, Credential, ServerOptions, UserMappingOptions};
use crate::sse::Interrupts;
use pgrx::pg_sys;
use pgrx::prelude::*;
use serde_json::Value;
use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::CStr;
use std::time::Duration;

/// `(foreign server OID, user OID)` — the backend PID is implicit in the map
/// being process-local.
pub type SessionKey = (pg_sys::Oid, pg_sys::Oid);

thread_local! {
    static SESSIONS: RefCell<HashMap<SessionKey, McpSession>> = RefCell::new(HashMap::new());
}

static EXIT_HOOK_REGISTERED: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

/// Register the backend-exit hook that drops the session cache (PRD-6 §4.4).
/// The map is process-local, so this is hygiene — the pooled `ureq` sockets it
/// releases belong to a process that is going away — but it keeps the
/// teardown path explicit rather than incidental.
pub fn register_exit_hook() {
    use std::sync::atomic::Ordering;
    if EXIT_HOOK_REGISTERED.swap(true, Ordering::SeqCst) {
        return;
    }
    // SAFETY: `on_proc_exit` registers a callback for backend shutdown; the
    // callback only clears a thread-local map and allocates nothing.
    unsafe {
        pg_sys::on_proc_exit(Some(pg_mcp_sessions_cleanup), pg_sys::Datum::from(0usize));
    }
}

#[pg_guard]
unsafe extern "C-unwind" fn pg_mcp_sessions_cleanup(_code: i32, _arg: pg_sys::Datum) {
    clear_all_sessions();
}

/// `CHECK_FOR_INTERRUPTS` between SSE events, so a long stream stays cancelable
/// (FR-6.14). `pgrx::check_for_interrupts!` longjmps out through pgrx's error
/// machinery, which is what we want: the statement is cancelled, not swallowed.
pub struct PgInterrupts;

impl Interrupts for PgInterrupts {
    fn check(&self) -> McpResult<()> {
        pgrx::check_for_interrupts!();
        Ok(())
    }
}

/// Everything resolved from the catalog for one call (design rule D3: nothing
/// is captured at build time).
pub struct Resolved {
    pub server_oid: pg_sys::Oid,
    pub user_oid: pg_sys::Oid,
    pub options: ServerOptions,
    pub bearer: Option<Bearer>,
}

/// Resolve a foreign server by name plus the calling role's credential.
pub fn resolve(server_name: &str) -> McpResult<Resolved> {
    let (server_oid, server_options) = lookup_foreign_server(server_name)?;
    let options = ServerOptions::parse(&server_options)?;
    let user_oid = current_user_oid();

    let bearer = match options.auth {
        AuthMode::None => None,
        AuthMode::Bearer => Some(resolve_bearer(server_oid, user_oid, server_name)?),
    };

    Ok(Resolved {
        server_oid,
        user_oid,
        options,
        bearer,
    })
}

/// FR-6.8: under `auth 'bearer'` a missing mapping is `28000` and **no request
/// is sent**.
fn resolve_bearer(
    server_oid: pg_sys::Oid,
    user_oid: pg_sys::Oid,
    server_name: &str,
) -> McpResult<Bearer> {
    let mapping = lookup_user_mapping(server_oid, user_oid).ok_or_else(|| {
        McpError::NoAuthMapping(format!(
            "no USER MAPPING for the current role on foreign server \"{server_name}\"; \
             create one with OPTIONS (token_secret 'schema.table') or set the server's auth option to 'none' for a loopback URL"
        ))
    })?;

    let parsed = UserMappingOptions::parse(&mapping)?;
    match parsed.credential {
        Credential::Token(token) => Ok(Bearer::new(token)),
        Credential::TokenSecret { schema, table } => {
            let token = read_token_secret(&schema, &table)?;
            Ok(Bearer::new(token))
        }
    }
}

/// Read `(role, token)` for `current_user` from the operator-named secret table.
///
/// SEC-3: the SPI query runs as the calling role, so Postgres's own privilege
/// checks decide whether the role may read the table. An unprivileged role gets
/// `42501` from Postgres, not from us.
fn read_token_secret(schema: &str, table: &str) -> McpResult<String> {
    // `schema` and `table` already passed `is_plain_identifier` in options.rs,
    // so quoting them is a belt-and-braces measure rather than the only defence.
    let sql = format!(
        "SELECT token FROM \"{}\".\"{}\" WHERE role = current_user LIMIT 1",
        schema.replace('"', "\"\""),
        table.replace('"', "\"\"")
    );

    let fetched: Option<String> = Spi::get_one(&sql).map_err(|e| {
        McpError::NoAuthMapping(format!(
            "could not read the token_secret table \"{schema}\".\"{table}\": {e}"
        ))
    })?;

    match fetched {
        Some(token) if !token.trim().is_empty() => Ok(token),
        // Deliberately does not distinguish "no row" from "empty token".
        _ => Err(McpError::NoAuthMapping(format!(
            "no token for the current role in \"{schema}\".\"{table}\""
        ))),
    }
}

/// Run `f` against the cached session for this `(server, user)`, opening one on
/// first use (FR-6.4: exactly one `initialize` for N calls).
pub fn with_session<T>(
    resolved: &Resolved,
    f: impl FnOnce(&mut McpSession, &Transport<'_, PgInterrupts>) -> McpResult<T>,
) -> McpResult<T> {
    let key = (resolved.server_oid, resolved.user_oid);
    let interrupts = PgInterrupts;
    let transport = Transport {
        timeout: Duration::from_millis(resolved.options.timeout_ms),
        bearer: resolved.bearer.as_ref(),
        interrupts: &interrupts,
    };

    // The closure runs with the map borrow released: an MCP call can re-enter
    // SQL (SPI for token_secret) and must not find the RefCell already borrowed.
    let mut session = match SESSIONS.with(|map| map.borrow_mut().remove(&key)) {
        Some(existing) if existing.url == resolved.options.url => existing,
        // A server whose URL was ALTERed underneath us gets a fresh session
        // rather than talking to the old endpoint (D3).
        _ => McpSession::open(&resolved.options.url, &transport)?,
    };

    let outcome = f(&mut session, &transport);

    // D5 fail-open per server: a failed call returns the session to the cache
    // unless the transport itself is unusable, so one bad statement does not
    // poison unrelated foreign servers.
    let keep = !matches!(outcome, Err(McpError::Transport(_)));
    if keep {
        SESSIONS.with(|map| {
            map.borrow_mut().insert(key, session);
        });
    }

    outcome
}

/// FR-6.13: drop the cached session for `(server, current user)`.
pub fn drop_session(server_oid: pg_sys::Oid, user_oid: pg_sys::Oid) -> bool {
    SESSIONS.with(|map| map.borrow_mut().remove(&(server_oid, user_oid)).is_some())
}

/// Test/diagnostic hook: how many `initialize` round trips the cached session
/// has performed. `None` when no session is cached.
pub fn initialize_count(server_oid: pg_sys::Oid, user_oid: pg_sys::Oid) -> Option<u32> {
    SESSIONS.with(|map| {
        map.borrow()
            .get(&(server_oid, user_oid))
            .map(|s| s.initialize_count)
    })
}

/// Read-only peek at a cached session. `None` when none is cached.
pub fn with_cached_session<T>(
    server_oid: pg_sys::Oid,
    user_oid: pg_sys::Oid,
    f: impl FnOnce(&McpSession) -> T,
) -> Option<T> {
    SESSIONS.with(|map| map.borrow().get(&(server_oid, user_oid)).map(f))
}

/// Number of cached sessions in this backend.
pub fn session_count() -> usize {
    SESSIONS.with(|map| map.borrow().len())
}

pub fn clear_all_sessions() {
    SESSIONS.with(|map| map.borrow_mut().clear());
}

// ── catalog access ───────────────────────────────────────────────────────────

pub fn current_user_oid() -> pg_sys::Oid {
    // SAFETY: GetUserId reads session state; valid in any backend context.
    unsafe { pg_sys::GetUserId() }
}

/// Which catalog relation an FDW validator invocation is checking options for
/// (FR-6.1: the `unsafe` compile-time OID reads live here, not in `api.rs`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ValidatorCatalog {
    ForeignServer,
    UserMapping,
    ForeignDataWrapper,
    Other,
}

pub fn validator_catalog(catalog: pg_sys::Oid) -> ValidatorCatalog {
    // pgrx exposes the compile-time catalog relation OIDs as safe constants.
    if catalog == pg_sys::ForeignServerRelationId {
        ValidatorCatalog::ForeignServer
    } else if catalog == pg_sys::UserMappingRelationId {
        ValidatorCatalog::UserMapping
    } else if catalog == pg_sys::ForeignDataWrapperRelationId {
        ValidatorCatalog::ForeignDataWrapper
    } else {
        ValidatorCatalog::Other
    }
}

/// FR-6.10 / §4.6: an unknown foreign server name raises `42704`.
pub fn lookup_foreign_server(name: &str) -> McpResult<(pg_sys::Oid, Vec<(String, String)>)> {
    let c_name = std::ffi::CString::new(name).map_err(|_| {
        McpError::UndefinedObject(format!("invalid foreign server name \"{name}\""))
    })?;

    // SAFETY: `GetForeignServerByName` with missing_ok = true returns NULL for
    // an unknown name rather than raising, so the null check below is the whole
    // contract. The returned palloc'd struct lives in the current memory
    // context, which outlives this function.
    let server = unsafe { pg_sys::GetForeignServerByName(c_name.as_ptr(), true) };
    if server.is_null() {
        return Err(McpError::UndefinedObject(format!(
            "foreign server \"{name}\" does not exist"
        )));
    }

    // SAFETY: non-null, produced by the call above.
    let (oid, options) = unsafe { ((*server).serverid, defelem_list((*server).options)) };
    Ok((oid, options))
}

/// ADR-004 / FR-6.8: the token comes from `USER MAPPING`, read through
/// `GetUserMapping` for `GetUserId()`. Returns `None` when no mapping exists
/// (including no `PUBLIC` mapping).
pub fn lookup_user_mapping(
    server_oid: pg_sys::Oid,
    user_oid: pg_sys::Oid,
) -> Option<Vec<(String, String)>> {
    // `GetUserMapping` raises when no mapping exists, so probe the catalog
    // first: this is the one place PRD-6 needs to distinguish absent from
    // erroring, and raising ERROR here would lose the 28000 mapping.
    if !user_mapping_exists(server_oid, user_oid) {
        return None;
    }

    // SAFETY: a mapping is known to exist for (user_oid, server_oid), so
    // GetUserMapping returns a palloc'd UserMapping rather than raising.
    unsafe {
        let mapping = pg_sys::GetUserMapping(user_oid, server_oid);
        if mapping.is_null() {
            return None;
        }
        Some(defelem_list((*mapping).options))
    }
}

/// Is there a mapping for this exact role, or a `PUBLIC` mapping, on this
/// server? Mirrors `GetUserMapping`'s own lookup order.
fn user_mapping_exists(server_oid: pg_sys::Oid, user_oid: pg_sys::Oid) -> bool {
    // SAFETY: SearchSysCache2 with a released tuple; both OIDs are plain values.
    unsafe {
        for candidate in [user_oid, pg_sys::InvalidOid] {
            let tuple = pg_sys::SearchSysCache2(
                pg_sys::SysCacheIdentifier::USERMAPPINGUSERSERVER as i32,
                pg_sys::Datum::from(candidate),
                pg_sys::Datum::from(server_oid),
            );
            if !tuple.is_null() {
                pg_sys::ReleaseSysCache(tuple);
                return true;
            }
        }
        false
    }
}

/// Convert a `List *` of `DefElem *` (catalog options) into `(name, value)`.
///
/// SAFETY: caller guarantees `list` is a valid `List *` of `DefElem *` owned by
/// the current memory context, as produced by `GetForeignServer`/`GetUserMapping`.
unsafe fn defelem_list(list: *mut pg_sys::List) -> Vec<(String, String)> {
    let mut out = Vec::new();
    if list.is_null() {
        return out;
    }

    let length = (*list).length as usize;
    for index in 0..length {
        let cell = (*list).elements.add(index);
        let node = (*cell).ptr_value as *mut pg_sys::DefElem;
        if node.is_null() {
            continue;
        }

        let name = match CStr::from_ptr((*node).defname).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => continue,
        };

        let value = defelem_string((*node).arg);
        out.push((name, value));
    }
    out
}

/// A catalog option's value is always a `String` node in practice.
unsafe fn defelem_string(arg: *mut pg_sys::Node) -> String {
    if arg.is_null() {
        return String::new();
    }
    let ptr = pg_sys::defGetString(&mut pg_sys::DefElem {
        type_: pg_sys::NodeTag::T_DefElem,
        defnamespace: std::ptr::null_mut(),
        defname: c"opt".as_ptr().cast_mut(),
        arg,
        defaction: pg_sys::DefElemAction::DEFELEM_UNSPEC,
        location: -1,
    });
    if ptr.is_null() {
        String::new()
    } else {
        CStr::from_ptr(ptr).to_string_lossy().into_owned()
    }
}

/// Convert a `text[]` of `name=value` strings (the shape PostgreSQL hands the
/// FDW validator) into `(name, value)` pairs.
pub fn split_validator_options(raw: Vec<Option<String>>) -> Vec<(String, String)> {
    raw.into_iter()
        .flatten()
        .filter_map(|entry| {
            entry
                .split_once('=')
                .map(|(k, v)| (k.to_string(), v.to_string()))
        })
        .collect()
}

/// Turn a JSON-RPC `params` value into the shape MCP expects, defaulting a
/// missing/NULL argument object to `{}`.
pub fn params_object(value: Option<Value>) -> Value {
    match value {
        Some(Value::Object(map)) => Value::Object(map),
        Some(Value::Null) | None => Value::Object(Default::default()),
        Some(other) => other,
    }
}

#[cfg(any(test, feature = "pg_test"))]
#[pgrx::pg_schema]
mod tests {
    use super::*;
    use serde_json::json;

    #[pgrx::pg_test]
    fn unknown_foreign_server_is_42704() {
        let err = lookup_foreign_server("no_such_server_at_all").unwrap_err();
        assert_eq!(err.sqlstate(), "42704");
        assert!(err.message().contains("no_such_server_at_all"));
    }

    #[pgrx::pg_test]
    fn validator_option_array_splits_on_the_first_equals() {
        let parsed = split_validator_options(vec![
            Some("url=https://x.example/mcp?a=b".to_string()),
            Some("timeout_ms=5000".to_string()),
            None,
            Some("malformed".to_string()),
        ]);
        assert_eq!(
            parsed,
            vec![
                ("url".to_string(), "https://x.example/mcp?a=b".to_string()),
                ("timeout_ms".to_string(), "5000".to_string()),
            ]
        );
    }

    #[pgrx::pg_test]
    fn params_object_defaults_to_empty() {
        assert_eq!(params_object(None), json!({}));
        assert_eq!(params_object(Some(Value::Null)), json!({}));
        assert_eq!(params_object(Some(json!({"a": 1}))), json!({"a": 1}));
    }

    #[pgrx::pg_test]
    fn session_map_starts_empty_in_a_fresh_backend() {
        clear_all_sessions();
        assert_eq!(session_count(), 0);
        assert_eq!(
            initialize_count(pg_sys::Oid::INVALID, pg_sys::Oid::INVALID),
            None
        );
    }

    #[pgrx::pg_test]
    fn dropping_an_absent_session_reports_false() {
        clear_all_sessions();
        assert!(!drop_session(pg_sys::Oid::INVALID, current_user_oid()));
    }

    #[pgrx::pg_test]
    fn current_user_oid_is_a_real_role() {
        assert_ne!(current_user_oid(), pg_sys::Oid::INVALID);
    }
}
