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

/// PRD-7 §4.10: catalog cache TTL, overridable per server. `0` disables
/// caching entirely (every statement re-fetches the lists it needs).
pub const DEFAULT_CACHE_TTL_MS: u64 = 60_000;

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
    /// §4.10: catalog cache TTL in milliseconds; `0` disables caching.
    pub cache_ttl_ms: u64,
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
    "cache_ttl_ms",
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

        // §4.10: `0` is meaningful ("no caching"), so the only validation is
        // that it parses as a non-negative integer.
        let cache_ttl_ms = match get("cache_ttl_ms") {
            Some(v) => parse_non_negative_u64(v, "cache_ttl_ms")?,
            None => DEFAULT_CACHE_TTL_MS,
        };

        Ok(ServerOptions {
            url: parsed.to_string(),
            mode,
            timeout_ms,
            auth,
            max_unqualified_reads,
            audit_table,
            cache_ttl_ms,
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

/// Like [`parse_non_negative`] but the option is documented in milliseconds
/// that may legitimately be large; parses as `u64`.
fn parse_non_negative_u64(raw: &str, option: &str) -> McpResult<u64> {
    let n: u64 = raw.trim().parse().map_err(|_| {
        McpError::InvalidOption(format!(
            "invalid value for foreign server option \"{option}\": \"{raw}\" is not an integer"
        ))
    })?;
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
            ("cache_ttl_ms", "5000"),
        ]))
        .unwrap();

        assert_eq!(parsed.mode, Mode::Auto);
        assert_eq!(parsed.timeout_ms, 15_000);
        assert_eq!(parsed.auth, AuthMode::Bearer);
        assert_eq!(parsed.max_unqualified_reads, 0);
        assert_eq!(parsed.audit_table.as_deref(), Some("mcp_audit.tool_calls"));
        assert_eq!(parsed.cache_ttl_ms, 5_000);
    }

    #[pgrx::pg_test]
    fn applies_documented_defaults() {
        let parsed = ServerOptions::parse(&opts(&[("url", "https://x.example/mcp")])).unwrap();
        assert_eq!(parsed.mode, Mode::Auto);
        assert_eq!(parsed.timeout_ms, DEFAULT_TIMEOUT_MS);
        assert_eq!(parsed.auth, AuthMode::Bearer);
        assert_eq!(parsed.max_unqualified_reads, 0);
        assert!(parsed.audit_table.is_none());
        assert_eq!(parsed.cache_ttl_ms, DEFAULT_CACHE_TTL_MS);
    }

    #[pgrx::pg_test]
    fn cache_ttl_zero_disables_and_negatives_are_rejected() {
        // PRD-7 §4.10: 0 disables caching — valid, distinct from the default.
        let parsed = ServerOptions::parse(&opts(&[
            ("url", "https://x.example/mcp"),
            ("cache_ttl_ms", "0"),
        ]))
        .unwrap();
        assert_eq!(parsed.cache_ttl_ms, 0);

        let err = ServerOptions::parse(&opts(&[
            ("url", "https://x.example/mcp"),
            ("cache_ttl_ms", "-1"),
        ]))
        .unwrap_err();
        assert_eq!(err.sqlstate(), "22023");
        assert!(err.message().contains("cache_ttl_ms"));
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

/// Host-side unit tests (no PostgreSQL; `cargo test --lib -- --skip pg_`).
/// Numeric-parsing corners and the loopback/auth decision table, table-driven.
#[cfg(test)]
mod host_tests {
    use super::*;
    use std::net::IpAddr;

    fn opts(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    fn server(pairs: &[(&str, &str)]) -> McpResult<ServerOptions> {
        ServerOptions::parse(&opts(pairs))
    }

    /// `cache_ttl_ms`: 0 is meaningful (no caching), the full u64 range is
    /// legal, and the parse is `u64::from_str` after trimming.
    #[test]
    fn cache_ttl_parsing_edges() {
        for (raw, want) in [
            ("0", 0),
            ("1", 1),
            ("60000", 60_000),
            (u64::MAX.to_string().as_str(), u64::MAX),
            ("  5000  ", 5_000, ),
        ] {
            let parsed = server(&[
                ("url", "https://x.example/mcp"),
                ("cache_ttl_ms", raw),
            ])
            .unwrap_or_else(|e| panic!("{raw:?}: {e:?}"));
            assert_eq!(parsed.cache_ttl_ms, want, "cache_ttl_ms {raw:?}");
        }
        for bad in ["-1", "abc", "1.5", "", "+", "0x10"] {
            assert!(
                server(&[("url", "https://x.example/mcp"), ("cache_ttl_ms", bad)]).is_err(),
                "cache_ttl_ms {bad:?} must be rejected"
            );
        }
        // i64 overflow (9223372036854775808 = 2^63) is still legal u64 space…
        let big = server(&[
            ("url", "https://x.example/mcp"),
            ("cache_ttl_ms", "10000000000000000000"),
        ])
        .unwrap();
        assert_eq!(big.cache_ttl_ms, 10_000_000_000_000_000_000);
    }

    /// `timeout_ms`: inclusive [1, 600_000], trimmed before parsing.
    #[test]
    fn timeout_parsing_edges() {
        for ok in ["1", "600000", " 15 ", "15000"] {
            assert!(
                server(&[("url", "https://x.example/mcp"), ("timeout_ms", ok)]).is_ok(),
                "timeout_ms {ok:?} must be accepted"
            );
        }
        for bad in ["0", "-1", "600001", "abc", "", "1.5", "18446744073709551616"] {
            assert!(
                server(&[("url", "https://x.example/mcp"), ("timeout_ms", bad)]).is_err(),
                "timeout_ms {bad:?} must be rejected"
            );
        }
        let err = server(&[("url", "https://x.example/mcp"), ("timeout_ms", "abc")])
            .unwrap_err();
        assert_eq!(err.sqlstate(), "22023");
        assert!(err.message().contains("timeout_ms"));
        assert!(err.message().contains("abc"), "echoes the bad value: it is not a credential");
    }

    /// `max_unqualified_reads`: any i64 >= 0, including i64::MAX; negatives
    /// and junk rejected.
    #[test]
    fn max_unqualified_reads_edges() {
        let max = server(&[
            ("url", "https://x.example/mcp"),
            ("max_unqualified_reads", &i64::MAX.to_string()),
        ])
        .unwrap();
        assert_eq!(max.max_unqualified_reads, i64::MAX);
        for bad in ["-1", "9223372036854775808", "abc"] {
            assert!(server(&[
                ("url", "https://x.example/mcp"),
                ("max_unqualified_reads", bad),
            ])
            .is_err());
        }
    }

    /// ADR-004's decision table: `auth 'none'` only with a loopback URL; and
    /// independently, plaintext http only with a loopback URL.
    #[test]
    fn loopback_and_scheme_table() {
        // (url, auth) → expected ok
        let table = [
            ("http://127.0.0.1:4000/mcp", "none", true),
            ("http://[::1]:4000/mcp", "none", true),
            ("http://localhost:4000/mcp", "none", true),
            ("https://npl.noizu.com/mcp", "none", false),
            ("http://10.1.2.3:4000/mcp", "none", false),
            ("https://npl.noizu.com/mcp", "bearer", true),
            ("http://127.0.0.1:4000/mcp", "bearer", true),
            ("http://10.1.2.3:4000/mcp", "bearer", false),
            ("http://[fd00::1]:4000/mcp", "bearer", false),
        ];
        for (url, auth, ok) in table {
            let outcome = server(&[("url", url), ("auth", auth)]);
            assert_eq!(outcome.is_ok(), ok, "{url} with auth {auth}");
            if let Err(e) = outcome {
                assert_eq!(e.sqlstate(), "22023");
            }
        }
        // Default is bearer, so a bare loopback http URL is fine and a bare
        // routable http URL is not.
        assert!(server(&[("url", "http://127.0.0.1/mcp")]).is_ok());
        assert!(server(&[("url", "http://example.com/mcp")]).is_err());
    }

    /// `is_loopback` directly: literal IPs decide without DNS; the name
    /// `localhost` short-circuits; an unresolvable name is not loopback.
    #[test]
    fn is_loopback_over_literals_and_names() {
        let u = |s: &str| url::Url::parse(s).unwrap();
        assert!(is_loopback(&u("http://127.0.0.1:1/mcp")));
        assert!(is_loopback(&u("http://127.255.0.7/mcp")));
        assert!(is_loopback(&u("http://[::1]/mcp")));
        assert!(!is_loopback(&u("http://192.168.0.1/mcp")));
        assert!(!is_loopback(&u("http://[fe80::1]/mcp")));
        assert!(is_loopback(&u("http://LOCALHOST/mcp")), "name match is case-insensitive");
        // A domain that cannot resolve (reserved TLD) is never loopback.
        assert!(!is_loopback(&u("http://nonexistent.invalid/mcp")));
    }

    /// Every documented option name is accepted (with a value valid for that
    /// name); the unknown-option error names the offender and lists the valid
    /// set.
    #[test]
    fn option_name_matrix() {
        let valid_value = [
            ("url", "https://x.example/mcp"),
            ("mode", "auto"),
            ("timeout_ms", "15000"),
            ("auth", "bearer"),
            ("max_unqualified_reads", "1"),
            ("audit_table", "mcp_audit.tool_calls"),
            ("cache_ttl_ms", "5000"),
        ];
        for (name, value) in valid_value {
            if name == "url" {
                assert!(server(&[("url", value)]).is_ok());
                continue;
            }
            let parsed = server(&[("url", "https://x.example/mcp"), (name, value)]);
            assert!(parsed.is_ok(), "option {name:?} must be accepted");
        }
        let err = server(&[("url", "https://x.example/mcp"), ("urls", "x")]).unwrap_err();
        assert!(err.message().contains("urls"));
        assert!(err.message().contains("cache_ttl_ms"), "valid set is listed");

        for name in ["token", "token_secret"] {
            assert!(UserMappingOptions::parse(&opts(&[(name, "mcp_s.t")])).is_ok());
        }
        let err = UserMappingOptions::parse(&opts(&[("tokens", "x")])).unwrap_err();
        assert!(err.message().contains("tokens"));
    }

    /// `token_secret` / `audit_table` identifier-pair shapes.
    #[test]
    fn qualified_name_shapes() {
        for ok in ["mcp_secrets.npl", "a.b", "_x.y$1"] {
            let parsed = UserMappingOptions::parse(&opts(&[("token_secret", ok)])).unwrap();
            match parsed.credential {
                Credential::TokenSecret { schema, table } => {
                    assert!(!schema.is_empty() && !table.is_empty(), "{ok:?}");
                }
                other => panic!("{ok:?} → {other:?}"),
            }
        }
        for bad in [
            "npl", "a.b.c", ".b", "a.", "9a.b", "a.9b", "a b.c", "a. b", "a .b", "@.b", "a.b c",
        ] {
            assert!(
                UserMappingOptions::parse(&opts(&[("token_secret", bad)])).is_err(),
                "token_secret {bad:?} must be rejected"
            );
        }
        // A 64-character identifier half is rejected (NAMEDATALEN rule).
        let long = format!("{}.t", "s".repeat(64));
        assert!(UserMappingOptions::parse(&opts(&[("token_secret", &long)])).is_err());
        let long_table = format!("s.{}", "t".repeat(64));
        assert!(UserMappingOptions::parse(&opts(&[("token_secret", &long_table)])).is_err());
        // audit_table goes through the same shape check.
        assert!(server(&[("url", "https://x.example/mcp"), ("audit_table", "a.b")]).is_ok());
        assert!(server(&[("url", "https://x.example/mcp"), ("audit_table", "a")]).is_err());
    }

    /// SEC-1 across the whole surface: a canary credential never reaches any
    /// message, whatever else goes wrong with the options.
    #[test]
    fn no_error_path_echoes_the_credential() {
        let canary = "SPIKE_CANARY_TOKEN_9f8e7d";
        for bad in [
            vec![("token", canary), ("token_secret", "a.b")],
            vec![("token", "   ")],
            vec![("token", canary), ("unknown", "x")],
        ] {
            let err = UserMappingOptions::parse(&opts(&bad)).unwrap_err();
            assert!(!err.message().contains(canary), "{:?} leaked", err.message());
        }
        // And the URL/option values are echoed only where they are not
        // credentials: a malformed URL is echoed, a bad mode is echoed.
        let err = server(&[("url", "https://x.example/mcp"), ("mode", "fast")]).unwrap_err();
        assert!(err.message().contains("fast"));
        let err = server(&[("url", "ht!tp://x")]).unwrap_err();
        assert!(err.message().contains("ht!tp://x"));
    }

    /// The URL is re-serialized canonically; mode defaults and parses.
    #[test]
    fn url_normalization_and_mode_matrix() {
        let parsed = server(&[("url", "HTTPS://x.example/mcp")]).unwrap();
        // The scheme is matched case-insensitively and re-emitted lowercase.
        assert!(parsed.url.starts_with("https://"), "{}", parsed.url);

        for (raw, want) in [
            ("auto", Mode::Auto),
            ("generic", Mode::Generic),
            ("sql", Mode::Sql),
        ] {
            assert_eq!(
                server(&[("url", "https://x.example/mcp"), ("mode", raw)])
                    .unwrap()
                    .mode,
                want
            );
        }
        // Path, query and fragment survive normalization.
        let parsed = server(&[("url", "https://x.example:8443/mcp?x=1#f")]).unwrap();
        assert_eq!(parsed.url, "https://x.example:8443/mcp?x=1#f");
    }

    /// A relative URL, a missing host, and a wrong scheme all fail with the
    /// url error class; fragments of the reason land in the message.
    #[test]
    fn malformed_urls_name_the_problem() {
        for bad in ["/mcp", "ftp://x.example", "x.example/mcp", "http://", ""] {
            let err = server(&[("url", bad)]).unwrap_err();
            assert_eq!(err.sqlstate(), "22023", "{bad:?}");
            assert!(err.message().contains("url"), "{bad:?}: {:?}", err.message());
        }
        // A URL with an empty host but a scheme ("http:///mcp") is rejected.
        assert!(server(&[("url", "http:///mcp")]).is_err());
        // Sanity: the IpAddr import is load-bearing for the loopback check.
        let _ip: IpAddr = "127.0.0.1".parse().unwrap();
    }
}
