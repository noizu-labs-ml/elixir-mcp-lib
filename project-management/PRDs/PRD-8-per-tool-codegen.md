# PRD-8: Per-Tool Tables, Functions, Views & Type Mapping

**Series**: pg_mcp — MCP servers as Postgres structures (PRD-8 of 6)
**Repo**: `Portfolio/Libs/ai/elixir-mcp` — subproject `pg/pg_mcp/` (Rust/pgrx)
**Version policy**: no `mix.exs` bump (single `0.4.0` bump in PRD-11). Crate version → `0.3.0`.
**Depends on**: PRD-7 (catalog tables, `tool_calls`, import); PRD-11 (the engine, whose namespaced tools are the primary generation input). PRD-6 §7.5 S4 determines whether SELECT-invocation ships at all.
**Date**: 2026-09-05 · **Author**: npl-prd-editor (Loom weave)
**Status**: Draft

---

## 1. Goal

Turn each individual MCP tool into a first-class, **typed** SQL object, so a person or an agent writing SQL gets column names, types, autocomplete and planner-visible predicates instead of hand-assembled `jsonb`.

Deliverables:

1. A normative JSON Schema → PostgreSQL type map (§4.1).
2. A per-tool foreign table `tool_<name>` whose input properties are quals and whose output-schema properties are columns.
3. A safety gate: SELECT-invocation only for tools the server declares `readOnlyHint: true`, or under an explicit `invoke_on_select = 'all'` import option; every other tool's table is INSERT-only.
4. A typed SQL function per tool, `schema.<name>(...)`.
5. A flattened view `v_tool_<name>` per tool.
6. Identifier rules — snake_case derivation, quoting, 63-byte truncation with a hash suffix, collision handling.
7. `mcp.generate_functions(server, schema)`, regeneration on `refresh`/`import`, and `notifications/tools/list_changed` handling.

**Explicitly OUT of scope**: the `sql/*` experimental methods and Dataset DSL (PRD-9); packaging, CI and e2e (PRD-10).

---

## 2. Decision log applied to this PRD

| ADR / rule | How it binds this PRD |
|---|---|
| **ADR-003** SQL projection model | Per-tool objects are a *projection* of `mcp.tools`, generated from the schemas the server publishes. They add no capability the generic surface lacks; they add ergonomics and types. `readOnlyHint` is the gate for SELECT-invocation, exactly as ADR-003 states. |
| **ADR-007** engine federation | The **primary** generation input is `Noizu.MCP.Engine`'s catalog, whose tool names are `<upstream>.<tool>`. Generation against the engine therefore produces **one schema per upstream** — `github.create_issue` becomes `github.tool_create_issue` and `github.create_issue(...)`, not a flattened `tool_github_create_issue` in one schema. The upstream prefix is consumed as the target schema name and stripped before §4.5's identifier derivation runs on the remainder. Generic-mode generation against a single non-engine server is unchanged: no prefix, one schema. |
| **ADR-002** pgrx + wrappers | Generated foreign tables are ordinary `mcp_fdw` tables distinguished by a table option (`tool 'name'`); the same `ForeignDataWrapper` serves them. Generated SQL functions are emitted with SPI at generation time, not `#[pg_extern]` — they are per-database artifacts, not extension objects. |
| **ADR-004** identity | Generation runs as the invoking role and uses that role's `USER MAPPING`. Two roles may legitimately generate different function sets from the same server. Generated objects are ordinary Postgres objects governed by ordinary `GRANT`s; the extension issues no `GRANT` of its own. |
| **D1 one resolver** | The type map and column set derive from `tools/list` output — the same source `mcp.tools` reads. There is no second schema store. Regeneration re-reads; it never patches. |
| **D2 effective materialization** | Generation consumes the *effective* tool definitions the server returns for the generating principal, post-ACL and post-override. A tool the principal cannot see generates nothing. |
| **D5 fail-closed per table, fail-open per server** | A tool whose input or output schema cannot be mapped is **skipped with a warning**, not fatal to generation. `mcp.generate_functions` returns the count generated and the list skipped. |

---

## 3. Background

PRD-7 gives `INSERT INTO mcp.tool_calls (tool, arguments) VALUES ('search_docs', '{"query":"x","limit":10}') RETURNING structured`. That works, and it is what every tool falls back to. It is also untyped: a typo in `"limit"` is discovered at runtime by the MCP server, the result is opaque `jsonb`, and nothing in the database tells a BI tool or an LLM what arguments exist.

MCP tools carry the information needed to do better. `inputSchema` is a required JSON Schema object; `outputSchema` is optional but increasingly present. In the Noizu library both are generated from the field DSL at `lib/noizu/mcp/server/tool/fields.ex`, whose declared types are `:string`, `:integer`, `:number`, `:boolean` (`fields.ex:16`), plus `:enum` with `values:` (`fields.ex:150`), `:object` with nested fields (`fields.ex:151`), and `{:array, inner}` including `{:array, :object}` (`fields.ex:133`, `:161`). That is a small, closed vocabulary that maps cleanly onto Postgres types, which is why a mechanical map is viable rather than a heuristic.

The hazard is invocation-on-SELECT. A `SELECT * FROM tool_send_email WHERE to='x'` reads like a query and executes like a side effect, and Postgres will happily evaluate it twice in a nested loop. The MCP spec already carries the annotation that resolves this: `annotations.readOnlyHint`. Gating SELECT-invocation on the *server's own* declaration means the decision is made by the party that knows, and the default for an unannotated tool is the safe one.

---

## 4. Public surface

### 4.1 JSON Schema → PostgreSQL type map (normative)

| JSON Schema | Postgres type |
|---|---|
| `"type":"string"` | `text` |
| `"type":"string","format":"date-time"` | `timestamptz` |
| `"type":"string","format":"date"` | `date` |
| `"type":"string","format":"uuid"` | `uuid` |
| `"type":"string","enum":[…]` | `text` (values documented in the column comment; no PG enum type is created) |
| `"type":"integer"` | `bigint` |
| `"type":"number"` | `double precision` |
| `"type":"boolean"` | `boolean` |
| `"type":"object"` | `jsonb` |
| `"type":"array"` | `jsonb` |
| `"type":["string","null"]` / union | the non-null branch if exactly one, else `jsonb` |
| `$ref`, `oneOf`, `anyOf`, `allOf`, absent `type` | `jsonb` |

Rules:

- Every column is **nullable** unless the property is listed in the schema's `required` array. Required columns are still nullable in the table definition (an FDW cannot enforce NOT NULL usefully); requiredness surfaces as `NOT NULL` on the **function** parameter, which has no `DEFAULT`.
- Unrecognized `format` values are ignored; the base type applies.
- No PostgreSQL enum types are created. Enums are `text` with a comment listing the permitted values, because a server can change its enum between refreshes and a PG enum cannot shrink.
- Arrays map to `jsonb`, not to PG arrays, because JSON Schema arrays are heterogeneous in general and `jsonb` round-trips losslessly. `{"type":"array","items":{"type":"string"}}` is a tempting `text[]`; it is deliberately not taken, for one reason: a `NULL` element and a JSON `null` element are distinguishable in `jsonb` and not in `text[]`.

### 4.2 Per-tool foreign table

For tool `search_docs` with input `{query: string (required), limit: integer, since: string/date-time}` and output `{results: array of {id: string, score: number}}`:

```sql
CREATE FOREIGN TABLE npl.tool_search_docs (
  -- input properties, usable only as quals
  query    text,
  "limit"  bigint,
  since    timestamptz,
  -- output-schema columns
  id       text,
  score    double precision,
  -- always present
  content  jsonb,
  is_error boolean
) SERVER npl OPTIONS (tool 'search_docs', invoke_on_select 'true');
```

**Input columns are quals only.** A value supplied in `WHERE` becomes an entry in the `arguments` object. Input columns always read back as the value that was supplied (echoed), so `SELECT query FROM tool_search_docs WHERE query='x'` returns `x`. An input column referenced without an equality qual is `NULL` and contributes nothing to `arguments`. A required input with no qual raises `22023` naming the argument.

**Output columns.** Row shape depends on the output schema's top level:

- Top-level property that is an **array of objects**, and it is the only such property → **one row per element**, with that element's properties as columns. In the example, `results` is the array, so `id` and `score` become columns and a 5-result call yields 5 rows.
- Anything else (scalar properties, nested objects, multiple arrays) → **one row**, with each top-level property mapped per §4.1.
- No `outputSchema` at all → one row, columns `content` and `is_error` only.
- `content jsonb` and `is_error boolean` are appended in every case and carry the raw `CallToolResult` content and error flag. On `is_error = true`, output columns are `NULL` and the row is still returned (consistent with PRD-7 §4.7).

**Invocation gate (normative).** The table's `invoke_on_select` option is set at generation time:

| Server declares | Import option | `invoke_on_select` | SELECT behavior |
|---|---|---|---|
| `readOnlyHint: true` | default | `true` | SELECT invokes the tool |
| `readOnlyHint` false/absent | default | `false` | SELECT raises `0A000`: `tool <name> is not read-only; INSERT into <schema>.tool_<name> instead` |
| any | `invoke_on_select 'all'` | `true` | SELECT invokes; a `WARNING` is emitted at generation time listing the non-read-only tools so promoted |
| any | `invoke_on_select 'none'` | `false` | all tables INSERT-only |

`INSERT INTO tool_<name> (query, "limit") VALUES (...) RETURNING id, score` always works, for every tool, regardless of the gate. It is the universal path; SELECT is the ergonomic one.

`UPDATE`/`DELETE` raise `0A000`.

### 4.3 Typed SQL function per tool

```sql
-- returns SETOF when the output schema produces multiple rows (§4.2), else jsonb
CREATE FUNCTION npl.search_docs(query text, "limit" bigint DEFAULT NULL, since timestamptz DEFAULT NULL)
  RETURNS TABLE (id text, score double precision)
  LANGUAGE sql VOLATILE PARALLEL UNSAFE
AS $$ SELECT id, score FROM npl.tool_search_docs WHERE query = $1 AND ("limit" = $2 OR $2 IS NULL) ... $$;
```

Normative rules:

- Parameter order: required properties first in schema `required` order, then optional properties in schema property order. Required parameters have no `DEFAULT`; optional ones default to `NULL`.
- Return type: `RETURNS TABLE (…)` when §4.2 yields multiple rows, `RETURNS jsonb` (the whole `CallToolResult`) otherwise.
- The generated body inserts into `tool_<name>` and returns `RETURNING` when the tool is not read-only, and selects when it is — so the function is safe for every tool without the caller needing to know which.
- Marked `VOLATILE PARALLEL UNSAFE` unconditionally, including for read-only tools, because the call performs network I/O.
- A `COMMENT ON FUNCTION` carries the tool's `title` and `description`, so `\df+` and every BI tool's object browser show it.

### 4.4 Flattened view

```sql
CREATE VIEW npl.v_tool_search_docs AS
  SELECT id, score, content, is_error FROM npl.tool_search_docs;
```

The view exists to give a stable, output-only projection for read-only tools whose input arguments are all optional — a common shape for "list the things" tools, where `SELECT * FROM v_tool_list_projects` is the whole story. Views are generated **only** for tools with `invoke_on_select = true` and no required inputs. For every other tool the view would be a trap and is not created.

### 4.5 Identifier rules (normative)

Applied to tool names, property names, and the derived table/function/view/column names:

1. **Derive**: lowercase; replace every character outside `[a-z0-9_]` with `_`; collapse runs of `_`; strip leading/trailing `_`. `camelCase` and `PascalCase` are split on case boundaries first (`searchDocs` → `search_docs`).
2. **Leading digit**: prefix `_` (`2fa_check` → `_2fa_check`).
3. **Reserved words**: any name matching a Postgres reserved keyword is emitted **quoted** rather than renamed (`limit` → `"limit"`), so the SQL name still matches the MCP name.
4. **Length**: names longer than 63 bytes are truncated to 55 bytes and suffixed with `_` plus the first 7 hex characters of a SHA-256 of the *original* name. Deterministic across runs and machines.
5. **Collision**: if two distinct MCP names derive to the same SQL name, the second and subsequent get `_` plus 7 hex characters of their original name's SHA-256, applied after truncation if needed. A `WARNING` names both.
6. **Prefix**: the `prefix` import option (default empty) is prepended to table/function/view names before rule 4, so `prefix 'npl_'` gives `npl_tool_search_docs`.
7. The **table option** `tool` always carries the *original* MCP name, unmangled. The mapping is recoverable: `SELECT ftoptions FROM pg_foreign_table`.

### 4.6 Generation entry points

```sql
-- Generate (or regenerate) per-tool objects for a server into a schema.
-- Returns (generated int, skipped int, skipped_tools text[]).
CREATE FUNCTION mcp.generate_functions(server text, schema text)
  RETURNS TABLE (generated integer, skipped integer, skipped_tools text[]) VOLATILE;
```

And, as an import option on PRD-7 §4.11's statement:

```sql
IMPORT FOREIGN SCHEMA mcp FROM SERVER npl INTO npl
  OPTIONS (per_tool 'true', invoke_on_select 'read_only', prefix '');
```

| Import option | Values | Default |
|---|---|---|
| `per_tool` | `true` \| `false` | `false` |
| `invoke_on_select` | `read_only` \| `all` \| `none` | `read_only` |
| `prefix` | identifier fragment | `''` |
| `per_upstream_schema` | `true` \| `false` — against an engine, generate each upstream's objects into its own schema named for the `engine.servers` row, stripping the prefix from object names | `true` when the server is an engine, else `false` |

**Regeneration semantics.** `mcp.generate_functions` is idempotent and destructive-in-scope: it drops and recreates only the objects it previously created in that schema, identified by an extension-owned bookkeeping table `mcp.generated` `(server text, schema text, kind text, name text, tool text, generated_at timestamptz, primary key (schema, name))`. It never touches an object it does not own. A tool that disappeared from the server has its objects dropped; a tool whose schema changed has its objects recreated. Objects are dropped with `DROP … RESTRICT`, so a user view depending on a generated table blocks the drop with a clear error rather than cascading.

`mcp.refresh(server)` drops caches and sessions (PRD-6 §4.4, PRD-7 §4.10). It does **not** regenerate — regeneration issues DDL and must be an explicit act. `mcp.refresh` returns `true` and, when generated objects exist for that server whose source schemas have changed, emits a `NOTICE` telling the operator to re-run `mcp.generate_functions`.

**`notifications/tools/list_changed`.** When observed (PRD-7 §4.10), the tool cache is dropped and, if generated objects exist for that server, a `WARNING` is logged: `tool list changed on server <s>; generated objects in <schema> are stale`. Automatic DDL from a server notification is deliberately not done — a remote party must not be able to make a Postgres database issue DDL.

---

## 5. Requirements

**FR-8.1** The §4.1 type map is implemented exactly, including nullability and the union/`$ref` fallbacks.
**FR-8.2** For each tool, a `tool_<name>` foreign table is created with input columns, output columns per §4.2, plus `content` and `is_error`.
**FR-8.3** Input columns act as quals contributing to `arguments`, and echo back their supplied values.
**FR-8.4** A missing required input raises `22023` naming the argument.
**FR-8.5** A single top-level array-of-objects output property yields one row per element; every other shape yields one row.
**FR-8.6** SELECT-invocation happens only when `invoke_on_select` is `true` per §4.2's table; otherwise SELECT raises `0A000` with the INSERT hint.
**FR-8.7** `invoke_on_select 'all'` emits a generation-time `WARNING` listing every non-read-only tool promoted.
**FR-8.8** `INSERT … RETURNING` works on every per-tool table regardless of the gate.
**FR-8.9** A typed function per tool exists per §4.3, with the stated parameter order, defaults, return type, volatility and comment.
**FR-8.10** `v_tool_<name>` is created only for read-only tools with no required inputs.
**FR-8.11** Identifier rules §4.5 are implemented, deterministic across runs, with warnings on collision and truncation.
**FR-8.12** `mcp.generate_functions(server, schema)` returns `(generated, skipped, skipped_tools)` and skips unmappable tools without failing.
**FR-8.13** Regeneration drops and recreates only extension-owned objects recorded in `mcp.generated`, using `RESTRICT`.
**FR-8.14** `IMPORT FOREIGN SCHEMA … OPTIONS (per_tool 'true')` generates per-tool objects alongside the PRD-7 generic tables.
**FR-8.15** `notifications/tools/list_changed` never triggers DDL; it drops the cache and warns.
**FR-8.16** Generation uses the invoking role's `USER MAPPING`; a tool invisible to that principal generates nothing.
**FR-8.17** Against an engine, `per_upstream_schema` routes each upstream's generated objects into a schema named for its `engine.servers` row, with the `<upstream>.` prefix stripped before §4.5 derivation; `mcp.generated` records the upstream so regeneration is scoped per upstream.
**FR-8.18** Attaching or detaching an upstream does not itself issue DDL; `mcp.generate_functions` must be re-run, and `mcp.refresh` emits the staleness NOTICE naming the changed upstream.

**Acceptance criteria**

**AC-8.1** For a fixture tool declaring one field of each `fields.ex` type (`:string`, `:integer`, `:number`, `:boolean`, `:enum`, `:object`, `{:array, :string}`, `{:array, :object}`), the generated table's column types match §4.1 exactly.
**AC-8.2** `format: date-time`, `date` and `uuid` string fields generate `timestamptz`, `date` and `uuid` columns and round-trip values correctly.
**AC-8.3** `SELECT * FROM tool_<read_only_tool> WHERE query='x'` returns rows; the same statement on a non-read-only tool raises `0A000` mentioning INSERT.
**AC-8.4** `INSERT INTO tool_<non_read_only> (…) VALUES (…) RETURNING …` succeeds.
**AC-8.5** A tool whose output schema has a single array-of-objects property returns N rows for an N-element result; a scalar-output tool returns exactly 1.
**AC-8.6** `is_error = true` yields one row with NULL output columns and populated `content`.
**AC-8.7** A tool named `limit` generates `"limit"`-quoted objects that are queryable.
**AC-8.8** A 70-character tool name generates a 63-byte identifier ending in `_` + 7 hex chars, identical across two runs and two machines.
**AC-8.9** Two tools deriving the same SQL name both generate, with a warning, and both are independently callable.
**AC-8.10** Removing a tool server-side and re-running `generate_functions` drops exactly that tool's three objects and nothing else.
**AC-8.11** A user view depending on a generated table causes regeneration to fail with a `RESTRICT` violation naming the dependent object; nothing is left half-dropped.
**AC-8.12** `\df npl.*` in psql shows every generated function with its description; `\d npl.tool_search_docs` shows typed columns.
**AC-8.13** A tool with an unmappable schema (a `$ref` cycle) is reported in `skipped_tools`; every other tool still generates.
**AC-8.15** Against an engine with two upstreams, generation creates `github.create_issue(...)` and `slack.post_message(...)` in two schemas, with no name carrying a redundant upstream prefix.
**AC-8.16** Detaching one upstream and re-running `mcp.generate_functions` drops exactly that upstream's schema objects and leaves the other upstream's untouched.
**AC-8.14** `cargo pgrx test` green on pg16, pg17, pg18.

---

## 6. Internal work checklist (with anchors)

| Step | File | Anchor / detail |
|---|---|---|
| 8.1 | `pg/pg_mcp/src/types.rs` | new; §4.1 map |
| 8.2 | `pg/pg_mcp/src/ident.rs` | new; §4.5 rules incl. SHA-256 suffixing and the reserved-word list |
| 8.3 | `pg/pg_mcp/src/codegen/table.rs` | per-tool `CREATE FOREIGN TABLE` emission + `tool`/`invoke_on_select` table options |
| 8.4 | `pg/pg_mcp/src/codegen/function.rs` | §4.3 function emission + `COMMENT ON FUNCTION` |
| 8.5 | `pg/pg_mcp/src/codegen/view.rs` | §4.4, gated |
| 8.6 | `pg/pg_mcp/src/codegen/registry.rs` | `mcp.generated` bookkeeping; drop-and-recreate with `RESTRICT` |
| 8.7 | `pg/pg_mcp/src/tables/per_tool.rs` | scan/insert for per-tool tables; row-shaping per §4.2 |
| 8.8 | `pg/pg_mcp/src/import.rs` | extend PRD-7 §4.11 with `per_tool`, `invoke_on_select`, `prefix` |
| 8.9 | `pg/pg_mcp/src/api.rs` | `mcp.generate_functions/2`; `mcp.refresh/1` NOTICE on staleness |
| 8.10 | `pg/pg_mcp/src/cache.rs` | list_changed → drop + WARNING (no DDL) |
| 8.11 | `pg/pg_mcp/sql/pg_mcp--0.2.0--0.3.0.sql` | upgrade script adding `mcp.generated` and `mcp.generate_functions` |
| 8.12 | Elixir side | **no change.** Field-DSL types consumed as published: `lib/noizu/mcp/server/tool/fields.ex:16` (scalars), `:133` (arrays), `:150-163` (enum/object/array validation). |

---

## 7. Test plan

### 7.1 Rust unit

- `types_test` — the whole §4.1 table plus union, `$ref`, missing-`type`, unknown-`format`, and `required` interaction.
- `ident_test` — derivation, leading digits, reserved words, 63-byte truncation determinism (fixed vectors), collision suffixing, `prefix` interaction. Includes a property test over random Unicode names asserting the output is always a valid, ≤63-byte Postgres identifier.
- `rowshape_test` — the §4.2 output-shape decision over a matrix of output schemas.

### 7.2 SQL-level (`cargo pgrx test pg17`)

Every AC in §5. Generation runs against the in-crate HTTP stub serving a synthetic `tools/list` with a deliberately hostile tool set: reserved-word names, 70-character names, colliding names, a `$ref` cycle, a tool with no `outputSchema`, a tool with two array properties.

### 7.3 Anti-pattern regression tests

- **AP-P5 (silent side effects):** for every generated table with `invoke_on_select = false`, a `SELECT` issues zero `tools/call` requests and raises. Asserted by stub hit-count.
- **AP-P6 (remote-triggered DDL):** a `notifications/tools/list_changed` from the stub produces zero DDL statements. Asserted by an event trigger counting `ddl_command_end` around the notification.
- **AP-P7 (parallel registry):** `mcp.generated` records only names and provenance — never a copy of a tool's schema. Regeneration always re-reads from the server. Asserted by mutating the stub's schema and confirming the regenerated column types follow.
- **AP-P8 (privilege escalation by generation):** the extension issues no `GRANT`. A generated object is visible to other roles only through ordinary Postgres privileges on the schema. Asserted by generating as role A and confirming role B gets `42501` until granted.

### 7.4 Cross-role

Generate as role A (broad principal) and role B (narrow principal) into two schemas from the same server; assert B's schema contains a strict subset, and that B invoking A's generated table still gets B's own principal server-side (the table option carries the tool name, not a credential).

---

## 8. Compat & rollback

- **Additive.** PRD-7's nine tables are unchanged; a database imported under PRD-7 keeps working. `per_tool` defaults to `false`, so an existing `IMPORT` statement re-run produces the same result as before.
- Extension upgrade path is a normal pgrx `--0.2.0--0.3.0.sql` script; `ALTER EXTENSION pg_mcp UPDATE` adds `mcp.generated` and `mcp.generate_functions` and nothing else.
- **Rollback**: `mcp.generate_functions` can be reversed by dropping the target schema, or by an operator dropping the rows' named objects listed in `mcp.generated`. Downgrading the extension is not supported (standard for pgrx); rollback is `DROP EXTENSION … CASCADE` plus reinstall of the prior version.
- **Risk watch**: generated objects are per-database DDL created by a function call. In a GitOps environment that is untracked drift. The PRD-10 runbook prescribes checking the `generate_functions` call into a migration (Liquibase, per the monorepo convention) rather than running it by hand.
- **Risk watch**: `invoke_on_select 'all'` is a foot-gun by construction. It warns loudly at generation and is named in the runbook's "do not do this in production" section.

---

## 9. Open questions

1. **Q1 (blocking):** If PRD-6 §7.5 **S4** (latency) fails, SELECT-invocation is dropped entirely and `invoke_on_select` disappears from this PRD. Confirm the fallback: per-tool tables become INSERT-only, functions still generate, views are dropped from scope.
2. **Q2:** `{"type":"array","items":{"type":"string"}}` → `jsonb` rather than `text[]`. The reasoning is null-distinguishability (§4.1). A `text[]` would be markedly friendlier for the common case. Lead's call; changing it later is a breaking column-type change, so decide before 0.4.0.
3. **Q3:** Enums as `text` + comment rather than PG enum types. Confirm. The alternative creates a type per enum per tool, which regeneration cannot shrink.
4. **Q4:** Should `mcp.generate_functions` require a specific privilege beyond `CREATE` on the target schema? It issues DDL as the caller, so Postgres already gates it, but an explicit `pg_mcp_generator` role would let operators separate "can query MCP" from "can create objects".
5. **Q5:** Function naming — `npl.search_docs(...)` collides with an application function of the same name in a shared schema. The `prefix` option covers it, but the default is empty. Should the default prefix be `mcp_`? Recommend yes for safety, no for ergonomics; lead decides.
6. **Q6 (blocking, shared with PRD-7 Q6a and PRD-11 Q1):** Per-upstream schema versus one flat schema. The spec above splits by upstream, which reads far better in psql and in a BI object browser, and matches PRD-11's namespacing. The cost is that a tool moving between upstreams changes its SQL name. Confirm the split.
7. **Q7:** Multiple array-of-objects properties in one output schema currently collapse to a single row with `jsonb` columns. An alternative is to pick the property named in a `x-primary` extension or the first one. Recommend the conservative collapse for 0.4.0.
