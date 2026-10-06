# Lib-owned tables (Runner / v1_toolsets)

Source of truth: `lib/noizu/mcp/migrations/v1_toolsets.ex` (raw DDL, applied by
`Noizu.MCP.Migrations.Runner` through the host Repo; `if not exists` guards
make re-runs idempotent). The Runner creates its own ledger table
(`noizu_mcp_schema_versions`) before applying sets — it is deliberately not
part of the v1 statements. Sole reader: `Noizu.MCP.Persistence.Ecto`.

## noizu_mcp_toolsets

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| slug | text | No | — | PK |
| title | text | Yes | — | Display title |
| description | text | Yes | — | Display description |
| base | text | No | — | Base toolset module name |
| immutable | boolean | No | false | Host-locked toolsets |
| include | jsonb | Yes | — | Include list |
| exclude | jsonb | No | `'[]'` | Exclude list |
| tools | jsonb | No | `'{}'` | Materialized tool overrides |
| metadata | jsonb | No | `'{}'` | Free-form metadata |
| inserted_at / updated_at | timestamptz | No | now() | |

## noizu_mcp_toolset_grants

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| id | text | No | — | PK |
| toolset_slug | text | No | — | Logical ref (no FK) |
| authenticator | text | No | — | Authenticator identity |
| subject | text | No | — | Granted subject |
| effect | text | No | — | CHECK `allow`/`deny` |
| scopes | jsonb | No | `'[]'` | Scope list |
| tool_overrides | jsonb | No | `'{}'` | Per-tool override ops |
| expires_at | timestamptz | Yes | — | Grant expiry |
| metadata | jsonb | No | `'{}'` | |
| inserted_at | timestamptz | No | now() | |

**Index**: `noizu_mcp_grants_lookup_idx (toolset_slug, authenticator, subject)`

## noizu_mcp_toolset_negotiations

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| id | text | No | — | PK |
| toolset_slug | text | No | — | Logical ref (no FK) |
| authenticator | text | No | — | |
| tool | text | No | — | Tool under negotiation |
| required_scopes | jsonb | No | `'[]'` | |
| granted | boolean | No | false | |
| metadata_overrides | jsonb | No | `'{}'` | |
| expires_at | timestamptz | Yes | — | |
| metadata | jsonb | No | `'{}'` | |
| inserted_at | timestamptz | No | now() | |

**Index**: `noizu_mcp_negotiations_lookup_idx (toolset_slug, authenticator, tool)`

## noizu_mcp_store_versions

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| store_key | text | No | — | PK |
| version | bigint | No | 0 | Monotonic version (Store write facade bumps) |
| bumped_at | timestamptz | No | now() | |

## noizu_mcp_engine_servers

Engine federation upstream registry (PRD-11); pre-PRD-11 deployments pick it
up by re-running `Runner.up/3`.

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| name | text | No | — | PK |
| transport | text | No | — | CHECK `stdio`/`http` |
| command | text | Yes | — | stdio command line |
| url | text | Yes | — | http endpoint |
| auth_ref | text | Yes | — | Host credential reference |
| enabled | boolean | No | true | |
| inserted_at / updated_at | timestamptz | No | now() | |
