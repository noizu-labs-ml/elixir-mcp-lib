# Dataset Synchronization (ADR-009 / PRD-13)

Opt-in, experimental `sync/version 1` subsystem materializing MCP-exposed
datasets into ordinary PostgreSQL tables. Code: `lib/noizu/mcp/sync/`.
Schema: `priv/sql/noizu_mcp_sync.sql` (see
[../schema/sync.md](../schema/sync.md) for table detail). Operator setup:
[../guides/postgres_sync.md](../guides/postgres_sync.md).

## Shape

- A `SELECT` from `mcp_sync.records` makes no MCP request — the cache is
  regular SQL.
- SQL and MCP writers use explicit revisions. A SQL commit queues local intent
  in the outbox; the worker acknowledges it only after the source commits.
- Source and cache are **separate databases** with separate restricted
  `Ecto.Repo` pools (`mcp_sync_client` role each; the worker uses
  `mcp_sync_worker`). Never connect application pools as owners or superusers;
  authorization uses the authenticated PostgreSQL `session_user`.
- Bindings are registered administratively in each database, unique by
  `(tenant_id, source_id, principal_id, relation)`; `principal_id` MUST be
  resolved by the host from the authenticated principal — state is never
  derived from request parameters.

## Components

| Module | Role |
|---|---|
| `Sync.Protocol` | Validates and explicitly dispatches the five methods — `sync/capabilities`, `sync/snapshot`, `sync/changes`, `sync/mutate`, `sync/operation` — to a trusted, principal-bound Source |
| `Sync.Source` | Source behaviour contract: consistent snapshot, resumable tombstoning change feed, atomic CAS, durable idempotency |
| `Sync.RevisionedDataset` | First writable source: controlled PostgreSQL with durable revisions, idempotency, snapshots (Ecto-gated) |
| `Sync.RemoteSource` | Source over an already-authenticated `Noizu.MCP.Client`; the host owns the client and its credential lifecycle (one authenticated session per principal) |
| `Sync.Store` | Parameterized SQL facade over the host-owned `mcp_sync` schema; every call is one short transaction; no remote I/O under a record lock |
| `Sync.Worker` | Opt-in bounded per-binding worker — no process starts unless the host adds it to its supervision tree with `enabled: true` |

## Correctness model (PostgreSQL-owned)

- **RLS everywhere**: FORCE ROW LEVEL SECURITY on every table; NOLOGIN roles
  `mcp_sync_owner/apply/worker/client`; SECURITY DEFINER helpers
  (`_can_access`, `_assert_access`, `_assert_worker`) raise `42501` /
  `55000` rather than trust the caller.
- **CAS writes**: `_record_guard` trigger requires `expected_local_revision`
  to match (else `40001 revision_conflict`); physical DELETE denied
  (`physical_delete_denied`); sync metadata is immutable to clients
  (`metadata_change_denied`); `mcp_sync_apply` (remote origin) bypasses CAS
  by design.
- **Outbox**: one pending operation per resource (partial unique index),
  lease-based claiming, monotonically increasing fencing tokens, retry with
  `next_attempt_at`, terminal states including `unknown` (resolve via
  `sync/operation` idempotency probe).
- **Conflicts**: `mcp_sync.conflicts` holds base/remote revisions and both
  payloads; at most one `open` conflict per operation (partial unique).
- **Idempotency**: `source_operations` keyed by `(binding_id, operation_id)`
  with `request_hash` + outcome, retained per `retain_until`.
- **Snapshots**: `source_snapshots` blobs (15-minute default expiry) tied to a
  change cursor so restarts resume rather than re-snapshot.

## Explicit non-goals (v1)

Typed generated tables, automatic merges, and VFS write synchronization are
out of scope. `sql/modify`, timestamps, and ordinary VFS version stamps do
**not** establish source guarantees. The hosted `mcp.elixirmcp.dev` sandbox is
ephemeral and does not advertise this protocol. Engine targets must negotiate
`sync/version 1` explicitly and use pass-through.
