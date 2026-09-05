//! Foreign-server and user-mapping option parsing + validation.
//!
//! PRD-6 §4.2 (server options) and §4.3 (user-mapping options). The validator is
//! invoked by PostgreSQL at `CREATE`/`ALTER SERVER` and `CREATE`/`ALTER USER
//! MAPPING` time (FR-6.3); the parsers are re-run at call time so nothing is
//! captured at build time (design rule D3).

use crate::errors::{McpError, McpResult};
use std::net::{IpAddr, ToSocketAddrs};
use url::{Host, Url};

pub const DEFAULT_TIMEOUT_MS: u64 = 15_000;
pub const MIN_TIMEOUT_MS: u64 = 1;
pub const MAX_TIMEOUT_MS: u64 = 600_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Auto,
    Generic,
    Sql,
}

impl Mode {
    fn parse(raw: &str) -> McpResult<Mode> {
        match raw {
            "auto" => Ok(Mode::Auto),
            "generic" => Ok(Mode::Generic),
            "sql" => Ok(Mode::Sql),
            other => Err(McpError::InvalidOption(format!(
                "invalid value for foreign server option \"mode\": \"{other}\" (expected auto, generic or sql)"
            ))),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthMode {
    Bearer,
    None,
}

impl AuthMode {
    fn parse(raw: &str) -> McpResult<AuthMode> {
        match raw {
            "bearer" => Ok(AuthMode::Bearer),
            "none" => Ok(AuthMode::None),
            other => Err(McpError::InvalidOption(format!(
                "invalid value for foreign server option \"auth\": \"{other}\" (expected bearer or none)"
            ))),
        }
    }
}

#[derive(Debug, Clone)]
pub struct ServerOptions {
    pub url: String,
    pub mode: Mode,
    pub timeout_ms: u64,
    pub auth: AuthMode,
    pub max_unqualified_reads: i64,
    pub audit_table: Option<String>,
}

/// Recognised foreign-server option names. Anything else is rejected so a typo
/// fails at `CREATE SERVER` rather than silently doing nothing at call time.
const SERVER_OPTION_NAMES: &[&str] = &[
    "url",
    "mode",
    "timeout_ms",
    "auth",
    "max_unqualified_reads",
    "audit_table",
];

const USER_MAPPING_OPTION_NAMES: &[&str] = &["token", "token_secret"];

impl ServerOptions {
    /// Parse and validate a `(name, value)` option list. Used both by the
    /// validator and at call time.
    pub fn parse(opts: &[(String, String)]) -> McpResult<ServerOptions> {
        for (name, _) in opts {
            if !SERVER_OPTION_NAMES.contains(&name.as_str()) {
                return Err(McpError::InvalidOption(format!(
                    "invalid option \"{name}\" for a pg_mcp foreign server (valid options: {})",
                    SERVER_OPTION_NAMES.join(", ")
                )));
            }
        }

        let get = |k: &str| -> Option<&str> {
            opts.iter().find(|(n, _)| n == k).map(|(_, v)| v.as_str())
        };

        let raw_url = get("url").ok_or_else(|| {
            McpError::InvalidOption("foreign server option \"url\" is required".to_string())
        })?;
        let parsed = parse_url(raw_url)?;

        let mode = match get("mode") {
            Some(v) => Mode::parse(v)?,
            None => Mode::Auto,
        };

        let timeout_ms = match get("timeout_ms") {
            Some(v) => parse_timeout(v)?,
            None => DEFAULT_TIMEOUT_MS,
        };

        let auth = match get("auth") {
            Some(v) => AuthMode::parse(v)?,
            None => AuthMode::Bearer,
        };

        // ADR-004: `auth 'none'` is loopback-only, opt-in dev tooling.
        if auth == AuthMode::None && !is_loopback(&parsed) {
            return Err(McpError::InvalidOption(
                "foreign server option \"auth\" may only be 'none' when \"url\" points at a loopback host"
                    .to_string(),
            ));
        }

        // Plaintext http is loopback-only regardless of auth mode: a bearer
        // token must never cross an unencrypted hop.
        if parsed.scheme() == "http" && !is_loopback(&parsed) {
            return Err(McpError::InvalidOption(
                "foreign server option \"url\" must use https unless the host is loopback"
                    .to_string(),
            ));
        }

        let max_unqualified_reads = match get("max_unqualified_reads") {
            Some(v) => parse_non_negative(v, "max_unqualified_reads")?,
            None => 0,
        };

        let audit_table = match get("audit_table") {
            Some(v) => Some(parse_audit_table(v)?),
            None => None,
        };

        Ok(ServerOptions {
            url: parsed.to_string(),
            mode,
            timeout_ms,
            auth,
            max_unqualified_reads,
            audit_table,
        })
    }
}

/// A user mapping supplies exactly one of `token` or `token_secret`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Credential {
    /// Bearer credential carried inline in the mapping options.
    Token(String),
    /// `schema.table` naming a `(role name primary key, token text)` row set.
    TokenSecret { schema: String, table: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UserMappingOptions {
    pub credential: Credential,
}

impl UserMappingOptions {
    pub fn parse(opts: &[(String, String)]) -> McpResult<UserMappingOptions> {
        for (name, _) in opts {
            if !USER_MAPPING_OPTION_NAMES.contains(&name.as_str()) {
                return Err(McpError::InvalidOption(format!(
                    "invalid option \"{name}\" for a pg_mcp user mapping (valid options: {})",
                    USER_MAPPING_OPTION_NAMES.join(", ")
                )));
            }
        }

        let get = |k: &str| -> Option<&str> {
            opts.iter().find(|(n, _)| n == k).map(|(_, v)| v.as_str())
        };

        match (get("token"), get("token_secret")) {
            (Some(_), Some(_)) => Err(McpError::InvalidOption(
                "user mapping options \"token\" and \"token_secret\" are mutually exclusive"
                    .to_string(),
            )),
            (Some(token), None) => {
                if token.trim().is_empty() {
                    // Deliberately does not echo the value — it is a credential.
                    return Err(McpError::InvalidOption(
                        "user mapping option \"token\" must not be empty".to_string(),
                    ));
                }
                Ok(UserMappingOptions {
                    credential: Credential::Token(token.to_string()),
                })
            }
            (None, Some(secret)) => {
                let (schema, table) = split_qualified(secret, "token_secret")?;
                Ok(UserMappingOptions {
                    credential: Credential::TokenSecret { schema, table },
                })
            }
            (None, None) => Err(McpError::InvalidOption(
                "a pg_mcp user mapping requires either \"token\" or \"token_secret\"".to_string(),
            )),
        }
    }
}

fn parse_url(raw: &str) -> McpResult<Url> {
    let parsed = Url::parse(raw).map_err(|_| {
        McpError::InvalidOption(format!(
            "invalid value for foreign server option \"url\": \"{raw}\" is not an absolute URL"
        ))
    })?;

    if parsed.scheme() != "http" && parsed.scheme() != "https" {
        return Err(McpError::InvalidOption(format!(
            "invalid value for foreign server option \"url\": scheme \"{}\" is not http or https",
            parsed.scheme()
        )));
    }

    if parsed.host().is_none() {
        return Err(McpError::InvalidOption(
            "invalid value for foreign server option \"url\": missing host".to_string(),
        ));
    }

    Ok(parsed)
}

fn parse_timeout(raw: &str) -> McpResult<u64> {
    let n: u64 = raw.trim().parse().map_err(|_| {
        McpError::InvalidOption(format!(
            "invalid value for foreign server option \"timeout_ms\": \"{raw}\" is not an integer"
        ))
    })?;

    if !(MIN_TIMEOUT_MS..=MAX_TIMEOUT_MS).contains(&n) {
        return Err(McpError::InvalidOption(format!(
            "invalid value for foreign server option \"timeout_ms\": {n} is outside {MIN_TIMEOUT_MS}..{MAX_TIMEOUT_MS}"
        )));
    }
    Ok(n)
}

fn parse_non_negative(raw: &str, option: &str) -> McpResult<i64> {
    let n: i64 = raw.trim().parse().map_err(|_| {
        McpError::InvalidOption(format!(
            "invalid value for foreign server option \"{option}\": \"{raw}\" is not an integer"
        ))
    })?;
    if n < 0 {
        return Err(McpError::InvalidOption(format!(
            "invalid value for foreign server option \"{option}\": must be >= 0"
        )));
    }
    Ok(n)
}

/// `audit_table` must be a schema-qualified identifier pair. Existence is
/// checked lazily at first write (PRD-6 §4.2), not here.
fn parse_audit_table(raw: &str) -> McpResult<String> {
    let (schema, table) = split_qualified(raw, "audit_table")?;
    Ok(format!("{schema}.{table}"))
}

fn split_qualified(raw: &str, option: &str) -> McpResult<(String, String)> {
    let parts: Vec<&str> = raw.split('.').collect();
    if parts.len() != 2 || parts.iter().any(|p| p.is_empty()) {
        return Err(McpError::InvalidOption(format!(
            "invalid value for option \"{option}\": \"{raw}\" is not a schema-qualified name (expected schema.table)"
        )));
    }
    if !parts.iter().all(|p| is_plain_identifier(p)) {
        return Err(McpError::InvalidOption(format!(
            "invalid value for option \"{option}\": \"{raw}\" is not a plain SQL identifier pair"
        )));
    }
    Ok((parts[0].to_string(), parts[1].to_string()))
}

fn is_plain_identifier(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 63
        && s.chars()
            .next()
            .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '$')
}

/// Is the URL's host loopback? Literal addresses are checked directly; names are
/// resolved and every returned address must be loopback (a name that resolves to
/// both loopback and a routable address is rejected).
pub fn is_loopback(url: &Url) -> bool {
    match url.host() {
        Some(Host::Ipv4(ip)) => ip.is_loopback(),
        Some(Host::Ipv6(ip)) => ip.is_loopback(),
        Some(Host::Domain(name)) => {
            if name.eq_ignore_ascii_case("localhost") {
                return true;
            }
            let port = url.port_or_known_default().unwrap_or(80);
            match (name, port).to_socket_addrs() {
                Ok(mut addrs) => {
                    let mut any = false;
                    let all_loopback = addrs.all(|a| {
                        any = true;
                        match a.ip() {
                            IpAddr::V4(v4) => v4.is_loopback(),
                            IpAddr::V6(v6) => v6.is_loopback(),
                        }
                    });
                    any && all_loopback
                }
                Err(_) => false,
            }
        }
        None => false,
    }
}

#[cfg(any(test, feature = "pg_test"))]
#[pgrx::pg_schema]
mod tests {
    use super::*;

    fn opts(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    #[pgrx::pg_test]
    fn accepts_the_full_prd_option_set() {
        let parsed = ServerOptions::parse(&opts(&[
            ("url", "https://npl.noizu.com/mcp"),
            ("mode", "auto"),
            ("timeout_ms", "15000"),
            ("auth", "bearer"),
            ("max_unqualified_reads", "0"),
            ("audit_table", "mcp_audit.tool_calls"),
        ]))
        .unwrap();

        assert_eq!(parsed.mode, Mode::Auto);
        assert_eq!(parsed.timeout_ms, 15_000);
        assert_eq!(parsed.auth, AuthMode::Bearer);
        assert_eq!(parsed.max_unqualified_reads, 0);
        assert_eq!(parsed.audit_table.as_deref(), Some("mcp_audit.tool_calls"));
    }

    #[pgrx::pg_test]
    fn applies_documented_defaults() {
        let parsed = ServerOptions::parse(&opts(&[("url", "https://x.example/mcp")])).unwrap();
        assert_eq!(parsed.mode, Mode::Auto);
        assert_eq!(parsed.timeout_ms, DEFAULT_TIMEOUT_MS);
        assert_eq!(parsed.auth, AuthMode::Bearer);
        assert_eq!(parsed.max_unqualified_reads, 0);
        assert!(parsed.audit_table.is_none());
    }

    #[pgrx::pg_test]
    fn url_is_required_and_must_be_absolute_http() {
        assert!(ServerOptions::parse(&opts(&[("mode", "generic")])).is_err());
        assert!(ServerOptions::parse(&opts(&[("url", "/mcp")])).is_err());
        assert!(ServerOptions::parse(&opts(&[("url", "ftp://x.example/mcp")])).is_err());
        assert!(ServerOptions::parse(&opts(&[("url", "not a url")])).is_err());
    }

    #[pgrx::pg_test]
    fn plain_http_is_loopback_only() {
        assert!(ServerOptions::parse(&opts(&[("url", "http://127.0.0.1:4000/mcp")])).is_ok());
        assert!(ServerOptions::parse(&opts(&[("url", "http://localhost:4000/mcp")])).is_ok());
        assert!(ServerOptions::parse(&opts(&[("url", "http://npl.noizu.com/mcp")])).is_err());
    }

    #[pgrx::pg_test]
    fn auth_none_is_loopback_only() {
        assert!(ServerOptions::parse(&opts(&[
            ("url", "http://127.0.0.1:4000/mcp"),
            ("auth", "none"),
        ]))
        .is_ok());

        let err = ServerOptions::parse(&opts(&[
            ("url", "https://npl.noizu.com/mcp"),
            ("auth", "none"),
        ]))
        .unwrap_err();
        assert_eq!(err.sqlstate(), "22023");
        assert!(err.message().contains("loopback"));
    }

    #[pgrx::pg_test]
    fn rejects_bad_enum_and_range_values() {
        for bad in ["sideways", "AUTO", ""] {
            assert!(ServerOptions::parse(&opts(&[
                ("url", "https://x.example/mcp"),
                ("mode", bad),
            ]))
            .is_err());
        }
        for bad in ["0", "600001", "-1", "abc", "1.5"] {
            assert!(ServerOptions::parse(&opts(&[
                ("url", "https://x.example/mcp"),
                ("timeout_ms", bad),
            ]))
            .is_err());
        }
        assert!(ServerOptions::parse(&opts(&[
            ("url", "https://x.example/mcp"),
            ("max_unqualified_reads", "-1"),
        ]))
        .is_err());
        assert!(ServerOptions::parse(&opts(&[
            ("url", "https://x.example/mcp"),
            ("auth", "basic"),
        ]))
        .is_err());
    }

    #[pgrx::pg_test]
    fn timeout_boundaries_are_inclusive() {
        assert!(ServerOptions::parse(&opts(&[
            ("url", "https://x.example/mcp"),
            ("timeout_ms", "1"),
        ]))
        .is_ok());
        assert!(ServerOptions::parse(&opts(&[
            ("url", "https://x.example/mcp"),
            ("timeout_ms", "600000"),
        ]))
        .is_ok());
    }

    #[pgrx::pg_test]
    fn rejects_unknown_server_option() {
        let err = ServerOptions::parse(&opts(&[
            ("url", "https://x.example/mcp"),
            ("tmeout_ms", "5"),
        ]))
        .unwrap_err();
        assert_eq!(err.sqlstate(), "22023");
        assert!(err.message().contains("tmeout_ms"));
    }

    #[pgrx::pg_test]
    fn audit_table_must_be_schema_qualified() {
        assert!(ServerOptions::parse(&opts(&[
            ("url", "https://x.example/mcp"),
            ("audit_table", "tool_calls"),
        ]))
        .is_err());
        assert!(ServerOptions::parse(&opts(&[
            ("url", "https://x.example/mcp"),
            ("audit_table", "a.b.c"),
        ]))
        .is_err());
        assert!(ServerOptions::parse(&opts(&[
            ("url", "https://x.example/mcp"),
            ("audit_table", "mcp_audit.tool calls"),
        ]))
        .is_err());
    }

    #[pgrx::pg_test]
    fn user_mapping_accepts_exactly_one_credential() {
        let m = UserMappingOptions::parse(&opts(&[("token", "abc123")])).unwrap();
        assert_eq!(m.credential, Credential::Token("abc123".into()));

        let m = UserMappingOptions::parse(&opts(&[("token_secret", "mcp_secrets.npl")])).unwrap();
        assert_eq!(
            m.credential,
            Credential::TokenSecret {
                schema: "mcp_secrets".into(),
                table: "npl".into()
            }
        );

        assert!(UserMappingOptions::parse(&opts(&[])).is_err());
        assert!(UserMappingOptions::parse(&opts(&[
            ("token", "abc"),
            ("token_secret", "mcp_secrets.npl"),
        ]))
        .is_err());
        assert!(UserMappingOptions::parse(&opts(&[("bearer", "abc")])).is_err());
    }

    #[pgrx::pg_test]
    fn user_mapping_errors_never_echo_the_token() {
        // SEC-1: a distinctive token value must not survive into any message.
        let err = UserMappingOptions::parse(&opts(&[
            ("token", "SPIKE_CANARY_TOKEN"),
            ("token_secret", "mcp_secrets.npl"),
        ]))
        .unwrap_err();
        assert!(!err.message().contains("SPIKE_CANARY_TOKEN"));

        let err = UserMappingOptions::parse(&opts(&[("token", "   ")])).unwrap_err();
        assert!(!err.message().contains("   "), "no value echo");
    }
}
