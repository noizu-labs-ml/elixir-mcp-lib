//! §4.3 typed SQL function emission (PRD-8 checklist 8.4).
//!
//! One `LANGUAGE sql VOLATILE PARALLEL UNSAFE` function per tool, named
//! `<schema>.<sql_name>` — safe for every tool without the caller knowing
//! which are read-only:
//!
//! * **read-only tools with `invoke_on_select`**: the body SELECTs from
//!   `tool_<name>` (the gate is already open for these tables).
//! * **every other tool**: the body INSERTs (the universal path, §4.2) and
//!   returns via a data-modifying CTE.
//!
//! Return type per §4.3: `RETURNS TABLE (…)` when §4.2's shape fans out
//! (one row per element), `RETURNS jsonb` otherwise — the whole result as
//! `{"content": …, "is_error": …}`, the CallToolResult fields the per-tool
//! table carries.
//!
//! The body references parameters positionally (`$1`, `$2`, …) and qualifies
//! every column with an alias, so column names can never collide with the
//! `RETURNS TABLE` OUT-parameter names PostgreSQL injects. Required
//! parameters have no `DEFAULT` and no NULL clause; optional ones default to
//! `NULL` and match `(col = $n OR $n IS NULL)`.
//!
//! `VOLATILE PARALLEL UNSAFE` is unconditional, including read-only tools:
//! the call performs network I/O (ADR-004; the FR-6.10 rule every `mcp.*`
//! function follows).

use super::table::{quote_ident, quote_literal, table_name};
use super::PlannedTool;
use crate::tables::ColumnType;

/// The SQL type list of a function's parameters, in [`PlannedTool::params`]
/// order — the identity needed for `DROP FUNCTION` and `COMMENT ON FUNCTION`.
pub fn parameter_types(tool: &PlannedTool) -> Vec<ColumnType> {
    tool.params
        .iter()
        .filter_map(|param| {
            tool.inputs
                .iter()
                .find(|col| &col.sql_name == param)
                .map(|col| col.pg_type)
        })
        .collect()
}

/// The function body (§4.3).
fn function_body(tool: &PlannedTool) -> String {
    let qualified = format!(
        "{}.{}",
        quote_ident(&tool.schema),
        quote_ident(&table_name(tool))
    );

    // WHERE fragments: required inputs bind directly; optional inputs treat
    // NULL as "not supplied".
    let mut conjuncts: Vec<String> = Vec::new();
    for (i, param) in tool.params.iter().enumerate() {
        let n = i + 1;
        let col = tool
            .inputs
            .iter()
            .find(|c| &c.sql_name == param)
            .expect("params reference declared inputs");
        let binding = format!("t.{} = ${n}", quote_ident(param));
        if col.required {
            conjuncts.push(binding);
        } else {
            conjuncts.push(format!(
                "(${n}::{} IS NULL OR {binding})",
                col.pg_type.sql_name()
            ));
        }
    }
    let where_clause = if conjuncts.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", conjuncts.join(" AND "))
    };

    // Column list / VALUES for the INSERT arm: every parameter, in order.
    let insert_columns = tool
        .params
        .iter()
        .map(|p| quote_ident(p))
        .collect::<Vec<_>>()
        .join(", ");
    let insert_values = (1..=tool.params.len())
        .map(|n| format!("${n}"))
        .collect::<Vec<_>>()
        .join(", ");

    if tool.is_multi_row() {
        // RETURNS TABLE (…): fan out on SELECT; a non-read-only tool returns
        // its single inserted row carrying the typed shape (the outputs are
        // NULL there — INSERT cannot fan out — but the column list stands).
        let returning = tool
            .output_columns()
            .iter()
            .map(|c| format!("t.{}", quote_ident(&c.sql_name)))
            .collect::<Vec<_>>()
            .join(", ");
        if tool.read_only && tool.invoke_on_select {
            format!("SELECT {returning} FROM {qualified} AS t{where_clause}")
        } else {
            // INSERT cannot fan out and cannot fill the element columns, so
            // the typed shape is returned as NULLs (position-matched to
            // RETURNS TABLE) while the call itself rides the universal path.
            let nulls = tool
                .output_columns()
                .iter()
                .map(|c| format!("NULL::{}", c.pg_type.sql_name()))
                .collect::<Vec<_>>()
                .join(", ");
            let insert = if tool.params.is_empty() {
                format!("INSERT INTO {qualified} DEFAULT VALUES RETURNING \"content\", \"is_error\"")
            } else {
                format!(
                    "INSERT INTO {qualified} ({insert_columns}) VALUES ({insert_values}) \
                     RETURNING \"content\", \"is_error\""
                )
            };
            format!("WITH call AS ({insert}) SELECT {nulls} FROM call AS t")
        }
    } else {
        // RETURNS jsonb: the whole result the table carries, as one object.
        if tool.read_only && tool.invoke_on_select {
            format!(
                "SELECT jsonb_build_object('content', t.\"content\", 'is_error', t.\"is_error\") \
                 FROM {qualified} AS t{where_clause}"
            )
        } else if tool.params.is_empty() {
            // No columns to supply: the argument-free INSERT spelling.
            format!(
                "WITH call AS (\
                 INSERT INTO {qualified} DEFAULT VALUES \
                 RETURNING \"content\", \"is_error\") \
                 SELECT jsonb_build_object('content', \"content\", 'is_error', \"is_error\") \
                 FROM call"
            )
        } else {
            format!(
                "WITH call AS (\
                 INSERT INTO {qualified} ({insert_columns}) VALUES ({insert_values}) \
                 RETURNING \"content\", \"is_error\") \
                 SELECT jsonb_build_object('content', \"content\", 'is_error', \"is_error\") \
                 FROM call"
            )
        }
    }
}

/// The `CREATE FUNCTION` statement for one planned tool (§4.3).
pub fn create_function(tool: &PlannedTool) -> String {
    let params = parameter_types(tool);

    let signature = tool
        .params
        .iter()
        .zip(params.iter())
        .map(|(name, ty)| {
            let optional = tool
                .inputs
                .iter()
                .find(|c| &c.sql_name == name)
                .is_some_and(|c| !c.required);
            if optional {
                format!("{} {} DEFAULT NULL", quote_ident(name), ty.sql_name())
            } else {
                format!("{} {}", quote_ident(name), ty.sql_name())
            }
        })
        .collect::<Vec<_>>()
        .join(", ");

    let returns = if tool.is_multi_row() {
        let columns = tool
            .output_columns()
            .iter()
            .map(|c| format!("{} {}", quote_ident(&c.sql_name), c.pg_type.sql_name()))
            .collect::<Vec<_>>()
            .join(", ");
        if columns.is_empty() {
            "RETURNS TABLE (\"content\" jsonb, \"is_error\" boolean)".to_string()
        } else {
            format!("RETURNS TABLE ({columns})")
        }
    } else {
        "RETURNS jsonb".to_string()
    };

    format!(
        "CREATE FUNCTION {}.{}({}) {} \
         LANGUAGE sql VOLATILE PARALLEL UNSAFE \
         AS $pg_mcp_fn$ {} $pg_mcp_fn$;",
        quote_ident(&tool.schema),
        quote_ident(&tool.sql_name),
        signature,
        returns,
        function_body(tool)
    )
}

/// The `COMMENT ON FUNCTION` text: the tool's title and description, so
/// `\df+` and object browsers show it (§4.3, AC-8.12). `None` when the tool
/// carries no title and no description.
pub fn comment_text(tool: &PlannedTool) -> Option<String> {
    match (tool.title.as_deref(), tool.description.as_deref()) {
        (None, None) => None,
        (Some(title), None) => Some(title.to_string()),
        (None, Some(desc)) => Some(desc.to_string()),
        (Some(title), Some(desc)) => Some(format!("{title}: {desc}")),
    }
}

/// The `COMMENT ON FUNCTION` statement, when there is one to make.
pub fn comment_on_function(tool: &PlannedTool) -> Option<String> {
    let text = comment_text(tool)?;
    let types = parameter_types(tool)
        .iter()
        .map(|t| t.sql_name())
        .collect::<Vec<_>>()
        .join(", ");
    Some(format!(
        "COMMENT ON FUNCTION {}.{}({}) IS {};",
        quote_ident(&tool.schema),
        quote_ident(&tool.sql_name),
        types,
        quote_literal(&text)
    ))
}

/// A `DROP FUNCTION … RESTRICT` statement, given the function's identity
/// argument types (recorded/sourced by the caller — see [`super::registry`]).
pub fn drop_function(schema: &str, name: &str, arg_types: &[ColumnType]) -> String {
    let types = arg_types
        .iter()
        .map(|t| t.sql_name())
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "DROP FUNCTION {}.{}({}) RESTRICT;",
        quote_ident(schema),
        quote_ident(name),
        types
    )
}

#[cfg(any(test, feature = "pg_test"))]
#[pgrx::pg_schema]
mod tests {
    use super::*;
    use crate::codegen::{plan, InvokeOnSelect, SchemaMode};
    use serde_json::{json, Value};

    fn plan_one(tool: Value) -> PlannedTool {
        plan(&[tool], "npl", "", InvokeOnSelect::ReadOnly, SchemaMode::Single)
            .unwrap()
            .tools
            .remove(0)
    }

    const SEARCH_DOCS: &str = r#"{
        "name": "search_docs",
        "title": "Search documents",
        "description": "Full-text search over the corpus.",
        "annotations": {"readOnlyHint": true},
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "limit": {"type": "integer"},
                "since": {"type": "string", "format": "date-time"}
            },
            "required": ["query"]
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
                            "score": {"type": "number"}
                        }
                    }
                }
            }
        }
    }"#;

    /// §4.3's worked example: parameter order, defaults, RETURNS TABLE, and
    /// the SELECT body for a read-only fan-out tool.
    #[pgrx::pg_test]
    fn readonly_fanout_function_is_exact() {
        let tool = plan_one(serde_json::from_str(SEARCH_DOCS).unwrap());
        let ddl = create_function(&tool);
        assert_eq!(
            ddl,
            concat!(
                "CREATE FUNCTION \"npl\".\"search_docs\"(",
                "\"query\" text, \"limit\" bigint DEFAULT NULL, \"since\" timestamptz DEFAULT NULL) ",
                "RETURNS TABLE (\"id\" text, \"score\" double precision) ",
                "LANGUAGE sql VOLATILE PARALLEL UNSAFE ",
                "AS $pg_mcp_fn$ ",
                "SELECT t.\"id\", t.\"score\" FROM \"npl\".\"tool_search_docs\" AS t ",
                "WHERE t.\"query\" = $1 ",
                "AND ($2::bigint IS NULL OR t.\"limit\" = $2) ",
                "AND ($3::timestamptz IS NULL OR t.\"since\" = $3) ",
                "$pg_mcp_fn$;"
            )
        );

        let comment = comment_on_function(&tool).unwrap();
        assert!(
            comment.starts_with(
                "COMMENT ON FUNCTION \"npl\".\"search_docs\"(text, bigint, timestamptz) IS '"
            ),
            "{comment}"
        );
        assert!(
            comment.contains("Search documents: Full-text search over the corpus."),
            "{comment}"
        );
    }

    #[pgrx::pg_test]
    fn non_readonly_function_inserts_through_a_cte() {
        let tool = plan_one(json!({
            "name": "send_email",
            "inputSchema": {
                "type": "object",
                "properties": {"to": {"type": "string"}, "body": {"type": "string"}},
                "required": ["to", "body"]
            },
        }));
        let ddl = create_function(&tool);
        // REQUIRED parameters carry no DEFAULT (§4.3).
        assert!(ddl.contains("\"to\" text, \"body\" text)"), "{ddl}");
        assert!(!ddl.contains("DEFAULT"), "{ddl}");
        // The INSERT body: the universal path.
        assert!(
            ddl.contains("WITH call AS (INSERT INTO \"npl\".\"tool_send_email\""),
            "{ddl}"
        );
        assert!(
            ddl.contains("VALUES ($1, $2) RETURNING \"content\", \"is_error\")"),
            "{ddl}"
        );
        assert!(ddl.contains("RETURNS jsonb"), "{ddl}");
        // PARALLEL UNSAFE and VOLATILE are unconditional.
        assert!(ddl.contains("LANGUAGE sql VOLATILE PARALLEL UNSAFE"), "{ddl}");
    }

    #[pgrx::pg_test]
    fn non_readonly_fanout_tool_still_returns_the_typed_shape() {
        let tool = plan_one(json!({
            "name": "sync_users",
            "inputSchema": {"type": "object", "properties": {}},
            "outputSchema": {
                "type": "object",
                "properties": {
                    "users": {
                        "type": "array",
                        "items": {"type": "object",
                                  "properties": {"id": {"type": "string"}}}
                    }
                }
            }
        }));
        let ddl = create_function(&tool);
        assert!(ddl.contains("RETURNS TABLE (\"id\" text)"), "{ddl}");
        assert!(ddl.contains("INSERT INTO"), "{ddl}");
        assert!(ddl.contains("SELECT NULL::text FROM call AS t"), "{ddl}");
    }

    #[pgrx::pg_test]
    fn a_tool_with_no_outputs_returns_the_whole_result_as_jsonb() {
        let tool = plan_one(json!({
            "name": "bare",
            "annotations": {"readOnlyHint": true},
            "inputSchema": {"type": "object", "properties": {}},
        }));
        let ddl = create_function(&tool);
        assert!(ddl.contains("RETURNS jsonb"), "{ddl}");
        assert!(
            ddl.contains(
                "jsonb_build_object('content', t.\"content\", 'is_error', t.\"is_error\")"
            ),
            "{ddl}"
        );
    }

    #[pgrx::pg_test]
    fn reserved_word_parameters_and_names_are_quoted() {
        let tool = plan_one(json!({
            "name": "limit",
            "annotations": {"readOnlyHint": true},
            "inputSchema": {
                "type": "object",
                "properties": {"limit": {"type": "integer"}},
            },
        }));
        let ddl = create_function(&tool);
        assert!(ddl.starts_with("CREATE FUNCTION \"npl\".\"limit\"(\"limit\" bigint DEFAULT NULL)"), "{ddl}");
        assert!(ddl.contains("t.\"limit\" = $1"), "{ddl}");
    }

    #[pgrx::pg_test]
    fn tools_without_metadata_generate_no_comment() {
        let tool = plan_one(json!({
            "name": "bare",
            "annotations": {"readOnlyHint": true},
            "inputSchema": {"type": "object", "properties": {}},
        }));
        assert!(comment_on_function(&tool).is_none());
        // Title alone, description alone, and both together.
        let titled = plan_one(json!({
            "name": "t", "title": "Just a title",
            "annotations": {"readOnlyHint": true},
            "inputSchema": {"type":"object","properties":{}},
        }));
        assert_eq!(
            comment_on_function(&titled).unwrap(),
            "COMMENT ON FUNCTION \"npl\".\"t\"() IS 'Just a title';"
        );
    }

    #[pgrx::pg_test]
    fn drop_function_carries_the_identity_types() {
        let stmt = drop_function(
            "s",
            "search_docs",
            &[ColumnType::Text, ColumnType::Int8, ColumnType::TimestampTz],
        );
        assert_eq!(
            stmt,
            "DROP FUNCTION \"s\".\"search_docs\"(text, bigint, timestamptz) RESTRICT;"
        );
    }
}
