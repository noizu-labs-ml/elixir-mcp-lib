---
id: ADR-007
title: "One engine, many MCPs: elixir-mcp Engine federates upstream servers behind a single sql/* endpoint"
status: proposed
date: 2026-09-05
---

# ADR-007: The elixir-mcp Engine — install once, attach MCP servers as needed

> Refines ADR-001/005/006 after user direction (2026-09-05): "ideally we only need to add the
> elixir-mcp engine and with that in place can connect MCPs up as needed."

## Context

With ADR-001…006 alone, every MCP server an operator wants in SQL needs its own
`CREATE SERVER` + `USER MAPPING` + `IMPORT FOREIGN SCHEMA`, must speak Streamable HTTP, and
must be reachable from the Postgres host. That excludes stdio servers, pushes per-server
credential handling into Postgres, and makes "connect another MCP" a DBA task.

elixir-mcp already contains the other half: a client (`Noizu.MCP.Client` over
`Transport.Stdio.Client` and `Transport.StreamableHTTP.Client`), a sans-IO `Peer` state
machine, the `Toolset` protocol with weighted layers/overrides, ACL providers, persistence
stores, and — with ADR-005 — `sql/*` and datasets.

## Decision

Add **`Noizu.MCP.Engine`** to elixir-mcp: an MCP server (built with `use Noizu.MCP.Server`)
whose content is **federated upstream MCP servers**.

- **Upstream registry as data.** The engine registers a writable dataset `servers`
  (name, transport `stdio|http`, command/url, auth reference, enabled, status, last_seen).
  Attaching an MCP is `INSERT INTO engine.servers (…)` from SQL (via `sql/modify`), or the
  equivalent `tools/call` on the engine's `engine.attach` tool, or static config. Rows persist
  through the existing `Persistence` providers; credentials are stored by reference
  (secret name / Infisical key), never inline.
- **Federation.** For each enabled upstream the engine runs a supervised client session and
  projects its tools, prompts, resources and (when advertised) `sql/*` tables into its own
  catalog, namespaced `<server>.<name>` (Toolset layer per upstream, so overrides, ACL and
  toolset selection apply uniformly). Upstream `list_changed` notifications refresh the layer.
- **Single SQL entry point.** `pg_mcp` needs exactly one `CREATE SERVER` pointing at the
  engine; `IMPORT FOREIGN SCHEMA` produces one schema per upstream (`engine.servers` row) plus
  the engine's own schema. Postgres never talks to upstreams directly.
- **Identity.** The Postgres role's token (ADR-004) identifies the caller *to the engine*;
  the engine holds upstream credentials and decides, via ACL, which upstreams and tools each
  principal may see. Optional pass-through of the caller's token to an upstream is an
  explicit per-upstream setting.
- **Deployment.** Engine modules ship in the `noizu_mcp` package (`lib/noizu/mcp/engine/`);
  it runs embedded in any host app (mounted as the existing Streamable HTTP plug) or
  standalone via `mix mcp.engine` for local use. A dedicated deployable app is a follow-up
  outside this repo.
- **Extension scope shift.** `pg_mcp`'s generic mode stays (any MCP server still works
  directly), but the **engine + `sql` mode is the primary path** and is what the e2e suite
  targets first.

## Consequences

Positive
- "Install once": one extension, one foreign server, one credential in Postgres; new MCPs are
  rows.
- stdio-only servers, private-network servers and servers requiring OAuth become reachable
  from SQL because the engine, not Postgres, holds the connection.
- Aggregation, namespacing, ACL and caching live in Elixir where the library already has the
  machinery; the extension stays thin.

Negative / risks
- The engine is a new long-running component with connection supervision, backoff and
  health reporting (surfaced in `servers.status`).
- Namespace collisions across upstreams are resolved by prefixing; tool names longer than
  Postgres identifiers fall back to hashed suffixes (ADR-003).
- Federated latency: two hops for each call; mitigated by catalog caching and pushdown.

## Alternatives considered
- Per-server registration in Postgres only — works, but excludes stdio and makes attach a
  DBA operation; retained as generic mode.
- A separate gateway product outside elixir-mcp — duplicates client/toolset/ACL machinery.

## References
- `lib/noizu/mcp/client.ex`, `lib/noizu/mcp/transport/stdio_client.ex` (`Noizu.MCP.Transport.Stdio.Client`), `lib/noizu/mcp/transport/streamable_http/client.ex`, `lib/noizu/mcp/peer.ex`, `docs/arch/peer.md`, `docs/arch/client.md`, `docs/arch/toolsets.md`, `docs/arch/persistence.md`
