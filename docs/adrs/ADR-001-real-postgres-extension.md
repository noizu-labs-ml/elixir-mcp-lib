---
id: ADR-001
title: "Expose MCP servers inside a real PostgreSQL via an extension, not a Postgres-impersonating Elixir process"
status: accepted
date: 2026-09-05
---

# ADR-001: A real Postgres extension, not a pg-wire emulation

> Series: pg_mcp (MCP servers as Postgres structures). Parent of ADR-002…007.

## Context

We want operators, agents and ordinary SQL tooling (psql, Ecto, JDBC, DBeaver, BI) to log
into PostgreSQL and treat an MCP server's surface — tools, prompts, resources, VFS trees,
server-defined datasets — as tables, views and functions: list them, filter them, join them
with application data, and invoke tools from SQL.

Two fundamentally different shapes satisfy "Postgres-compatible":

1. **Emulate Postgres.** An Elixir process speaks the Postgres wire protocol and answers SQL
   itself. Research (2026-09-05) found no maintained Elixir library for the *server* side of
   the protocol (`pg_wire` 0.0.2 is abandoned, no extended query, no SSL). We would build the
   codec (mirroring `Postgrex.Messages`), a SQL parser, SCRAM server-side, *and* a fake
   `pg_catalog`/`information_schema` large enough to keep psql `\d`, JDBC metadata and DBeaver
   happy. Every client introspection query is a new compatibility bug. Nothing can be joined
   with real application data.
2. **Be inside Postgres.** A real extension makes MCP surfaces foreign tables and SQL
   functions. Login, roles, SCRAM/TLS, RLS, `pg_catalog`, planner, joins with application
   schemas (the shared `app-timescaledb` already hosts most Noizu databases) all come from
   Postgres. Any client that speaks to Postgres works unchanged.

Sub-variants of (2) considered: `postgres_fdw` pointed at an emulator (still requires 1);
plpgsql + `pgsql-http` functions (no foreign tables, no planner pushdown, `http` extension is
not in the Noizu image).

The user's direction on 2026-09-05: "these should be true postgres extensions — logging into
postgres would let us interact with the mcp data, query it etc."

## Decision

Build **`pg_mcp`**, a PostgreSQL extension containing a foreign data wrapper (`mcp_fdw`) and
SQL functions in schema `mcp`, that talks to MCP servers over the Streamable HTTP transport.
The extension works against **any** spec-compliant MCP server ("generic mode") and gains typed
schemas and predicate pushdown against elixir-mcp servers that advertise the `sql/*` extension
methods (ADR-005).

elixir-mcp does **not** grow a Postgres wire-protocol transport. Instead it grows an
**Engine** (ADR-007) that federates upstream MCP servers behind one endpoint, so Postgres is
configured once and further MCPs are attached as data.

## Consequences

Positive
- Every Postgres client works on day one; no compatibility chase.
- Postgres owns authentication (SCRAM, TLS, pg_hba), authorization (roles, grants, RLS) and
  auditing; MCP identity is mapped per role (ADR-004).
- MCP data becomes joinable with application tables in the same database; views and
  materialized views over MCP tables are ordinary SQL.
- Planner integration (qual/limit pushdown) lets tools with `readOnlyHint` behave like
  parameterised tables.

Negative / risks
- A new toolchain (Rust + pgrx, ADR-002) and a custom Postgres image rebuild (ADR-006).
- Outbound HTTP runs inside a Postgres backend: calls block that backend; every request must
  carry a timeout and honour `statement_timeout`/cancel. One MCP session per backend is
  cached; memory is bounded by catalog size and the per-backend call log cap.
- Tool invocation from SQL has side effects; the projection model (ADR-003) gates
  SELECT-triggered invocation on `readOnlyHint` and keeps mutating tools INSERT/function-only.
- Extension upgrades follow Postgres extension versioning (`pg_mcp--x.y.sql` scripts), a
  second release train next to the hex package.

## Alternatives considered

| Option | Why not |
|---|---|
| Elixir pg-wire server (thousand_island + hand-rolled codec/SQL/catalog) | Unbounded client-compat surface, no joins with real data, must reimplement auth; no library help exists. |
| `postgres_fdw` → emulator | Inherits all of the above plus a second hop. |
| plpgsql + `pgsql-http` | No foreign tables or pushdown; `http` not shipped in the Noizu image; kept as a mental fallback only. |

## References
- ADR-002 framework choice · ADR-003 projection model · ADR-004 identity · ADR-005 `sql/*` · ADR-006 packaging · ADR-007 engine federation
- Prior-art scan: hex `pg_wire` (dead), supabase/supavisor (proxy, not a library), `Postgrex.Messages` (client-side codec).
