---
id: ADR-002
title: "Build pg_mcp with pgrx, using the supabase-wrappers crate as a library"
status: proposed
date: 2026-09-05
---

# ADR-002: FDW framework — pgrx + `supabase-wrappers` as a library

> Implements ADR-001. Decides how the extension is written and loaded.

## Context

`pg_mcp` needs, from day one: foreign tables with qual/sort/limit pushdown, INSERT (and
later UPDATE/DELETE) on foreign tables, `IMPORT FOREIGN SCHEMA`, outbound HTTP from inside
the backend, and per-role credentials read from `USER MAPPING`. It must run on the Noizu
cluster image (`noizu/timescaledb-ha-with-age`, PostgreSQL 17.9; no `wrappers`, `multicorn`,
`http` or `plpython3u` installed).

Options surveyed 2026-09-05:

| | pgrx (+ `supabase-wrappers` crate) | Wrappers **Wasm FDW** | Multicorn2 (Python) | hand-written C FDW |
|---|---|---|---|---|
| Version / license | pgrx 0.19.2 MIT; wrappers 0.6.2 / crate 0.1.28 Apache-2.0 | host ABI 0.1.5, WIT v2 | 3.2, PostgreSQL license | — |
| PG support | 13–18 (+19 beta) | whatever host `wrappers` is built for | 14–18, Python 3.10–3.12 | any |
| Pushdown / modify / import schema | yes / yes / yes | yes / yes / yes | yes / yes / yes | write it all |
| HTTP | in-process (reqwest/ureq) | host `http` interface | Python `requests` | libcurl |
| USER MAPPING | **yes** (`pg_sys::GetUserMapping`) | **no** (server/table/import options only) | merged into options | yes |
| Install | compile `.so` into image | dynamic, but requires `wrappers` extension on host | compile + Python deps; conflicts with PL/Python ≥3.12 in same DB | compile |

## Decision

- Write `pg_mcp` in **Rust with pgrx 0.19.x**, targeting PostgreSQL 16–18 (17 is the
  production version).
- Use the **`supabase-wrappers` crate as a library** inside our own extension for the FDW
  scaffolding (`ForeignDataWrapper` trait: `begin_scan/iter_scan/end_scan`,
  `begin_modify/insert/update/delete/end_modify`, `import_foreign_schema`, quals/sorts/limit,
  option validation), while reading user-mapping options directly through
  `pgrx::pg_sys::GetUserMapping` where the crate's safe API stops.
- HTTP via a blocking client (`ureq`) with per-request timeouts; no tokio runtime inside the
  backend.
- Keep a **Wasm FDW build as a possible later distribution mode** (zero-compile installs on
  hosts that already ship `wrappers`); not the primary target because Wasm guests cannot read
  user mappings and no Noizu image ships `wrappers`.

## Consequences

Positive
- One codebase gives every required FDW routine plus real per-role credentials.
- pgrx handles `CREATE EXTENSION` packaging (`cargo pgrx package`), SQL schema generation
  and per-PG-version builds; `cargo pgrx test` provides in-database tests.
- Rust's HTTP/JSON ecosystem (serde_json, ureq) makes the JSON-RPC client small.

Negative / risks
- Rust toolchain + pgrx setup is new for this repo (currently Elixir only; ADR-006 keeps it
  isolated in `pg/pg_mcp/`).
- `supabase-wrappers` tracks pgrx closely; version pins must move together.
- Blocking HTTP inside a backend: we must check for interrupts (`check_for_interrupts!`)
  between requests and bound every call with `timeout_ms`.

## Alternatives considered
- **Wasm FDW**: capable (WIT v2 has modify + import-schema), attractive distribution, but no
  user-mapping access and a host dependency the cluster lacks. Revisit for external users.
- **Multicorn2**: fastest to prototype, but PL/Python co-tenancy landmine and a Python runtime
  in the database image.
- **C FDW**: maximal control, maximal effort; no benefit over pgrx for this scope.

## References
- github.com/pgcentralfoundation/pgrx · github.com/supabase/wrappers (`wrappers/src/fdw/*`, `wasm-wrappers/wit/v2/routines.wit`) · github.com/pgsql-io/multicorn2
- Cluster image: `terraform/kubernetes/modules/timescaledb/variables.tf` (monorepo)
