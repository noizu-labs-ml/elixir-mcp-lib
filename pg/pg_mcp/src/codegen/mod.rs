//! PRD-8 codegen: per-tool SQL objects planned from `tools/list` (D1: one
//! resolver — the same source `mcp.tools` reads; regeneration re-reads, it
//! never patches).
//!
//! Layout:
//!
//! * [`types`] — the §4.1 JSON Schema → PostgreSQL type map.
//! * [`ident`] — the §4.5 identifier rules, including SHA-256 truncation and
//!   collision suffixing.
//! * [`table`] / [`function`] / [`view`] — DDL emission for one planned tool.
//! * [`registry`] — the `mcp.generated` bookkeeping table and the
//!   drop-before-recreate cycle (`RESTRICT`; never touches unowned objects).
//!
//! [`plan`] is the single planning step both generation paths share —
//! `mcp.generate_functions` and `IMPORT FOREIGN SCHEMA`/`mcp.import` with
//! `per_tool 'true'`. It consumes the *effective* tool definitions the server
//! returned for the generating principal (D2): a tool the principal cannot
//! see never reaches it. Planning is pure — no I/O — so both unit tests and
//! the runtime paths exercise identical logic.

pub mod function;
pub mod ident;
pub mod registry;
pub mod table;
pub mod types;
pub mod view;

use crate::errors::{McpError, McpResult};
use crate::tables::ColumnType;
use serde_json::Value;

/// §4.2's invocation gate, as parsed from the import/generation options.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum InvokeOnSelect {
    /// `read_only` (default): SELECT invokes only tools the server declares
    /// `readOnlyHint: true` (ADR-003's gate).
    #[default]
    ReadOnly,
    /// `all`: every tool's table invokes on SELECT. A generation-time WARNING
    /// lists every non-read-only tool so promoted (FR-8.7).
    All,
    /// `none`: every table is INSERT-only.
    None,
}

impl InvokeOnSelect {
    /// Parse the string forms used by both the jsonb import option and the
    /// `IMPORT FOREIGN SCHEMA` OPTIONS clause.
    pub fn parse(raw: &str) -> McpResult<InvokeOnSelect> {
        match raw {
            "read_only" => Ok(InvokeOnSelect::ReadOnly),
            "all" => Ok(InvokeOnSelect::All),
            "none" => Ok(InvokeOnSelect::None),
            other => Err(McpError::InvalidOption(format!(
                "invalid value for invoke_on_select: \"{other}\" (expected 'read_only', 'all' or 'none')"
            ))),
        }
    }

    pub const fn as_str(self) -> &'static str {
        match self {
            InvokeOnSelect::ReadOnly => "read_only",
            InvokeOnSelect::All => "all",
            InvokeOnSelect::None => "none",
        }
    }
}

/// One mapped column of a per-tool table (input or output).
#[derive(Debug, Clone, PartialEq)]
pub struct Column {
    /// The original MCP property name (the `arguments` key on the wire).
    pub property: String,
    /// The derived SQL column name (§4.5), collision-resolved within the tool.
    pub sql_name: String,
    pub pg_type: ColumnType,
    /// In the input schema's `required` array (drives function parameters and
    /// the 22023 missing-qual rule, not column nullability).
    pub required: bool,
    /// Rendered `enum` values for the column comment, when the property
    /// carries an `enum` array.
    pub enum_hint: Option<String>,
}

/// §4.2's output-shape decision for one tool.
#[derive(Debug, Clone, PartialEq)]
pub enum OutputShape {
    /// No `outputSchema`: columns `content` and `is_error` only, one row.
    None,
    /// The single top-level property is an array of objects: one row per
    /// element, with the element's properties as columns (AC-8.5).
    ElementOf {
        /// The original property name carrying the array.
        property: String,
        columns: Vec<Column>,
    },
    /// Anything else (scalar properties, nested objects, multiple arrays,
    /// empty schema): one row, each top-level property mapped per §4.1
    /// (§4.2; Q7's conservative collapse).
    Single(Vec<Column>),
}

/// One planned tool: everything the DDL emitters and the runtime handler
/// need, derived from the tool's published schemas.
#[derive(Debug, Clone, PartialEq)]
pub struct PlannedTool {
    /// The original MCP tool name (the `tool` table option, unmangled).
    pub tool_name: String,
    /// The derived, prefixed, collision-resolved SQL name (§4.5). The table is
    /// `tool_<sql_name>`, the view `v_tool_<sql_name>`, the function
    /// `<sql_name>`.
    pub sql_name: String,
    /// Target schema for this tool's objects (the single target schema, or
    /// the upstream schema under `per_upstream_schema`).
    pub schema: String,
    /// `annotations.readOnlyHint` — ADR-003's gate input.
    pub read_only: bool,
    /// Whether SELECT on the table invokes (§4.2's gate table).
    pub invoke_on_select: bool,
    /// Input columns, in schema property order (table column order).
    pub inputs: Vec<Column>,
    pub output: OutputShape,
    /// Function parameter order (§4.3): required inputs first in `required`
    /// order, then optional inputs in property order.
    pub params: Vec<String>,
    pub title: Option<String>,
    pub description: Option<String>,
}

impl PlannedTool {
    /// Output columns in table order: element properties for
    /// [`OutputShape::ElementOf`], top-level properties for
    /// [`OutputShape::Single`], empty for [`OutputShape::None`].
    pub fn output_columns(&self) -> &[Column] {
        match &self.output {
            OutputShape::None => &[],
            OutputShape::ElementOf { columns, .. } => columns,
            OutputShape::Single(columns) => columns,
        }
    }

    /// The full table column list in DDL order: inputs, outputs, then the
    /// always-present `content` / `is_error` pair (§4.2).
    pub fn table_columns(&self) -> Vec<&Column> {
        self.inputs
            .iter()
            .chain(self.output_columns().iter())
            .collect()
    }

    /// Whether the output shape yields one row per result element (§4.3's
    /// `RETURNS TABLE` case).
    pub fn is_multi_row(&self) -> bool {
        matches!(self.output, OutputShape::ElementOf { .. })
    }
}

/// The result of planning one generation batch (D5: fail-open per server).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct GenerationPlan {
    /// Tools that generated (or would generate) objects, in `tools/list`
    /// order.
    pub tools: Vec<PlannedTool>,
    /// Tools skipped with a warning (unmappable input schema), by name.
    pub skipped: Vec<String>,
    /// Generation-time warnings to emit (FR-8.7's promoted-tools list,
    /// truncation/collision notices from §4.5).
    pub warnings: Vec<String>,
}

/// A JSON pointer into a tool definition, for error messages.
fn tool_display_name(tool: &Value) -> String {
    tool.get("name")
        .and_then(Value::as_str)
        .unwrap_or("<unnamed>")
        .to_string()
}

/// Plan one generation batch (§4.2-§4.5) from a `tools/list` result.
///
/// * `tools` — the items of the effective `tools/list` for the calling
///   principal (D2), in server order.
/// * `schemas` — [`SchemaMode::Single`] puts every tool into `schema`;
///   [`SchemaMode::PerUpstream`] routes `<upstream>.<tool>` names into a
///   schema named for the upstream, stripping the prefix before §4.5 runs
///   (ADR-007 / FR-8.17). Unprefixed names stay in `schema`.
pub fn plan(
    tools: &[Value],
    schema: &str,
    prefix: &str,
    gate: InvokeOnSelect,
    mode: SchemaMode,
) -> McpResult<GenerationPlan> {
    if schema.is_empty() {
        return Err(McpError::InvalidOption(
            "the target schema name must not be empty".to_string(),
        ));
    }

    // Per-upstream routing: group names by upstream first so collision
    // resolution runs per target schema (two upstreams may legitimately both
    // have a `create_issue`).
    let mut warnings: Vec<String> = Vec::new();

    // First pass: (tool value, target schema, unprefixed name).
    let mut routed: Vec<(&Value, String, &str)> = Vec::new();
    for tool in tools {
        let name = match tool.get("name").and_then(Value::as_str) {
            Some(n) if !n.is_empty() => n,
            _ => {
                // A tool with no name cannot be addressed; skip it (D5).
                warnings.push("skipped a tool entry with no usable name".to_string());
                continue;
            }
        };
        let (target, local) = match mode {
            SchemaMode::Single => (schema.to_string(), name),
            SchemaMode::PerUpstream => match name.split_once('.') {
                Some((upstream, rest)) if !upstream.is_empty() && !rest.is_empty() => {
                    (upstream.to_string(), rest)
                }
                _ => (schema.to_string(), name),
            },
        };
        routed.push((tool, target, local));
    }

    // Collision resolution per (schema, local name) — §4.5 rule 5.
    let mut by_target: std::collections::HashMap<String, Vec<usize>> =
        std::collections::HashMap::new();
    for (i, (_, target, _)) in routed.iter().enumerate() {
        by_target.entry(target.clone()).or_default().push(i);
    }
    let mut sql_names: Vec<String> = vec![String::new(); routed.len()];
    for (_, indexes) in by_target {
        let locals: Vec<&str> = indexes.iter().map(|&i| routed[i].2).collect();
        let deduped = ident::dedup(locals, prefix);
        for (i, (_, sql)) in indexes.into_iter().zip(deduped) {
            sql_names[i] = sql;
        }
    }

    let mut plan_out = GenerationPlan {
        warnings,
        ..GenerationPlan::default()
    };
    let mut promoted: Vec<String> = Vec::new();

    for (i, (tool, target, local)) in routed.into_iter().enumerate() {
        let sql_name = sql_names[i].clone();
        match plan_one(tool, local, sql_name, &target, gate) {
            Ok(planned) => {
                if gate == InvokeOnSelect::All && !planned.read_only {
                    promoted.push(planned.tool_name.clone());
                }
                plan_out.tools.push(planned);
            }
            Err(skip_reason) => {
                plan_out.skipped.push(tool_display_name(tool));
                plan_out
                    .warnings
                    .push(format!("skipped {}: {skip_reason}", tool_display_name(tool)));
            }
        }
    }

    // FR-8.7: `invoke_on_select 'all'` names every non-read-only tool
    // promoted to SELECT-invocation.
    if gate == InvokeOnSelect::All && !promoted.is_empty() {
        plan_out.warnings.push(format!(
            "invoke_on_select 'all': the following tools are not declared read-only but \
             their tables will invoke on SELECT: {}",
            promoted.join(", ")
        ));
    }

    Ok(plan_out)
}

/// How tools map onto target schemas (FR-8.17).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SchemaMode {
    /// Every tool into the one target schema (generic mode).
    Single,
    /// `<upstream>.<tool>` names route into a schema named for the upstream,
    /// prefix stripped; unprefixed names go to the fallback schema.
    PerUpstream,
}

/// Plan a single tool, or fail with the reason it is skipped (D5).
fn plan_one(
    tool: &Value,
    local_name: &str,
    sql_name: String,
    target_schema: &str,
    gate: InvokeOnSelect,
) -> Result<PlannedTool, String> {
    // inputSchema is a required MCP field; a tool without an object input
    // schema cannot have its arguments mapped — skip, don't fail (AC-8.13).
    let input_schema = tool.get("inputSchema").cloned().unwrap_or(Value::Null);
    let input_properties = match types::properties(&input_schema) {
        Some(props) if input_schema.as_object().is_some() => props,
        _ => {
            return Err(format!(
                "inputSchema is not a JSON Schema object with properties (PRD-8 §4.2)"
            ))
        }
    };
    let required = types::required_set(&input_schema);

    // Input columns: property order, per-tool collision resolution on the
    // derived column names (two properties may derive to one SQL name).
    let derived: Vec<String> = input_properties
        .iter()
        .map(|(name, _)| {
            let d = ident::derive(name, "");
            if d.is_empty() {
                // A name with no usable characters still needs a column.
                "_".to_string()
            } else {
                d
            }
        })
        .collect();
    let mut seen: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
    let mut inputs: Vec<Column> = Vec::with_capacity(input_properties.len());
    for ((property, schema), sql) in input_properties.iter().zip(derived.iter()) {
        let sql_name = if seen.insert(sql.as_str(), inputs.len()).is_some() {
            format!("{}_{}", sql, ident::sha_suffix(property))
        } else {
            sql.clone()
        };
        inputs.push(Column {
            property: property.to_string(),
            sql_name,
            pg_type: types::map_type(schema),
            required: required.contains(*property),
            enum_hint: types::enum_hint(schema),
        });
    }

    // Output shape (§4.2).
    let output_schema = tool.get("outputSchema");
    let output = analyze_output(output_schema);

    // §4.2's gate table.
    let read_only = tool
        .get("annotations")
        .map(|a| a.get("readOnlyHint").and_then(Value::as_bool).unwrap_or(false))
        .unwrap_or(false);
    let invoke_on_select = match gate {
        InvokeOnSelect::ReadOnly => read_only,
        InvokeOnSelect::All => true,
        InvokeOnSelect::None => false,
    };

    // Function parameter order (§4.3): required first in the schema's own
    // `required` order, then optional in property order.
    let mut params: Vec<String> = Vec::new();
    for name in types::required_list(&input_schema) {
        if let Some(col) = inputs.iter().find(|c| c.property == name) {
            params.push(col.sql_name.clone());
        }
    }
    debug_assert_eq!(params.len(), required.len(), "params cover every required input");
    for col in &inputs {
        if !col.required {
            params.push(col.sql_name.clone());
        }
    }

    Ok(PlannedTool {
        // The `tool` table option carries the original MCP name (§4.5 r7):
        // the full wire name even under per-upstream routing, so the mapping
        // stays recoverable from `pg_foreign_table`.
        tool_name: tool
            .get("name")
            .and_then(Value::as_str)
            .map(str::to_string)
            .unwrap_or_else(|| local_name.to_string()),
        sql_name,
        schema: target_schema.to_string(),
        read_only,
        invoke_on_select,
        inputs,
        output,
        params,
        title: tool
            .get("title")
            .and_then(Value::as_str)
            .map(str::to_string),
        description: tool
            .get("description")
            .and_then(Value::as_str)
            .map(str::to_string),
    })
}

/// §4.2's output-shape decision (AC-8.5):
///
/// * no `outputSchema` → [`OutputShape::None`];
/// * exactly one top-level property, and it is an array of objects →
///   [`OutputShape::ElementOf`] (one row per element);
/// * everything else → [`OutputShape::Single`] (one row; arrays and objects
///   become `jsonb` columns).
///
/// The single-array case is deliberately strict — "the only property", not
/// "the only array" — because fanning out alongside a sibling scalar column
/// would repeat that column's value on every row, which reads as corruption
/// in a BI tool. Sibling properties take the conservative one-row collapse
/// (Q7).
pub fn analyze_output(schema: Option<&Value>) -> OutputShape {
    let Some(schema) = schema else {
        return OutputShape::None;
    };
    let props = match types::properties(schema) {
        Some(props) => props,
        None => return OutputShape::Single(Vec::new()),
    };

    if let [(only_property, only_schema)] = props[..] {
        if let Some(items) = array_items_of_objects(only_schema) {
            return OutputShape::ElementOf {
                property: only_property.to_string(),
                columns: element_columns(items),
            };
        }
    }

    let columns = props
        .into_iter()
        .map(|(name, prop)| Column {
            property: name.to_string(),
            sql_name: {
                let d = ident::derive(name, "");
                if d.is_empty() {
                    "_".to_string()
                } else {
                    d
                }
            },
            pg_type: types::map_type(prop),
            required: false,
            enum_hint: types::enum_hint(prop),
        })
        .collect();
    OutputShape::Single(columns)
}

/// The `items` schema when `schema` is `{"type":"array","items":{"type":
/// "object", …}}` — the fan-out shape (§4.2).
fn array_items_of_objects(schema: &Value) -> Option<&Value> {
    if schema.get("type").and_then(Value::as_str) != Some("array") {
        return None;
    }
    let items = schema.get("items")?;
    if items.get("type").and_then(Value::as_str) == Some("object") {
        Some(items)
    } else {
        None
    }
}

/// Element columns for the fan-out shape: the `items` object's properties.
/// An `items` without properties yields no columns (rows carry only
/// `content` / `is_error`).
fn element_columns(items: &Value) -> Vec<Column> {
    types::properties(items)
        .unwrap_or_default()
        .into_iter()
        .map(|(name, prop)| Column {
            property: name.to_string(),
            sql_name: {
                let d = ident::derive(name, "");
                if d.is_empty() {
                    "_".to_string()
                } else {
                    d
                }
            },
            pg_type: types::map_type(prop),
            required: false,
            enum_hint: types::enum_hint(prop),
        })
        .collect()
}

#[cfg(any(test, feature = "pg_test"))]
#[pgrx::pg_schema]
mod tests {
    use super::*;
    use serde_json::json;

    fn fixture_tool(name: &str, inputs: Value, output: Option<Value>, read_only: bool) -> Value {
        let mut tool = json!({
            "name": name,
            "inputSchema": inputs,
        });
        if let Some(out) = output {
            tool["outputSchema"] = out;
        }
        if read_only {
            tool["annotations"] = json!({ "readOnlyHint": true });
        }
        tool
    }

    /// §4.2's worked example: input quals, element columns, gate, ordering.
    #[pgrx::pg_test]
    fn the_prd_example_tool_plans_exactly() {
        let tool = fixture_tool(
            "search_docs",
            json!({
                "type": "object",
                "properties": {
                    "query": {"type": "string"},
                    "limit": {"type": "integer"},
                    "since": {"type": "string", "format": "date-time"},
                },
                "required": ["query"],
            }),
            Some(json!({
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
            })),
            true,
        );
        let plan = plan(&[tool], "npl", "", InvokeOnSelect::ReadOnly, SchemaMode::Single).unwrap();
        assert_eq!(plan.skipped.len(), 0);
        assert_eq!(plan.tools.len(), 1);
        let t = &plan.tools[0];
        assert_eq!(t.tool_name, "search_docs");
        assert_eq!(t.sql_name, "search_docs");
        assert_eq!(t.schema, "npl");
        assert!(t.read_only && t.invoke_on_select);

        // Input columns: property order, types per §4.1.
        assert_eq!(t.inputs.len(), 3);
        assert_eq!(t.inputs[0].property, "query");
        assert_eq!(t.inputs[0].pg_type, ColumnType::Text);
        assert!(t.inputs[0].required);
        assert_eq!(t.inputs[1].sql_name, "limit");
        assert_eq!(t.inputs[1].pg_type, ColumnType::Int8);
        assert!(!t.inputs[1].required);
        assert_eq!(t.inputs[2].pg_type, ColumnType::TimestampTz);

        // Output: the single array-of-objects property fans out.
        match &t.output {
            OutputShape::ElementOf { property, columns } => {
                assert_eq!(property, "results");
                assert_eq!(columns.len(), 2);
                assert_eq!(columns[0].sql_name, "id");
                assert_eq!(columns[0].pg_type, ColumnType::Text);
                assert_eq!(columns[1].sql_name, "score");
                assert_eq!(columns[1].pg_type, ColumnType::Float8);
            }
            other => panic!("expected fan-out, got {other:?}"),
        }

        // Parameter order: required first, then optional in property order.
        assert_eq!(t.params, vec!["query", "limit", "since"]);
    }

    /// AC-8.5's two row-shape arms, plus the conservative collapse (Q7).
    #[pgrx::pg_test]
    fn output_shape_matrix_matches_prd_4_2() {
        let shape = |out: Option<Value>| {
            let tool = fixture_tool("t", json!({"type":"object","properties":{}}), out, true);
            plan(&[tool], "s", "", InvokeOnSelect::ReadOnly, SchemaMode::Single)
                .unwrap()
                .tools
                .remove(0)
                .output
        };

        // No outputSchema.
        assert_eq!(shape(None), OutputShape::None);

        // Single array-of-objects property: fan out.
        assert!(matches!(
            shape(Some(json!({"type":"object","properties":{"results":{
                "type":"array","items":{"type":"object","properties":{"id":{"type":"string"}}}}}}))),
            OutputShape::ElementOf { .. }
        ));

        // Scalar properties: one row per property type.
        match shape(Some(json!({"type":"object","properties":{"total":{"type":"integer"}}}))) {
            OutputShape::Single(cols) => {
                assert_eq!(cols.len(), 1);
                assert_eq!(cols[0].pg_type, ColumnType::Int8);
            }
            other => panic!("expected single-row shape, got {other:?}"),
        }

        // A sibling property next to the array: the conservative one-row
        // collapse — the array becomes a jsonb column (Q7).
        match shape(Some(json!({"type":"object","properties":{
            "results":{"type":"array","items":{"type":"object"}},
            "total":{"type":"integer"}}}))) {
            OutputShape::Single(cols) => {
                assert_eq!(cols.len(), 2);
                assert_eq!(cols[0].pg_type, ColumnType::Jsonb);
                assert_eq!(cols[1].pg_type, ColumnType::Int8);
            }
            other => panic!("expected single-row shape, got {other:?}"),
        }

        // Two array-of-objects properties: collapse (Q7).
        assert!(matches!(
            shape(Some(json!({"type":"object","properties":{
                "a":{"type":"array","items":{"type":"object"}},
                "b":{"type":"array","items":{"type":"object"}}}}))),
            OutputShape::Single(_)
        ));

        // An array of *scalars* is not a fan-out shape.
        assert!(matches!(
            shape(Some(json!({"type":"object","properties":{
                "tags":{"type":"array","items":{"type":"string"}}}}))),
            OutputShape::Single(_)
        ));

        // An array-of-objects without properties fans out to content-only rows.
        match shape(Some(json!({"type":"object","properties":{
            "items":{"type":"array","items":{"type":"object"}}}}))) {
            OutputShape::ElementOf { property, columns } => {
                assert_eq!(property, "items");
                assert!(columns.is_empty());
            }
            other => panic!("expected fan-out, got {other:?}"),
        }
    }

    /// §4.2's gate table: readOnlyHint drives the default, options override.
    #[pgrx::pg_test]
    fn invocation_gate_follows_the_prd_matrix() {
        let ro = fixture_tool(
            "ro",
            json!({"type":"object","properties":{}}),
            None,
            true,
        );
        let rw = fixture_tool(
            "rw",
            json!({"type":"object","properties":{}}),
            None,
            false,
        );

        let gate_for = |gate: InvokeOnSelect, tool: &Value| {
            plan(std::slice::from_ref(tool), "s", "", gate, SchemaMode::Single)
                .unwrap()
                .tools[0]
                .invoke_on_select
        };

        // Default (read_only): the server's own declaration decides.
        assert!(gate_for(InvokeOnSelect::ReadOnly, &ro));
        assert!(!gate_for(InvokeOnSelect::ReadOnly, &rw));
        // 'all': everything invokes, and the non-read-only ones are named in
        // a warning (FR-8.7).
        assert!(gate_for(InvokeOnSelect::All, &ro));
        assert!(gate_for(InvokeOnSelect::All, &rw));
        // 'none': nothing invokes.
        assert!(!gate_for(InvokeOnSelect::None, &ro));
        assert!(!gate_for(InvokeOnSelect::None, &rw));

        // An absent readOnlyHint is the safe default.
        let unannotated = json!({
            "name": "plain",
            "inputSchema": {"type":"object","properties":{}},
        });
        assert!(!gate_for(InvokeOnSelect::ReadOnly, &unannotated));

        let both = plan(&[ro, rw], "s", "", InvokeOnSelect::All, SchemaMode::Single).unwrap();
        let promoted_warning = both
            .warnings
            .iter()
            .find(|w| w.contains("not declared read-only"))
            .expect("FR-8.7 warning");
        assert!(promoted_warning.contains("rw"), "{promoted_warning}");
    }

    /// AC-8.13: a tool whose input schema cannot be mapped is skipped with a
    /// warning; every other tool still generates (D5).
    #[pgrx::pg_test]
    fn unmappable_tools_are_skipped_not_fatal() {
        let broken = json!({
            "name": "broken_ref",
            "inputSchema": {"type": "string", "maxLength": 3},
        });
        let fine = fixture_tool(
            "fine",
            json!({"type":"object","properties":{"q":{"type":"string"}}}),
            None,
            true,
        );
        let plan = plan(&[broken, fine], "s", "", InvokeOnSelect::ReadOnly, SchemaMode::Single)
            .unwrap();
        assert_eq!(plan.skipped, vec!["broken_ref".to_string()]);
        assert_eq!(plan.tools.len(), 1);
        assert_eq!(plan.tools[0].tool_name, "fine");
        assert!(plan.warnings.iter().any(|w| w.contains("broken_ref")));
    }

    #[pgrx::pg_test]
    fn unnamed_tools_are_skipped() {
        let plan = plan(&[json!({"inputSchema": {"type":"object"}})], "s", "", InvokeOnSelect::ReadOnly, SchemaMode::Single).unwrap();
        assert!(plan.tools.is_empty());
        assert!(plan.warnings.iter().any(|w| w.contains("no usable name")));
    }

    /// FR-8.17: per-upstream routing strips the prefix, routes the schema,
    /// and keeps collisions per-upstream (AC-8.15's shape).
    #[pgrx::pg_test]
    fn per_upstream_routing_splits_schemas_and_strips_prefixes() {
        let tools = vec![
            fixture_tool("github.create_issue", json!({"type":"object","properties":{}}), None, true),
            fixture_tool("github.list_issues", json!({"type":"object","properties":{}}), None, true),
            fixture_tool("slack.post_message", json!({"type":"object","properties":{}}), None, false),
            fixture_tool("local_echo", json!({"type":"object","properties":{}}), None, true),
        ];
        let planned = plan(
            &tools,
            "engine_mcp",
            "",
            InvokeOnSelect::ReadOnly,
            SchemaMode::PerUpstream,
        )
        .unwrap();
        assert_eq!(planned.tools.len(), 4);

        let schema_of = |tool: &str| planned.tools.iter().find(|t| t.tool_name == tool).unwrap();
        assert_eq!(schema_of("github.create_issue").schema, "github");
        assert_eq!(schema_of("github.create_issue").sql_name, "create_issue",
            "no redundant upstream prefix in the object name");
        assert_eq!(schema_of("slack.post_message").schema, "slack");
        assert_eq!(schema_of("local_echo").schema, "engine_mcp",
            "unprefixed names stay in the target schema");
        assert_eq!(schema_of("local_echo").sql_name, "local_echo");

        // `tool_name` (the table option) keeps the full wire name (§4.5 r7).
        assert_eq!(schema_of("github.create_issue").tool_name, "github.create_issue");

        // Collisions resolve per upstream: both upstreams may have `search`.
        let twins = vec![
            fixture_tool("a.search", json!({"type":"object","properties":{}}), None, true),
            fixture_tool("b.search", json!({"type":"object","properties":{}}), None, true),
        ];
        let plan = plan(&twins, "e", "", InvokeOnSelect::ReadOnly, SchemaMode::PerUpstream).unwrap();
        assert!(plan
            .tools
            .iter()
            .all(|t| t.sql_name == "search"), "no cross-upstream collision suffix");
    }

    #[pgrx::pg_test]
    fn per_tool_column_collisions_get_property_hash_suffixes() {
        // `a-b` and `a_b` both derive to `a_b`.
        let tool = fixture_tool(
            "t",
            json!({"type":"object","properties":{"a-b":{"type":"string"},"a_b":{"type":"integer"}}}),
            None,
            true,
        );
        let plan = plan(&[tool], "s", "", InvokeOnSelect::ReadOnly, SchemaMode::Single).unwrap();
        let inputs = &plan.tools[0].inputs;
        assert_eq!(inputs[0].sql_name, "a_b", "first property keeps the plain name");
        assert_ne!(inputs[1].sql_name, "a_b", "second gets a suffix");
        assert!(inputs[1].sql_name.starts_with("a_b_"));
        // The wire mapping is preserved: arguments use original property names.
        assert_eq!(inputs[1].property, "a_b");
    }

    #[pgrx::pg_test]
    fn prefix_lands_on_the_derived_object_names() {
        let tool = fixture_tool(
            "search_docs",
            json!({"type":"object","properties":{}}),
            None,
            true,
        );
        let plan = plan(&[tool], "s", "npl_", InvokeOnSelect::ReadOnly, SchemaMode::Single).unwrap();
        assert_eq!(plan.tools[0].sql_name, "npl_search_docs");
    }

    #[pgrx::pg_test]
    fn empty_target_schema_is_rejected() {
        let err = plan(&[], "", "", InvokeOnSelect::ReadOnly, SchemaMode::Single).unwrap_err();
        assert_eq!(err.sqlstate(), "22023");
    }

    /// Title and description ride along for COMMENT ON FUNCTION (§4.3).
    #[pgrx::pg_test]
    fn title_and_description_are_carried_for_comments() {
        let tool = json!({
            "name": "search_docs",
            "title": "Search documents",
            "description": "Full-text search over the doc corpus.",
            "annotations": {"readOnlyHint": true},
            "inputSchema": {"type":"object","properties":{}},
        });
        let plan = plan(&[tool], "s", "", InvokeOnSelect::ReadOnly, SchemaMode::Single).unwrap();
        assert_eq!(plan.tools[0].title.as_deref(), Some("Search documents"));
        assert_eq!(
            plan.tools[0].description.as_deref(),
            Some("Full-text search over the doc corpus.")
        );
    }
}
