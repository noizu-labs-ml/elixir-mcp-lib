//! `mcp.generated` — the extension-owned generation bookkeeping table
//! (PRD-8 §4.6, checklist 8.6) and the drop-before-recreate cycle.
//!
//! One row per generated object:
//!
//! ```sql
//! CREATE TABLE mcp.generated (
//!   server       text        NOT NULL,  -- the foreign server's catalog name
//!   schema       text        NOT NULL,  -- schema the object was created in
//!   kind         text        NOT NULL,  -- 'table' | 'function' | 'view'
//!   name         text        NOT NULL,  -- SQL object name (unquoted spelling)
//!   tool         text        NOT NULL,  -- the original MCP tool name
//!   generated_at timestamptz NOT NULL DEFAULT now(),
//!   PRIMARY KEY (schema, name)
//! );
//! ```
//!
//! AP-P7 discipline: this table records *names and provenance only* — never
//! a tool's schema. Regeneration always re-reads from the server (D1); the
//! one lookup this module does against the system catalog (a generated
//! function's identity arguments, at drop time) reads the live definition,
//! never a stored copy.
//!
//! Drops run `RESTRICT` (§4.6): a user object depending on a generated table
//! blocks the drop with a clear error instead of cascading, and because
//! generation runs in the caller's transaction the statement aborts whole —
//! nothing is left half-dropped (AC-8.11).

use crate::errors::{McpError, McpResult};
use pgrx::prelude::Spi;

/// Fully-qualified name of the bookkeeping table.
pub const GENERATED_TABLE: &str = "mcp.generated";

/// The `kind` column's values.
pub const KIND_TABLE: &str = "table";
pub const KIND_FUNCTION: &str = "function";
pub const KIND_VIEW: &str = "view";

/// The CREATE TABLE for the bookkeeping table — emitted by the extension SQL
/// (fresh installs) and by the `0.2.0--0.3.0` upgrade script. Kept here as
/// the single source of the shape.
pub const CREATE_TABLE_SQL: &str = "CREATE TABLE mcp.generated (\n  \
    server text NOT NULL,\n  \
    schema text NOT NULL,\n  \
    kind text NOT NULL,\n  \
    name text NOT NULL,\n  \
    tool text NOT NULL,\n  \
    generated_at timestamptz NOT NULL DEFAULT now(),\n  \
    PRIMARY KEY (schema, name)\n);";

/// One owned object row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OwnedObject {
    pub kind: String,
    pub name: String,
    pub schema: String,
    pub tool: String,
}

/// Read the objects this extension owns for `server` in `schema`, oldest
/// first (generation order — callers drop in reverse).
pub fn owned(server: &str, schema: &str) -> McpResult<Vec<OwnedObject>> {
    let sql = format!(
        "SELECT kind, name, schema, tool FROM {GENERATED_TABLE} \
         WHERE server = {server} AND schema = {schema} \
         ORDER BY generated_at, name",
        server = super::table::quote_literal(server),
        schema = super::table::quote_literal(schema),
    );
    Spi::connect(|client| {
        let table = client
            .select(sql.as_str(), None, &[])
            .map_err(|e| McpError::Internal(format!("mcp.generated lookup failed: {e}")))?;
        let mut out = Vec::with_capacity(table.len());
        for row in table {
            out.push(OwnedObject {
                kind: row
                    .get_by_name::<String, _>("kind")
                    .unwrap_or(None)
                    .unwrap_or_default(),
                name: row
                    .get_by_name::<String, _>("name")
                    .unwrap_or(None)
                    .unwrap_or_default(),
                schema: row
                    .get_by_name::<String, _>("schema")
                    .unwrap_or(None)
                    .unwrap_or_default(),
                tool: row
                    .get_by_name::<String, _>("tool")
                    .unwrap_or(None)
                    .unwrap_or_default(),
            });
        }
        Ok(out)
    })
}

/// The schemas that hold objects generated from `server`, sorted.
pub fn schemas_for(server: &str) -> McpResult<Vec<String>> {
    let sql = format!(
        "SELECT DISTINCT schema FROM {GENERATED_TABLE} WHERE server = {}",
        super::table::quote_literal(server)
    );
    Spi::connect(|client| {
        let table = client
            .select(sql.as_str(), None, &[])
            .map_err(|e| McpError::Internal(format!("mcp.generated lookup failed: {e}")))?;
        let mut out: Vec<String> = Vec::new();
        for row in table {
            if let Some(s) = row
                .get_by_name::<String, _>("schema")
                .unwrap_or(None)
            {
                out.push(s);
            }
        }
        out.sort();
        out.dedup();
        Ok(out)
    })
}

/// Record one generated object.
pub fn record(server: &str, object: &OwnedObject) -> McpResult<()> {
    let sql = format!(
        "INSERT INTO {GENERATED_TABLE} (server, schema, kind, name, tool, generated_at) \
         VALUES ({}, {}, {}, {}, {}, now()) \
         ON CONFLICT (schema, name) DO UPDATE \
         SET server = EXCLUDED.server, kind = EXCLUDED.kind, tool = EXCLUDED.tool, \
             generated_at = now()",
        super::table::quote_literal(server),
        super::table::quote_literal(&object.schema),
        super::table::quote_literal(&object.kind),
        super::table::quote_literal(&object.name),
        super::table::quote_literal(&object.tool),
    );
    Spi::run(&sql).map_err(|e| McpError::Internal(format!("mcp.generated write failed: {e}")))
}

/// Remove the bookkeeping rows for objects this extension owns for `server`
/// in `schema` (called after their drops succeeded).
pub fn clear(server: &str, schema: &str) -> McpResult<()> {
    let sql = format!(
        "DELETE FROM {GENERATED_TABLE} WHERE server = {a} AND schema = {b}",
        a = super::table::quote_literal(server),
        b = super::table::quote_literal(schema),
    );
    Spi::run(&sql).map_err(|e| McpError::Internal(format!("mcp.generated delete failed: {e}")))
}

/// A generated object's drop statement. Functions need their identity
/// argument types, which are re-derived from the catalog at drop time —
/// never from a stored copy (AP-P7).
pub fn drop_statement(object: &OwnedObject) -> McpResult<String> {
    let schema = super::table::quote_ident(&object.schema);
    let name = super::table::quote_ident(&object.name);
    match object.kind.as_str() {
        KIND_VIEW => Ok(format!("DROP VIEW {schema}.{name} RESTRICT;")),
        KIND_TABLE => Ok(format!("DROP FOREIGN TABLE {schema}.{name} RESTRICT;")),
        KIND_FUNCTION => {
            // Scalar-subquery form: exactly one row even when the function
            // is gone (Spi::get_one errors on zero-row results), which the
            // caller's DROP then reports honestly as 42883.
            let identity = format!(
                "SELECT (SELECT pg_get_function_identity_arguments(p.oid) \
                   FROM pg_proc p \
                   JOIN pg_namespace n ON n.oid = p.pronamespace \
                  WHERE n.nspname = {schema_lit} AND p.proname = {name_lit})",
                schema_lit = super::table::quote_literal(&object.schema),
                name_lit = super::table::quote_literal(&object.name),
            );
            let args: Option<String> = Spi::get_one(&identity)
                .map_err(|e| McpError::Internal(format!("function lookup failed: {e}")))?;
            let args = args.unwrap_or_default();
            Ok(format!("DROP FUNCTION {schema}.{name}({args}) RESTRICT;"))
        }
        other => Err(McpError::Internal(format!(
            "mcp.generated holds unknown kind \"{other}\" for {}.{}",
            object.schema, object.name
        ))),
    }
}

/// Drop every object the extension owns for `server` in `schema`, in reverse
/// generation order (views, then functions, then tables), and clear the
/// bookkeeping rows. A `RESTRICT` violation propagates (AC-8.11).
pub fn drop_owned(server: &str, schema: &str) -> McpResult<usize> {
    let owned = owned(server, schema)?;
    let mut dropped = 0;
    for object in owned.iter().rev() {
        let sql = drop_statement(object)?;
        Spi::run(&sql).map_err(|e| {
            McpError::Internal(format!(
                "drop of {}.{} failed: {e}",
                object.schema, object.name
            ))
        })?;
        dropped += 1;
    }
    clear(server, schema)?;
    Ok(dropped)
}

#[cfg(any(test, feature = "pg_test"))]
#[pgrx::pg_schema]
mod tests {
    use super::*;

    /// AP-P7: the bookkeeping table records names and provenance only — the
    /// CREATE TABLE it ships with has no schema-carrying column.
    #[pgrx::pg_test]
    fn the_bookkeeping_shape_holds_names_and_provenance_only() {
        for column in ["server", "schema", "kind", "name", "tool", "generated_at"] {
            assert!(CREATE_TABLE_SQL.contains(column), "missing {column}");
        }
        assert!(CREATE_TABLE_SQL.contains("PRIMARY KEY (schema, name)"));
        // No jsonb anywhere: no tool schema copies live here.
        assert!(!CREATE_TABLE_SQL.contains("jsonb"));
    }

    /// The drop-statement builder over every kind.
    #[pgrx::pg_test]
    fn drop_statements_are_restrict_per_kind() {
        let owned = |kind: &str| OwnedObject {
            kind: kind.to_string(),
            name: "tool_x".to_string(),
            schema: "s".to_string(),
            tool: "x".to_string(),
        };
        assert_eq!(
            drop_statement(&owned(KIND_TABLE)).unwrap(),
            "DROP FOREIGN TABLE \"s\".\"tool_x\" RESTRICT;"
        );
        assert_eq!(
            drop_statement(&owned(KIND_VIEW)).unwrap(),
            "DROP VIEW \"s\".\"tool_x\" RESTRICT;"
        );
        // Functions resolve their argument types from the live catalog; an
        // unknown function yields an empty identity list, which still names
        // the object in the DROP (and cannot silently no-op — the lookup's
        // absence surfaces as `()` types, and the caller's DROP raises 42883
        // if the object truly is gone, which regeneration treats as the
        // ordinary end state).
        let stmt = drop_statement(&owned(KIND_FUNCTION)).unwrap();
        assert_eq!(stmt, "DROP FUNCTION \"s\".\"tool_x\"() RESTRICT;");
        let err = drop_statement(&owned("index")).unwrap_err();
        assert!(err.message().contains("unknown kind"));
    }

    /// Round-trip through the real bookkeeping table (created by the
    /// extension SQL), then drop via `drop_owned`.
    #[pgrx::pg_test]
    fn record_lookup_and_drop_owned_round_trip() {
        // The extension SQL creates the table on fresh installs; only an
        // environment that somehow lacks it needs the DDL here.
        let exists: Option<bool> =
            Spi::get_one("SELECT to_regclass('mcp.generated') IS NOT NULL").unwrap();
        if exists != Some(true) {
            Spi::run(CREATE_TABLE_SQL).unwrap();
        }
        Spi::run("CREATE SCHEMA IF NOT EXISTS gen_round").unwrap();

        let a = OwnedObject {
            kind: KIND_TABLE.to_string(),
            name: "tool_gen_a".to_string(),
            schema: "gen_round".to_string(),
            tool: "a".to_string(),
        };
        let b = OwnedObject {
            kind: KIND_FUNCTION.to_string(),
            name: "gen_a".to_string(),
            schema: "gen_round".to_string(),
            tool: "a".to_string(),
        };
        record("gen_srv", &a).unwrap();
        record("gen_srv", &b).unwrap();
        record("other_srv", &OwnedObject {
            kind: KIND_TABLE.to_string(),
            name: "tool_gen_b".to_string(),
            schema: "gen_round".to_string(),
            tool: "b".to_string(),
        })
        .unwrap();

        let mine = owned("gen_srv", "gen_round").unwrap();
        assert_eq!(mine.len(), 2);
        assert_eq!(mine[0].name, "gen_a");
        assert_eq!(mine[1].tool, "a");

        assert_eq!(schemas_for("gen_srv").unwrap(), vec!["gen_round".to_string()]);

        // The recorded foreign table was never created by this probe (a
        // probe cannot create a foreign table without a server); take its
        // row out of scope so drop_owned exercises only the function drop.
        Spi::run("DELETE FROM mcp.generated WHERE name = 'tool_gen_a'").unwrap();
        // Drop the function for real so drop_owned's DROP succeeds.
        Spi::run("CREATE FUNCTION gen_round.gen_a() RETURNS int LANGUAGE sql AS 'SELECT 1'")
            .unwrap();
        assert_eq!(drop_owned("gen_srv", "gen_round").unwrap(), 1);
        assert!(owned("gen_srv", "gen_round").unwrap().is_empty());
        // The other server's row survives (drop scope is per server+schema).
        assert_eq!(owned("other_srv", "gen_round").unwrap().len(), 1);
        // The dropped function is actually gone.
        let gone: Option<i64> = Spi::get_one(
            "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace \
             WHERE n.nspname = 'gen_round' AND p.proname = 'gen_a'",
        )
        .unwrap();
        assert_eq!(gone, Some(0));
    }
}
