# PRD-7: `mcp_fdw` Catalog Tables, `tool_calls`, and Generic `IMPORT FOREIGN SCHEMA`

**Series**: pg_mcp — MCP servers as Postgres structures (PRD-7 of 6)
**Repo**: `Portfolio/Libs/ai/elixir-mcp` — subproject `pg/pg_mcp/` (Rust/pgrx)
**Version policy**: no `mix.exs` bump (single `0.4.0` bump in PRD-11). Crate version → `0.2.0`.
**Depends on**: PRD-6 (client, session, options, error base) — and on PRD-6 §7.5 S1+S3 passing. Sequenced after PRD-9 and PRD-11, whose engine is this PRD's primary target.
**Date**: 2026-09-05 · **Author**: npl-prd-editor (Loom weave)
**Status**: Draft

---

## 1. Goal

Make an MCP server's surface queryable as ordinary SQL relations, and make tool invocation an ordinary SQL write, using only generic MCP methods — no per-server code generation (that is PRD-8).

Deliverables:

1. A full `ForeignDataWrapper` implementation over the PRD-6 client, with quals/limit pushdown.
2. Nine foreign tables: `server`, `tools`, `prompts`, `prompt_arguments`, `resources`, `resource_templates`, `resource_contents`, `prompt_messages`, `completions`.
3. `tool_calls` — a foreign table where `INSERT … RETURNING` performs `tools/call` and `SELECT` returns this backend's call log, with an optional durable local audit table.
4. A catalog cache with TTL, invalidated by `mcp.refresh/1` and by `notifications/tools/list_changed`.
5. Complete MCP-error → SQLSTATE mapping, including the "tool `isError` becomes a row, never an exception" rule.
6. `IMPORT FOREIGN SCHEMA mcp FROM SERVER s INTO <schema>` creating all of the above in one statement.

**Explicitly OUT of scope**: per-tool tables/functions/views and JSON-Schema type mapping (PRD-8); the `sql/*` experimental methods and Dataset DSL that let a server project its own relations (PRD-9); packaging and e2e (PRD-10).

---

## 2. Decision log applied to this PRD

| ADR / rule | How it binds this PRD |
|---|---|
| **ADR-007** engine federation | The **primary** foreign server is `Noizu.MCP.Engine` (PRD-11), whose catalog is the namespaced union of its upstreams. Everything in this PRD is written against generic MCP methods and therefore works against any server — generic mode is retained and is the fallback — but the tables an operator actually creates are usually the engine's. `mcp.tools` against the engine returns `<upstream>.<tool>` names; `tool_calls` inserts route through it. §4.11's import produces one schema per upstream when `all_upstreams` is set. |
| **ADR-002** `supabase-wrappers` as a library | `begin_scan/iter_scan/re_scan/end_scan`, `begin_modify/insert/end_modify` and `import_foreign_schema` come from the crate's `ForeignDataWrapper` trait. Quals arrive already normalized as `Qual { field, operator, value, use_or }`; we consume `=`, `= ANY`, `IN`, and nothing else (§4.8). |
| **ADR-003** SQL projection model | Catalog tables mirror MCP list methods one-for-one. Invocation is an INSERT into `tool_calls`. Read-through tables (`resource_contents`, `prompt_messages`, `completions`) require a qual and are capped otherwise. |
| **ADR-004** identity | Every scan and every insert resolves the token from `USER MAPPING` for the *current* user (PRD-6 §4.3). Two roles querying the same foreign table see the tool sets their own principals are entitled to. No row is served from another role's cached catalog: the cache key includes the user OID. |
| **ADR-005** FDW mode | `mode 'generic'` (and `auto` falling back to generic) is what this PRD implements. `mode 'sql'` tables arrive in PRD-9. |
| **D1 one resolver** | The catalog tables are projections of `tools/list`, `prompts/list`, `resources/list`, `resources/templates/list` — never a parallel registry maintained in Postgres. There is exactly one source of truth: the MCP server. |
| **D5 fail-closed per table, fail-open per server** | A table whose backing method the server does not implement (`-32601`) is **empty**, not an error, and other tables on the same server keep working. A genuine transport failure raises for that statement only. |

---

## 3. Background

PRD-6 proved a backend can hold an MCP session and call methods. What it does not give is anything a BI tool, a `JOIN`, or an agent writing SQL can use: every interaction is a function call returning opaque `jsonb`.

MCP's list methods are already table-shaped. `tools/list` returns wire structs matching `lib/noizu/mcp/types/tool.ex:36`; `prompts/list` and `resources/list` are served by `lib/noizu/mcp/server/features/prompts.ex:17` and `features/resources.ex:24` with cursor pagination through `features/pagination.ex`. `resources/read` (`features/resources.ex:128`), `prompts/get` (`features/prompts.ex:58`) and `completion/complete` (`features/completion.ex:13`) are keyed lookups — natural read-through tables with a required qual.

The one genuinely awkward fit is `tools/call`. A `SELECT` that invokes side effects is wrong: the planner may call it zero, one, or many times, and Postgres offers no way to promise otherwise. The chosen shape — `INSERT INTO tool_calls (tool, arguments) VALUES (...) RETURNING content` — puts invocation exactly where SQL already expects effects, executes exactly once per row, and gives `RETURNING` as the result channel. PRD-8 layers a narrow, opt-in SELECT path on top for tools the *server itself* declares read-only (`annotations.readOnlyHint`), which is the only case where the planner's freedom is harmless.

---

## 4. Public surface

### 4.1 `server` — one row, server identity

| Column | Type | Source |
|---|---|---|
| `name` | text | foreign server name |
| `url` | text | server option |
| `protocol_version` | text | negotiated `initialize` result |
| `server_name` | text | `serverInfo.name` |
| `server_version` | text | `serverInfo.version` |
| `instructions` | text | `initialize` result `instructions` |
| `capabilities` | jsonb | `initialize` result `capabilities` |
| `mode` | text | resolved mode (`generic` or `sql`) after `auto` probing |
| `session_id` | text | current `Mcp-Session-Id` for this backend, or NULL |

Exactly one row. No quals pushed. Costs nothing beyond the already-established handshake.

### 4.2 `tools`

| Column | Type | Source |
|---|---|---|
| `name` | text | `tools/list[].name` |
| `title` | text | `.title` |
| `description` | text | `.description` |
| `input_schema` | jsonb | `.inputSchema` |
| `output_schema` | jsonb | `.outputSchema` |
| `annotations` | jsonb | `.annotations` |
| `read_only` | boolean | `.annotations.readOnlyHint`, NULL when absent |
| `destructive` | boolean | `.annotations.destructiveHint` |
| `idempotent` | boolean | `.annotations.idempotentHint` |
| `open_world` | boolean | `.annotations.openWorldHint` |
| `meta` | jsonb | `._meta` |

`name = 'x'` and `name = ANY(...)` are pushed down as a post-fetch filter (MCP has no server-side name filter on `tools/list`); the full list is fetched once per cache period regardless, so pushdown here is a row-count optimization only. Pagination cursors are followed transparently until exhausted.

### 4.3 `prompts` / `prompt_arguments`

`prompts`: `name, title, description, meta jsonb`.
`prompt_arguments`: `prompt text, name text, description text, required boolean, idx int` — the flattened `.arguments[]` of each prompt. A `prompt = 'x'` qual filters after fetch.

### 4.4 `resources` / `resource_templates` / `resource_contents`

`resources`: `uri, name, title, description, mime_type, size bigint, annotations jsonb, meta jsonb`.
`resource_templates`: `uri_template, name, title, description, mime_type, annotations jsonb, meta jsonb`.

`resource_contents` is a **read-through** table:

| Column | Type |
|---|---|
| `uri` | text |
| `idx` | int (index within the `contents` array; ADR-003's name, not `position`, which reads as a reserved word in several clients) |
| `mime_type` | text |
| `text` | text (NULL for blobs) |
| `blob` | bytea (NULL for text) |
| `meta` | jsonb |

Qual rules, normative:

- `uri = '...'` or `uri = ANY(ARRAY[...])` or `uri IN (...)` → one `resources/read` per distinct URI, results unioned.
- No `uri` qual → the table falls back to reading every URI returned by `resources/list`, **capped by the server option `max_unqualified_reads`**. With the default `0`, an unqualified scan raises `0A000` with the message `unqualified scan of mcp.resource_contents requires a uri qual or max_unqualified_reads > 0`.
- Reads exceeding the cap raise `54023` (`too_many_arguments`) naming the cap.

### 4.5 `prompt_messages` — read-through `prompts/get`

| Column | Type |
|---|---|
| `prompt` | text (**qual required**) |
| `arguments` | jsonb (optional qual; defaults to `{}`) |
| `idx` | int |
| `role` | text |
| `content_type` | text (`text`, `image`, `audio`, `resource`) |
| `text` | text |
| `content` | jsonb (full content block) |
| `description` | text (the prompt's own description from the `prompts/get` result) |

Without a `prompt` qual the scan raises `0A000` (`mcp.prompt_messages requires a prompt = '...' qual`). `arguments` is matched as an equality qual on a `jsonb` literal, e.g. `WHERE prompt = 'summarize' AND arguments = '{"style":"terse"}'`.

### 4.6 `completions` — read-through `completion/complete`

| Column | Type |
|---|---|
| `ref` | jsonb (**qual required**; e.g. `'{"type":"ref/prompt","name":"summarize"}'`) |
| `argument_name` | text (**qual required**) |
| `argument_value` | text (**qual required**, `''` for "all") |
| `value` | text (one row per completion candidate) |
| `idx` | int |
| `total` | int |
| `has_more` | boolean |

All three quals required; any missing one raises `0A000` naming the missing column.

### 4.7 `tool_calls` — invocation and log

```sql
CREATE FOREIGN TABLE mcp.tool_calls (
  id          uuid,           -- generated by the extension, returned via RETURNING
  tool        text,           -- NOT NULL on insert
  arguments   jsonb,          -- default '{}'
  content     jsonb,          -- CallToolResult.content
  structured  jsonb,          -- CallToolResult.structuredContent
  is_error    boolean,        -- CallToolResult.isError
  error       jsonb,          -- JSON-RPC error object for protocol-level failures
  called_at   timestamptz,
  duration_ms integer
) SERVER npl;
```

**INSERT semantics (normative).** `INSERT INTO mcp.tool_calls (tool, arguments) VALUES ($1, $2) RETURNING content, structured, is_error` performs exactly one `tools/call` per inserted row, in row order, and fills every output column in the returned tuple. Columns other than `tool` and `arguments` are ignored on input (supplying them is not an error; they are overwritten). `tool` NULL raises `23502`.

**A tool that reports failure is a row, not an exception.** `isError: true` yields a normal returned tuple with `is_error = true`, `content` carrying the tool's own error content, and `error = NULL`. This is the single most important behavioral rule in the table: it lets a caller write `INSERT … RETURNING is_error, content` and branch in SQL, and it lets a multi-row insert survive one failing tool. Protocol-level failures (`-32602`, `-32601`, transport) do raise, per §4.9.

**SELECT semantics.** A `SELECT` on `tool_calls` returns this backend's in-memory call log for this foreign server — the calls this session made, newest first, capped at 1000 entries. It performs no network I/O and invokes nothing. `tool = '...'` and `id = '...'` quals are pushed into the log filter. When `audit_table` is set on the server, the log is *also* appended to that local table (§4.8) and `SELECT` still reads the in-memory log — the audit table is queried as an ordinary local table by name.

`UPDATE` and `DELETE` on `tool_calls` raise `0A000`. They arrive, if ever, with a separate ADR.

### 4.8 Optional local audit table

When `audit_table 'schema.table'` is set, each completed call is inserted there with `SPI` in the same transaction as the foreign INSERT, so a rollback discards the audit row along with the caller's work. Expected shape:

```sql
CREATE TABLE mcp_audit.tool_calls (
  id uuid PRIMARY KEY, server text NOT NULL, role_name name NOT NULL,
  tool text NOT NULL, arguments jsonb, content jsonb, structured jsonb,
  is_error boolean, error jsonb, called_at timestamptz, duration_ms integer
);
```

A shape mismatch raises `42804` at first write, naming the column. The extension never creates the table — an operator does, with whatever RLS, retention and partitioning they want.

### 4.9 Error mapping (complete)

| Condition | SQLSTATE | Symbolic |
|---|---|---|
| `-32602` invalid params | `22023` | invalid_parameter_value |
| `-32601` method not found, on a **read-through** call | `0A000` | feature_not_supported |
| `-32601` on a **list** method backing a catalog table | *(no error)* | table scans as empty (D5) |
| `-32600` invalid request / `-32700` parse error | `XX000` | internal_error, with the raw payload |
| `-32603` internal error | `XX000` | internal_error |
| HTTP 401/403 or verifier rejection | `42501` | insufficient_privilege |
| Transport: connect, read, TLS, DNS, malformed frame | `08006` | connection_failure |
| Unqualified read-through scan with cap 0 | `0A000` | feature_not_supported |
| Read-through fan-out exceeding cap | `54023` | too_many_arguments |
| Missing required qual | `0A000` | feature_not_supported |
| `tool` NULL on insert | `23502` | not_null_violation |
| `UPDATE`/`DELETE` on `tool_calls` | `0A000` | feature_not_supported |
| Tool result `isError: true` | *(no error)* | row with `is_error = true` |
| Audit table shape mismatch | `42804` | datatype_mismatch |

Every raised error carries `errdetail` naming the foreign server and the MCP method, and never the token (PRD-6 FR-6.11).

### 4.10 Catalog cache

One cache per `(backend, server OID, user OID)`, holding the parsed results of `tools/list`, `prompts/list`, `resources/list`, `resources/templates/list` and the `initialize` result.

- TTL default **60 seconds**, overridable per server with `cache_ttl_ms` (`0` disables caching).
- `mcp.refresh(server)` drops the cache and the session (extending PRD-6 §4.4 step 4).
- A `notifications/tools/list_changed` observed on the SSE channel drops the `tools` slice immediately. Because the extension only reads the stream during an in-flight request, this is best-effort: a notification arriving between statements is not seen. TTL is the guarantee; the notification is the optimization. Documented as such.
- Read-through tables (`resource_contents`, `prompt_messages`, `completions`) are **never** cached.

### 4.11 `IMPORT FOREIGN SCHEMA` (generic mode)

```sql
IMPORT FOREIGN SCHEMA mcp FROM SERVER npl INTO npl_mcp;
IMPORT FOREIGN SCHEMA mcp LIMIT TO (tools, tool_calls) FROM SERVER npl INTO npl_mcp;

-- Programmatic equivalent (ADR-003), callable from a migration or DO block.
-- Returns the count of tables created. opts carries the same import options.
SELECT mcp.import('npl', 'npl_mcp', '{"per_tool": true, "all_upstreams": true}');
```

`mcp.import/3` and `IMPORT FOREIGN SCHEMA` share one implementation; the function exists because `IMPORT FOREIGN SCHEMA` cannot be parameterized or run conditionally, which a Liquibase changelog needs (PRD-10 §4.5 step 9).

- Remote schema `mcp` (any other name raises `3F000`) creates the nine tables of §4.1–§4.7.
- `LIMIT TO` / `EXCEPT` filter the created set by table name.
- Import options: `cache_ttl_ms` (per-table override); `all_upstreams` (see below). PRD-8 adds `per_tool`, `invoke_on_select`, `prefix`.
- **Against the engine (ADR-007, PRD-11)**, `all_upstreams 'true'` additionally creates **one Postgres schema per enabled upstream**, named for the `engine.servers` row, holding that upstream's slice of the catalog. The engine's own schema holds `servers`, `tool_calls` and the engine-local tools. Default is `false`: a plain import against the engine produces the nine tables with fully-qualified `<upstream>.<tool>` names in one schema, and nothing is created implicitly. This keeps the "install once" promise opt-in rather than making a later `INSERT INTO engine.servers` silently change what a re-import produces (PRD-11 §9 Q1).
- Re-running `IMPORT` is safe: it emits `CREATE FOREIGN TABLE` statements which fail on existing names in the ordinary Postgres way; operators drop the schema or use a fresh one.

---

## 5. Requirements

**FR-7.1** `mcp_fdw` implements `ForeignDataWrapper` with `begin_scan`, `iter_scan`, `re_scan`, `end_scan`, `begin_modify`, `insert`, `end_modify`, and `import_foreign_schema`.
**FR-7.2** The nine tables of §4.1–§4.7 exist with exactly the stated columns and types.
**FR-7.3** Catalog tables follow MCP pagination cursors to exhaustion in one scan.
**FR-7.4** A list method answering `-32601` yields an empty table; sibling tables on that server continue to work (D5).
**FR-7.5** `resource_contents` honors `uri` `=` and `= ANY` quals, issuing one `resources/read` per distinct URI.
**FR-7.6** An unqualified `resource_contents` scan is capped by `max_unqualified_reads`; `0` raises `0A000`, exceeding the cap raises `54023`.
**FR-7.7** `prompt_messages` requires a `prompt` qual and accepts an optional `arguments` jsonb qual.
**FR-7.8** `completions` requires `ref`, `argument_name` and `argument_value` quals.
**FR-7.9** `INSERT INTO tool_calls … RETURNING` performs exactly one `tools/call` per row and populates all output columns.
**FR-7.10** `isError: true` returns a row with `is_error = true` and raises nothing.
**FR-7.11** `SELECT` on `tool_calls` performs no network I/O and returns this backend's log for this server.
**FR-7.12** `UPDATE`/`DELETE` on `tool_calls` raise `0A000`.
**FR-7.13** With `audit_table` set, each call appends to that table transactionally; a rollback discards both.
**FR-7.14** Catalog cache honors TTL, is keyed by `(backend, server, user)`, and is dropped by `mcp.refresh/1`.
**FR-7.15** `notifications/tools/list_changed` seen on an in-flight stream drops the cached tool list.
**FR-7.16** `IMPORT FOREIGN SCHEMA mcp` creates the nine tables and honors `LIMIT TO` / `EXCEPT`; `mcp.import/3` (PRD-6 §4.6) shares that implementation and returns the count created.
**FR-7.19** Against an engine, `all_upstreams 'true'` creates one schema per enabled upstream plus the engine's own; the default `false` creates one schema with fully-qualified names and creates nothing implicitly.
**FR-7.17** The §4.9 error table is implemented exactly, with `errdetail` naming server and method and never the token.
**FR-7.18** All foreign tables are readable by any role holding a `USER MAPPING`; a role without one gets `28000` on first access, not an empty result.

**Acceptance criteria**

**AC-7.1** `SELECT count(*) FROM mcp.tools` equals the length of a direct `tools/list` against the same server as the same principal.
**AC-7.2** `SELECT name, read_only FROM mcp.tools ORDER BY name` matches the fixture server's declared annotations, with `read_only` NULL where the annotation is absent.
**AC-7.3** `INSERT INTO mcp.tool_calls (tool, arguments) VALUES ('echo','{"message":"hi"}') RETURNING content` returns the echo result; a second row in the same statement calling a failing tool returns `is_error = true` and the statement succeeds.
**AC-7.4** `SELECT * FROM mcp.resource_contents WHERE uri = ANY(ARRAY['a','b'])` issues exactly two `resources/read` calls.
**AC-7.5** `SELECT * FROM mcp.resource_contents` with default options raises `0A000`.
**AC-7.6** `SELECT * FROM mcp.prompt_messages WHERE prompt='summarize' AND arguments='{"style":"terse"}'` returns the prompt's messages in order.
**AC-7.7** A join works: `SELECT t.name, c.is_error FROM mcp.tools t JOIN mcp.tool_calls c ON c.tool = t.name`.
**AC-7.8** Two roles with different `USER MAPPING`s see different row counts in `mcp.tools` on the same foreign server, in the same session-free sense (separate connections).
**AC-7.9** `IMPORT FOREIGN SCHEMA mcp FROM SERVER npl INTO s` creates nine tables; `LIMIT TO (tools)` creates one.
**AC-7.13** Against an engine with two upstreams attached, `all_upstreams 'true'` creates three schemas (two upstreams plus the engine's own); `SELECT name FROM <upstream>.tools` returns that upstream's tools with the prefix stripped.
**AC-7.14** A `SELECT` on the engine's `mcp.tools` returns the union of its upstreams' tools, prefixed, and a down upstream contributes zero rows without failing the scan (PRD-11 D5).
**AC-7.10** `EXPLAIN (VERBOSE) SELECT * FROM mcp.resource_contents WHERE uri='x'` shows the qual as pushed down, and shows no token.
**AC-7.11** Killing the MCP server mid-scan yields `08006` on that statement; a later statement after the server returns succeeds without operator intervention.
**AC-7.12** `cargo pgrx test` green on pg16, pg17, pg18.

---

## 6. Internal work checklist (with anchors)

| Step | File | Anchor / detail |
|---|---|---|
| 7.1 | `pg/pg_mcp/src/fdw.rs` | new; `ForeignDataWrapper` impl per §4 |
| 7.2 | `pg/pg_mcp/src/tables/mod.rs` | table registry: name → column list → fetch strategy |
| 7.3 | `pg/pg_mcp/src/tables/catalog.rs` | `server`, `tools`, `prompts`, `prompt_arguments`, `resources`, `resource_templates` |
| 7.4 | `pg/pg_mcp/src/tables/readthrough.rs` | `resource_contents`, `prompt_messages`, `completions`; qual requirements + caps |
| 7.5 | `pg/pg_mcp/src/tables/tool_calls.rs` | insert path, in-memory log, audit SPI write |
| 7.6 | `pg/pg_mcp/src/cache.rs` | §4.10 TTL cache keyed `(backend, server OID, user OID)` |
| 7.7 | `pg/pg_mcp/src/quals.rs` | crate `Qual` → supported operator subset; unsupported quals left for Postgres to re-check |
| 7.8 | `pg/pg_mcp/src/errors.rs` | extend PRD-6 §4.7 to the full §4.9 table |
| 7.9 | `pg/pg_mcp/src/import.rs` | `import_foreign_schema`, generic mode (PRD-8 extends with `per_tool`) |
| 7.10 | `pg/pg_mcp/src/client.rs` | extend PRD-6: cursor-following list helper; notification sniffing on the SSE reader |
| 7.11 | `pg/pg_mcp/src/options.rs` | add `cache_ttl_ms` to §4.2's table |
| 7.12 | Elixir side | **no change.** `features/tools.ex:156` `list_registered/3`, `features/prompts.ex:17`, `features/resources.ex:24,128`, `features/completion.ex:13` are consumed over the wire, unmodified. |

---

## 7. Test plan

### 7.1 Rust unit

- `quals_test` — every supported operator shape; `= ANY` with 0/1/N elements; unsupported operators fall through untouched.
- `cache_test` — TTL expiry, per-user isolation (two user OIDs never share entries), `refresh` clearing, `cache_ttl_ms = 0` disabling.
- `errors_test` — full §4.9 table.
- `tool_calls_log_test` — 1000-entry cap, newest-first ordering, per-server partitioning.

### 7.2 Rust integration against the in-crate HTTP stub

Multi-page `tools/list` cursor following; `-32601` on `prompts/list` yielding an empty table while `tools` still works; `isError` row; audit-write rollback.

### 7.3 SQL-level tests (`cargo pgrx test pg17`)

Every AC in §5 that does not need a real Elixir server. The rest (AC-7.1, AC-7.2, AC-7.6, AC-7.8) are re-asserted end-to-end in PRD-10 §7.

### 7.4 Anti-pattern regression tests

- **AP-P1 (parallel registry):** no code path writes a tool/prompt/resource list into a local Postgres table as a source of truth. Asserted structurally: the only local writes the extension performs are audit rows. A grep-level test in CI fails on any `INSERT INTO` in the crate outside `tool_calls.rs`'s audit path.
- **AP-P2 (SELECT with side effects):** a `SELECT` on any table in this PRD issues zero `tools/call` requests. Asserted by counting stub-server hits around a `SELECT * FROM tool_calls`.
- **AP-P3 (cross-role cache bleed):** a cache populated under role A is never served to role B. Asserted by two backends, two mappings, one server, differing tool sets.
- **AP-P4 (discovery oracle):** a tool hidden from role B's principal is absent from `mcp.tools` for B and, if invoked by name through `tool_calls`, returns the server's own `invalid_params` — the same error an absent tool returns. The extension adds no "you lack permission" distinction of its own.

### 7.5 Performance

`SELECT * FROM mcp.tools` twice in one session must issue one `tools/list` (cache hit). A 100-row `INSERT … SELECT` into `tool_calls` must issue exactly 100 `tools/call` requests, sequentially, with total wall time under `100 × p99` from PRD-6 §7.5 S4.

---

## 8. Compat & rollback

- **Additive.** No Elixir library change; no hex publish; consumers unaffected.
- **Postgres-side compat**: PRD-6's six `mcp.*` functions keep their signatures and behavior. `mcp.refresh/1` gains catalog-dropping on top of session-dropping — a strict superset.
- **Rollback**: `DROP EXTENSION pg_mcp CASCADE` drops the FDW, servers, mappings and all foreign tables. Local audit tables survive and are the operator's to keep or drop — deliberately, since they hold the only durable record.
- **Risk watch**: `max_unqualified_reads` defaulting to `0` means a naive `SELECT * FROM resource_contents` errors instead of quietly issuing thousands of reads. That is intentional and will surprise people; the error message names the option and the fix.
- **Forward compat with PRD-8**: PRD-8 adds tables and import options but changes none of the nine tables here. A database imported under PRD-7 keeps working after the PRD-8 upgrade without re-import.

---

## 9. Open questions

1. **Q1 (blocking PRD-8):** `tool_calls.id` — the extension generates a UUID per call. Should it instead carry the JSON-RPC request id, or the server's `_meta` correlation id when one exists? A server-supplied id would make the audit table joinable to server-side telemetry.
2. **Q2:** `SELECT` on `tool_calls` reading a **backend-local** log means a fresh connection sees nothing. The alternative is reading the `audit_table` when one is configured. Recommend keeping the log semantics as specified and documenting `audit_table` as the durable view, but the lead may prefer the SELECT to transparently union the two.
3. **Q3:** `resource_contents.blob` as `bytea` requires base64-decoding on the extension side. Confirm that is wanted rather than surfacing the base64 `text` verbatim.
4. **Q4:** Cache TTL default of 60s matches series-1's PRD-3 cache default. Confirm 60s is right for a catalog that changes rarely but whose staleness is user-visible in `tools`.
5. **Q5:** Should `notifications/tools/list_changed` handling be strengthened by a background reader? That would mean a permanently open SSE stream per backend, which is a materially different resource profile. Recommend no for 0.4.0; TTL is the contract.
6. **Q6a (blocking, shared with PRD-11 Q1):** Confirm `all_upstreams` defaults to `false`. Automatic per-upstream schema creation is the more seductive reading of "install once", but it means an `INSERT INTO engine.servers` changes the result of a later re-import, which is drift no operator asked for. Explicit opt-in is the recommendation.
7. **Q6:** `mode 'auto'` probing is specified in PRD-9. In PRD-7, `auto` resolves to `generic` unconditionally. Confirm that intermediate state is acceptable at the PRD-7 merge point.
