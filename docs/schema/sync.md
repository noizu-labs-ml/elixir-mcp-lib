# mcp_sync schema (ADR-009 / PRD-13)

Source of truth: `priv/sql/noizu_mcp_sync.sql`, applied through Liquibase by
`priv/liquibase/noizu_mcp_sync.yaml` (single changeSet, `splitStatements:
false`). Optional, host-owned PostgreSQL 14+ schema; requires an
administrative role capable of provisioning NOLOGIN roles. Rollback refuses by
design (pause sync + reconcile first). Elixir side:
`lib/noizu/mcp/sync/{store,revisioned_dataset,worker}.ex` (Ecto-gated).

## Roles & RLS (schema-level machinery)

Four NOLOGIN roles: `mcp_sync_owner`, `mcp_sync_apply`, `mcp_sync_worker`,
`mcp_sync_client`. Every table gets OWNER `mcp_sync_owner` + ENABLE/FORCE ROW
LEVEL SECURITY. `SECURITY DEFINER` helpers gate access:

- `_can_access(binding)` — binding enabled AND `app_role = session_user` OR
  worker role membership.
- `_assert_access(binding, write?)` — raises `42501 permission_denied` /
  `55000 unsupported_consistency` (write on a `read_only` binding).
- `_assert_worker()` — worker-role-only entry points.
- Policies: `binding_reader` on bindings; `binding_access` on records/outbox/
  checkpoints/inbound_deferred/conflicts (client + worker roles).
- `_record_guard()` trigger on records: physical DELETE denied; resource_key
  must be a non-empty object; non-deleted rows need an object payload;
  `mcp_sync_apply` writes bypass CAS (remote origin); everyone else needs
  `expected_local_revision` matching (CAS, `40001 revision_conflict`) and
  cannot touch sync metadata (`metadata_change_denied`).

## mcp_sync.bindings

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| id | uuid | No | gen_random_uuid() | PK |
| tenant_id | text | No | — | |
| source_id | text | No | — | |
| source_binding_id | uuid | Yes | — | |
| principal_id | text | No | — | Host-resolved from authenticated principal, never request params |
| relation | text | No | — | e.g. `upstream.notes` |
| app_role | name | No | — | Session user allowed to access this binding |
| credential_ref | text | Yes | — | |
| access_mode | text | No | `read_only` | CHECK read_only/read_write |
| capabilities | jsonb | No | `'{}'` | read_write requires conditionalWrites+idempotency+changes+consistent snapshot and positive retention seconds |
| enabled | boolean | No | true | |

**Constraint**: `UNIQUE (tenant_id, source_id, principal_id, relation)`

## mcp_sync.records

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| binding_id | uuid | No | — | PK part; FK → bindings |
| resource_key | jsonb | No | — | PK part; non-empty object (CHECK) |
| payload | jsonb | Yes | — | Object when not deleted (trigger CHECK) |
| source_revision | text | Yes | — | |
| source_counter | bigint | No | 0 | |
| local_revision | bigint | No | 0 | CHECK `> 0` after trigger assigns |
| deleted | boolean | No | false | Tombstone flag |
| state | text | No | `pending` | CHECK clean/pending/conflict/blocked/tombstone |
| expected_local_revision | bigint | Yes | — | CAS guard (cleared for remote applies) |
| last_origin | text | No | `local` | CHECK local/remote |
| updated_at | timestamptz | No | clock_timestamp() | |
| checked_at | timestamptz | Yes | — | |

**Indexes**: `records_binding_state (binding_id, state, updated_at)`;
`records_payload GIN (payload jsonb_path_ops)`

## mcp_sync.outbox

Durable outbound operations; one pending op per resource
(partial unique), lease-based claiming with fencing tokens.

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| operation_id | uuid | No | gen_random_uuid() | PK |
| binding_id | uuid | No | — | FK (composite) → records |
| resource_key | jsonb | No | — | FK part |
| queued_local_revision | bigint | No | — | |
| operation | text | No | — | CHECK create/update/delete |
| precondition | jsonb | No | — | |
| payload | jsonb | Yes | — | |
| request_hash | text | No | — | Idempotency key material |
| state | text | No | `pending` | CHECK pending/claimed/unknown/conflict/blocked/acknowledged/resolved |
| attempts | integer | No | 0 | |
| next_attempt_at | timestamptz | No | clock_timestamp() | |
| lease_until | timestamptz | Yes | — | |
| fencing_token | bigint | No | 0 | |
| first_attempt_at | timestamptz | Yes | — | |
| last_error | text | Yes | — | |
| outcome | jsonb | Yes | — | |
| created_at | timestamptz | No | clock_timestamp() | |

**Indexes**: `outbox_one_pending UNIQUE (binding_id, resource_key) WHERE state
IN ('pending','claimed','unknown','conflict','blocked')`; `outbox_due
(binding_id, next_attempt_at, operation_id) WHERE state IN
('pending','unknown','claimed')`

## mcp_sync.conflicts

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| id | uuid | No | gen_random_uuid() | PK |
| binding_id | uuid | No | — | FK (composite) → records |
| resource_key | jsonb | No | — | |
| operation_id | uuid | No | — | FK → outbox |
| base_revision | text | Yes | — | |
| remote_revision | text | Yes | — | |
| local_payload | jsonb | Yes | — | |
| remote_evidence | jsonb | Yes | — | |
| reason | text | No | — | |
| state | text | No | `open` | CHECK open/resolved |
| resolution | text | Yes | — | |
| created_at | timestamptz | No | clock_timestamp() | |
| resolved_at | timestamptz | Yes | — | |

**Index**: `conflicts_one_open UNIQUE (operation_id) WHERE state = 'open'`

## mcp_sync.checkpoints

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| binding_id | uuid | No | — | PK; FK → bindings |
| source_cursor | text | Yes | — | Resumable change-feed cursor |
| last_event_id | bigint | No | 0 | |
| snapshot_id | text | Yes | — | |
| last_success_at | timestamptz | Yes | — | |
| status | text | No | `new` | |

## mcp_sync.inbound_deferred

Out-of-order inbound events held until their predecessors apply.

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| binding_id | uuid | No | — | PK part; FK → bindings |
| event_id | bigint | No | — | PK part |
| resource_key | jsonb | No | — | |
| event | jsonb | No | — | |
| observed_at | timestamptz | No | clock_timestamp() | |
| applied_at | timestamptz | Yes | — | |

## Controlled-source tables (RevisionedDataset)

Mirror-side storage for a Source served out of Postgres:

- **mcp_sync.source_heads** — `binding_id uuid PK/FK`, `counter bigint` (head),
  `retained_after bigint`.
- **mcp_sync.source_records** — PK `(binding_id, resource_key)`; `payload`,
  `revision text NOT NULL`, `deleted boolean`, `counter bigint`.
- **mcp_sync.source_changes** — PK `(binding_id, counter)`; `event jsonb`,
  `created_at` — the resumable tombstoning change feed.
- **mcp_sync.source_operations** — PK `(binding_id, operation_id)`;
  `request_hash`, `outcome jsonb`, `retain_until` — idempotency ledger.
- **mcp_sync.source_snapshots** — `id uuid PK`, `binding_id FK`, `rows jsonb`,
  `change_cursor text`, `expires_at` (default 15 minutes).
