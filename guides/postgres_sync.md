# PostgreSQL cache synchronization (experimental v1)

This optional subsystem creates **regular PostgreSQL tables** for local reads and
processing. A `SELECT` from `mcp_sync.records` makes no MCP request. SQL and MCP
writers use explicit revisions; a SQL commit queues local intent, and the worker
acknowledges it only after the source commits. The hosted `mcp.elixirmcp.dev`
sandbox remains ephemeral and does not advertise this durable protocol.

The first writable source is `Noizu.MCP.Sync.RevisionedDataset`, backed by
PostgreSQL. Other sources must explicitly implement consistent snapshots,
resumable tombstone changes, atomic conditional writes and durable idempotency.
`sql/modify`, timestamps and ordinary VFS version stamps do not establish those
guarantees. Typed generated tables, automatic merges and VFS write synchronization
are outside this version.

## Install source and cache databases

Install the library version containing ADR-009 and PRD-13. Add `ecto_sql` and
`postgrex` to the host's dependencies and configure separate source and cache
`Ecto.Repo` connection pools. PostgreSQL 14 or newer is required. PostgreSQL owns
all locks and queues; the library starts no database or worker automatically.

Include `priv/liquibase/noizu_mcp_sync.yaml` in each host's Liquibase changelog,
keeping its sibling `priv/sql/noizu_mcp_sync.sql` relative path intact. Run as the
schema administrator, once against each dedicated database:

```sh
liquibase --changelog-file=priv/liquibase/noizu_mcp_sync.yaml \
  --url="$SOURCE_JDBC_URL" update
liquibase --changelog-file=priv/liquibase/noizu_mcp_sync.yaml \
  --url="$CACHE_JDBC_URL" update
```

Supply credentials through the host's secret manager or Liquibase configuration;
never put them in source files. The migration creates NOLOGIN roles
`mcp_sync_owner`, `mcp_sync_apply`, `mcp_sync_worker` and `mcp_sync_client`.
Create restricted LOGIN roles using your normal password/credential process:

```sql
-- Cluster administrator; these roles deliberately have no password here.
CREATE ROLE notes_source LOGIN;
CREATE ROLE notes_cache LOGIN;
CREATE ROLE notes_worker LOGIN;
GRANT mcp_sync_client TO notes_source, notes_cache;
GRANT mcp_sync_worker TO notes_worker;
```

Connect `SourceRepo` as `notes_source`, `CacheRepo` as `notes_cache` and
`CacheWorkerRepo` as `notes_worker`. Do not connect application pools as owners
or superusers, and never grant them `mcp_sync_apply` or `mcp_sync_owner`.
`SET ROLE` on an administrator connection does not simulate these clients:
authorization uses the authenticated PostgreSQL `session_user`.

Register a binding administratively in **each** database. This example uses the
same binding UUID in both; if they differ, set the cache binding's
`source_binding_id` to the source UUID. Bindings are unique by
`(tenant_id, source_id, principal_id, relation)`:

```sql
-- Source database: app_role = 'notes_source'.
-- Cache database:  app_role = 'notes_cache'.
INSERT INTO mcp_sync.bindings
  (id, tenant_id, source_id, principal_id, relation, app_role,
   access_mode, capabilities)
VALUES (
  '11111111-1111-4111-8111-111111111111',
  'my-team', 'notes-service', 'operator', 'notes', 'notes_source',
  'read_write',
  '{"version":1,"snapshot":"consistent","changes":true,
    "conditionalWrites":true,"idempotency":true,
    "idempotencyRetentionSeconds":604800,"changeRetentionSeconds":604800}'
);
```

For an external source, store its negotiated guarantees, not the example above.
Use `access_mode='read_only'` unless all writable guarantees were verified. The
controlled source's direct base-table DML is denied, so every source edit uses
`source_mutate` with the same CAS and deduplication transaction.

## Seed the source and take a snapshot

As `notes_source`, create a record conditionally:

```sql
SELECT mcp_sync.source_mutate(
 '11111111-1111-4111-8111-111111111111',
 '{"relation":"notes","key":{"id":"n-1"},
   "operationId":"22222222-2222-4222-8222-222222222222",
   "operation":"create","precondition":{"absent":true},
   "value":{"title":"Source note"}}'
);
```

In the host's `iex -S mix`, with the three Repos started by its supervisor:

```elixir
alias Noizu.MCP.Sync.{RevisionedDataset, Store, Worker}

binding = "11111111-1111-4111-8111-111111111111"
source = {RevisionedDataset,
          %{repo: MyApp.SourceRepo, binding_id: binding, relation: "notes"}}
opts = [store_repo: MyApp.CacheWorkerRepo, binding_id: binding, source: source]
{:ok, _} = Worker.snapshot(opts)
```

Snapshots are bounded to 100,000 rows/64 MiB at the controlled source and 500 rows
per page, with 15-minute immutable pagination generations. The worker additionally caps accumulation at 64 MiB and 1,000 pages
(`max_snapshot_bytes`, `max_snapshot_pages`, `max_snapshot_rows` options). It stages all
pages before one atomic publish; failure cannot erase the old cache. Replacement
is refused while pending, conflicted or blocked local intent exists.

As `notes_cache`, inspect local data and freshness:

```sql
SELECT resource_key, payload, local_revision, source_revision, state, checked_at
FROM mcp_sync.records
WHERE binding_id='11111111-1111-4111-8111-111111111111';
SELECT source_cursor, status, last_success_at FROM mcp_sync.checkpoints;
```

Local rows remain queryable when the source is offline. `checked_at` and
checkpoint `last_success_at` tell you how old the observation is; a cached clean
row does not promise the remote source is unchanged. Binding revocation denies
local access immediately.

## Edit from SQL and synchronize

Read the actual `local_revision`, then supply that exact value:

```sql
SELECT mcp_sync.put(
 '11111111-1111-4111-8111-111111111111', '{"id":"n-1"}',
 '{"title":"Edited through SQL"}', 1
);
-- Equivalently, direct DML uses the same BEFORE/AFTER hooks:
-- UPDATE mcp_sync.records SET payload='{"title":"Edited through SQL"}',
--   expected_local_revision=1
-- WHERE binding_id='11111111-1111-4111-8111-111111111111'
--   AND resource_key='{"id":"n-1"}';
```

The result is `pending` with an `operationId`. The hook consumes the expected
revision and atomically queues an immutable operation. Rollback removes both.
A stale observed revision fails with SQLSTATE `40001`; another pending edit fails
with `55000`. Metadata edits and physical `DELETE` are denied. For deletion use
`mcp_sync.remove(binding, key, expected_local_revision)`, which queues a tombstone.
Direct `UPDATE` callers must also check affected row count.

```elixir
{:ok, _} = Worker.run_once(opts)  # one claim, remote CAS, fenced acknowledgment
{:ok, _} = Worker.pull_once(opts) # one durable change page and atomic checkpoint
```

For continuous synchronization, add this child to the host supervision tree
**after its Repos and authenticated client, if any**:

```elixir
{Noizu.MCP.Sync.Worker,
 Keyword.merge(opts, enabled: true, poll_interval: 1_000,
               timeout: 5_000, lease_seconds: 30)}
```

Each child handles one binding, one queued write and one change page per poll.
`enabled: false` (the default) starts nothing. Calls must not run inside a Repo
transaction. Remote calls use bounded tasks; killing a worker cancels its local
callback but does not prove a remote mutation failed. Durable operation lookup
and identical retry resolve uncertain outcomes. Once the dedupe guarantee is
exhausted, unresolved intent becomes `blocked`, requiring operator reconciliation. A retained source `sync/operation` result may
still prove its outcome, but expired blocked work is never automatically reissued.

## Expose the source over MCP

The host remains responsible for OAuth and authenticated-principal resolution.
For example, resolve a fixed binding from trusted context in a server callback:

```elixir
defmodule MyApp.NotesMCP do
  use Noizu.MCP.Server, name: "notes", version: "1", sync: true

  @impl true
  def handle_sync(method, params, %{auth: %{subject: "operator"}}) do
    source = {Noizu.MCP.Sync.RevisionedDataset,
      %{repo: MyApp.SourceRepo,
        binding_id: "11111111-1111-4111-8111-111111111111", relation: "notes"}}
    Noizu.MCP.Sync.Protocol.dispatch(source, method, params)
  end

  def handle_sync(_, _, _),
    do: {:error, Noizu.MCP.Sync.Protocol.error("permission_denied")}
end
```

A multi-user host needs a server-controlled principal-to-binding mapping and
correct restricted source connection for each identity. Never take a Repo,
binding ID, credential or principal from MCP request parameters. The feature is
advertised as `experimental.sync={"version":1}` only when explicitly enabled and
implemented. The five methods are `sync/capabilities`, `sync/snapshot`,
`sync/changes`, `sync/mutate`, and `sync/operation`; the request/response contract
is in PRD-13. Conditional MCP edits use the **source revision**, not local revision:

```json
{"relation":"notes","key":{"id":"n-1"},
 "operationId":"33333333-3333-4333-8333-333333333333",
 "operation":"update","precondition":{"revision":"REVISION_FROM_SOURCE"},
 "value":{"title":"Edited through MCP"}}
```

Point a worker at an already authenticated MCP client using
`{Noizu.MCP.Sync.RemoteSource, %{client: client_pid, relation: "notes"}}` as its
`:source`. For an engine-attached upstream, use relation `"upstream.notes"`.
Federated sync requires `auth_ref="passthrough"`, per-principal sessions,
engine dataset authorization and a negotiated upstream sync v1 capability.
Allow the upstream connection timeout plus cleanup time for the management
attach request (for example a 1-second connect timeout and a 10-second attach
request timeout in local tests). Protected upstreams may reject the anonymous
catalog session; its error status does not replace or authorize a principal
session. Sync requests establish the separately authenticated principal session.
Pooled service credentials are refused for this path; a deliberately configured
single-principal `RevisionedDataset` or `RemoteSource` remains available directly.

A host MCP tool that edits the **local cache** must call
`Store.put(CacheRepo, binding, key, payload, expected_local_revision)` or
`Store.remove/4`; this uses the same SQL hooks. Do not register the source as a
legacy writable Dataset: `sql/modify` has no revision/idempotency preconditions.

## Conflicts, operations and rollback

If an MCP source edit wins while a SQL edit is pending, source CAS rejects the
SQL operation and preserves local intent plus remote evidence in
`mcp_sync.conflicts`. Pull again to record a fresh source observation before
resolving. Read the current local revision, review the evidence, then:

```sql
SELECT id, resource_key, local_payload, remote_evidence, reason
FROM mcp_sync.conflicts WHERE state='open';
SELECT mcp_sync.resolve('CONFLICT_UUID', 'accept_remote', CURRENT_LOCAL_REVISION);
-- Or retry_local: new operation ID, CAS against the latest observed source
-- revision. A further concurrent source edit produces another conflict.
```

If a source cursor expires (`resnapshot_required`), explicitly call
`Worker.snapshot(opts)` after reconciling pending/conflicted intent. Incomplete
replacement preserves existing rows.

`accept_remote` discards the reviewed local intent; `retry_local` queues a new
conditional operation. There is no force-write or automatic merge mode.
Delayed worker responses cannot overwrite newer inbound events. Source changes
use a transactional per-binding counter, not a sequence as a commit cursor.
This serializes writers within a source binding as a deliberate first-version
tradeoff. Notifications are optional; the durable queue is authoritative.

Monitor outbox state/count/oldest `created_at`, attempts, conflicts, blocked work,
checkpoint `last_success_at`, and `[:noizu_mcp, :sync, :poll]` telemetry. Payloads
and credentials are excluded from worker telemetry. Expired/revoked credentials
pause synchronization; fix credentials, then call `Store.resume(CacheWorkerRepo, binding)`
(or worker-only `mcp_sync.resume_binding(binding)`) explicitly. This does not
unblock outcomes that require reconciliation. To revoke a
binding administratively, set `bindings.enabled=false`. To roll back, stop
workers and writes, reconcile/export pending intent and keep tables/evidence.
Never drop tables with pending or unknown operations as routine rollback.

## Run real PostgreSQL validation

```sh
scripts/test_sync.sh
```

The script starts a disposable loopback PostgreSQL cluster, installs separate
source/cache databases, runs restricted LOGIN roles and real race/crash tests,
then removes only its own cluster. Set `MCP_SYNC_PG_BIN` if PostgreSQL executables
are not on PATH. It requires PostgreSQL binaries, Mix and the project's shared
dependencies. This is an integration harness, not a production install command.
