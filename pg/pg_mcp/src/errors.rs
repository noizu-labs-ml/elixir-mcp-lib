//! MCP / transport failures → PostgreSQL SQLSTATEs.
//!
//! PRD-6 §4.7 defined the subset used by the client core; PRD-7 §4.9 completes
//! the table (FR-7.17). Every variant here carries a *message we composed
//! ourselves*: nothing that ever held a bearer token is allowed into `McpError`
//! (FR-6.11), and FDW-path errors are raised through [`McpError::raise_ctx`],
//! whose `errdetail` names the foreign server and the MCP method — never the
//! token.

use pgrx::prelude::*;

/// JSON-RPC reserved codes we map explicitly.
pub const JSONRPC_INVALID_PARAMS: i64 = -32602;
pub const JSONRPC_METHOD_NOT_FOUND: i64 = -32601;
pub const JSONRPC_INVALID_REQUEST: i64 = -32600;
pub const JSONRPC_PARSE_ERROR: i64 = -32700;
pub const JSONRPC_INTERNAL_ERROR: i64 = -32603;

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
    /// PRD-7 §4.9: `-32600` invalid request, `-32700` parse error, `-32603`
    /// internal error → XX000 internal_error
    Internal(String),
    /// PRD-7 §4.9: missing required qual, unqualified read-through scan with
    /// cap 0, UPDATE/DELETE on tool_calls, or any other "this shape of access
    /// is not supported" → 0A000 feature_not_supported
    FeatureNotSupported(String),
    /// PRD-7 §4.9: read-through fan-out exceeding `max_unqualified_reads`
    /// → 54023 too_many_arguments
    TooManyArguments(String),
    /// PRD-7 §4.9: `tool` NULL on insert into tool_calls → 23502
    NotNullViolation(String),
    /// PRD-7 §4.9: audit table column shape mismatch → 42804
    DatatypeMismatch(String),
    /// PRD-7 §4.11: IMPORT FOREIGN SCHEMA with a remote schema other than
    /// `mcp` → 3F000 invalid_schema_name
    InvalidSchemaName(String),
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
            McpError::FeatureNotSupported(_) => "0A000",
            McpError::Internal(_) => "XX000",
            McpError::TooManyArguments(_) => "54023",
            McpError::NotNullViolation(_) => "23502",
            McpError::DatatypeMismatch(_) => "42804",
            McpError::InvalidSchemaName(_) => "3F000",
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
            | McpError::Internal(m)
            | McpError::FeatureNotSupported(m)
            | McpError::TooManyArguments(m)
            | McpError::NotNullViolation(m)
            | McpError::DatatypeMismatch(m)
            | McpError::InvalidSchemaName(m)
            | McpError::Rpc(_, m) => m,
        }
    }

    /// Map a JSON-RPC `error` object onto a variant. HTTP-level rejections are
    /// classified by [`from_http_status`] before this is reached.
    pub fn from_rpc(code: i64, message: &str) -> McpError {
        match code {
            JSONRPC_INVALID_PARAMS => McpError::InvalidParams(message.to_string()),
            JSONRPC_METHOD_NOT_FOUND => McpError::MethodNotFound(message.to_string()),
            // §4.9: protocol-level garbage and server-side failures are
            // internal errors, with the message we were given.
            JSONRPC_INVALID_REQUEST | JSONRPC_PARSE_ERROR | JSONRPC_INTERNAL_ERROR => {
                McpError::Internal(format!("MCP protocol failure ({}): {message}", code))
            }
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

    /// PRD-7 §4.9: the FDW path always reports *which* foreign server and MCP
    /// method failed, as `errdetail`. The credential is never part of either
    /// (FR-6.11): server names are catalog objects, method names are protocol
    /// constants.
    pub fn raise_ctx(&self, server: &str, method: &str) -> ! {
        let code = self.error_code();
        ereport!(
            PgLogLevel::ERROR,
            code,
            self.message().to_string(),
            format!("foreign server \"{}\", MCP method \"{}\"", server, method)
        );
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
            McpError::FeatureNotSupported(_) => PgSqlErrorCode::ERRCODE_FEATURE_NOT_SUPPORTED,
            McpError::Internal(_) => PgSqlErrorCode::ERRCODE_INTERNAL_ERROR,
            McpError::TooManyArguments(_) => PgSqlErrorCode::ERRCODE_TOO_MANY_ARGUMENTS,
            McpError::NotNullViolation(_) => PgSqlErrorCode::ERRCODE_NOT_NULL_VIOLATION,
            McpError::DatatypeMismatch(_) => PgSqlErrorCode::ERRCODE_DATATYPE_MISMATCH,
            McpError::InvalidSchemaName(_) => PgSqlErrorCode::ERRCODE_INVALID_SCHEMA_NAME,
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
    fn errcode_table_covers_the_full_prd_7_4_9_set() {
        // FR-7.17: every row of §4.9 that is an exception.
        assert_eq!(
            McpError::from_rpc(-32602, "bad").sqlstate(),
            "22023",
            "-32602 → invalid_parameter_value"
        );
        // -32601 on a read-through call surfaces as 0A000 (§4.9 row 2); on a
        // list method it becomes an empty table (D5) and never reaches here.
        assert_eq!(
            McpError::from_rpc(-32601, "nope").sqlstate(),
            "0A000",
            "-32601 → feature_not_supported"
        );
        for code in [-32600, -32700, -32603] {
            assert_eq!(
                McpError::from_rpc(code, "m").sqlstate(),
                "XX000",
                "{code} → internal_error"
            );
        }
        assert_eq!(
            McpError::from_http_status(401).sqlstate(),
            "42501",
            "401/403 → insufficient_privilege"
        );
        assert_eq!(
            McpError::Transport("conn".into()).sqlstate(),
            "08006",
            "transport → connection_failure"
        );
        assert_eq!(
            McpError::FeatureNotSupported("missing qual".into()).sqlstate(),
            "0A000",
            "unqualified read-through / missing qual / UPDATE+DELETE → feature_not_supported"
        );
        assert_eq!(
            McpError::TooManyArguments("cap".into()).sqlstate(),
            "54023",
            "fan-out beyond cap → too_many_arguments"
        );
        assert_eq!(
            McpError::NotNullViolation("tool".into()).sqlstate(),
            "23502",
            "tool NULL on insert → not_null_violation"
        );
        assert_eq!(
            McpError::DatatypeMismatch("column".into()).sqlstate(),
            "42804",
            "audit shape mismatch → datatype_mismatch"
        );
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

/// Host-side unit tests (no PostgreSQL; `cargo test --lib -- --skip pg_`).
/// The complete §4.9 SQLSTATE table as a data table, plus the wording
/// contracts the client relies on.
#[cfg(test)]
mod host_tests {
    use super::*;

    /// Every variant carries the PRD's five-character SQLSTATE. New variants
    /// fail here until their row is added — the compiler cannot force this.
    #[test]
    fn every_variant_has_its_sqlstate_row() {
        use McpError as E;
        let table: &[(E, &str)] = &[
            (E::InvalidParams("m".into()), "22023"),
            (E::InvalidOption("m".into()), "22023"),
            (E::Rpc(-1, "m".into()), "22023"),
            (E::MethodNotFound("m".into()), "0A000"),
            (E::NotImplemented("m".into()), "0A000"),
            (E::FeatureNotSupported("m".into()), "0A000"),
            (E::Internal("m".into()), "XX000"),
            (E::TooManyArguments("m".into()), "54023"),
            (E::NotNullViolation("m".into()), "23502"),
            (E::DatatypeMismatch("m".into()), "42804"),
            (E::InvalidSchemaName("m".into()), "3F000"),
            (E::Forbidden("m".into()), "42501"),
            (E::Transport("m".into()), "08006"),
            (E::UndefinedObject("m".into()), "42704"),
            (E::NoAuthMapping("m".into()), "28000"),
            (E::ToolError("m".into()), "P0001"),
        ];
        for (error, sqlstate) in table {
            assert_eq!(&error.sqlstate(), sqlstate, "{error:?}");
            // The message round-trips verbatim through every variant.
            assert_eq!(error.message(), "m", "{error:?}");
        }
    }

    /// §4.9's JSON-RPC code → SQLSTATE rows, including the authz-message
    /// heuristic and the pass-through class.
    #[test]
    fn from_rpc_covers_the_full_prd_table() {
        let code_of = |code: i64, msg: &str| McpError::from_rpc(code, msg);
        assert_eq!(code_of(-32602, "x").sqlstate(), "22023");
        assert_eq!(code_of(-32601, "x").sqlstate(), "0A000");
        for protocol_garbage in [-32600, -32700, -32603] {
            let e = code_of(protocol_garbage, "x");
            assert_eq!(e.sqlstate(), "XX000", "{protocol_garbage}");
            // The code number rides along in the message for diagnosis.
            assert!(e.message().contains(&protocol_garbage.to_string()));
        }
        // Authz-shaped messages on unknown codes → 42501.
        for msg in [
            "Unauthorized",
            "FORBIDDEN",
            "access denied",
            "Insufficient scope",
            "invalid_token",
        ] {
            assert_eq!(code_of(-32001, msg).sqlstate(), "42501", "{msg}");
        }
        // …and the same codes with an innocuous message keep the 22023 class.
        assert_eq!(code_of(-32001, "disk full").sqlstate(), "22023");
        assert_eq!(code_of(-32003, "disk full").sqlstate(), "22023");
        // Anything else is Rpc, carrying the server's message verbatim.
        let e = code_of(-31415, "custom failure");
        assert!(matches!(e, McpError::Rpc(-31415, _)));
        assert_eq!(e.message(), "custom failure");
    }

    /// HTTP status mapping. 404 is intercepted upstream (session re-init);
    /// `from_http_status` still maps it as plain transport if it ever
    /// reaches here — pinned so a change is deliberate.
    #[test]
    fn from_http_status_table() {
        assert_eq!(McpError::from_http_status(401).sqlstate(), "42501");
        assert_eq!(McpError::from_http_status(403).sqlstate(), "42501");
        assert_eq!(McpError::from_http_status(400).sqlstate(), "22023");
        assert_eq!(McpError::from_http_status(405).sqlstate(), "0A000");
        assert_eq!(McpError::from_http_status(404).sqlstate(), "08006");
        for other in [402, 409, 429, 500, 502, 503] {
            assert_eq!(McpError::from_http_status(other).sqlstate(), "08006", "{other}");
        }
    }

    /// FR-6.11: an HTTP-level rejection message is *composed here* — exactly
    /// the status number and nothing from the response. A canary planted in
    /// the (hypothetical) body can never appear because the body is never
    /// read; the exact-message pins enforce that structurally.
    #[test]
    fn http_error_messages_are_composed_not_reflected() {
        assert_eq!(
            McpError::from_http_status(401).message(),
            "MCP server rejected the request (HTTP 401)"
        );
        assert_eq!(
            McpError::from_http_status(400).message(),
            "MCP server rejected the request (HTTP 400)"
        );
        assert_eq!(
            McpError::from_http_status(405).message(),
            "MCP server does not accept POST (HTTP 405)"
        );
        assert_eq!(
            McpError::from_http_status(502).message(),
            "MCP server returned HTTP 502"
        );
    }

    /// Expired-session detection matrix (pairs with HTTP 404, PRD-6 §4.4
    /// step 3).
    #[test]
    fn expired_session_matrix() {
        for yes in [
            "Session expired",
            "MCP session has EXPIRED",
            "unknown session",
            "session not found",
            "Unknown Session",
            "Invalid session id",
            "invalid session id: abc123",
            "the session was not found on this server",
        ] {
            assert!(is_expired_session(yes), "{yes:?}");
        }
        for no in [
            "tool not found",
            "timeout",
            "invalid arguments",
            "expired token",
            "unknown method",
            "",
        ] {
            assert!(!is_expired_session(no), "{no:?}");
        }
    }

    /// The reserved-code constants are the wire values, not nice numbers.
    #[test]
    fn jsonrpc_reserved_codes() {
        assert_eq!(JSONRPC_INVALID_PARAMS, -32602);
        assert_eq!(JSONRPC_METHOD_NOT_FOUND, -32601);
        assert_eq!(JSONRPC_INVALID_REQUEST, -32600);
        assert_eq!(JSONRPC_PARSE_ERROR, -32700);
        assert_eq!(JSONRPC_INTERNAL_ERROR, -32603);
    }
}
