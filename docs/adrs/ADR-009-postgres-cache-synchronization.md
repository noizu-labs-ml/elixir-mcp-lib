---
id: ADR-009
title: "Regular Postgres cache tables with conditional bidirectional synchronization"
status: accepted
date: 2026-09-07
---

# ADR-009: Local tables, durable synchronization, explicit conflicts

## Context

The user requests regular local Postgres tables for fast processing, with locks
and hooks coordinating edits made through both MCP and SQL. The public
`mcp.elixirmcp.dev` proof of concept offers an ephemeral sandbox isolated per
GitHub/Google-authenticated OAuth session, with read-only fixtures, writable scratch files and settings
control nodes. Those session-local writes are not durable synchronization.
Durable writable synchronization belongs to an explicitly enabled operator deployment.

Today `pg/pg_mcp/src/cache.rs` caches catalogs per backend/server/user with a
TTL. Resource contents are fetched on every scan. `sql/modify` is best-effort
and has no conditional-write or idempotency contract. VFS version stamps
support read caching, not atomic write comparison. None is synchronized storage.

This decision extends accepted ADR-004/005/007. The maintainer explicitly
approved ADR-009 and PRD-13 on 2026-09-07 ("approved you have my signh off").
Implementation follows the repository's docs-only PR sequencing rule.

## Decision

### Storage and identity

Add optional `Noizu.MCP.Sync` and a Liquibase-owned schema `mcp_sync`. Keep
existing FDW/catalog-cache behavior intact. First create actual regular tables
with JSONB payload and indexed key/revision/status columns. Typed generated
tables are a later additive feature. Local SELECT uses no network.

Identity is `(binding_id, resource_key)`. Each binding uniquely identifies
`(tenant_id, source_id, principal_id, relation)` with a server-controlled
Postgres role mapping. Different principals have separate rows/checkpoints even
for the same source resource. Credentials remain references and source
authorization applies. No cross-principal cache reuse is allowed.

Each row has opaque source revision, monotonic local revision, tombstone,
payload, state and freshness. Normal MVCC gives local transactional reads.
Pending/stale/offline data is visible as such, never described as acknowledged.

### Source contract

Advertise `experimental.sync = {"version":1}` separately from `sql/*`, with
per-relation capabilities. Writable sources must implement:

1. A consistent snapshot and resumable change-feed boundary, including tombstones.
2. Opaque revisions and atomic conditional create/update/delete. A mismatched
   expected revision changes nothing; create explicitly requires absence.
3. Durable idempotency scoped to principal/relation/operation ID. Replay returns
   the original result; different request content under the same ID is rejected.
4. Defined change-cursor and idempotency retention. Unknown outcome after the
   dedupe horizon blocks for reconciliation, never becomes a blind new write.

Never infer these from tool names, timestamps, update callbacks or VFS cache
versions. Sources lacking conditional mutations remain read-only. Snapshot-only
sources can provide manually refreshed read-only caches with honest freshness.
No weaker writable mode ships in the first slice.

### SQL writes and hooks

SQL edits supply `expected_local_revision`. BEFORE trigger checks the locked
row, prohibits identity/revision metadata tampering, increments local revision,
and consumes/clears the input precondition. Creates require zero; updates require
exact equality. Physical DELETE is denied: deletion is a conditional tombstone
update. AFTER trigger inserts an immutable outbox operation in the same
transaction. Rollback removes both changes.

Initially permit one unacknowledged operation per row. Further edits to pending
or conflicted rows are rejected, avoiding chains with unknown remote versions.
SQL convenience functions and the MCP local-cache adapter use these same hooks.
No network calls happen in a trigger or row-lock transaction.

### Workers and inbound changes

Claim outbox with `FOR UPDATE SKIP LOCKED`, lease deadline and incrementing
fencing token; commit before network I/O. Retry identical operation IDs,
payloads and preconditions. Ack requires matching fence and queued local
revision. Crash after source commit/before ack replays the durable source
idempotency result. Timeout means unknown outcome. Explicit source CAS mismatch
creates a conflict, retaining local intent and remote evidence.

Inbound apply uses the same row locks. Clean rows receive remote revisions and
monotonic local revisions. Pending rows retain local values: persist deferred
events and advance the source checkpoint atomically. An event with the same
operation ID may acknowledge that edit; other events await its CAS outcome.
Replay is idempotent. Source cursor expiry requires a new consistent snapshot.

Acknowledgment, including a matching inbound event, additionally requires the
outbox operation to remain in flight. Once acknowledged, a delayed worker
response is a no-op and cannot restore an older payload/revision after a newer
inbound event. Terminal queue status is checked under the same record/outbox locks.

Postgres sequences are not commit-order cursors. The controlled source uses a
transactional per-binding counter row, locked until commit, to order source
changes and establish snapshot boundaries. Aborts roll back counter increments;
later writers cannot publish past an uncommitted hole. Outbox claims use durable
status, never a maximum observed ID. NOTIFY may wake workers but is not durable
delivery. Source serialization per binding is a documented first-slice tradeoff.

### Permissions

Separate NOLOGIN schema owner/apply roles, narrowly privileged worker login,
and per-binding app roles. Force RLS on cache/checkpoint/status surfaces.
Security-definer functions fix a safe search path, qualify all relations,
revoke PUBLIC execution, and explicitly authorize bindings.

Application roles cannot modify metadata/outbox/checkpoints, disable triggers,
TRUNCATE, invoke privileged apply functions or SET ROLE to their owners. Echo
suppression is available only through the dedicated NOLOGIN apply role inside
authorized functions; no user-settable session flag can bypass hooks. Superusers
and object owners remain administrative trust boundaries.

Revoked bindings immediately deny local reads/writes; expired credentials pause
sync without anonymous retry. Offline status alone does not revoke a binding.

### First vertical slice

Implement one controlled Postgres-backed `RevisionedDataset` source, durable
source changes/deduplication and a local records table. Use separate source/cache
connections and test competing SQL/MCP writes. Third-party writable adapters,
typed table generation, automatic merges and VFS write sync are later work.
The public hosted sandbox does not advertise durable sync capabilities. Its
session-local file/settings writes never imply cross-session persistence or
participation in this source synchronization contract.

Every mutation of the controlled source, including direct SQL, ordinary tools
and legacy sql/modify, must route through the same revision/change/deduplication
transaction or be denied by database privileges. No unversioned alternate
source-write path is allowed.

## Consequences

Local reads are indexed and available offline. SQL commit means queued intent;
remote acknowledgment remains asynchronous. Conflicts preserve competing edits.
This is eventual convergence through at-least-once delivery and repeat-safe
source effects within retention, not distributed transactions or exactly-once
delivery. Row locks coordinate only local writers; source CAS handles external
MCP writers. Costs include durable logs/queues, explicit conflict handling,
permission setup and one pending edit per row.

## Alternatives considered

- TTL caching cannot coordinate edits or preserve pending writes.
- Network in triggers holds locks across latency without remote rollback.
- Last-write-wins silently discards concurrent changes.
- User-settable echo suppression creates a permissions bypass.
- Generic `sql/modify` cannot promise preconditions it never received.

## References

- [PRD-13](../../project-management/PRDs/PRD-13-postgres-cache-synchronization.md)
- [ADR-004](ADR-004-identity-mapping.md), [ADR-005](ADR-005-sql-extension-methods.md),
  [ADR-007](ADR-007-engine-federation.md)
- `lib/noizu/mcp/server/dataset.ex`, `lib/noizu/mcp/server/features/sql.ex`
- `lib/noizu/mcp/server/features/vfs.ex`, `pg/pg_mcp/src/cache.rs`
- [PostgreSQL locks](https://www.postgresql.org/docs/current/explicit-locking.html)
- [PostgreSQL triggers](https://www.postgresql.org/docs/current/trigger-definition.html)
