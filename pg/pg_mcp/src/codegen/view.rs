//! §4.4 flattened view emission (PRD-8 checklist 8.5).
//!
//! `v_tool_<name>` — a stable, output-only projection — exists **only** for
//! tools whose table invokes on SELECT and whose inputs are all optional
//! ("list the things" tools, where `SELECT * FROM v_tool_list_projects` is
//! the whole story). For any other tool the view would be a trap: it would
//! look like a free read while hiding a gated invocation (or an error) behind
//! it, so it is not created (FR-8.10).

use super::table::{quote_ident, table_name, view_name};
use super::PlannedTool;

/// Is this tool eligible for its flattened view? (§4.4: read-only, gated on,
/// and no required inputs — the view exists for "list the things" tools. An
/// `invoke_on_select 'all'` promotion never widens eligibility: the
/// promotion is already a foot-gun and the view would spread it further.)
pub fn eligible(tool: &PlannedTool) -> bool {
    tool.read_only && tool.invoke_on_select && tool.inputs.iter().all(|col| !col.required)
}

/// The `CREATE VIEW` statement, or `None` for ineligible tools.
pub fn create_view(tool: &PlannedTool) -> Option<String> {
    if !eligible(tool) {
        return None;
    }
    let mut columns: Vec<String> = tool
        .output_columns()
        .iter()
        .map(|c| quote_ident(&c.sql_name))
        .collect();
    columns.push("\"content\"".to_string());
    columns.push("\"is_error\"".to_string());

    Some(format!(
        "CREATE VIEW {}.{} AS SELECT {} FROM {}.{};",
        quote_ident(&tool.schema),
        quote_ident(&view_name(tool)),
        columns.join(", "),
        quote_ident(&tool.schema),
        quote_ident(&table_name(tool))
    ))
}

/// A `DROP VIEW … RESTRICT` statement (the caller regenerates views before
/// tables, so a stale view never outlives its table).
pub fn drop_view(schema: &str, name: &str) -> String {
    format!(
        "DROP VIEW {}.{} RESTRICT;",
        quote_ident(schema),
        quote_ident(name)
    )
}

#[cfg(any(test, feature = "pg_test"))]
#[pgrx::pg_schema]
mod tests {
    use super::*;
    use crate::codegen::{plan, InvokeOnSelect, SchemaMode};
    use serde_json::{json, Value};

    fn plan_one(tool: Value, gate: InvokeOnSelect) -> PlannedTool {
        plan(&[tool], "npl", "", gate, SchemaMode::Single)
            .unwrap()
            .tools
            .remove(0)
    }

    /// §4.4's worked example: read-only, all-optional inputs → flat view.
    #[pgrx::pg_test]
    fn eligible_read_only_tools_get_the_flat_view() {
        let tool = plan_one(
            json!({
                "name": "search_docs",
                "annotations": {"readOnlyHint": true},
                "inputSchema": {
                    "type": "object",
                    "properties": {"query": {"type": "string"}},
                },
                "outputSchema": {
                    "type": "object",
                    "properties": {
                        "results": {
                            "type": "array",
                            "items": {"type": "object",
                                      "properties": {"id": {"type": "string"},
                                                     "score": {"type": "number"}}},
                        },
                    },
                },
            }),
            InvokeOnSelect::ReadOnly,
        );
        let ddl = create_view(&tool).expect("all-optional read-only tool is eligible");
        assert_eq!(
            ddl,
            "CREATE VIEW \"npl\".\"v_tool_search_docs\" AS \
             SELECT \"id\", \"score\", \"content\", \"is_error\" \
             FROM \"npl\".\"tool_search_docs\";"
        );
    }

    #[pgrx::pg_test]
    fn required_inputs_block_the_view() {
        let tool = plan_one(
            json!({
                "name": "must_qualify",
                "annotations": {"readOnlyHint": true},
                "inputSchema": {
                    "type": "object",
                    "properties": {"query": {"type": "string"}},
                    "required": ["query"],
                },
            }),
            InvokeOnSelect::ReadOnly,
        );
        assert!(!eligible(&tool));
        assert!(create_view(&tool).is_none(), "a view without quals could not answer the required input");
    }

    #[pgrx::pg_test]
    fn gated_tables_get_no_view() {
        // Not read-only, gate at its default: no view.
        let tool = plan_one(
            json!({
                "name": "send_email",
                "inputSchema": {"type": "object", "properties": {}},
            }),
            InvokeOnSelect::ReadOnly,
        );
        assert!(create_view(&tool).is_none());

        // Not read-only, promoted with 'all': still no view (the promotion is
        // a deliberate foot-gun; the view would spread it further).
        let promoted = plan_one(
            json!({
                "name": "send_email",
                "inputSchema": {"type": "object", "properties": {}},
            }),
            InvokeOnSelect::All,
        );
        assert!(promoted.invoke_on_select);
        assert!(create_view(&promoted).is_none());

        // Read-only, but demoted with 'none': no view.
        let demoted = plan_one(
            json!({
                "name": "list_things",
                "annotations": {"readOnlyHint": true},
                "inputSchema": {"type": "object", "properties": {}},
            }),
            InvokeOnSelect::None,
        );
        assert!(!demoted.invoke_on_select);
        assert!(create_view(&demoted).is_none());
    }

    #[pgrx::pg_test]
    fn view_without_output_schema_projects_the_bare_pair() {
        let tool = plan_one(
            json!({
                "name": "list_things",
                "annotations": {"readOnlyHint": true},
                "inputSchema": {"type": "object", "properties": {}},
            }),
            InvokeOnSelect::ReadOnly,
        );
        let ddl = create_view(&tool).unwrap();
        assert_eq!(
            ddl,
            "CREATE VIEW \"npl\".\"v_tool_list_things\" AS \
             SELECT \"content\", \"is_error\" FROM \"npl\".\"tool_list_things\";"
        );
    }

    #[pgrx::pg_test]
    fn drop_view_is_restrict() {
        assert_eq!(
            drop_view("s", "v_tool_x"),
            "DROP VIEW \"s\".\"v_tool_x\" RESTRICT;"
        );
    }
}
