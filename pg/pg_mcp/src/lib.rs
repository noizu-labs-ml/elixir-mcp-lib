//! `pg_mcp` — call Model Context Protocol servers from SQL.
//!
//! PRD-6 scope: the extension skeleton, a blocking Streamable HTTP JSON-RPC
//! client, `USER MAPPING` credential sourcing, option validators and the
//! `mcp.*` function surface. PRD-7 adds the FDW: the foreign-table registry
//! (`tables`), the `FdwRoutine` plumbing (`fdw`), quals, the ten catalog /
//! read-through / invocation tables (tracks A-C), the §4.10 catalog cache,
//! `IMPORT FOREIGN SCHEMA` + `mcp.import/3` (track D), and the integration
//! battery (`e2e`, track E).
//!
//! ## ADR deviation (recorded, not silent)
//!
//! ADR-002 specifies `supabase-wrappers` 0.1.28 used as a library alongside
//! pgrx 0.19. That combination does not exist: `supabase-wrappers` 0.1.28 pins
//! `pgrx = "=0.16.1"` exactly and depends on tokio, which contradicts ADR-002's
//! own "pgrx 0.19" and "no tokio runtime inside the backend" clauses, and 0.16.1
//! predates PostgreSQL 18 support. PRD-6's scope (SQL functions, HTTP client,
//! option validators — no FDW trait implementation) needs none of the crate's
//! scaffolding, so it is built on plain pgrx. See `pg/README.md`.

use pgrx::prelude::*;

::pgrx::pg_module_magic!(name, version);

/// Backend load: register the session-cache exit hook (PRD-6 §4.4).
#[pg_guard]
extern "C-unwind" fn _PG_init() {
    session::register_exit_hook();
}

pub mod api;
pub mod cache;
pub mod client;
pub mod codegen;
#[cfg(any(test, feature = "pg_test"))]
mod e2e;
pub mod errors;
pub mod fdw;
pub mod import;
pub mod options;
pub mod quals;
pub mod session;
pub mod sse;
pub mod tables;

// The `mcp` schema is created before anything is placed in it. `#[pg_schema] mod
// mcp` in api.rs emits `CREATE SCHEMA mcp` itself, but the FDW SQL below is
// hand-written and must be ordered after it.
extension_sql!(
    r#"
-- This hand-written block is emitted before pgrx's `#[pg_schema]` statements,
-- so the schema must exist before the FDW function below lands in it. The
-- later `CREATE SCHEMA IF NOT EXISTS mcp` from the schema modules then skips
-- cleanly (an object the extension already owns).
CREATE SCHEMA IF NOT EXISTS mcp;

-- FR-6.3: register the mcp_fdw foreign-data wrapper so CREATE SERVER and
-- CREATE USER MAPPING run their option validators. The handler's scan/modify
-- routines landed with PRD-7.
--
-- The validator's Rust body is `api::mcp_fdw_validator` (`#[pg_extern]`); its
-- CREATE FUNCTION is written here because `CREATE FOREIGN DATA WRAPPER` below
-- needs it before pgrx emits the schema modules. pgrx later re-emits the same
-- signature as CREATE OR REPLACE FUNCTION, which is a no-op here.
CREATE FUNCTION mcp.mcp_fdw_validator(text[], oid)
  RETURNS void
  AS 'MODULE_PATHNAME', 'mcp_fdw_validator_wrapper'
  LANGUAGE C;

CREATE FUNCTION mcp.mcp_fdw_handler()
  RETURNS fdw_handler
  AS 'MODULE_PATHNAME', 'mcp_fdw_handler'
  LANGUAGE C STRICT;

CREATE FOREIGN DATA WRAPPER mcp_fdw
  HANDLER mcp.mcp_fdw_handler
  VALIDATOR mcp.mcp_fdw_validator;

COMMENT ON FOREIGN DATA WRAPPER mcp_fdw IS
  'Model Context Protocol servers as Postgres foreign servers (pg_mcp)';

-- PRD-8 section 4.6: the per-tool generation bookkeeping. Names and
-- provenance only (AP-P7) -- never a copy of a tool schema; regeneration
-- always re-reads from the server. Lives in this hand-written block because
-- it must follow the CREATE SCHEMA mcp above, and extension_sql blocks
-- cannot depend on each other's ordering. The same DDL is mirrored in the
-- hand-written pg_mcp--0.2.0--0.3.0.sql upgrade script; the shape's single
-- source is codegen::registry::CREATE_TABLE_SQL.
CREATE TABLE mcp.generated (
  server text NOT NULL,
  schema text NOT NULL,
  kind text NOT NULL,
  name text NOT NULL,
  tool text NOT NULL,
  generated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (schema, name)
);

COMMENT ON TABLE mcp.generated IS
  'Per-tool generation bookkeeping (PRD-8 section 4.6): names and provenance of the SQL objects pg_mcp created from MCP tool definitions. Never a copy of a tool schema - regeneration always re-reads from the server.';
"#,
    name = "mcp_fdw",
    requires = [api::mcp_fdw_validator],
);

/// Crate version, so `SELECT mcp.version()` matches `clientInfo.version` on the
/// wire.
#[pg_schema]
mod mcp {
    use super::*;

    #[pg_extern(immutable, parallel_safe, strict)]
    fn version() -> &'static str {
        crate::client::CLIENT_VERSION
    }

    /// The newest MCP protocol version this extension knows.
    #[pg_extern(immutable, parallel_safe, strict)]
    fn protocol_version() -> &'static str {
        crate::client::CLIENT_PROTOCOL_VERSION
    }
}

#[cfg(test)]
#[pg_schema]
mod tests {
    use pgrx::prelude::*;

    #[pg_test]
    fn extension_installs_into_schema_mcp() {
        // FR-6.2: the functions land in `mcp`, not `public`.
        let count = Spi::get_one::<i64>(
            "SELECT count(*) FROM pg_proc p
               JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'mcp' AND p.proname = 'call_tool'",
        )
        .unwrap();
        assert_eq!(count, Some(1));
    }

    #[pg_test]
    fn the_seven_prd_functions_exist_with_the_stated_volatility() {
        // FR-6.10 / §4.6. provolatile 'v' = VOLATILE, proparallel 'u' = UNSAFE.
        for name in [
            "call_tool",
            "call_tool_text",
            "get_prompt",
            "read_resource",
            "complete",
            "refresh",
            "import",
        ] {
            let row = Spi::get_two::<String, String>(&format!(
                "SELECT p.provolatile::text, p.proparallel::text
                   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'mcp' AND p.proname = '{name}'"
            ))
            .unwrap();
            assert_eq!(
                row,
                (Some("v".to_string()), Some("u".to_string())),
                "{name} must be VOLATILE PARALLEL UNSAFE"
            );
        }
    }

    #[pg_test]
    fn the_mcp_fdw_wrapper_is_registered_with_both_routines() {
        let found = Spi::get_one::<i64>(
            "SELECT count(*) FROM pg_foreign_data_wrapper
              WHERE fdwname = 'mcp_fdw' AND fdwhandler <> 0 AND fdwvalidator <> 0",
        )
        .unwrap();
        assert_eq!(found, Some(1));
    }

    #[pg_test]
    fn create_server_accepts_a_valid_option_set() {
        Spi::run(
            "CREATE SERVER ok_srv FOREIGN DATA WRAPPER mcp_fdw
               OPTIONS (url 'https://npl.noizu.com/mcp', mode 'generic',
                        timeout_ms '5000', auth 'bearer',
                        max_unqualified_reads '10',
                        audit_table 'mcp_audit.tool_calls')",
        )
        .unwrap();
        let n =
            Spi::get_one::<i64>("SELECT count(*) FROM pg_foreign_server WHERE srvname='ok_srv'")
                .unwrap();
        assert_eq!(n, Some(1));
    }

    #[pg_test]
    fn create_server_rejects_a_bad_timeout_with_22023() {
        let err = Spi::run(
            "CREATE SERVER bad_srv FOREIGN DATA WRAPPER mcp_fdw
               OPTIONS (url 'https://x.example/mcp', timeout_ms '0')",
        )
        .unwrap_err();
        assert!(format!("{err:?}").contains("timeout_ms"), "{err:?}");
    }

    #[pg_test]
    fn create_server_rejects_auth_none_off_loopback() {
        let err = Spi::run(
            "CREATE SERVER remote_none FOREIGN DATA WRAPPER mcp_fdw
               OPTIONS (url 'https://npl.noizu.com/mcp', auth 'none')",
        )
        .unwrap_err();
        assert!(format!("{err:?}").contains("loopback"), "{err:?}");
    }

    #[pg_test]
    fn create_server_accepts_auth_none_on_loopback() {
        Spi::run(
            "CREATE SERVER local_none FOREIGN DATA WRAPPER mcp_fdw
               OPTIONS (url 'http://127.0.0.1:4001/mcp', auth 'none')",
        )
        .unwrap();
    }

    #[pg_test]
    fn create_user_mapping_rejects_both_credentials() {
        Spi::run(
            "CREATE SERVER um_srv FOREIGN DATA WRAPPER mcp_fdw
               OPTIONS (url 'https://x.example/mcp')",
        )
        .unwrap();
        let err = Spi::run(
            "CREATE USER MAPPING FOR CURRENT_USER SERVER um_srv
               OPTIONS (token 'SPIKE_CANARY_TOKEN', token_secret 'a.b')",
        )
        .unwrap_err();
        let rendered = format!("{err:?}");
        assert!(rendered.contains("mutually exclusive"), "{rendered}");
        // SEC-1: the credential must not survive into the error.
        assert!(!rendered.contains("SPIKE_CANARY_TOKEN"), "{rendered}");
    }

    #[pg_test]
    fn unknown_server_name_raises_42704_from_every_entry_point() {
        for stmt in [
            "SELECT mcp.call_tool('nope','echo')",
            "SELECT mcp.call_tool_text('nope','echo')",
            "SELECT mcp.get_prompt('nope','p')",
            "SELECT mcp.read_resource('nope','x://y')",
            "SELECT mcp.complete('nope','{}'::jsonb,'a','b')",
            "SELECT mcp.refresh('nope')",
        ] {
            let err = Spi::run(stmt).unwrap_err();
            assert!(
                format!("{err:?}").contains("does not exist"),
                "{stmt}: {err:?}"
            );
        }
    }

    #[pg_test]
    fn import_creates_the_catalog_from_sql() {
        // PRD-7 §4.11: the FR-6.10 stub is gone — mcp.import projects the
        // registry over SPI and returns the count created. No network I/O is
        // involved until `all_upstreams 'true'` asks the engine for its tools.
        Spi::run(
            "CREATE SERVER imp_srv FOREIGN DATA WRAPPER mcp_fdw
               OPTIONS (url 'https://x.example/mcp')",
        )
        .unwrap();
        Spi::run("CREATE SCHEMA imp_s").unwrap();
        let n = Spi::get_one::<i32>("SELECT mcp.import('imp_srv','imp_s')").unwrap();
        assert_eq!(n, Some(10));
    }

    #[pg_test]
    fn missing_user_mapping_under_bearer_raises_28000() {
        // FR-6.8: and no request is sent — the URL below is unroutable, so a
        // transport error would surface as 08006 instead if we did send one.
        Spi::run(
            "CREATE SERVER nomap_srv FOREIGN DATA WRAPPER mcp_fdw
               OPTIONS (url 'https://192.0.2.1/mcp', timeout_ms '1000')",
        )
        .unwrap();
        let err = Spi::run("SELECT mcp.call_tool('nomap_srv','echo')").unwrap_err();
        assert!(format!("{err:?}").contains("USER MAPPING"), "{err:?}");
    }

    #[pg_test]
    fn on_error_rejects_any_other_value() {
        Spi::run(
            "CREATE SERVER oe_srv FOREIGN DATA WRAPPER mcp_fdw
               OPTIONS (url 'http://127.0.0.1:4002/mcp', auth 'none')",
        )
        .unwrap();
        let err =
            Spi::run("SELECT mcp.call_tool('oe_srv','echo','{}'::jsonb,'explode')").unwrap_err();
        assert!(format!("{err:?}").contains("on_error"), "{err:?}");
    }

    #[pg_test]
    fn version_functions_report_the_pinned_values() {
        assert_eq!(
            Spi::get_one::<String>("SELECT mcp.version()").unwrap(),
            Some("0.3.0".to_string())
        );
        assert_eq!(
            Spi::get_one::<String>("SELECT mcp.protocol_version()").unwrap(),
            Some("2025-11-25".to_string())
        );
    }

    #[pg_test]
    fn a_server_and_mapping_round_trip_through_the_validator() {
        // AC-6.8 in miniature: re-running the DDL a dump would emit must pass
        // validation a second time.
        Spi::run(
            "CREATE SERVER dump_srv FOREIGN DATA WRAPPER mcp_fdw
               OPTIONS (url 'https://npl.noizu.com/mcp', mode 'sql', timeout_ms '30000')",
        )
        .unwrap();
        Spi::run(
            "CREATE USER MAPPING FOR CURRENT_USER SERVER dump_srv
               OPTIONS (token_secret 'mcp_secrets.npl')",
        )
        .unwrap();

        let opts = Spi::get_one::<Vec<Option<String>>>(
            "SELECT srvoptions FROM pg_foreign_server WHERE srvname = 'dump_srv'",
        )
        .unwrap()
        .unwrap();
        assert!(opts.iter().flatten().any(|o| o.starts_with("url=")));

        // ALTER re-runs the validator over the merged set.
        Spi::run("ALTER SERVER dump_srv OPTIONS (SET timeout_ms '45000')").unwrap();
        let err = Spi::run("ALTER SERVER dump_srv OPTIONS (SET timeout_ms '999999')").unwrap_err();
        assert!(format!("{err:?}").contains("timeout_ms"), "{err:?}");
    }
}

/// Required by `cargo pgrx test`.
#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}

    pub fn postgresql_conf_options() -> Vec<&'static str> {
        vec![]
    }
}
