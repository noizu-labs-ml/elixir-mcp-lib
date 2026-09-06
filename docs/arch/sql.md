# `sql/*` — the SQL projection protocol (PRD-9 / ADR-005)

This document is protocol-facing: the wire shapes, the derivation rules and
the versioning story of the experimental `sql/*` method family. For the
operator-facing view — installing the FDW, `CREATE SERVER`, datasets — see
[the Postgres guide](../guides/postgres.md). Design rationale lives in
[ADR-005](../docs/adrs/ADR-005-sql-extension-methods.md) and
[ADR-003](../docs/adrs/ADR-003-sql-projection-model.md).

## Status

`sql/*` is **experimental**. It carries no stability promise until MCP
standardizes something comparable. The methods are version-tagged
(`version: 1`) and additive changes only within a version; the version
integer is the migration lever if a spec family ever collides with this one.

## Capability

A server advertises the family under `initialize`:

```json
{
  "capabilities": {
    "experimental": { "sql": { "version": 1 } }
  }
}
```

The capability appears when and only when the server opted in — it
registered at least one dataset, passed `sql: true` to `use Noizu.MCP.Server`,
or defined its own `handle_sql_*` callbacks. Servers that do not opt in are
byte-identical on the wire to servers before this family existed, and answer
`-32601` for all three methods. Clients that ignore `experimental` are
unaffected.

## Methods

### `sql/schema` → payload

Params: `{}`. Result:

```json
{
  "version": 1,
  "relations": [
    {
      "name": "tools",
      "kind": "catalog",
      "columns": [
        {"name": "name", "type": "text", "nullable": true, "description": "Tool name"}
      ],
      "primary_key": ["name"],
      "writable": false,
      "qual_columns": ["name"],
      "required_quals": [],
      "sort": false,
      "limit": true
    }
  ]
}
```

Each relation declares:

* `kind` ∈ `catalog | dataset | tool | resource | prompt` — the invoke kind
  (ADR-005);
* `qual_columns` — which columns accept pushed quals;
* `required_quals` — quals the server refuses a scan without (mirrors what
  generic-mode read-through hardcodes);
* `sort`, `limit` — whether the relation honors sort entries and limit/cursor;
* for `kind: "tool"` additionally `tool` (the invoked tool's name) and
  `read_only` (its `annotations.readOnlyHint`).

Derivation (D1 — one resolver): catalog relations read the same wire maps the
list methods emit; tool relations are derived from the *effective* toolset
catalog for the requesting principal, post-ACL (D2) — a tool the caller may
not call has no relation. Datasets are the only explicitly registered source.

Column types come from the closed vocabulary in `Noizu.MCP.SQL.Types` —
exactly what the FDW's JSON Schema → Postgres map can express:

| vocabulary member | PostgreSQL type |
|---|---|
| `:text` | `text` |
| `:bigint` | `bigint` |
| `:double` | `double precision` |
| `:boolean` | `boolean` |
| `:timestamptz` | `timestamptz` |
| `:date` | `date` |
| `:uuid` | `uuid` |
| `:jsonb` | `jsonb` |
| `{:enum, [values]}` | `text` (+ `enum` members on the wire) |

### `sql/scan`

Params: `{"relation", "quals", "columns", "sort", "limit", "cursor"}` — all
but `relation` optional. A qual is `{"column", "op", "value"}` with `op` ∈
`eq | ne | lt | lte | gt | gte | in | not_in | like | is_null | is_not_null`
(`value` omitted for the null tests, a list for `in`/`not_in`). Unknown
operators and quals outside `qual_columns` are `invalid_params`. A scan
missing a `required_quals` entry is `invalid_params`.

Result — rows are **positional** against the returned `columns` array, one
array per row:

```json
{
  "columns": ["name", "description"],
  "rows": [["echo", "Echo a message back"]],
  "nextCursor": null
}
```

Invoke semantics by kind:

* `catalog` — served from the live catalog, offset-paged by the server;
* `dataset` — delegated to the dataset's `scan/3`, which may honor or ignore
  any opts; the returned `nextCursor` is the dataset's own;
* `tool` — one `tools/call` invocation with the `eq` quals as arguments;
  structured output flattens one row per element of a single top-level
  array-of-objects, else one row; `content`/`is_error` columns always present;
* `resource` / `prompt` (read-through) — one `resources/read` / `prompts/get`
  per required qual value.

### `sql/modify`

Params: `{"relation", "op" ∈ insert|update|delete, "rows", "quals",
"changes"}`. Result: `{"rows": [...]}` for insert/update (the rows actually
written — writes are best-effort, not transactional), `{"count": n}` for
delete.

* `tool` relations: `insert` invokes the tool once per row (INSERT-driven
  invocation); other ops are refused.
* `dataset` relations: routed to the dataset's `insert/2`, `update/3`,
  `delete/2`. An op whose callback the dataset does not implement answers
  `-32601` naming the relation and the op.
* Everything else is read-only (`invalid_request`).

## Authorization

`sql/scan` never reveals what `tools/call` would deny: tool-derived relations
exist only for tools the requesting principal may call (same materialization,
same ACL pass, same existence-hiding `invalid_params`). Datasets take an ACL
subject of their own, `{:dataset, name}`; a provider that does not recognize
the subject falls to its own default, which for a configured provider is
deny. Every handler receives the request's `%Ctx{}` with its `%Principal{}` —
there is no trusted-context escape.

## Failure isolation

A dataset that raises during `scan/3` (or a write) yields `internal_error`
for that relation only; `sql/schema` and sibling relations keep working in
the same session (D5 — fail-closed per set, fail-open per server).

## The qual-honesty contract

Quals are a hint. The caller re-checks every qual locally, so a dataset MAY
ignore any of them. The one prohibition: a dataset must never return a row a
qual it *did* apply would have excluded, nor drop a row a qual it did not
apply would have kept. `scan/3` deliberately does not report which quals it
applied — the unconditional re-check keeps the contract one-directional.
`Noizu.MCP.SQL.Quals.apply/2` is the reference re-filter; the conformance
battery (`Noizu.MCP.Test.SQLConformanceCase`) asserts every served relation
against it.
