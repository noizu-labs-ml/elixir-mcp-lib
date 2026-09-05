# CLAUDE.md — elixir-mcp

Guidance for Claude Code. Monorepo ops → `../../../../../CLAUDE.md` (trl-infra root).

## Identity

Elixir MCP (Model Context Protocol) library backing Noizu MCP hosts — NPL/tobor.locker tooling and MCP servers such as `Apps/AI/dropbox-mcp`. Protocol-correctness matters: changes here surface in every consumer's tool surface.

## Stack & Commands

Elixir. `mix deps.get && mix compile`; `mix test`; `mix format`, `mix credo`, `mix dialyzer`.

## Publishing

Hex-published as `noizu_mcp` (consumers pin `~> 0.1.x`) — bump `version` + CHANGELOG on release; hex publish discipline (2FA).

## Universal Rules (compressed)

- **Trinity Protocol REQUIRED**: Orientation → Friction → Response (full text: monorepo `protocols/the-trinity-protocol.md`).
- **No shell in main thread** — delegate to taskers.
- **Worktrees**: all work on worktrees; `epic.<group>` consolidation branches off `develop`; squash-PR provenance into epics.
- MAIN checkout owns `deps/_build`; worktrees symlink deps (absolute path).

## Branch & PR Policy

- Submodules sit on **`develop`** — keep your checkout on `develop`.
- All PRs target **`develop`** (feature/bug/task branches fork from `develop`).
- **`main` is CI/CD-only**: CI/CD automation performs all merges into `main` (release path). Never merge to or push `main` by hand.

## Decision records

ADRs: `docs/adrs/` (`INDEX.md` lists them; status `proposed` → `accepted` gates implementation). PRDs: `project-management/PRDs/` (`INDEX.md`, numbered series). Substantial changes land ADRs + PRDs as a docs-only PR before code.
