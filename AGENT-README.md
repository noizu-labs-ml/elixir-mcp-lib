# AGENT-README

> Orientation for AI coding agents working in this repo. Human docs: README.md.

## Type

elixir-lib (Model Context Protocol library — server and client)

## Purpose

`noizu_mcp` on Hex: full-spec MCP for Elixir (targeting spec 2025-11-25, negotiates down to 2025-06-18) — compile-time DSL for tools/resources/prompts, stdio + Streamable HTTP transports, per-caller toolsets with ACL/persistence, OAuth 2.1, VFS file surface, engine federation. Backs every Noizu MCP host and MCP-server repo (dropbox-mcp, secrets-mcp, sendgrid-mcp, namecheap-mcp, NPL backend).

## Stack

Elixir; JSV (JSON Schema validation); Plug/Bandit (HTTP transport, mountable in Phoenix); optional Postgres/Ecto persistence providers; Go FUSE daemon for the VFS file mounters (`fuse/`, `make fuse-build`).

## Dev mode

```bash
mix deps.get && mix compile
mix test
mix format   # also: mix credo, mix dialyzer
mix mcp.client   # opens the HTML inspector for any MCP server
```

## Ports / URLs

- none (library/CLI) — transports are provided to host apps; stdio and Streamable HTTP (Plug/Bandit) ship in-lib

## Tests

```bash
mix test
```

## Gotchas

- Hex-published as `noizu_mcp` (0.4.x; consumers pin `~> 0.4`) — bump `version` in mix.exs + CHANGELOG on release; hex publish requires 2FA discipline.
- Toolset/ACL/persistence interfaces are frozen since 0.3.0; changes go through an ADR. Substantial changes land ADRs (`docs/adrs/`) + PRDs (`project-management/PRDs/`) as a docs-only PR before code.
- MAIN checkout owns `deps/` + `_build/` — worktrees under `.claude/worktrees/` symlink them by absolute path (no per-worktree recompile).
- Downstream testing: use `Noizu.MCP.Test` in-memory transport (async-safe); protocol correctness matters — changes here surface in every consumer's tool surface.
