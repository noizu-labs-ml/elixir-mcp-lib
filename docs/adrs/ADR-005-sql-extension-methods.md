---
id: ADR-005
title: "elixir-mcp gains experimental sql/* methods and a Dataset DSL; pg_mcp uses them when advertised"
status: proposed
date: 2026-09-05
---

# ADR-005: `sql/*` extension methods and server-defined datasets

> Implements ADR-001 on the server side. Normative surface in PRD-9.

## Context

Generic MCP gives `pg_mcp` enough to build catalog tables and invoke tools (ADR-003), but
three things are lost without server cooperation:

1. **Typed columns** beyond what JSON Schema on tools carries — e.g. a server that wants to
   expose tickets, sessions or a prompt library as first-class tables.
2. **Predicate, sort and limit pushdown** — otherwise every `WHERE` filters after fetching
   the whole list.
3. **Tabular data that is not a tool** — today a server would have to fake it as a resource
   or a tool returning arrays.

elixir-mcp already ships non-spec extension methods (`vfs/*`) advertised through capability
flags and routed alongside spec methods, so a precedent exists for a namespaced extension.

## Decision

- Add an optional feature module `Noizu.MCP.Server.Features.SQL` with three JSON-RPC methods:
  - `sql/schema` → tables with typed columns, which columns accept pushed quals, sort/limit
    support, and the invoke kind (`catalog | dataset | tool | resource | prompt`);
  - `sql/scan` (table, quals, columns, sort, limit, cursor) → rows + next cursor;
  - `sql/modify` (table, op ∈ insert|update|delete, rows/quals) → affected rows.
- Add a `Noizu.MCP.Server.Dataset` behaviour (`columns/0`, `scan/3`, optional `insert/2`,
  `update/3`, `delete/2`) and a `dataset/2` registration macro next to `tool/2`, so servers
  declare tabular surfaces explicitly (D4: explicit participation, no probing).
- `sql/schema` **derives** tool/prompt/resource tables from the `Toolset` protocol catalog and
  feature modules (D1: one resolver); datasets are the only new registry.
- Advertise `capabilities.experimental.sql = %{version: 1}` when a server registers datasets
  or sets `sql: true`. Session dispatch adds the three clauses beside `completion/complete`,
  with optional `handle_sql_*` host callbacks, following the existing feature pattern.
- ACL applies: `sql/scan` over a tool-derived table is authorised exactly like `tools/call`;
  datasets take an ACL subject of their own.
- `pg_mcp` server option `mode`: `auto` (default; use `sql/*` if advertised, else generic),
  `generic`, `sql` (fail if not advertised). Generic mode must remain fully functional so the
  extension works with third-party servers.
- The **Engine** (ADR-007) is the reference `sql/*` implementation and the primary
  counterpart of `pg_mcp`: it federates upstreams and exposes the `servers` dataset that makes
  attaching an MCP a row insert.

## Consequences

Positive
- Noizu servers (NPL/tobor, secrets-mcp, product backends) can export real tables with
  pushdown and typed columns without teaching Postgres anything server-specific.
- Compatible with the VFS precedent; no spec-breaking changes; clients that ignore
  `experimental` are unaffected.

Negative / risks
- A second query surface to keep consistent with `tools/*`; mitigated by deriving from the
  same catalog and by conformance tests that compare `sql/scan` with `tools/list`/`tools/call`.
- Version negotiation for `sql/*` is ours to manage (`version` field; additive changes only
  within v1).

## Alternatives considered
- Generic-only FDW — simpler, but no pushdown and no non-tool tables; kept as a mode, not the ceiling.
- Datasets as resources with JSON bodies — no quals, no typing, whole-payload reads.
- A GraphQL/SQL-string query endpoint — reintroduces a SQL parser on the server; rejected.

## References
- `lib/noizu/mcp/server/session.ex` dispatch table · `lib/noizu/mcp/server.ex` `build_capabilities/2` · `lib/noizu/mcp/toolset.ex` · `docs/arch/toolsets.md` · VFS precedent `lib/noizu/mcp/server/vfs.ex`, `docs/arch/vfs.md`
