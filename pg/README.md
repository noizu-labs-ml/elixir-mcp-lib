# pg_mcp — call MCP servers from SQL

`pg_mcp` is a PostgreSQL extension (PRD-6 of the pg_mcp series) that lets a SQL
statement talk to any MCP Streamable HTTP server — including the `Noizu.MCP`
plug and the PRD-11 `Noizu.MCP.Engine` — from inside a backend:

```sql
CREATE EXTENSION pg_mcp;

CREATE SERVER npl FOREIGN DATA WRAPPER mcp_fdw
  OPTIONS (url 'https://npl.noizu.com/mcp', timeout_ms '15000');

CREATE USER MAPPING FOR CURRENT_USER SERVER npl
  OPTIONS (token_secret 'mcp_secrets.npl');   -- preferred over inline `token`

SELECT mcp.call_tool_text('npl', 'echo', jsonb_build_object('message', 'hi'));
```

## Layout

```
pg/pg_mcp/
├── Cargo.toml / pg_mcp.control / sql/pg_mcp--0.{1,2}.0.sql (generated)
├── src/
│   ├── {lib,api,client,session,options,errors,sse}.rs   (PRD-6 core)
│   ├── fdw.rs            FdwRoutine plumbing — the unsafe FDW boundary
│   ├── quals.rs          normalized Qual model (=, = ANY, IN)
│   ├── tables/           the frozen table registry (mod.rs) + per-track impls
│   │   ├── catalog.rs       server/tools/prompts/… list scans  (PRD-7.A)
│   │   ├── readthrough.rs   resource_contents/prompt_messages/completions (PRD-7.B)
│   │   └── tool_calls.rs    INSERT invocation + audit          (PRD-7.C)
│   ├── import.rs         IMPORT FOREIGN SCHEMA + mcp.import/3  (PRD-7.D)
│   ├── cache.rs          §4.10 catalog cache + shared HTTP stub
│   └── e2e.rs            PRD-7.E battery: anti-patterns, perf, engine ACs
├── run-tests.sh            deterministic pg test runner (158 probes)
└── spike/                  PRD-6 §7.5 go/no-go spike harness + report
```

PRD-7 (crate 0.2.0): all ten tables of §4.1-§4.7 are implemented — catalog
scans through the §4.10 cache (A), read-through tables with their required
qual rules (B), `INSERT INTO tool_calls` invocation with the transactional
audit write (C), and `IMPORT FOREIGN SCHEMA` / `mcp.import/3` including the
engine `all_upstreams` layout (D). Track E (integration) adds the
anti-pattern/perf/AC battery in `src/e2e.rs` and the cross-track OPTIONS
contract below.

## Import OPTIONS in read paths (PRD-7.E contract)

`mcp.import` stamps every created foreign table with two OPTIONS entries that
the read path consumes (`import.rs` emits them, `fdw.rs` hands them to the
handlers):

* `upstream '<name>'` scopes the table to one engine upstream's slice of the
  catalog: only `<name>.<tool>`-prefixed items, prefix stripped (AC-7.13).
  `''` is the engine-local slice (un-prefixed names only); the option absent
  is the unfiltered union (a default import reads the fully-qualified union).
  The §4.10 cache always holds the union; scoping happens per table after it.
* `cache_ttl_ms '<n>'` overrides the server's `cache_ttl_ms` for that one
  table's freshness checks; `0` makes that table always refetch.

## Build & test

Requirements: `cargo` (rust-toolchain.toml pins 1.98.1), `cargo-pgrx 0.19.2`
(`cargo install --locked cargo-pgrx@0.19.2`), PostgreSQL dev files for the
major you target (`pg_config` registered with `cargo pgrx init`).

```bash
cargo pgrx init --pg18 $(which pg_config)   # once per major
cargo pgrx install -c $(which pg_config)    # install into the server
cargo pgrx test pg18                        # pgrx framework runner
./run-tests.sh                              # deterministic runner (see note)
PG_MAJOR=17 PGBIN=/opt/homebrew/opt/postgresql@17/bin ./run-tests.sh
```

The suite is version-gated where signatures drifted: `create_foreignscan_path`
(PG18 added `disabled_nodes`, PG17 added `fdw_restrictinfo`) and
`heap_form_tuple` (pg16's binding takes `*mut`). Verified matrix (PRD-7.E,
AC-7.12): **pg18 158/158 · pg17 158/158 · pg16 158/158** (pg16 via
`cargo pgrx init --pg16 download`).

**Note on `cargo pgrx test`:** the underlying pgrx-tests framework misbehaves
on some machines — its `CREATE EXTENSION` step and its probe queries end up
against different state, so every probe reports "does not exist" even though
the extension installs perfectly. `run-tests.sh` performs the identical flow
explicitly (build → generate SQL → throwaway cluster → replay → run every
`tests.*` probe) and is the runner we trust. PostgreSQL's macOS linker also
needs `-Wl,-undefined,dynamic_lookup`, which `.cargo/config.toml` supplies
(cargo-pgrx's own template default).

## Surface (PRD-6 §4.6)

| Function | Notes |
|---|---|
| `mcp.call_tool(server, tool, args := '{}', on_error := 'raise')` | full `CallToolResult` as jsonb; `isError` → `P0001` by default, data under `'return'` |
| `mcp.call_tool_text(server, tool, args, on_error)` | concatenated text content; NULL if none |
| `mcp.get_prompt(server, prompt, args)` / `mcp.read_resource(server, uri)` / `mcp.complete(server, ref, name, value)` | STRICT |
| `mcp.refresh(server)` | drops this backend's cached MCP session **and the catalog cache** (PRD-7 §4.10), returns true; NOTICEs when PRD-8 generated objects exist for the server |
| `mcp.import(server, schema, opts)` | projects the registry over SPI, returns the count created; opts: `cache_ttl_ms`, `all_upstreams` (engine layout); PRD-8 adds `per_tool`, `invoke_on_select`, `prefix`, `per_upstream_schema` |
| `mcp.generate_functions(server, schema, opts := '{}')` | PRD-8 §4.6: per-tool tables + typed functions + views; returns `(generated, skipped, skipped_tools)` |

One MCP session per `(backend, server OID, user OID)`: `initialize` once, the
`Mcp-Session-Id` echoed on every request, one silent re-initialize if the
server 404s or reports an expired session. `timeout_ms` is a total deadline
per exchange (connect + read, default 15s); every statement stays cancelable.

`IMPORT FOREIGN SCHEMA mcp FROM SERVER … INTO …` creates the ten foreign
tables; a renamed or hand-created foreign table outside the registry scans as
`0A000`. `INSERT` is supported only on `tool_calls` (§4.7, one `tools/call`
per row); every other table refuses it with `0A000`, as do
`UPDATE`/`DELETE` on `tool_calls` (FR-7.12). The `mcp_fdw` wrapper validates
`CREATE SERVER` / `CREATE USER MAPPING` options as in PRD-6, plus
`cache_ttl_ms` (default 60s, `0` disables) on servers.

## PRD-7.E battery (`src/e2e.rs`)

`./run-tests.sh` runs 158 probes across all test schemas. The PRD-7 §7.4/§7.5
battery lives in `e2e.rs`:

* **Anti-patterns**: catalog tables refuse INSERT (AP-P1 dynamic half; the
  structural half is a grep in `run-tests.sh` — library sources may not say
  `INSERT INTO` outside `tool_calls.rs`'s audit path); a cross-table SELECT
  issues zero `tools/call` (AP-P2); cross-role cache bleed is impossible at
  the cache level *and* at SQL level (AP-P3, `catalog.rs`); a hidden tool is
  absent from the limited principal's catalog and invoking it relays the
  server's own `invalid_params` with no permission distinction (AP-P4).
* **Performance**: a catalog double-scan costs one `tools/list` (cache hit);
  a 100-row `INSERT … SELECT` is exactly 100 sequential `tools/call` under
  the 100 × 250ms p99 budget (PRD-6 §7.5 S4). Wall times are NOTICEed by the
  probes and recorded by the runner into `target/testrunner/probe-output.log`.
* **Engine ACs (AC-7.13/AC-7.14)** run against the in-crate stub serving the
  engine's `<upstream>.<tool>` namespacing: that *is* the extension's whole
  engine contract (upstream discovery and per-upstream scans all ride the
  generic MCP surface). The same probes against a live `Noizu.MCP.Engine`
  land with PRD-10's e2e suite.

## Security posture

* Bearer tokens come only from `USER MAPPING` options (`token`, or the
  preferred `token_secret 'schema.table'` row lookup). Server options never
  carry a token, and no option value is ever echoed into an error (SEC-1).
* `auth 'none'` is accepted only for loopback URLs; plaintext `http` likewise.
* `token_secret` lookups run as the calling role (SEC-3): Postgres's own
  grants decide readability.
* `url` is operator-supplied at `CREATE SERVER` time (superuser or
  `pg_create_foreign_server`); there is no per-call URL override (SEC-4).

## Per-tool codegen (PRD-8, crate 0.3.0)

Every MCP tool can become typed SQL objects: a `tool_<name>` foreign table,
a `schema.<name>(args…) RETURNS jsonb | TABLE(…)` function, and — for
read-only tools with all-optional inputs — a `v_tool_<name>` view.

* **Type map (§4.1, `codegen/types.rs`)**: string → `text` (with
  `format: date-time`/`date`/`uuid` → `timestamptz`/`date`/`uuid`),
  integer → `bigint`, number → `double precision`, boolean → `boolean`,
  enum → `text` + a column comment listing values, object/array → `jsonb`,
  single-non-null unions take the branch, `$ref`/composition/unknown → `jsonb`.
  No PG enum types are created and arrays never become PG arrays (JSON-null
  distinguishability).
* **Generation (§4.6)**: `SELECT * FROM mcp.generate_functions('srv', 'sch')`
  returns `(generated, skipped, skipped_tools)`. It drops and recreates only
  the objects recorded in `mcp.generated` — `RESTRICT`, so a user view over a
  generated table blocks regeneration instead of cascading — re-reading the
  server's `tools/list` fresh each run (never a stored schema copy). Options:
  `invoke_on_select 'read_only'|'all'|'none'` (ADR-003's `readOnlyHint` gate;
  `'all'` warns naming every non-read-only tool promoted), `prefix`,
  `per_upstream_schema` (engine tools route into one schema per upstream,
  prefix stripped), `cache_ttl_ms`. `mcp.import(…, '{"per_tool": true}')`
  generates the same objects alongside the ten generic tables.
* **Invocation (§4.2)**: SELECT on a per-tool table invokes the tool — input
  columns become `arguments` from `=` quals and echo back; a required input
  without a qual raises `22023` naming it. The gate is stamped on the table
  at generation (`invoke_on_select` option): off → SELECT raises `0A000`
  naming the INSERT alternative, before any I/O. `INSERT … RETURNING` is the
  universal path for every tool. `isError` results are rows with NULL output
  columns, never exceptions. A single top-level array-of-objects output
  fans out to one row per element; everything else is one row; `content`
  and `is_error` are appended columns in every case.
* **Identifiers (§4.5, `codegen/ident.rs`)**: camelCase split, non-word
  characters → `_`, leading digit prefixed, 63-byte truncation with a
  SHA-256 suffix, deterministic collision suffixes; reserved words are
  quoted, never renamed. The original tool name always rides the table's
  `tool` option.
* **Regeneration & staleness**: `mcp.refresh` never issues DDL; it NOTICEs
  when generated objects exist for the server. A
  `notifications/tools/list_changed` observation drops the tools cache and
  warns that generated objects are stale — a remote party can never make
  Postgres run DDL (AP-P6). A stale table (its tool vanished server-side)
  fails with `42704` naming `mcp.generate_functions` as the fix.
* **Upgrade**: `sql/pg_mcp--0.2.0--0.3.0.sql` is additive — `mcp.generated`
  and `mcp.generate_functions` only. A PRD-7 database keeps working after
  `ALTER EXTENSION pg_mcp UPDATE TO '0.3.0'`, no re-import.
* Known limitation: a 63-byte derived tool name prefixed with `tool_` is
  further truncated by PostgreSQL itself to 63 bytes for the relation name
  (the hash suffix loses its last characters); tool names near the limit
  should carry a distinct prefix.

## ADR-002 deviation (recorded)

ADR-002 names `supabase-wrappers` 0.1.28 as a library dependency alongside
pgrx 0.19. That combination does not exist: `supabase-wrappers` 0.1.28 pins
`pgrx = "=0.16.1"` **exactly** and pulls tokio, contradicting ADR-002's own
"pgrx 0.19" and "no tokio inside the backend" clauses (0.16.1 also predates
PostgreSQL 18). PRD-6's scope needs none of the crate's scaffolding, so the
crate is built on plain pgrx 0.19.2. PRD-7 must decide: accept the ADR-002
risk note (plain pgrx FDW) or re-spec the framework. Filed for the ADR owner;
not silently ignored.

## Terraform image bump (cluster roll — informational, not done here)

The cluster's Postgres deploys `docker.io/noizu/timescaledb-ha-with-age:pg17.9-ts2.25.2-all-age1.7.0-r2`, pinned as the `image` variable default in the monorepo at `terraform/kubernetes/modules/timescaledb/variables.tf` (the `default = "docker.io/noizu/timescaledb-ha-with-age:…"` block). Shipping pg_mcp to the cluster means bumping that value to the layered tag, following the `-mcp` convention: the base tag with `-mcp<extension version>-r<layer revision>` appended, e.g.

```
docker.io/noizu/timescaledb-ha-with-age-mcp:pg17.9-ts2.25.2-all-age1.7.0-mcp0.3.0-r1
```

so the base provenance stays legible. The bump itself is an infra change in the monorepo — outside this repo and outside any pg_mcp PR — and it is an image roll with an HA failover; see `docs/pg-mcp-install.md` §2 for the blast radius and the operator runbook.
