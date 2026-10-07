# Supply Chain

Detail for T-030; CI-workflow gaps live in the main register (T-015…T-017).

## Package path

- Published to Hex as `noizu_mcp`; releases follow 2FA publish discipline;
  version + CHANGELOG bump per release (`.github/workflows/release.yml`).
- Dependencies locked via `mix.lock`; optional deps (Ecto/Postgrex, Req,
  Bandit) are feature-gated — code paths compile only when the host opts in
  (`Code.ensure_loaded?` guards), shrinking the default dependency surface.

## Shipped executable artifacts

Consumers run code that ships in the package:

- `priv/liquibase/*.yaml` + `priv/sql/noizu_mcp_sync.sql` — raw SQL applied by
  the host with administrative roles. This is the highest-privilege artifact
  the package distributes (creates NOLOGIN roles, enables RLS). Treated as
  reviewed, versioned artifacts; changes go through ADR/PR review.
- `priv/inspector/` — browser UI served by the Inspector (localhost-only).
- No NIFs; no build-time code execution during `mix deps.compile` beyond
  ordinary Elixir compilation.

## CI

`.github/workflows/`: `fuse.yml` (Go daemon), `pg_mcp.yml` (Rust extension),
`release.yml`. Gaps: no artifact signing, no SLSA provenance, no pinned
third-party action SHAs enforced repo-wide — consumers trusting Hex metadata
plus 2FA discipline is the current acceptance.
