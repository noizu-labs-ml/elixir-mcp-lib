//! The §4.1 JSON Schema → PostgreSQL type map (PRD-8, normative).
//!
//! One function, [`map_type`], is the whole contract: it takes one JSON Schema
//! property definition and returns the [`ColumnType`] its columns and function
//! parameters use. The map is deliberately mechanical — the vocabulary the
//! Noizu field DSL (`fields.ex`) publishes is small and closed — and it never
//! recurses: `$ref`, `oneOf`, `anyOf`, `allOf` and an absent `type` all fall
//! back to `jsonb` immediately, so a `$ref` cycle cannot loop (D5; AC-8.13's
//! "unmappable" tools are those whose *input schema is not an object at all*,
//! decided by the planner, not here).
//!
//! Nullability is metadata, not DDL: every column is created nullable (an FDW
//! cannot enforce NOT NULL usefully); `required` surfaces as NOT-NULL-on-
//! *parameter* (no `DEFAULT`) in `codegen/function.rs`. The planner reads the
//! schema's `required` array itself; this module only maps types.
//!
//! No PostgreSQL enum types are ever created: `"enum"` maps like a plain
//! string and the permitted values travel as a column comment
//! ([`enum_hint`]). Arrays map to `jsonb`, not PG arrays: JSON null elements
//! and SQL NULL elements are distinguishable in `jsonb` and not in `text[]`.

use crate::tables::ColumnType;
use serde_json::Value;

/// Map one JSON Schema property definition onto its PostgreSQL type (§4.1).
///
/// Anything that is not a JSON object (or carries no usable `type`) is `jsonb`
/// — the lossless fallback, never an error.
pub fn map_type(schema: &Value) -> ColumnType {
    let Some(obj) = schema.as_object() else {
        return ColumnType::Jsonb;
    };

    // Composition keywords and `$ref` are opaque here: jsonb, always (§4.1).
    for keyword in ["$ref", "oneOf", "anyOf", "allOf"] {
        if obj.contains_key(keyword) {
            return ColumnType::Jsonb;
        }
    }

    match obj.get("type") {
        // `{"type": "<single>"}` — the common case.
        Some(Value::String(t)) => map_named_type(t, schema),
        // `{"type": ["string", "null"]}` — the non-null branch when there is
        // exactly one, else `jsonb`. Union members are plain type *strings*.
        Some(Value::Array(types)) => {
            let named: Vec<&str> = types
                .iter()
                .filter_map(Value::as_str)
                .filter(|t| *t != "null")
                .collect();
            match named[..] {
                [only] => map_named_type(only, schema),
                _ => ColumnType::Jsonb,
            }
        }
        // Absent `type`, `type: null`, or a non-string/array `type`.
        _ => ColumnType::Jsonb,
    }
}

/// The named-type arm of [`map_type`]. `schema` is re-read for `string`'s
/// `format` keyword; every other type ignores it (§4.1: unrecognized formats
/// never apply, and formats on non-strings never apply at all).
fn map_named_type(t: &str, schema: &Value) -> ColumnType {
    match t {
        "string" => match schema.get("format").and_then(Value::as_str) {
            Some("date-time") => ColumnType::TimestampTz,
            Some("date") => ColumnType::Date,
            Some("uuid") => ColumnType::Uuid,
            // `enum` maps like a plain string (comment-documented; no PG enum).
            _ => ColumnType::Text,
        },
        "integer" => ColumnType::Int8,
        "number" => ColumnType::Float8,
        "boolean" => ColumnType::Boolean,
        // object, array, and any unknown type name: the lossless fallback.
        _ => ColumnType::Jsonb,
    }
}

/// The `required` array of a JSON Schema object, **in published order** —
/// §4.3's function parameter order follows it. Empty for anything that is not
/// an object schema.
pub fn required_list(schema: &Value) -> Vec<String> {
    schema
        .get("required")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

/// The `required` array of a JSON Schema object, as a set of property names.
/// Empty for anything that is not an object schema.
pub fn required_set(schema: &Value) -> std::collections::HashSet<String> {
    schema
        .get("required")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

/// The properties of a JSON Schema object, in published order. `None` when the
/// schema is not an object or declares no `properties`.
pub fn properties(schema: &Value) -> Option<Vec<(&str, &Value)>> {
    schema
        .get("properties")?
        .as_object()
        .map(|props| props.iter().map(|(k, v)| (k.as_str(), v)).collect())
}

/// Human-readable permitted values for an `enum` property, for the column
/// comment (§4.1: "values documented in the column comment; no PG enum type
/// is created"). `None` when the schema carries no `enum` array.
pub fn enum_hint(schema: &Value) -> Option<String> {
    let values = schema.get("enum").and_then(Value::as_array)?;
    if values.is_empty() {
        return None;
    }
    let rendered: Vec<String> = values
        .iter()
        .map(|v| match v {
            Value::String(s) => s.clone(),
            other => other.to_string(),
        })
        .collect();
    Some(format!("Permitted values: {}", rendered.join(", ")))
}

#[cfg(any(test, feature = "pg_test"))]
#[pgrx::pg_schema]
mod tests {
    use super::*;

    fn map(json: &str) -> ColumnType {
        map_type(&serde_json::from_str(json).unwrap())
    }

    /// AC-8.1: every `fields.ex` declared type maps exactly per §4.1.
    #[pgrx::pg_test]
    fn the_prd_type_table_maps_exactly() {
        assert_eq!(map(r#"{"type":"string"}"#), ColumnType::Text);
        assert_eq!(
            map(r#"{"type":"string","format":"date-time"}"#),
            ColumnType::TimestampTz
        );
        assert_eq!(
            map(r#"{"type":"string","format":"date"}"#),
            ColumnType::Date
        );
        assert_eq!(
            map(r#"{"type":"string","format":"uuid"}"#),
            ColumnType::Uuid
        );
        assert_eq!(
            map(r#"{"type":"string","enum":["a","b"]}"#),
            ColumnType::Text
        );
        assert_eq!(map(r#"{"type":"integer"}"#), ColumnType::Int8);
        assert_eq!(map(r#"{"type":"number"}"#), ColumnType::Float8);
        assert_eq!(map(r#"{"type":"boolean"}"#), ColumnType::Boolean);
        assert_eq!(map(r#"{"type":"object"}"#), ColumnType::Jsonb);
        assert_eq!(map(r#"{"type":"array"}"#), ColumnType::Jsonb);
        // An array of strings is *still* jsonb: null-distinguishability (§4.1).
        assert_eq!(
            map(r#"{"type":"array","items":{"type":"string"}}"#),
            ColumnType::Jsonb
        );
    }

    #[pgrx::pg_test]
    fn union_schemas_take_the_single_non_null_branch() {
        assert_eq!(
            map(r#"{"type":["string","null"]}"#),
            ColumnType::Text,
            "single non-null branch applies"
        );
        // The branch's own format still applies.
        assert_eq!(
            map(r#"{"type":["string","null"],"format":"uuid"}"#),
            ColumnType::Uuid
        );
        assert_eq!(
            map(r#"{"type":["integer","null"]}"#),
            ColumnType::Int8
        );
        // Two non-null branches: the lossless fallback.
        assert_eq!(
            map(r#"{"type":["string","integer","null"]}"#),
            ColumnType::Jsonb
        );
        // Pure null, or a union with no recognizable member.
        assert_eq!(map(r#"{"type":["null"]}"#), ColumnType::Jsonb);
        assert_eq!(map(r#"{"type":["string","integer"]}"#), ColumnType::Jsonb);
    }

    #[pgrx::pg_test]
    fn composition_keywords_and_refs_fall_back_to_jsonb() {
        assert_eq!(map(r##"{"$ref":"#/components/x"}"##), ColumnType::Jsonb);
        // A $ref cycle is just another jsonb here — it cannot loop.
        assert_eq!(
            map(r##"{"$ref":"#/self","description":"points at itself"}"##),
            ColumnType::Jsonb
        );
        assert_eq!(map(r#"{"oneOf":[{"type":"string"}]}"#), ColumnType::Jsonb);
        assert_eq!(map(r#"{"anyOf":[{"type":"string"}]}"#), ColumnType::Jsonb);
        assert_eq!(map(r#"{"allOf":[{"type":"string"}]}"#), ColumnType::Jsonb);
        // Even when the keyword *duplicates* a usable type, the keyword wins:
        // the shape is not the simple closed vocabulary.
        assert_eq!(
            map(r#"{"type":"string","oneOf":[]}"#),
            ColumnType::Jsonb
        );
    }

    #[pgrx::pg_test]
    fn absent_and_malformed_schemas_are_jsonb() {
        assert_eq!(map(r#"{"description":"no type"}"#), ColumnType::Jsonb);
        assert_eq!(map("{}"), ColumnType::Jsonb);
        assert_eq!(map(r#""just a string""#), ColumnType::Jsonb);
        assert_eq!(map("7"), ColumnType::Jsonb);
        assert_eq!(map("null"), ColumnType::Jsonb);
        assert_eq!(map("[]"), ColumnType::Jsonb);
        // A non-string/array `type` value.
        assert_eq!(map(r#"{"type":42}"#), ColumnType::Jsonb);
        // Unknown type names and unknown formats: base/fallback applies.
        assert_eq!(map(r#"{"type":"int64"}"#), ColumnType::Jsonb);
        assert_eq!(
            map(r#"{"type":"string","format":"email"}"#),
            ColumnType::Text,
            "unrecognized format is ignored"
        );
        // Formats on non-string types never apply.
        assert_eq!(
            map(r#"{"type":"integer","format":"date-time"}"#),
            ColumnType::Int8
        );
    }

    #[pgrx::pg_test]
    fn required_set_reads_the_required_array() {
        let schema: Value = serde_json::from_str(
            r#"{"required":["query","limit"],"properties":{}}"#,
        )
        .unwrap();
        let req = required_set(&schema);
        assert!(req.contains("query") && req.contains("limit"));
        assert_eq!(req.len(), 2);

        // Absent, non-array, and non-string members.
        assert!(required_set(&serde_json::from_str::<Value>(r#"{}"#).unwrap()).is_empty());
        assert!(
            required_set(&serde_json::from_str::<Value>(r#"{"required":"query"}"#).unwrap())
                .is_empty()
        );
        assert!(
            required_set(&serde_json::from_str::<Value>(r#"{"required":[1,null]}"#).unwrap())
                .is_empty()
        );
    }

    #[pgrx::pg_test]
    fn properties_preserve_published_order() {
        let schema: Value = serde_json::from_str(
            r#"{"properties":{"query":{},"limit":{},"since":{}}}"#,
        )
        .unwrap();
        let names: Vec<&str> = properties(&schema).unwrap().into_iter().map(|(n, _)| n).collect();
        assert_eq!(names, vec!["query", "limit", "since"]);

        assert!(properties(&serde_json::from_str::<Value>(r#"{}"#).unwrap()).is_none());
        assert!(
            properties(&serde_json::from_str::<Value>(r#"{"properties":7}"#).unwrap()).is_none()
        );
    }

    #[pgrx::pg_test]
    fn enum_hint_renders_permitted_values_for_the_column_comment() {
        let hint = enum_hint(&serde_json::from_str::<Value>(r#"{"enum":["low","mid","high"]}"#).unwrap())
            .unwrap();
        assert_eq!(hint, "Permitted values: low, mid, high");

        // Non-string members render as JSON, not Rust debug output.
        let hint =
            enum_hint(&serde_json::from_str::<Value>(r#"{"enum":[1,true,null]}"#).unwrap())
                .unwrap();
        assert_eq!(hint, "Permitted values: 1, true, null");

        // An empty enum documents nothing (nothing is permitted; the comment
        // would be noise).
        assert!(enum_hint(&serde_json::from_str::<Value>(r#"{"enum":[]}"#).unwrap()).is_none());
        assert!(enum_hint(&serde_json::from_str::<Value>(r#"{"type":"string"}"#).unwrap())
            .is_none());
    }
}

/// Host-side unit tests (no PostgreSQL; `cargo test --lib -- --skip pg_`).
/// The `tests` module above carries the same map as `#[pg_test]` probes; this
/// module adds the property layer and the JSON-Schema shapes the closed
/// `fields.ex` vocabulary never produces but the wire might.
#[cfg(test)]
mod host_tests {
    use super::*;
    use proptest::prelude::*;

    fn map(json: &str) -> ColumnType {
        map_type(&serde_json::from_str(json).unwrap())
    }

    /// §4.1 normative rows, re-asserted host-side so a regression is visible
    /// without a PostgreSQL install.
    #[test]
    fn the_normative_rows_hold_host_side() {
        assert_eq!(map(r#"{"type":"string"}"#), ColumnType::Text);
        assert_eq!(map(r#"{"type":"string","format":"date-time"}"#), ColumnType::TimestampTz);
        assert_eq!(map(r#"{"type":"string","format":"date"}"#), ColumnType::Date);
        assert_eq!(map(r#"{"type":"string","format":"uuid"}"#), ColumnType::Uuid);
        assert_eq!(map(r#"{"type":"string","enum":["a"]}"#), ColumnType::Text);
        assert_eq!(map(r#"{"type":"integer"}"#), ColumnType::Int8);
        assert_eq!(map(r#"{"type":"number"}"#), ColumnType::Float8);
        assert_eq!(map(r#"{"type":"boolean"}"#), ColumnType::Boolean);
        assert_eq!(map(r#"{"type":"object"}"#), ColumnType::Jsonb);
        assert_eq!(map(r#"{"type":"array","items":{"type":"string"}}"#), ColumnType::Jsonb);
    }

    /// `true` and `false` are legal (trivial) JSON Schemas; both carry no type
    /// and fall back to jsonb like any other non-object schema.
    #[test]
    fn boolean_schemas_are_jsonb() {
        assert_eq!(map_type(&Value::Bool(true)), ColumnType::Jsonb);
        assert_eq!(map_type(&Value::Bool(false)), ColumnType::Jsonb);
        assert_eq!(map_type(&Value::Null), ColumnType::Jsonb);
        // A schema-typed `true` nested where a property schema is expected.
        assert_eq!(
            map(r#"{"type":"object","properties":{"a":true}}"#),
            ColumnType::Jsonb,
            "the property itself is irrelevant; the object type decides"
        );
    }

    /// Formats only apply to strings, and only the three §4.1 names apply.
    #[test]
    fn format_matrix_is_exact() {
        for (format, want) in [
            ("date-time", ColumnType::TimestampTz),
            ("date", ColumnType::Date),
            ("uuid", ColumnType::Uuid),
            ("email", ColumnType::Text),
            ("uri", ColumnType::Text),
            ("duration", ColumnType::Text),
            ("json-pointer", ColumnType::Text),
            ("", ColumnType::Text),
        ] {
            let schema = serde_json::json!({"type": "string", "format": format});
            assert_eq!(map_type(&schema), want, "format {format:?}");
            // The same format on a number is invisible (§4.1: formats on
            // non-strings never apply).
            let on_number = serde_json::json!({"type": "number", "format": format});
            assert_eq!(map_type(&on_number), ColumnType::Float8);
        }
        // A non-string `format` is ignored, not fatal.
        assert_eq!(map(r#"{"type":"string","format":7}"#), ColumnType::Text);
    }

    /// `nullable` is OpenAPI vocabulary, not JSON Schema: it does not affect
    /// the map (nullability is metadata, not DDL — moduledoc).
    #[test]
    fn nullable_keyword_does_not_change_the_map() {
        assert_eq!(
            map(r#"{"type":"string","nullable":true}"#),
            ColumnType::Text
        );
        // The JSON-Schema spelling of the same intent is the type union.
        assert_eq!(map(r#"{"type":["string","null"]}"#), ColumnType::Text);
    }

    /// `const` and a single-member `enum` still map like their base type —
    /// this module never looks at `const`, and `enum` is comment metadata.
    #[test]
    fn const_and_single_member_enum_map_like_their_base() {
        assert_eq!(map(r#"{"const":"lit"}"#), ColumnType::Jsonb, "no type: fallback");
        assert_eq!(
            map(r#"{"type":"string","const":"lit"}"#),
            ColumnType::Text
        );
        assert_eq!(map(r#"{"type":"integer","enum":[1]}"#), ColumnType::Int8);
    }

    /// Union arrays: exactly one non-null string member applies (with its
    /// format); anything wider falls back. A non-§4.1 type name inside a
    /// union is an unknown name like any other — jsonb.
    #[test]
    fn union_matrix_is_exact() {
        assert_eq!(map(r#"{"type":["string"]}"#), ColumnType::Text);
        // `uuid` is not a §4.1 *type name* (it is a string format), so a
        // union of it falls back even with the format present.
        assert_eq!(map(r#"{"type":["uuid","null"],"format":"uuid"}"#), ColumnType::Jsonb);
        assert_eq!(map(r#"{"type":["null","null"]}"#), ColumnType::Jsonb);
        assert_eq!(map(r#"{"type":[["string"]]}"#), ColumnType::Jsonb, "nested arrays are not type names");
        assert_eq!(map(r#"{"type":["string",42,"null"]}"#), ColumnType::Text, "non-string members skipped");
    }

    /// Deeply-nested property paths cannot loop: the map never recurses, so
    /// even a self-referential-looking document maps on its face.
    #[test]
    fn deeply_nested_schemas_map_without_recursion() {
        let mut schema = serde_json::json!({"type":"object"});
        for _ in 0..64 {
            schema = serde_json::json!({"type":"object","properties":{"leaf": schema}});
        }
        assert_eq!(map_type(&schema), ColumnType::Jsonb);
    }

    /// Property order preservation (the `preserve_order` feature is
    /// load-bearing for §4.2/§4.3): `properties` must return names exactly as
    /// published, and `required_list` its own order.
    #[test]
    fn property_and_required_order_are_preserved() {
        let schema: Value = serde_json::from_str(
            r#"{"required":["z","a","m"],
                "properties":{"z":{},"a":{},"m":{},"q":{},"b":{}}}"#,
        )
        .unwrap();
        let names: Vec<&str> = properties(&schema).unwrap().into_iter().map(|(n, _)| n).collect();
        assert_eq!(names, vec!["z", "a", "m", "q", "b"]);
        assert_eq!(required_list(&schema), vec!["z", "a", "m"]);
        // `required` naming a property that does not exist is kept verbatim
        // (the function layer simply finds no column for it).
        let phantom: Value = serde_json::from_str(r#"{"required":["ghost"]}"#).unwrap();
        assert_eq!(required_list(&phantom), vec!["ghost"]);
    }

    /// The §4.1 map is total: for *any* JSON value it returns a fixed
    /// `ColumnType`, deterministically, without panicking.
    #[test]
    fn the_type_map_is_total_and_deterministic_over_arbitrary_json() {
        fn assert_total(v: &Value) {
            let a = map_type(v);
            let b = map_type(v);
            assert_eq!(a, b, "deterministic for {v}");
            // Whatever it returns must be one of the ten real types; the enum
            // match below fails to compile if the set drifts.
            match a {
                ColumnType::Text
                | ColumnType::Jsonb
                | ColumnType::Boolean
                | ColumnType::Int4
                | ColumnType::Int8
                | ColumnType::Bytea
                | ColumnType::Uuid
                | ColumnType::TimestampTz
                | ColumnType::Float8
                | ColumnType::Date => {}
            }
        }
        for raw in [
            "null", "true", "false", "0", "-1.5e3", r#""string""#, "[]",
            r#"{"type":null}"#, r#"{"type":{}}"#, r#"{"TYPE":"string"}"#,
            r##"{"$ref":"#/a","type":"string"}"##,
            r#"{"allOf":[],"anyOf":[],"oneOf":[]}"#,
            r#"{"type":"string","oneOf":[{"type":"integer"}]}"#,
            r#"{"type":"STRING"}"#, r#"{"type":""}"#,
            r#"{"type":["string","null","null"]}"#,
            r#"{"format":"date-time"}"#,
            r#"{"properties":null}"#,
        ] {
            assert_total(&serde_json::from_str::<Value>(raw).unwrap());
        }
    }

    // Property: generated schema shapes always map to one of the declared
    // column types and never panic — the type-map fuzz.
    proptest! {
        #![proptest_config(proptest::test_runner::Config::with_cases(512))]

        #[test]
        fn generated_schemas_always_map_to_a_declared_type(
            type_name in prop::option::of(prop::sample::select(vec![
                "string", "integer", "number", "boolean", "object", "array",
                "null", "int64", "",
            ])),
            format in prop::option::of(prop::sample::select(vec![
                "date-time", "date", "uuid", "email", "unknown-format",
            ])),
            composition in prop::option::of(prop::sample::select(vec![
                "$ref", "oneOf", "anyOf", "allOf",
            ])),
            as_union in prop::bool::ANY,
            extra in prop::sample::select(vec![
                "enum", "const", "nullable", "properties", "items", "required",
            ]),
        ) {
            let mut schema = serde_json::Map::new();
            if let Some(t) = &type_name {
                if as_union {
                    schema.insert("type".into(), serde_json::json!([t, "null"]));
                } else {
                    schema.insert("type".into(), serde_json::json!(t));
                }
            }
            if let Some(f) = &format {
                schema.insert("format".into(), serde_json::json!(f));
            }
            if let Some(c) = &composition {
                schema.insert((*c).to_string(), serde_json::json!([{"type": "string"}]));
            }
            schema.insert(extra.into(), serde_json::json!(null));

            let mapped = map_type(&Value::Object(schema.clone()));
            let again = map_type(&Value::Object(schema));
            prop_assert_eq!(mapped, again, "deterministic");
            prop_assert!(
                matches!(
                    mapped,
                    ColumnType::Text
                        | ColumnType::Jsonb
                        | ColumnType::Boolean
                        | ColumnType::Int8
                        | ColumnType::Float8
                        | ColumnType::TimestampTz
                        | ColumnType::Date
                        | ColumnType::Uuid
                ),
                "{mapped:?} is a §4.1 type"
            );
        }
    }
}
