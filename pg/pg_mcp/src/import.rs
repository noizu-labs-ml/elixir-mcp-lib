//! **Track D owns this file** (PRD-7 §6 step 7.9): `IMPORT FOREIGN SCHEMA`
//! support and the PRD-8 import options.
//!
//! Three builders share one DDL projection from the `tables/mod.rs` registry:
//!
//! * [`statements`] — the plain `IMPORT FOREIGN SCHEMA` layout (what `fdw.rs`'s
//!   `import_foreign_schema` callback returns): every registry table into one
//!   local schema, honoring `LIMIT TO` / `EXCEPT`. Re-running the import fails
//!   on existing names in the ordinary Postgres way (§4.11): the statements
//!   are emitted verbatim, no `IF NOT EXISTS`, no `DROP`.
//! * [`statements_with`] — the same layout plus the per-table OPTIONS the
//!   import options stamp on every created foreign table (`cache_ttl_ms`).
//! * [`engine_statements`] — the `all_upstreams 'true'` engine layout
//!   (ADR-007 / FR-7.19): one `CREATE SCHEMA` per enabled upstream holding
//!   that upstream's slice of the catalog (names un-prefixed within its
//!   schema), plus the engine's own ten tables in the target schema with the
//!   federated ones marked engine-local.
//!
//! The upstream slice is carried in each foreign table's OPTIONS (`upstream`
//! option): the FDW read path reads the option off `pg_foreign_table` and
//! scopes its list/read-through calls to that upstream, stripping the
//! `<upstream>.` prefix from names. `''` marks the engine-local slice (tools
//! with no `<upstream>.` prefix); an absent option is the unfiltered union —
//! exactly what a default import produces. This is the cross-track contract
//! with the catalog/read-through handlers (`tables/catalog.rs`,
//! `tables/readthrough.rs`): they honour the option, this file only emits it.
//!
//! No `pg_sys` here: `fdw.rs` decodes the `ImportForeignSchemaStmt` and hands
//! us plain strings, and `api.rs`'s `mcp.import` executes what we build.

use crate::codegen;
use crate::errors::{McpError, McpResult};
use crate::tables::{self, Source};
use serde_json::Value;

/// Foreign-table option scoping a table to one engine upstream's slice. The
/// empty string is the engine-local slice (names carry no `<upstream>.`
/// prefix); an absent option is the unfiltered union (default import).
pub const TABLE_OPTION_UPSTREAM: &str = "upstream";

/// Foreign-table option overriding the §4.10 catalog cache TTL for one table.
pub const TABLE_OPTION_CACHE_TTL_MS: &str = "cache_ttl_ms";

/// Import options (PRD-7 §4.11: `cache_ttl_ms`, `all_upstreams`; PRD-8 §4.6:
/// `per_tool`, `invoke_on_select`, `prefix`, `per_upstream_schema`).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ImportOptions {
    /// Stamp `cache_ttl_ms '<n>'` into every created foreign table's OPTIONS.
    pub cache_ttl_ms: Option<u64>,
    /// Engine layout: one schema per enabled upstream (FR-7.19). Default
    /// `false`: one schema, fully-qualified `<upstream>.<tool>` names, nothing
    /// created implicitly.
    pub all_upstreams: bool,
    /// PRD-8: generate the per-tool objects (§4.2-§4.4) alongside the ten
    /// generic tables. Default `false` (PRD-7 §8 compat: an existing IMPORT
    /// re-run produces the same result as before).
    pub per_tool: bool,
    /// PRD-8 §4.2's invocation gate. Default `read_only` (ADR-003).
    pub invoke_on_select: codegen::InvokeOnSelect,
    /// PRD-8 §4.5 rule 6: identifier fragment prepended to derived
    /// table/function/view names.
    pub prefix: String,
    /// PRD-8 FR-8.17: against an engine, generate each upstream's objects
    /// into its own schema, stripping the `<upstream>.` prefix.
    pub per_upstream_schema: bool,
}

impl ImportOptions {
    /// Parse the `mcp.import/3` jsonb options argument. `null` and `{}`
    /// produce the defaults.
    pub fn parse(value: &Value) -> McpResult<ImportOptions> {
        let obj = match value {
            Value::Null => return Ok(ImportOptions::default()),
            Value::Object(map) => map,
            other => {
                return Err(McpError::InvalidOption(format!(
                    "mcp.import options must be a jsonb object, got: {other}"
                )))
            }
        };

        let mut opts = ImportOptions::default();
        for (key, val) in obj {
            match key.as_str() {
                "cache_ttl_ms" => {
                    let n = val
                        .as_u64()
                        .or_else(|| val.as_str().and_then(|s| s.trim().parse::<u64>().ok()));
                    opts.cache_ttl_ms = Some(n.ok_or_else(|| {
                        McpError::InvalidOption(format!(
                            "invalid value for import option \"cache_ttl_ms\": {val} is not a non-negative integer"
                        ))
                    })?);
                }
                "all_upstreams" => {
                    opts.all_upstreams = val.as_bool().ok_or_else(|| {
                        McpError::InvalidOption(format!(
                            "invalid value for import option \"all_upstreams\": {val} is not true or false"
                        ))
                    })?;
                }
                "per_tool" => {
                    opts.per_tool = val.as_bool().ok_or_else(|| {
                        McpError::InvalidOption(format!(
                            "invalid value for import option \"per_tool\": {val} is not true or false"
                        ))
                    })?;
                }
                "invoke_on_select" => {
                    let raw = val.as_str().ok_or_else(|| {
                        McpError::InvalidOption(format!(
                            "invalid value for import option \"invoke_on_select\": {val} is not a string"
                        ))
                    })?;
                    opts.invoke_on_select = codegen::InvokeOnSelect::parse(raw)?;
                }
                "prefix" => {
                    let raw = val.as_str().ok_or_else(|| {
                        McpError::InvalidOption(format!(
                            "invalid value for import option \"prefix\": {val} is not a string"
                        ))
                    })?;
                    opts.prefix = validate_prefix(raw)?;
                }
                "per_upstream_schema" => {
                    opts.per_upstream_schema = val.as_bool().ok_or_else(|| {
                        McpError::InvalidOption(format!(
                            "invalid value for import option \"per_upstream_schema\": {val} is not true or false"
                        ))
                    })?;
                }
                other => {
                    return Err(McpError::InvalidOption(format!(
                        "unknown import option \"{other}\" (valid options: all_upstreams, cache_ttl_ms, \
                         per_tool, invoke_on_select, prefix, per_upstream_schema)"
                    )));
                }
            }
        }
        Ok(opts)
    }

    /// The OPTIONS clause contents stamped onto every created foreign table.
    pub fn table_options(&self) -> Vec<(String, String)> {
        match self.cache_ttl_ms {
            Some(ttl) => vec![(TABLE_OPTION_CACHE_TTL_MS.to_string(), ttl.to_string())],
            None => Vec::new(),
        }
    }
}

/// §4.5 rule 6: the prefix must be an identifier fragment — only the
/// characters the derivation rules could emit. Empty is the default.
fn validate_prefix(raw: &str) -> McpResult<String> {
    if raw
        .bytes()
        .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
        && !raw.bytes().next().is_some_and(|b| b.is_ascii_digit())
    {
        Ok(raw.to_string())
    } else {
        Err(McpError::InvalidOption(format!(
            "invalid value for import option \"prefix\": \"{raw}\" is not an identifier fragment \
             (lowercase letters, digits, underscores; must not start with a digit)"
        )))
    }
}

/// The `IMPORT FOREIGN SCHEMA` table filter (§4.11).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TableFilter {
    /// No LIMIT TO / EXCEPT clause.
    All,
    /// `LIMIT TO (a, b, ...)`
    LimitTo(Vec<String>),
    /// `EXCEPT (a, b, ...)`
    Except(Vec<String>),
}

/// Quote a SQL identifier (the only escaping the generated DDL needs; schema,
/// table and server names all pass through here).
fn quote_ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

/// One CREATE FOREIGN TABLE statement for `spec`, with `table_options`
/// (possibly empty) appended after the SERVER clause.
fn create_foreign_table(
    server_name: &str,
    local_schema: &str,
    spec: &tables::TableSpec,
    table_options: &[(String, String)],
) -> String {
    let columns = spec
        .columns
        .iter()
        .map(|col| format!("  {} {}", quote_ident(col.name), col.pg_type.sql_name()))
        .collect::<Vec<_>>()
        .join(",\n");
    let options = if table_options.is_empty() {
        String::new()
    } else {
        let parts = table_options
            .iter()
            .map(|(k, v)| format!("{k} '{}'", v.replace('\'', "''")))
            .collect::<Vec<_>>()
            .join(", ");
        format!(" OPTIONS ({parts})")
    };
    format!(
        "CREATE FOREIGN TABLE {}.{} (\n{}\n) SERVER {}{};",
        quote_ident(local_schema),
        quote_ident(spec.name),
        columns,
        quote_ident(server_name),
        options
    )
}

/// The CREATE FOREIGN TABLE statements for this filter, in registry order —
/// the FDW callback path, default options (§4.11 remote schema `mcp`).
pub fn statements(server_name: &str, local_schema: &str, filter: &TableFilter) -> Vec<String> {
    statements_with(server_name, local_schema, filter, &ImportOptions::default())
}

/// [`statements`] with the import options applied (the `mcp.import/3` path).
pub fn statements_with(
    server_name: &str,
    local_schema: &str,
    filter: &TableFilter,
    opts: &ImportOptions,
) -> Vec<String> {
    let table_options = opts.table_options();
    tables::REGISTRY
        .iter()
        .filter(|entry| match filter {
            TableFilter::All => true,
            TableFilter::LimitTo(names) => names.iter().any(|n| n == entry.spec.name),
            TableFilter::Except(names) => !names.iter().any(|n| n == entry.spec.name),
        })
        .map(|entry| create_foreign_table(server_name, local_schema, entry.spec, &table_options))
        .collect()
}

/// The PRD-8 per-tool layout (FR-8.14): for each tool in `tools` (the
/// effective `tools/list` — D2), the §4.2 foreign table, §4.3 typed function
/// + comment, and §4.4 gated view. Skipped tools are silently absent here —
/// callers (`mcp.import`, `mcp.generate_functions`) surface the skip list and
/// warnings from the shared planner themselves.
///
/// The statement list is paired with the planned tools so callers can write
/// the `mcp.generated` rows (via [`codegen::registry`]) once the DDL lands.
///
/// Under `per_upstream_schema`, upstream schemas are created with plain
/// `CREATE SCHEMA` (the engine layout's precedent: an occupied schema fails
/// the import rather than being silently reused); each upstream slice's
/// tables carry the `upstream` option. Generated tables also carry the
/// PRD-7 contracts: `cache_ttl_ms` from the options, `upstream` marks.
pub fn per_tool_plan(
    server_name: &str,
    local_schema: &str,
    tools: &[Value],
    opts: &ImportOptions,
) -> McpResult<(Vec<String>, codegen::GenerationPlan)> {
    let mode = if opts.per_upstream_schema {
        codegen::SchemaMode::PerUpstream
    } else {
        codegen::SchemaMode::Single
    };
    let planned = codegen::plan(
        tools,
        local_schema,
        &opts.prefix,
        opts.invoke_on_select,
        mode,
    )?;

    let mut out = Vec::new();
    let mut created_schemas: Vec<&str> = Vec::new();
    for tool in planned.tools.iter() {
        // Per-upstream schemas are created ahead of their objects (once).
        if opts.per_upstream_schema && tool.schema != local_schema {
            if !created_schemas.contains(&tool.schema.as_str()) {
                out.push(format!("CREATE SCHEMA {};", quote_ident(&tool.schema)));
                created_schemas.push(&tool.schema);
            }
        }
        let extra = codegen::table::ExtraOptions {
            // The engine-slice marker: per-upstream tables are scoped to
            // their upstream, single-schema per-tool tables are unmarked.
            upstream: if opts.per_upstream_schema && tool.schema != local_schema {
                Some(tool.schema.clone())
            } else {
                None
            },
            cache_ttl_ms: opts.cache_ttl_ms,
        };
        out.push(codegen::table::create_table(server_name, tool, &extra));
        out.extend(codegen::table::column_comments(tool));
        out.push(codegen::function::create_function(tool));
        if let Some(comment) = codegen::function::comment_on_function(tool) {
            out.push(comment);
        }
        if let Some(view) = codegen::view::create_view(tool) {
            out.push(view);
        }
    }
    Ok((out, planned))
}

/// Tables the engine itself owns rather than federates: no column is sourced
/// from a list or read-through MCP method. Today that is exactly `server`
/// (identity + initialize) and `tool_calls` (the local call log).
pub fn is_engine_local(spec: &tables::TableSpec) -> bool {
    spec.columns
        .iter()
        .all(|c| !matches!(c.source, Source::List(_) | Source::ReadThrough(_)))
}

/// Upstream names implied by the engine's namespacing convention
/// (`<upstream>.<tool>` on `tools/list`): the set of prefixes, sorted,
/// deduplicated. Names without a prefix are engine-local and contribute
/// nothing.
pub fn upstreams_from_tool_names<'a, I>(names: I) -> Vec<String>
where
    I: IntoIterator<Item = &'a str>,
{
    let mut upstreams: Vec<String> = names
        .into_iter()
        .filter_map(|n| n.split_once('.').map(|(upstream, _)| upstream.to_string()))
        .collect();
    upstreams.sort();
    upstreams.dedup();
    upstreams
}

/// The `all_upstreams 'true'` engine layout (ADR-007 / FR-7.19).
///
/// For each upstream (caller passes the sorted, deduplicated list derived from
/// the engine's `tools/list`): `CREATE SCHEMA <upstream>` plus that upstream's
/// slice of the catalog — every federated table with `upstream '<name>'`
/// OPTIONS, names un-prefixed because the schema is per-upstream. Then the
/// engine's own ten tables in the target schema, federated ones marked with
/// `upstream ''` (engine-local slice) so the engine schema reads `servers`,
/// `tool_calls` and the engine-local tools, and nothing is created implicitly
/// beyond what this import names.
pub fn engine_statements(
    server_name: &str,
    local_schema: &str,
    opts: &ImportOptions,
    upstreams: &[String],
) -> Vec<String> {
    let mut out = Vec::new();

    for upstream in upstreams {
        out.push(format!("CREATE SCHEMA {};", quote_ident(upstream)));
        for entry in tables::REGISTRY.iter().filter(|e| !is_engine_local(e.spec)) {
            let mut table_options = vec![(TABLE_OPTION_UPSTREAM.to_string(), upstream.clone())];
            table_options.extend(opts.table_options());
            out.push(create_foreign_table(
                server_name,
                upstream,
                entry.spec,
                &table_options,
            ));
        }
    }

    for entry in tables::REGISTRY.iter() {
        // Upstream marker first, so both schemas spell OPTIONS the same way.
        let mut table_options = opts.table_options();
        if !is_engine_local(entry.spec) {
            table_options.insert(0, (TABLE_OPTION_UPSTREAM.to_string(), String::new()));
        }
        out.push(create_foreign_table(
            server_name,
            local_schema,
            entry.spec,
            &table_options,
        ));
    }
    out
}

#[cfg(any(test, feature = "pg_test"))]
#[pgrx::pg_schema]
mod tests {
    use super::*;

    #[pgrx::pg_test]
    fn all_emits_one_statement_per_registry_table() {
        let stmts = statements("npl", "npl_mcp", &TableFilter::All);
        assert_eq!(stmts.len(), tables::REGISTRY.len());
        assert!(stmts[0].starts_with("CREATE FOREIGN TABLE \"npl_mcp\".\"server\""));
        assert!(stmts[0].ends_with("SERVER \"npl\";"));
    }

    #[pgrx::pg_test]
    fn limit_to_and_except_filter_by_table_name() {
        let limit = statements("npl", "s", &TableFilter::LimitTo(vec!["tools".into()]));
        assert_eq!(limit.len(), 1);
        assert!(limit[0].starts_with("CREATE FOREIGN TABLE \"s\".\"tools\""));
        assert!(limit[0].contains("\"name\" text"));

        let except = statements(
            "npl",
            "s",
            &TableFilter::Except(vec!["tools".into(), "tool_calls".into()]),
        );
        assert_eq!(except.len(), tables::REGISTRY.len() - 2);
        assert!(!except.iter().any(|s| s.contains("\"s\".\"tools\"")));
        assert!(!except.iter().any(|s| s.contains("\"s\".\"tool_calls\"")));
    }

    #[pgrx::pg_test]
    fn tool_calls_ddl_matches_the_prd_column_block() {
        let stmts = statements("npl", "s", &TableFilter::LimitTo(vec!["tool_calls".into()]));
        for needle in [
            "\"id\" uuid",
            "\"tool\" text",
            "\"arguments\" jsonb",
            "\"content\" jsonb",
            "\"structured\" jsonb",
            "\"is_error\" boolean",
            "\"error\" jsonb",
            "\"called_at\" timestamptz",
            "\"duration_ms\" integer",
        ] {
            assert!(
                stmts[0].contains(needle),
                "missing `{needle}` in:\n{}",
                stmts[0]
            );
        }
    }

    #[pgrx::pg_test]
    fn identifiers_are_quoted() {
        let stmts = statements("we\"ird", "s", &TableFilter::All);
        assert!(stmts[0].ends_with("SERVER \"we\"\"ird\";"));
    }

    // ── every table, exact columns ───────────────────────────────────────────

    /// Each statement carries exactly the §4.1-§4.7 columns of its registry
    /// spec — the right names, the right SQL types, nothing else.
    #[pgrx::pg_test]
    fn every_statement_projects_its_spec_exactly() {
        for entry in tables::REGISTRY {
            let stmt = statements(
                "npl",
                "s",
                &TableFilter::LimitTo(vec![entry.spec.name.into()]),
            )
            .pop()
            .unwrap();
            for col in entry.spec.columns {
                let column_line = format!("\"{}\" {}", col.name, col.pg_type.sql_name());
                assert!(
                    stmt.contains(&column_line),
                    "table {}: missing `{column_line}` in:\n{stmt}",
                    entry.spec.name
                );
            }
            // One line per column plus the header and footer lines.
            assert_eq!(
                stmt.matches('\n').count(),
                entry.spec.columns.len() + 1,
                "table {}: unexpected extra column lines:\n{stmt}",
                entry.spec.name
            );
        }
    }

    /// The `server` table's DDL verbatim: identity + initialize columns in
    /// registry order.
    #[pgrx::pg_test]
    fn server_table_ddl_is_exact() {
        let stmt = statements("npl", "s", &TableFilter::LimitTo(vec!["server".into()]))
            .pop()
            .unwrap();
        let expected = concat!(
            "CREATE FOREIGN TABLE \"s\".\"server\" (\n",
            "  \"name\" text,\n",
            "  \"url\" text,\n",
            "  \"protocol_version\" text,\n",
            "  \"server_name\" text,\n",
            "  \"server_version\" text,\n",
            "  \"instructions\" text,\n",
            "  \"capabilities\" jsonb,\n",
            "  \"mode\" text,\n",
            "  \"session_id\" text\n",
            ") SERVER \"npl\";"
        );
        assert_eq!(stmt, expected);
    }

    // ── import options ───────────────────────────────────────────────────────

    fn parse_opts(json: &str) -> McpResult<ImportOptions> {
        ImportOptions::parse(&serde_json::from_str(json).unwrap())
    }

    #[pgrx::pg_test]
    fn import_options_default_to_empty_and_null_is_accepted() {
        assert_eq!(parse_opts("{}").unwrap(), ImportOptions::default());
        assert_eq!(
            ImportOptions::parse(&Value::Null).unwrap(),
            ImportOptions::default()
        );
    }

    #[pgrx::pg_test]
    fn cache_ttl_ms_accepts_number_and_string_forms() {
        let opts = parse_opts(r#"{"cache_ttl_ms": 5000}"#).unwrap();
        assert_eq!(opts.cache_ttl_ms, Some(5_000));

        let opts = parse_opts(r#"{"cache_ttl_ms": "0"}"#).unwrap();
        assert_eq!(opts.cache_ttl_ms, Some(0));

        // The full PRD §4.11 example minus the PRD-8 key.
        let opts = parse_opts(r#"{"all_upstreams": true}"#).unwrap();
        assert!(opts.all_upstreams);
    }

    #[pgrx::pg_test]
    fn bad_import_options_are_rejected() {
        let err = parse_opts(r#"{"cache_ttl_ms": -1}"#).unwrap_err();
        assert_eq!(err.sqlstate(), "22023");
        assert!(err.message().contains("cache_ttl_ms"));

        let err = parse_opts(r#"{"cache_ttl_ms": "soon"}"#).unwrap_err();
        assert!(err.message().contains("cache_ttl_ms"));

        let err = parse_opts(r#"{"all_upstreams": "yes"}"#).unwrap_err();
        assert!(err.message().contains("all_upstreams"));

        // Not an object at all.
        let err = ImportOptions::parse(&serde_json::from_str(r#"[1]"#).unwrap()).unwrap_err();
        assert!(err.message().contains("jsonb object"));

        // Unknown key.
        let err = parse_opts(r#"{"cache_ttl": 5}"#).unwrap_err();
        assert_eq!(err.sqlstate(), "22023");
        assert!(err.message().contains("cache_ttl"));

        // Bad values across the PRD-8 option set.
        for (json, key) in [
            (r#"{"per_tool": "yes"}"#, "per_tool"),
            (r#"{"invoke_on_select": "sometimes"}"#, "invoke_on_select"),
            (r#"{"invoke_on_select": 7}"#, "invoke_on_select"),
            (r#"{"prefix": 9}"#, "prefix"),
            (r#"{"prefix": "has-dashes"}"#, "prefix"),
            (r#"{"prefix": "9lives"}"#, "prefix"),
            (r#"{"per_upstream_schema": "maybe"}"#, "per_upstream_schema"),
        ] {
            let err = parse_opts(json).unwrap_err();
            assert_eq!(err.sqlstate(), "22023", "{json}");
            assert!(err.message().contains(key), "{json}: {}", err.message());
        }
    }

    #[pgrx::pg_test]
    fn prd8_import_options_parse_to_their_defaults_and_values() {
        // Defaults: PRD-7 compat (§8) — no per-tool generation, the ADR-003
        // gate, no prefix.
        let opts = parse_opts("{}").unwrap();
        assert!(!opts.per_tool);
        assert_eq!(opts.invoke_on_select, codegen::InvokeOnSelect::ReadOnly);
        assert_eq!(opts.prefix, "");
        assert!(!opts.per_upstream_schema);

        // §4.6's example, all four keys at once.
        let opts = parse_opts(
            r#"{"per_tool": true, "invoke_on_select": "all", "prefix": "npl_"}"#,
        )
        .unwrap();
        assert!(opts.per_tool);
        assert_eq!(opts.invoke_on_select, codegen::InvokeOnSelect::All);
        assert_eq!(opts.prefix, "npl_");

        let opts = parse_opts(r#"{"invoke_on_select": "none"}"#).unwrap();
        assert_eq!(opts.invoke_on_select, codegen::InvokeOnSelect::None);

        let opts = parse_opts(r#"{"per_upstream_schema": true}"#).unwrap();
        assert!(opts.per_upstream_schema);
    }

    #[pgrx::pg_test]
    fn per_tool_plan_emits_the_full_object_set() {
        let tools: Vec<Value> = serde_json::from_str(
            r#"[
                {"name": "search_docs",
                 "title": "Search",
                 "annotations": {"readOnlyHint": true},
                 "inputSchema": {"type": "object",
                                 "properties": {"query": {"type": "string"}}},
                 "outputSchema": {"type": "object",
                                  "properties": {
                                      "results": {"type": "array",
                                                  "items": {"type": "object",
                                                            "properties": {"id": {"type": "string"}}}}}}},
                {"name": "send_email",
                 "inputSchema": {"type": "object", "properties": {}}}
            ]"#,
        )
        .unwrap();
        let mut opts = ImportOptions::default();
        opts.per_tool = true;
        let (stmts, planned) = per_tool_plan("npl", "npl_s", &tools, &opts).unwrap();
        assert_eq!(planned.tools.len(), 2);
        assert!(planned.skipped.is_empty());

        // search_docs: table + function (+view, read-only all-optional);
        // send_email: table + function only.
        assert!(stmts.iter().any(|s| s.starts_with("CREATE FOREIGN TABLE \"npl_s\".\"tool_search_docs\" (")));
        assert!(stmts.iter().any(|s| s.starts_with("CREATE FUNCTION \"npl_s\".\"search_docs\"(")));
        assert!(stmts.iter().any(|s| s.starts_with("CREATE VIEW \"npl_s\".\"v_tool_search_docs\"")));
        assert!(stmts.iter().any(|s| s.starts_with("CREATE FOREIGN TABLE \"npl_s\".\"tool_send_email\" (")));
        assert!(stmts.iter().any(|s| s.starts_with("CREATE FUNCTION \"npl_s\".\"send_email\"(")));
        assert!(!stmts.iter().any(|s| s.contains("v_tool_send_email")));
        // Tables carry the runtime contract options.
        let table = stmts.iter().find(|s| s.contains("tool_search_docs")).unwrap();
        assert!(table.contains("tool 'search_docs'"), "{table}");
        assert!(table.contains("invoke_on_select 'true'"), "{table}");
        let gated = stmts.iter().find(|s| s.contains("tool_send_email")).unwrap();
        assert!(gated.contains("invoke_on_select 'false'"), "{gated}");
    }

    #[pgrx::pg_test]
    fn per_tool_plan_honors_prefix_and_cache_ttl() {
        let tools: Vec<Value> = serde_json::from_str(
            r#"[{"name": "echo", "annotations": {"readOnlyHint": true},
                 "inputSchema": {"type": "object", "properties": {}}}]"#,
        )
        .unwrap();
        let mut opts = ImportOptions::default();
        opts.per_tool = true;
        opts.prefix = "mcp_".to_string();
        opts.cache_ttl_ms = Some(2500);
        let (stmts, _) = per_tool_plan("npl", "s", &tools, &opts).unwrap();
        assert!(stmts
            .iter()
            .any(|s| s.starts_with("CREATE FOREIGN TABLE \"s\".\"tool_mcp_echo\" (")
                && s.contains("cache_ttl_ms '2500'")));
    }

    #[pgrx::pg_test]
    fn per_upstream_layout_creates_schemas_and_marks_slices() {
        let tools: Vec<Value> = serde_json::from_str(
            r#"[
                {"name": "github.create_issue", "annotations": {"readOnlyHint": true},
                 "inputSchema": {"type": "object", "properties": {}}},
                {"name": "local_echo", "annotations": {"readOnlyHint": true},
                 "inputSchema": {"type": "object", "properties": {}}}
            ]"#,
        )
        .unwrap();
        let mut opts = ImportOptions::default();
        opts.per_tool = true;
        opts.per_upstream_schema = true;
        let (stmts, _) = per_tool_plan("engine", "eng_s", &tools, &opts).unwrap();

        assert_eq!(stmts[0], "CREATE SCHEMA \"github\";");
        assert!(stmts.iter().any(|s| s.starts_with("CREATE FOREIGN TABLE \"github\".\"tool_create_issue\" (")
            && s.contains("tool 'github.create_issue'")
            && s.contains("upstream 'github'")));
        // Unprefixed names stay in the target schema, unmarked.
        assert!(stmts.iter().any(|s| s.starts_with("CREATE FOREIGN TABLE \"eng_s\".\"tool_local_echo\" (")
            && s.contains("tool 'local_echo'")
            && !s.contains("upstream")));
        assert!(!stmts.iter().any(|s| s.contains("tool_github_create_issue")));
    }

    #[pgrx::pg_test]
    fn cache_ttl_lands_in_every_tables_options() {
        let opts = ImportOptions {
            cache_ttl_ms: Some(5_000),
            ..ImportOptions::default()
        };
        let stmts = statements_with("npl", "s", &TableFilter::All, &opts);
        for stmt in &stmts {
            assert!(stmt.contains(" OPTIONS (cache_ttl_ms '5000');"), "{stmt}");
        }
        // And the plain layout emits no OPTIONS clause at all.
        assert!(!statements("npl", "s", &TableFilter::All)
            .iter()
            .any(|s| s.contains("OPTIONS")));
    }

    // ── engine all_upstreams layout ──────────────────────────────────────────

    #[pgrx::pg_test]
    fn engine_local_tables_are_exactly_server_and_tool_calls() {
        let local: Vec<&str> = tables::REGISTRY
            .iter()
            .filter(|e| is_engine_local(e.spec))
            .map(|e| e.spec.name)
            .collect();
        assert_eq!(local, vec!["server", "tool_calls"]);
    }

    #[pgrx::pg_test]
    fn upstream_prefixes_come_from_the_tools_list_namespacing() {
        let upstreams = upstreams_from_tool_names([
            "alpha.echo",
            "plain_local_tool",
            "beta.tools",
            "alpha.second",
            "weird.dotted.name",
        ]);
        assert_eq!(upstreams, vec!["alpha", "beta", "weird"]);

        // No prefixed names → no upstream schemas, nothing implicit.
        assert!(upstreams_from_tool_names(["echo", "add"]).is_empty());
    }

    #[pgrx::pg_test]
    fn engine_layout_creates_one_schema_per_upstream_plus_the_engine_schema() {
        let opts = ImportOptions::default();
        let stmts = engine_statements(
            "engine",
            "mcp_engine",
            &opts,
            &["alpha".to_string(), "beta".to_string()],
        );

        // Two upstreams: (1 CREATE SCHEMA + 8 federated tables) each, plus the
        // engine's own ten tables.
        assert_eq!(stmts.len(), 2 * (1 + 8) + 10);

        assert_eq!(stmts[0], "CREATE SCHEMA \"alpha\";");
        // The upstream's slice: federated tables, marked, un-prefixed names.
        assert!(stmts.iter().any(
            |s| s.starts_with("CREATE FOREIGN TABLE \"alpha\".\"tools\"")
                && s.contains("OPTIONS (upstream 'alpha')")
        ));
        assert!(stmts.iter().any(|s| s
            .starts_with("CREATE FOREIGN TABLE \"beta\".\"resource_contents\"")
            && s.contains("OPTIONS (upstream 'beta')")));
        // Engine-local tables are NOT duplicated into upstream schemas.
        assert!(!stmts.iter().any(|s| s.contains("\"alpha\".\"server\"")));
        assert!(!stmts.iter().any(|s| s.contains("\"beta\".\"tool_calls\"")));

        // The engine's own schema: all ten tables, federated ones marked
        // engine-local (`upstream ''`), the engine-local ones unmarked.
        let engine_tools = stmts
            .iter()
            .find(|s| s.starts_with("CREATE FOREIGN TABLE \"mcp_engine\".\"tools\""))
            .unwrap();
        assert!(engine_tools.contains("OPTIONS (upstream '')"));
        let engine_server = stmts
            .iter()
            .find(|s| s.starts_with("CREATE FOREIGN TABLE \"mcp_engine\".\"server\""))
            .unwrap();
        assert!(!engine_server.contains("OPTIONS"));
        let engine_tool_calls = stmts
            .iter()
            .find(|s| s.starts_with("CREATE FOREIGN TABLE \"mcp_engine\".\"tool_calls\""))
            .unwrap();
        assert!(!engine_tool_calls.contains("OPTIONS"));
    }

    #[pgrx::pg_test]
    fn engine_layout_combines_upstream_and_cache_ttl_options() {
        let opts = ImportOptions {
            cache_ttl_ms: Some(2_500),
            all_upstreams: true,
            ..ImportOptions::default()
        };
        let stmts = engine_statements("engine", "mcp_engine", &opts, &["alpha".to_string()]);
        assert!(stmts.iter().any(|s| {
            s.starts_with("CREATE FOREIGN TABLE \"alpha\".\"tools\"")
                && s.contains("OPTIONS (upstream 'alpha', cache_ttl_ms '2500')")
        }));
        assert!(stmts.iter().any(|s| {
            s.starts_with("CREATE FOREIGN TABLE \"mcp_engine\".\"tools\"")
                && s.contains("OPTIONS (upstream '', cache_ttl_ms '2500')")
        }));
    }

    #[pgrx::pg_test]
    fn engine_layout_quotes_odd_upstream_names() {
        let stmts = engine_statements(
            "engine",
            "s",
            &ImportOptions::default(),
            &["up\"stream".to_string()],
        );
        assert!(stmts[0] == "CREATE SCHEMA \"up\"\"stream\";");
        assert!(stmts
            .iter()
            .any(|s| s.contains("OPTIONS (upstream 'up\"stream')")));
    }
}
