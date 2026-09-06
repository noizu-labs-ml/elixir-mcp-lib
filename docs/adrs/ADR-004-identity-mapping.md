---
id: ADR-004
title: "Identity: Postgres roles log in natively; USER MAPPING carries the MCP token"
status: accepted
date: 2026-09-05
---

# ADR-004: Identity mapping between Postgres roles and MCP principals

> Implements ADR-001. Constrains PRD-6 (client core) and PRD-10 (e2e auth tests).

## Context

Two identities are in play: the **Postgres role** that logs in, and the **MCP principal**
the server authorises (`%Noizu.MCP.Auth.Principal{}`, produced by the token verifier chain
in `lib/noizu/mcp/auth/` — JWT, API key, compound, chain). elixir-mcp's rule is strict: a
`nil` principal means anonymous and a principal is never synthesised.

The user asked for SCRAM-capable login. In the emulation design that meant storing password
verifiers in the library; in the real-extension design Postgres already performs SCRAM, TLS
and `pg_hba` checks before any extension code runs.

## Decision

- **Login is Postgres's job.** No credential store, SCRAM verifier or password handling is
  added to elixir-mcp or `pg_mcp`.
- **Per-role MCP identity via `USER MAPPING`.**
  `CREATE USER MAPPING FOR <role> SERVER <s> OPTIONS (token '<bearer>')` or
  `OPTIONS (token_secret '<name>')` where the secret is resolved at call time from a
  configurable secret source (Supabase Vault when present; otherwise a `mcp.secrets` table
  readable only by the extension's SECURITY DEFINER functions). `PUBLIC` mappings are allowed
  but discouraged; the FDW reads the mapping with `pg_sys::GetUserMapping`.
- The FDW sends `Authorization: Bearer <token>` on every request; the MCP server's existing
  verifier chain produces the principal. Therefore **ACL, toolset selection and visibility
  follow the Postgres role automatically** — two roles with different mappings see different
  `tools` rows and import different objects.
- Server option `auth 'none'` disables the header; the validator only accepts it for
  loopback/`localhost` URLs (dev tooling).
- Tokens never appear in logs, error messages, `pg_user_mappings` for non-owners (Postgres
  already masks options), or `EXPLAIN` output.

## Consequences

Positive
- Zero new auth code in the library; the existing `Auth.TokenVerifier` behaviours and OAuth
  facade remain the single source of truth.
- Postgres grants (`GRANT USAGE ON FOREIGN SERVER`, schema/table grants, RLS on audit tables)
  layer on top for defence in depth.

Negative / risks
- Token rotation requires updating mappings (or the secret source); `mcp.refresh(server)`
  drops the cached MCP session so the next call re-authenticates.
- A shared `PUBLIC` mapping collapses identities on the MCP side; documentation must warn.
- Long-lived backends hold a token in memory for the session lifetime (same as any FDW).

## Alternatives considered
- SCRAM verifier store inside elixir-mcp — only needed for the emulation design; redundant now.
- A single server-level token for all roles — loses per-role authorisation; allowed only via
  explicit `PUBLIC` mapping.
- Trust/anonymous mode by default — rejected; `auth 'none'` is loopback-only and opt-in.

## References
- `lib/noizu/mcp/auth/principal.ex`, `lib/noizu/mcp/auth/token_verifier.ex`, `guides/authentication.md`
- PostgreSQL `CREATE USER MAPPING`, `pg_user_mappings` masking rules
