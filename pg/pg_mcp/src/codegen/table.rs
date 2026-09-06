//! §4.2 per-tool `CREATE FOREIGN TABLE` emission (PRD-8 checklist 8.3).
//!
//! Pure string builders over a [`PlannedTool`]: no I/O, no SPI — the callers
//! (`mcp.import`, the `IMPORT FOREIGN SCHEMA` callback, and
//! `mcp.generate_functions` via [`super::registry`]) decide how the
//! statements run. Every identifier is quoted unconditionally, which is what
//! makes §4.5 rule 3 ("reserved words are emitted quoted, not renamed") hold.
//!
//! Table options on generated tables (all carrying forward the PRD-7
//! contracts):
//!
//! * `tool '<original MCP name>'` — §4.5 rule 7; the runtime handler resolves
//!   the table through this option, and the mapping stays recoverable from
//!   `pg_foreign_table`.
//! * `invoke_on_select 'true'|'false'` — §4.2's gate, decided at generation.
//! * `upstream '<name>'` / `upstream ''` — PRD-7's engine slice marker,
//!   stamped when the caller provides one.
//! * `cache_ttl_ms '<n>'` — PRD-7 §4.10's per-table TTL override, stamped
//!   when the caller provides one.

use super::{PlannedTool};

/// Quote a SQL identifier (same escaping discipline as `import.rs`).
pub(crate) fn quote_ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

/// Quote a SQL single-quoted literal.
pub(crate) fn quote_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

/// The canonical object names for a planned tool.
pub fn table_name(tool: &PlannedTool) -> String {
    format!("tool_{}", tool.sql_name)
}

pub fn view_name(tool: &PlannedTool) -> String {
    format!("v_tool_{}", tool.sql_name)
}

/// One `(name, value)` table option pair, in emission order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExtraOptions {
    pub upstream: Option<String>,
    pub cache_ttl_ms: Option<u64>,
}

impl Default for ExtraOptions {
    fn default() -> Self {
        ExtraOptions {
            upstream: None,
            cache_ttl_ms: None,
        }
    }
}

/// The per-tool table's full OPTIONS clause contents (without the
/// `OPTIONS (...)` wrapper), `tool` and `invoke_on_select` first.
pub fn table_options(tool: &PlannedTool, extra: &ExtraOptions) -> Vec<(String, String)> {
    let mut options = vec![
        (
            "tool".to_string(),
            tool.tool_name.clone(),
        ),
        (
            "invoke_on_select".to_string(),
            if tool.invoke_on_select { "true" } else { "false" }.to_string(),
        ),
    ];
    if let Some(upstream) = &extra.upstream {
        options.push(("upstream".to_string(), upstream.clone()));
    }
    if let Some(ttl) = extra.cache_ttl_ms {
        options.push(("cache_ttl_ms".to_string(), ttl.to_string()));
    }
    options
}

/// The `CREATE FOREIGN TABLE` statement for one planned tool (§4.2's column
/// block: input columns, output columns, then `content jsonb` and
/// `is_error boolean`).
pub fn create_table(server_name: &str, tool: &PlannedTool, extra: &ExtraOptions) -> String {
    let mut columns: Vec<String> = tool
        .table_columns()
        .iter()
        .map(|col| {
            format!(
                "  {} {}",
                quote_ident(&col.sql_name),
                col.pg_type.sql_name()
            )
        })
        .collect();
    // The always-present pair (§4.2).
    columns.push("  \"content\" jsonb".to_string());
    columns.push("  \"is_error\" boolean".to_string());

    let options = table_options(tool, extra)
        .into_iter()
        .map(|(k, v)| format!("{k} {}", quote_literal(&v)))
        .collect::<Vec<_>>()
        .join(", ");

    format!(
        "CREATE FOREIGN TABLE {}.{} (\n{}\n) SERVER {} OPTIONS ({});",
        quote_ident(&tool.schema),
        quote_ident(&table_name(tool)),
        columns.join(",\n"),
        quote_ident(server_name),
        options
    )
}

/// `COMMENT ON COLUMN` statements for the enum-documented input/output
/// columns (§4.1: enum values live in the column comment; no PG enum type).
pub fn column_comments(tool: &PlannedTool) -> Vec<String> {
    let table = format!(
        "{}.{}",
        quote_ident(&tool.schema),
        quote_ident(&table_name(tool))
    );
    tool.table_columns()
        .iter()
        .filter_map(|col| {
            col.enum_hint.as_ref().map(|hint| {
                format!(
                    "COMMENT ON COLUMN {}.{} IS {};",
                    table,
                    quote_ident(&col.sql_name),
                    quote_literal(hint)
                )
            })
        })
        .collect()
}

#[cfg(any(test, feature = "pg_test"))]
#[pgrx::pg_schema]
mod tests {
    use super::*;
    use crate::codegen::{plan, InvokeOnSelect, OutputShape, SchemaMode};
    use serde_json::json;

    /// §4.2's worked example, verbatim.
    #[pgrx::pg_test]
    fn the_prd_example_table_ddl_is_exact() {
        let tool = json!({
            "name": "search_docs",
            "annotations": {"readOnlyHint": true},
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string"},
                    "limit": {"type": "integer"},
                    "since": {"type": "string", "format": "date-time"},
                },
                "required": ["query"],
            },
            "outputSchema": {
                "type": "object",
                "properties": {
                    "results": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "id": {"type": "string"},
                                "score": {"type": "number"},
                            },
                        },
                    },
                },
            },
        });
        let planned = plan(&[tool], "npl", "", InvokeOnSelect::ReadOnly, SchemaMode::Single)
            .unwrap()
            .tools
            .remove(0);
        let ddl = create_table("npl", &planned, &ExtraOptions::default());
        assert_eq!(
            ddl,
            concat!(
                "CREATE FOREIGN TABLE \"npl\".\"tool_search_docs\" (\n",
                "  \"query\" text,\n",
                "  \"limit\" bigint,\n",
                "  \"since\" timestamptz,\n",
                "  \"id\" text,\n",
                "  \"score\" double precision,\n",
                "  \"content\" jsonb,\n",
                "  \"is_error\" boolean\n",
                ") SERVER \"npl\" OPTIONS (tool 'search_docs', invoke_on_select 'true');"
            )
        );
    }

    #[pgrx::pg_test]
    fn the_gate_and_extra_options_are_stamped_in_order() {
        let tool = json!({
            "name": "send_email",
            "inputSchema": {"type": "object", "properties": {}},
        });
        let planned = plan(&[tool], "npl", "", InvokeOnSelect::ReadOnly, SchemaMode::Single)
            .unwrap()
            .tools
            .remove(0);
        assert!(!planned.invoke_on_select);
        let ddl = create_table(
            "npl",
            &planned,
            &ExtraOptions {
                upstream: Some("mail".to_string()),
                cache_ttl_ms: Some(5000),
            },
        );
        assert!(
            ddl.ends_with("OPTIONS (tool 'send_email', invoke_on_select 'false', \
                           upstream 'mail', cache_ttl_ms '5000');"),
            "{ddl}"
        );
    }

    #[pgrx::pg_test]
    fn reserved_word_names_are_quoted_not_renamed() {
        let tool = json!({
            "name": "limit",
            "annotations": {"readOnlyHint": true},
            "inputSchema": {"type": "object", "properties": {}},
        });
        let planned = plan(&[tool], "s", "", InvokeOnSelect::ReadOnly, SchemaMode::Single)
            .unwrap()
            .tools
            .remove(0);
        assert_eq!(planned.sql_name, "limit");
        let ddl = create_table("s", &planned, &ExtraOptions::default());
        assert!(ddl.contains("\"s\".\"tool_limit\" ("), "{ddl}");
        assert!(ddl.contains("tool 'limit'"), "{ddl}");
    }

    #[pgrx::pg_test]
    fn no_output_schema_means_content_and_is_error_only() {
        let tool = json!({
            "name": "bare",
            "annotations": {"readOnlyHint": true},
            "inputSchema": {"type": "object", "properties": {}},
        });
        let planned = plan(&[tool], "s", "", InvokeOnSelect::ReadOnly, SchemaMode::Single)
            .unwrap()
            .tools
            .remove(0);
        assert_eq!(planned.output, OutputShape::None);
        let ddl = create_table("s", &planned, &ExtraOptions::default());
        assert!(ddl.contains("\"content\" jsonb,\n  \"is_error\" boolean"), "{ddl}");
        assert_eq!(ddl.matches('\n').count(), 3, "two columns only: {ddl}");
    }

    #[pgrx::pg_test]
    fn enum_properties_get_column_comments() {
        let tool = json!({
            "name": "set_priority",
            "annotations": {"readOnlyHint": true},
            "inputSchema": {
                "type": "object",
                "properties": {
                    "level": {"type": "string", "enum": ["low", "high"]},
                },
            },
        });
        let planned = plan(&[tool], "s", "", InvokeOnSelect::ReadOnly, SchemaMode::Single)
            .unwrap()
            .tools
            .remove(0);
        let comments = column_comments(&planned);
        assert_eq!(comments.len(), 1);
        assert_eq!(
            comments[0],
            "COMMENT ON COLUMN \"s\".\"tool_set_priority\".\"level\" \
             IS 'Permitted values: low, high';"
        );
    }
}
