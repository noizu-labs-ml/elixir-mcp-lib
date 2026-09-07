# PRD-13: PostgreSQL cache tables and conditional synchronization

**Date:** 2026-09-07
**Status:** Accepted by maintainer sign-off on 2026-09-07; docs-only sequencing applies
**Architecture:** [ADR-009](../../docs/adrs/ADR-009-postgres-cache-synchronization.md), accepted
**Scope:** Optional library subsystem, SQL migration, controlled source adapter,
operator guide and integration tests. Hosted demo uses an ephemeral sandbox per OAuth session after GitHub or Google
login; it is not durable sync storage.

## 1. Goal and bounded delivery

Read indexed regular local tables and edit eligible records from SQL or MCP
without silently losing concurrent changes. First storage is JSONB payload plus
typed identity/revision/status columns. First writable source is a controlled
Postgres adapter providing full CAS/idempotency. Arbitrary MCP sources remain
read-only unless they explicitly satisfy conformance. No universal writable
cache, auto-merge, typed-schema generator or VFS write synchronization claim.

## 2. Implementation entrypoints

New modules: `lib/noizu/mcp/sync/{source,revisioned_dataset,worker,store,protocol}.ex`.
Source behaviour defines capabilities/snapshot/changes/mutate/operation lookup.
Store uses parameterized SQL. Worker has supervised restart, bounded concurrency,
timeouts and polling; no process starts unless sync is enabled.

Schema template: `priv/liquibase/noizu_mcp_sync.yaml`, included by host Liquibase.
Add optional sync feature dispatcher beside `server/features/sql.ex`, capability
derivation beside `sql/schema.ex`, and explicit server method routing. Existing
Dataset.update/3 does not carry preconditions; do not silently reuse it for CAS.
Engine forwards negotiated sync methods with principal-bound source credentials.

No Rust FDW rewrite needed initially: query `mcp_sync.records` directly. Existing
catalog cache and foreign-table semantics remain intact.

## 3. Wire contract version 1

Initialize advertises `experimental.sync:{"version":1}` only when enabled.
`sync/capabilities {"relation":"notes"}` returns:

```json
{
  "version": 1,
  "relation": "notes",
  "primaryKey": ["id"],
  "snapshot": "consistent",
  "changes": true,
  "conditionalWrites": true,
  "idempotency": true,
  "idempotencyRetentionSeconds": 604800,
  "changeRetentionSeconds": 604800,
  "maxPageSize": 500
}
```

Retention is a minimum guarantee. Missing capabilities refuse writable binding.
Snapshot-only sources report changes/conditionalWrites/idempotency false.

`sync/snapshot {relation,snapshotCursor?,limit?}` →
`{snapshotId,rows:[{key,revision,value,deleted}],nextCursor,changeCursor}`.
Key is canonical JSON for the declared PK; revision is opaque nonempty string.
All pages share one snapshot and change boundary; cursors are expiring and
principal-bound. Stage pages, then atomically publish only after completion.
Failed snapshots cannot erase published data. Initial slice rejects snapshot
replacement while pending/conflicted rows exist.

`sync/changes {relation,cursor,limit?}` →
`{events:[{eventId,key,revision,value,deleted,operationId?}],nextCursor,hasMore}`.
Events are ordered within a binding, replayable and include tombstones.
Expired cursor → `resnapshot_required`, never resume silently at present.

`sync/mutate` accepts one record operation:

```json
{
  "relation":"notes", "key":{"id":"n-1"},
  "operationId":"3ae1271f-6b6c-4a6e-933a-c328f166aec7",
  "operation":"update",
  "precondition":{"revision":"opaque-source-revision"},
  "value":{"title":"Edited locally"}
}
```

Create uses `precondition:{"absent":true}`; delete omits value. Success returns
`{operationId,key,revision,value,deleted}`. Identical replay returns original
result even after later edits; different request hash under same ID is rejected.
Deduplication, source revision and source change event commit together.

All controlled-source mutation entrypoints (direct SQL, legacy sql/modify and
ordinary tools included) use that transaction/precondition contract or are
denied by privileges. Source table DML is not exposed as an unversioned bypass.

`sync/operation {relation,operationId}` returns remembered result or
`{status:"unknown"}`. Unknown does not prove a timed-out mutation never committed.
Record first-attempt time; stop retry before guaranteed dedupe retention expires
if outcome remains unknown, then require explicit reconciliation.

MCP errors carry stable `data.syncCode`: revision_conflict,
idempotency_mismatch, resnapshot_required, unsupported_consistency,
permission_denied, invalid_request. Conflict current value/revision is returned
only if principal may read it. All methods enforce record authorization.

## 4. PostgreSQL objects

These are accepted contracts, not currently installed objects.

| Object | Essential columns/constraints |
|---|---|
| bindings | UUID id; tenant/source/principal/relation unique tuple; authorized role; credential_ref; mode; capabilities; enabled |
| records | binding_id/resource_key composite PK; payload JSONB; source_revision text; local_revision bigint; deleted; state; transient expected_local_revision; updated_at/checked_at |
| outbox | operation UUID PK; binding/key; queued_local_revision; expected source revision/absent; immutable operation/payload/hash; status; attempts; next_attempt; lease_until; fencing_token; first_attempt_at |
| checkpoints | binding PK; source cursor; last event; published snapshot; last_success; status |
| inbound_deferred | binding/event unique; complete event; observed_at/applied_at |
| conflicts | binding/key; operation; base/current revisions; local/remote payload; reason/resolution audit |
| source_records | controlled source identity/key; value; opaque revision; tombstone |
| source_heads | source binding PK; transactional change counter; retention boundary |
| source_changes | binding/counter unique; event/revision/operation; durable retention |
| source_operations | principal/relation/operation unique; request hash; outcome; retain_until |

Outbox partial uniqueness prevents multiple pending/claimed/unknown/conflict
operations per row. Index due operations by next_attempt/id; records by binding,
state, update time and optional GIN payload. FKs prevent orphan queue/conflicts.
Tombstones preserve source revision; no automatic garbage collection in slice one.

The controlled source locks its source_heads row and increments counter in the
same transaction as record/change/dedupe writes. This serializes source commits
per binding; an uncommitted transaction cannot be skipped by a later cursor.
Never use a PostgreSQL sequence/max ID as commit order. Snapshot reads a
consistent boundary and data in one MVCC snapshot; continuation pages are served
from an explicitly retained immutable snapshot generation, not fresh reads.
Snapshot retention and page-size limits are configurable and bounded.

## 5. Local SQL and MCP mutation path

Functions `mcp_sync.put(binding,key,payload,expected_local_revision)` and
`remove(binding,key,expected_local_revision)` return local revision/state/
operation_id. Expected zero means create. SQLSTATE 40001 indicates stale local
revision; 55000 indicates pending/conflict blocks edit. Local commit queues work;
it does not acknowledge remote commit.

Direct edit is supported through the same trigger:

```sql
UPDATE mcp_sync.records
SET payload = '{"title":"Edited locally"}', expected_local_revision = 12
WHERE binding_id = :binding AND resource_key = '{"id":"n-1"}';
```

BEFORE checks locked OLD revision, rejects absent/stale expected revision and
metadata tampering, increments local revision, clears transient precondition,
sets pending. AFTER inserts immutable outbox using OLD source revision. SQL
rollback rolls both back. Clients check affected row count when WHERE matches
nothing. Identity cannot change. Physical DELETE is denied; remove/tombstone
UPDATE applies the same hooks. MCP local-cache mutations invoke these functions.

One pending local mutation per record initially. Conflict resolver
`resolve(conflict_id,strategy,expected_local_revision)` permits accept_remote
(discard local intent after fresh check) or retry_local (new operation ID based
on reviewed current source revision). Keep audit evidence. No force-write mode.

## 6. Permissions, lock order, transitions

Separate NOLOGIN schema owner, NOLOGIN inbound-apply owner, worker login and
per-binding app roles. Revoke PUBLIC function execution; fixed
search_path=pg_catalog and qualified names. Application roles cannot SET ROLE
to privileged roles. FORCE RLS plus explicit function binding checks use
server-controlled role mappings, never freely settable tenant session flags.
Binding revocation denies reads/writes immediately.

Worker-only functions: claim_outbox, ack_outbox, record_conflict, apply_changes,
publish_snapshot, pause_binding. Trigger echo suppression checks dedicated
apply execution role only. App cannot modify metadata/outbox/checkpoints,
disable triggers, TRUNCATE, or invoke privileged apply.

Claim uses SKIP LOCKED, database-time lease and fencing increment, commits
before I/O. Transactions touching both lock record then outbox. Claim touches
only outbox. Multi-record inbound batches lock canonical binding/key order.
Ack verifies fencing token and queued revision. Lease renewal needs same fence.

Ack also requires an in-flight outbox status. Event-as-ack atomically terminalizes
that operation. Any later worker ack is a no-op, even when its fence still
matches; it cannot replace data installed by subsequent inbound events.
NOTIFY is optional wakeup; durable status scanning is correctness mechanism.

| Event | Transition |
|---|---|
| Local SQL/MCP edit | clean → pending + outbox in one transaction |
| Claim | pending → claimed; fence increases; lease recorded |
| Remote success | conditional ack → clean/tombstone, outbox acknowledged |
| Network uncertainty | unknown/retry, same operation ID |
| Lease expires | newer claimant/fence may retry; stale ack rejected |
| Explicit source CAS mismatch | conflict, preserve local/remote evidence |
| Token expiry/revocation | pause binding; never anonymous retry |
| Pull on clean row | apply revision/value/tombstone + checkpoint atomically |
| Pull on pending row | retain payload, store deferred event + checkpoint |
| Dedupe horizon expires unknown | blocked, explicit reconciliation |

Source-side CAS is required against external MCP writers; local row locks are
not distributed locks. Delivery is at least once with repeat-safe effects, no
cross-system atomic commit claim.

## 7. Acceptance tests

1. Load 10,000 rows, stop source, prove indexed local SELECT issues zero remote
   requests and exposes stale/pending metadata.
2. Race two SQL sessions with same expected revision: one commits, one gets
   40001, one outbox operation; rollback restores payload/revision/outbox.
3. Race external MCP edit against queued SQL edit: source CAS permits at most
   one at the expected revision; conflict retains both edits.
4. Kill worker before remote call, after remote commit/before ack, and after
   lease expiry. Retry identical ID yields one remote effect; stale fence fails.
5. Pull during pending edit cannot overwrite it; checkpoint/deferred event
   survive restart and reconcile after ack/conflict.
6. Replay pages/tombstones; no duplicate effect/resurrection. Expired cursor
   requires snapshot; incomplete snapshot leaves published rows intact.
7. Hold earlier source transaction open while later writer attempts commit:
   cursor cannot skip earlier change. Aborted writer creates no cursor hole.
8. Same resource under two tenants/principals never shares rows/checkpoints/
   conflict payload; revoked binding cannot read cached data.
9. App role cannot SET echo bypass, alter metadata, disable hooks, TRUNCATE,
   SET ROLE to worker/owner, or invoke apply; authorized pull creates no echo.
10. Timeout/token expiry retains pending work without false acknowledgment.
11. Reuse operation ID with different payload rejects; outcome unknown beyond
    dedupe retention blocks rather than retrying as new mutation.
12. Unsupported source rejects writable binding; hosted sandbox does not advertise durable sync and never crosses session boundaries.
13. Second local edit during pending rejects; resolution requires current local
    revision and new operation ID for retried intent.
14. Run real PostgreSQL multiprocess race/crash tests, not mocks alone. Verify
    no transaction/row lock remains held during remote network waits.
15. Source commit → matching event acknowledges → newer source event applies →
    delayed worker success must leave the newer payload/revision intact.
16. Attempt source changes via direct SQL, ordinary tools and legacy sql/modify:
    each enforces revision/change/deduplication or denies the write entirely.

## 8. Rollout, operations and rollback

Land/accept docs-only ADR/PRD, then source contract+conformance, Liquibase
schema/roles/hooks, worker+controlled adapter, failure tests and operator guide.
Read-only is default; writes enable per binding after capability verification.

Report queue depth, oldest pending age, retry/lease count, conflicts, blocked
operations, last pull and cursor lag. Logs name binding/operation, never tokens
or full payloads. Measure local/source latency honestly before speedup claims.

Rollback pauses workers and app writes, reconciles/exports pending operations,
then disables subsystem while preserving tables/conflicts. Never DROP tables
with pending/unknown work as routine rollback. Existing FDW and hosted sandbox
routes remain usable. Schema deletion needs separate destructive authorization.

## 9. Review decision

Accept ADR-009 with: reject stale writes; one pending edit per row; indexed
JSONB regular tables first; controlled CAS-capable source first; no automatic
merge; unknown outcome beyond dedupe horizon blocks. Implementation begins only
after maintainer sign-off and required docs-only sequencing, or an explicit
maintainer exception to that sequencing.
