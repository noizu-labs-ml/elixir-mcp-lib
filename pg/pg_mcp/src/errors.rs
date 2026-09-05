//! MCP / transport failures → PostgreSQL SQLSTATEs.
//!
//! PRD-6 §4.7 defines the subset used by the client core; PRD-7 §4.7 extends the
//! table with per-table `is_error` row semantics. Every variant here carries a
//! *message we composed ourselves*: nothing that ever held a bearer token is
//! allowed into `McpError` (FR-6.11).

use pgrx::prelude::*;

/// JSON-RPC reserved codes we map explicitly.
pub const JSONRPC_INVALID_PARAMS: i64 = -32602;
pub const JSONRPC_METHOD_NOT_FOUND: i64 = -32601;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum McpError {
    /// JSON-RPC -32602 → 22023 invalid_parameter_value
    InvalidParams(String),
    /// JSON-RPC -32601 → 0A000 feature_not_supported
    MethodNotFound(String),
    /// HTTP 401/403, or a verifier rejection → 42501 insufficient_privilege
    Forbidden(String),
    /// connect / read timeout, DNS, TLS, malformed frame → 08006 connection_failure
    Transport(String),
    /// unknown foreign server name → 42704 undefined_object
    UndefinedObject(String),
    /// missing USER MAPPING under `auth 'bearer'` → 28000
    NoAuthMapping(String),
    /// tool returned `isError: true` under `on_error => 'raise'` → P0001
    ToolError(String),
    /// option validation failure → 22023 (same class as invalid params)
    InvalidOption(String),
    /// declared-but-not-yet-implemented surface → 0A000
    NotImplemented(String),
    /// any other JSON-RPC error code → 22023 with the server's message
    Rpc(i64, String),
}

impl McpError {
    /// The five-character SQLSTATE this error is reported as.
    pub fn sqlstate(&self) -> &'static str {
        match self {
            McpError::InvalidParams(_) | McpError::InvalidOption(_) | McpError::Rpc(_, _) => {
                "22023"
            }
            McpError::MethodNotFound(_) | McpError::NotImplemented(_) => "0A000",
            McpError::Forbidden(_) => "42501",
            McpError::Transport(_) => "08006",
            McpError::UndefinedObject(_) => "42704",
            McpError::NoAuthMapping(_) => "28000",
            McpError::ToolError(_) => "P0001",
        }
    }

    pub fn message(&self) -> &str {
        match self {
            McpError::InvalidParams(m)
            | McpError::MethodNotFound(m)
            | McpError::Forbidden(m)
            | McpError::Transport(m)
            | McpError::UndefinedObject(m)
            | McpError::NoAuthMapping(m)
            | McpError::ToolError(m)
            | McpError::InvalidOption(m)
            | McpError::NotImplemented(m)
            | McpError::Rpc(_, m) => m,
        }
    }

    /// Map a JSON-RPC `error` object onto a variant. HTTP-level rejections are
    /// classified by [`from_http_status`] before this is reached.
    pub fn from_rpc(code: i64, message: &str) -> McpError {
        match code {
            JSONRPC_INVALID_PARAMS => McpError::InvalidParams(message.to_string()),
            JSONRPC_METHOD_NOT_FOUND => McpError::MethodNotFound(message.to_string()),
            // Servers commonly reuse -32001/-32003 for authz; treat them as such
            // only when the message says so, otherwise keep the generic mapping.
            _ if is_authz_message(message) => McpError::Forbidden(message.to_string()),
            other => McpError::Rpc(other, message.to_string()),
        }
    }

    /// Non-2xx HTTP. 404 is handled by the session layer (expired session
    /// re-initialize, PRD-6 §4.4 step 3) before it reaches here.
    pub fn from_http_status(status: u16) -> McpError {
        match status {
            401 | 403 => {
                McpError::Forbidden(format!("MCP server rejected the request (HTTP {status})"))
            }
            400 => McpError::InvalidParams("MCP server rejected the request (HTTP 400)".into()),
            405 => McpError::MethodNotFound("MCP server does not accept POST (HTTP 405)".into()),
            other => McpError::Transport(format!("MCP server returned HTTP {other}")),
        }
    }

    /// Report through `ereport(ERROR, ...)`. Diverges: never returns.
    pub fn raise(&self) -> ! {
        // `ereport!` wants a literal-ish code; pgrx exposes PgSqlErrorCode
        // variants, so translate rather than passing the string through.
        let code = self.error_code();
        ereport!(PgLogLevel::ERROR, code, self.message().to_string());
        unreachable!("ereport(ERROR) does not return")
    }

    fn error_code(&self) -> PgSqlErrorCode {
        match self {
            McpError::InvalidParams(_) | McpError::InvalidOption(_) | McpError::Rpc(_, _) => {
                PgSqlErrorCode::ERRCODE_INVALID_PARAMETER_VALUE
            }
            McpError::MethodNotFound(_) | McpError::NotImplemented(_) => {
                PgSqlErrorCode::ERRCODE_FEATURE_NOT_SUPPORTED
            }
            McpError::Forbidden(_) => PgSqlErrorCode::ERRCODE_INSUFFICIENT_PRIVILEGE,
            McpError::Transport(_) => PgSqlErrorCode::ERRCODE_CONNECTION_FAILURE,
            McpError::UndefinedObject(_) => PgSqlErrorCode::ERRCODE_UNDEFINED_OBJECT,
            McpError::NoAuthMapping(_) => {
                PgSqlErrorCode::ERRCODE_INVALID_AUTHORIZATION_SPECIFICATION
            }
            McpError::ToolError(_) => PgSqlErrorCode::ERRCODE_RAISE_EXCEPTION,
        }
    }
}

fn is_authz_message(message: &str) -> bool {
    let lower = message.to_ascii_lowercase();
    lower.contains("unauthorized")
        || lower.contains("forbidden")
        || lower.contains("access denied")
        || lower.contains("insufficient scope")
        || lower.contains("invalid_token")
}

/// Does this JSON-RPC error message describe an unknown or expired MCP session?
/// Paired with HTTP 404 in PRD-6 §4.4 step 3.
pub fn is_expired_session(message: &str) -> bool {
    let lower = message.to_ascii_lowercase();
    (lower.contains("session")
        && (lower.contains("expired") || lower.contains("unknown") || lower.contains("not found")))
        || lower.contains("invalid session id")
}

pub type McpResult<T> = Result<T, McpError>;

#[cfg(any(test, feature = "pg_test"))]
#[pgrx::pg_schema]
mod tests {
    use super::*;

    #[pgrx::pg_test]
    fn errcode_table_matches_prd_6_4_7() {
        assert_eq!(McpError::from_rpc(-32602, "bad").sqlstate(), "22023");
        assert_eq!(McpError::from_rpc(-32601, "nope").sqlstate(), "0A000");
        assert_eq!(McpError::from_http_status(401).sqlstate(), "42501");
        assert_eq!(McpError::from_http_status(403).sqlstate(), "42501");
        assert_eq!(McpError::from_http_status(502).sqlstate(), "08006");
        assert_eq!(McpError::Transport("t".into()).sqlstate(), "08006");
        assert_eq!(McpError::UndefinedObject("s".into()).sqlstate(), "42704");
        assert_eq!(McpError::NoAuthMapping("m".into()).sqlstate(), "28000");
        assert_eq!(McpError::ToolError("boom".into()).sqlstate(), "P0001");
        assert_eq!(McpError::NotImplemented("later".into()).sqlstate(), "0A000");
    }

    #[pgrx::pg_test]
    fn rpc_error_carries_server_message() {
        let e = McpError::from_rpc(-32602, "arguments.location is required");
        assert_eq!(e.message(), "arguments.location is required");
    }

    #[pgrx::pg_test]
    fn authz_shaped_rpc_errors_become_42501() {
        assert_eq!(
            McpError::from_rpc(-32001, "Unauthorized").sqlstate(),
            "42501"
        );
        assert_eq!(
            McpError::from_rpc(-32003, "invalid_token").sqlstate(),
            "42501"
        );
        // A plain application error keeps the generic mapping.
        assert_eq!(McpError::from_rpc(-32000, "disk full").sqlstate(), "22023");
    }

    #[pgrx::pg_test]
    fn expired_session_detection() {
        assert!(is_expired_session("Session expired"));
        assert!(is_expired_session("unknown session"));
        assert!(is_expired_session("Invalid session id"));
        assert!(is_expired_session("session not found"));
        assert!(!is_expired_session("tool not found"));
        assert!(!is_expired_session("timeout"));
    }
}
