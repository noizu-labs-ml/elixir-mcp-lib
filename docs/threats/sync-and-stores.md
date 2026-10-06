# Data Stores & Synchronization Controls

Detail for T-003, T-007, T-008, T-013. Schema reference:
[../PROJ-SCHEMA.md](../PROJ-SCHEMA.md) (per-table detail under `schema/`).

## Credentials at rest (T-003)

- Convention enforced across all shipped schemas: hash columns hold SHA-256
  hex (64 chars); password-ish columns (`secret_hash`, `password_hash`,
  `recovery_hashes`) hold caller-hashed Argon2/PBKDF2 strings — the library
  never re-hashes or stores plaintext.
- Public identifiers (`mcp_agent_accounts.id`, `handle`, `fingerprint`,
  `public_key`) are plaintext **by design** — documented, not an oversight.
- Purge sweeps (`purge_expired/2`) garbage-collect expired sessions, codes,
  JTIs; undefined-table during the agent sweep is tolerated (optional tables).

## Synchronization correctness (T-007, ADR-009)

All correctness is PostgreSQL-owned — the library holds no authority state in
process memory:

- **CAS**: `mcp_sync.records` writes require `expected_local_revision` to
  match (`40001 revision_conflict` otherwise); a `_record_guard` trigger also
  denies physical DELETE and client edits to sync metadata.
- **Fencing + leases**: outbox claims carry monotonically increasing fencing
  tokens; stale workers cannot commit over a new claimant.
- **Idempotency**: `source_operations` keyed by `(binding_id, operation_id)`
  with `request_hash`; `unknown` outcomes are resolved by probing
  `sync/operation`, never by blind retry.
- **Role separation**: NOLOGIN roles; apps connect as restricted LOGIN roles
  granted only `mcp_sync_client` (or `_worker`); authorization checks the
  authenticated `session_user` — `SET ROLE` does not simulate a client.
- **One pending op per resource** (partial unique index) prevents duplicate
  outbound intents; **one open conflict per operation** keeps resolution
  single-threaded.

## Principal binding (T-008 — host audit)

The `Sync.Source` contract requires state to be server-controlled and bound
to one principal+relation, resolved from the authenticated principal — never
from request parameters. This is a **contract the host code must uphold**;
the database cannot distinguish a correctly derived `principal_id` from a
sloppily derived one. Any new Source implementation must be reviewed against
this rule (see `Sync.Source` moduledoc; ADR-009).

## Operational hygiene (T-013)

`erl_crash.dump` is gitignored; hosts running the library must keep crash
dumps and structured logs (which may carry JSON-RPC frames) out of
world-readable storage. The Inspector ring buffer lives only in memory.
