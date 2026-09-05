//! Normalized qual model (PRD-7 §6 step 7.7, ADR-002 amendment).
//!
//! The FDW planner hook (`fdw.rs`, the only unsafe boundary) extracts
//! PostgreSQL `RestrictInfo` clauses into these `Qual`s before anything safe
//! sees them. Mirroring the supabase-wrappers architecture we adopted as our
//! internal API (ADR-002), a qual is `field / operator / value / use_or`.
//!
//! What we **consume** (PRD-7 §4.8): `=`, `= ANY(ARRAY[...])` and `IN (...)`
//! — the planner lowers `IN` to the same `ScalarArrayOpExpr` as `= ANY`, so
//! both arrive as [`Operator::AnyEqual`]. Everything else (range comparisons,
//! LIKE, IS NULL, OR-ed subtrees, functions, …) is *not* extracted here and is
//! left in the plan for Postgres to re-check: an unsupported qual is never
//! marked as pushed down, so correctness never depends on this module.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// A single pushed-down restriction on one column.
///
/// `use_or` exists for shape parity with the wrappers `Qual` model; the
/// extractor never produces `use_or = true` (we do not descend into `OR`
/// expressions), so downstream tables may treat it as always `false` while
/// keeping the field for forward compatibility.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Qual {
    pub field: String,
    pub operator: Operator,
    /// Scalar for [`Operator::Equal`], array for [`Operator::AnyEqual`].
    pub value: Value,
    pub use_or: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Operator {
    /// `column = value`
    Equal,
    /// `column = ANY(ARRAY[...])` and `column IN (...)` — the planner emits
    /// the same node for both.
    AnyEqual,
}

impl Qual {
    /// Convenience constructor for an `AND`-ed scalar equality.
    pub fn equal(field: impl Into<String>, value: Value) -> Qual {
        Qual {
            field: field.into(),
            operator: Operator::Equal,
            value,
            use_or: false,
        }
    }

    /// Constructor for `= ANY` / `IN` over a set of values.
    pub fn any_equal(field: impl Into<String>, values: Vec<Value>) -> Qual {
        Qual {
            field: field.into(),
            operator: Operator::AnyEqual,
            value: Value::Array(values),
            use_or: false,
        }
    }

    /// Would this qual actually be consumed downstream?
    ///
    /// Guards the invariants the extractor promises: a scalar for `Equal`, a
    /// non-empty? (empty allowed) array of JSON *primitives* for `AnyEqual`,
    /// never SQL NULL, never a nested structure the value comparison in
    /// [`Qual::matches_json`] would silently get wrong (objects/arrays for
    /// `Equal` are allowed only because jsonb columns genuinely compare that
    /// way — see below).
    pub fn is_supported(&self) -> bool {
        if self.field.is_empty() {
            return false;
        }
        match self.operator {
            Operator::Equal => !self.value.is_null(),
            Operator::AnyEqual => self
                .value
                .as_array()
                .is_some_and(|items| items.iter().all(|v| is_qual_primitive(v))),
        }
    }

    /// Does a row's value for `field` satisfy this qual? Used by tables as the
    /// post-fetch filter for pushdown that is only a row-count optimization
    /// (PRD-7 §4.2: MCP list methods have no server-side filter, so pushed
    /// quals are applied in the extension).
    ///
    /// The row side is JSON so table code can convert its cells uniformly;
    /// text/bool/number compare natively, `Equal` on any other JSON shape
    /// compares structurally (correct for `jsonb` columns).
    pub fn matches_json(&self, column: &str, candidate: &Value) -> bool {
        if column != self.field {
            return true; // a different column's qual: not ours to falsify
        }
        match self.operator {
            Operator::Equal => json_equal(&self.value, candidate),
            Operator::AnyEqual => self
                .value
                .as_array()
                .map(|items| items.iter().any(|v| json_equal(v, candidate)))
                .unwrap_or(false),
        }
    }

    /// The distinct values this qual restricts `field` to (`AnyEqual`
    /// flattens; `Equal` yields one). Read-through tables (PRD-7 §4.4-§4.6)
    /// use this to turn quals into one request per distinct key.
    pub fn restricted_values(&self) -> Vec<&Value> {
        match (&self.operator, &self.value) {
            (Operator::Equal, v) => vec![v],
            (Operator::AnyEqual, Value::Array(items)) => items.iter().collect(),
            (Operator::AnyEqual, _) => Vec::new(),
        }
    }
}

/// A value that round-trips through the qual comparison exactly: primitives
/// only. A null is *never* supported (`= NULL` is not a satisfiable
/// restriction, and `IS NULL` is a different planner node we do not claim).
fn is_qual_primitive(v: &Value) -> bool {
    matches!(v, Value::String(_) | Value::Number(_) | Value::Bool(_))
}

fn json_equal(a: &Value, b: &Value) -> bool {
    match (a, b) {
        // A missing column value (SQL NULL) satisfies no equality qual.
        (Value::Null, _) | (_, Value::Null) => false,
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        _ => a == b,
    }
}

/// A pushed-down equality whose value lives in a plan *parameter* (a SQL
/// function's `$n`, a prepared statement's argument) rather than a Const.
/// SQL-function bodies on pg16/17 always plan generically (`SPI_prepare`),
/// so their parameters can never be folded to Consts at plan time; `fdw.rs`
/// carries the Param node in the plan's `fdw_exprs` and resolves the value
/// at executor start (the postgres_fdw pattern), where the parameter list is
/// populated on every major.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ParamQual {
    /// The column the parameter binds.
    pub field: String,
    /// Index into the plan's `fdw_exprs` list (the Param node).
    pub index: usize,
    /// True for the `($n IS NULL OR col = $n)` optional-argument shape the
    /// generated functions emit: a NULL resolution binds nothing (matching
    /// pg18, where a custom plan folds the OR away).
    pub omit_null: bool,
    /// The parameter's declared type OID, as `u32` — needed to interpret the
    /// datum at resolution time (kept type-free so this module stays on
    /// plain Rust).
    pub param_type: u32,
}

/// `fdw_private` wire form: the plan carries pushed quals as one `String`
/// node holding this JSON (design rule: `fdw_private` lists must survive
/// `copyObject`, and a single `makeString` blob is the safest carrier).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FdwPrivate {
    /// Canonical table name from the [`crate::tables`] registry.
    pub table: String,
    pub quals: Vec<Qual>,
    /// Parameter-bound equalities, resolved at executor start. Absent in
    /// plans produced before PRD-8's param support — `default` keeps old
    /// blobs decodable.
    #[serde(default)]
    pub params: Vec<ParamQual>,
}

#[cfg(any(test, feature = "pg_test"))]
#[pgrx::pg_schema]
mod tests {
    use super::*;
    use serde_json::json;

    fn q(field: &str, op: Operator, value: Value) -> Qual {
        Qual {
            field: field.into(),
            operator: op,
            value,
            use_or: false,
        }
    }

    #[pgrx::pg_test]
    fn equal_on_primitives_is_supported() {
        assert!(q("name", Operator::Equal, json!("x")).is_supported());
        assert!(q("size", Operator::Equal, json!(42)).is_supported());
        assert!(q("read_only", Operator::Equal, json!(true)).is_supported());
    }

    #[pgrx::pg_test]
    fn any_equal_with_zero_one_and_n_elements_is_supported() {
        // PRD-7 §7.1: `= ANY` with 0/1/N elements.
        assert!(q("uri", Operator::AnyEqual, json!([])).is_supported());
        assert!(q("uri", Operator::AnyEqual, json!(["a"])).is_supported());
        assert!(q("uri", Operator::AnyEqual, json!(["a", "b", "c"])).is_supported());
        // An empty ANY(ARRAY[]) is vacuous: supported, and matches nothing.
        assert!(!q("uri", Operator::AnyEqual, json!([])).matches_json("uri", &json!("a")));
    }

    #[pgrx::pg_test]
    fn nulls_and_nested_sets_are_unsupported() {
        assert!(!q("name", Operator::Equal, json!(null)).is_supported());
        assert!(!q("uri", Operator::AnyEqual, json!([null])).is_supported());
        assert!(!q("uri", Operator::AnyEqual, json!([["a"]])).is_supported());
        assert!(!q("uri", Operator::AnyEqual, json!([{"a": 1}])).is_supported());
        assert!(!q("", Operator::Equal, json!("x")).is_supported());
    }

    #[pgrx::pg_test]
    fn other_columns_are_never_falsified() {
        // A qual on `name` must not filter `uri` rows: post-fetch filters are
        // per-column, and tables apply only the quals they declared.
        let qual = q("name", Operator::Equal, json!("x"));
        assert!(qual.matches_json("uri", &json!("anything")));
        assert!(!qual.matches_json("name", &json!("y")));
        assert!(qual.matches_json("name", &json!("x")));
    }

    #[pgrx::pg_test]
    fn matches_json_semantics() {
        assert!(q("name", Operator::Equal, json!("x")).matches_json("name", &json!("x")));
        assert!(!q("name", Operator::Equal, json!("x")).matches_json("name", &json!("X")));
        // SQL NULL satisfies no equality.
        assert!(!q("name", Operator::Equal, json!("x")).matches_json("name", &Value::Null));
        // Numbers compare numerically across int/float spellings.
        assert!(q("idx", Operator::Equal, json!(1)).matches_json("idx", &json!(1.0)));
        // ANY: any-of semantics.
        let any = q("uri", Operator::AnyEqual, json!(["a", "b"]));
        assert!(any.matches_json("uri", &json!("a")));
        assert!(any.matches_json("uri", &json!("b")));
        assert!(!any.matches_json("uri", &json!("c")));
        // jsonb structural equality.
        assert!(q("arguments", Operator::Equal, json!({"style":"terse"}))
            .matches_json("arguments", &json!({"style":"terse"})));
    }

    #[pgrx::pg_test]
    fn restricted_values_flattens_sets() {
        let one = q("uri", Operator::Equal, json!("a"));
        assert_eq!(one.restricted_values(), vec![&json!("a")]);

        let many = q("uri", Operator::AnyEqual, json!(["a", "b"]));
        assert_eq!(many.restricted_values(), vec![&json!("a"), &json!("b")]);
    }

    #[pgrx::pg_test]
    fn fdw_private_round_trips_through_json() {
        // The plan carries this as a makeString node; it must survive a
        // text round trip bit-for-bit in meaning.
        let private = FdwPrivate {
            table: "resource_contents".into(),
            quals: vec![
                q("uri", Operator::Equal, json!("file:///a")),
                q("uri", Operator::AnyEqual, json!(["b", "c"])),
            ],
            params: Vec::new(),
        };
        let text = serde_json::to_string(&private).unwrap();
        let back: FdwPrivate = serde_json::from_str(&text).unwrap();
        assert_eq!(back.table, "resource_contents");
        assert_eq!(back.quals.len(), 2);
        assert_eq!(back.quals[0].operator, Operator::Equal);
        assert_eq!(back.quals[1].value, json!(["b", "c"]));
        // use_or stays false: the extractor never descends into ORs.
        assert!(!back.quals.iter().any(|qual| qual.use_or));
    }
}
