# Architecture Decision Records — elixir-mcp

Format: front-matter `id / title / status / date`, then Context → Decision → Consequences →
Alternatives considered → References. Status flow: `proposed` → `accepted` (user sign-off)
→ `superseded` / `amended` by a later ADR. Implementation PRDs cite ADR ids in their §2.

## Series: pg_mcp — MCP servers as Postgres structures (2026-09-05)

| ADR | Title | Status |
|---|---|---|
| [ADR-001](ADR-001-real-postgres-extension.md) | A real Postgres extension, not a pg-wire emulation | accepted |
| [ADR-002](ADR-002-fdw-framework-pgrx-wrappers.md) | pgrx + `supabase-wrappers` crate as a library | accepted |
| [ADR-003](ADR-003-sql-projection-model.md) | SQL projection model (catalog, `tool_calls`, per-tool objects, type map) | accepted |
| [ADR-004](ADR-004-identity-mapping.md) | Postgres roles + USER MAPPING tokens → MCP principals | accepted |
| [ADR-005](ADR-005-sql-extension-methods.md) | `sql/*` extension methods + Dataset DSL | accepted |
| [ADR-006](ADR-006-placement-and-packaging.md) | Placement in `pg/pg_mcp`, release trains, packaging | accepted |
| [ADR-007](ADR-007-engine-federation.md) | The Engine: install once, federate upstream MCPs behind one `sql/*` endpoint | accepted |

PRDs for this series: `project-management/PRDs/` (PRD-6 … PRD-11, Series 2 in `INDEX.md`).
