# Persistence (PRD-4)

## Contract

`Noizu.MCP.Persistence` is the provider contract for the three
lib-owned stores:

| Store | Contents |
|-------|----------|
| `toolsets` | DB-defined toolsets |
| `toolset_grants` | per-caller `%Permission.Grant{}` records |
| `toolset_negotiations` | per-tool `%Permission.Negotiation{}` consent records |

A provider implements `put/get/list/delete/version` (+ optional
`ping`). Provider truth is the shared conformance suite (AP-8), not
callback internals. Three providers ship:

- `Memory` — default; one lazily-created public ETS table.
- `Ecto` — raw SQL over lib-owned Postgres tables.
- `Disabled` — `:disabled` is a **policy** (no persisted layers), not
  an outage; every call is a no-op.

## Provider invariants

Every provider must honor the shared store invariants:

- **Expiry** — `expires_at <= at` records are excluded on get AND
  list; callers never re-implement expiry.
- **JSON round-trip** — atoms restored, datetimes ISO8601, toolset
  `base` via `to_existing_atom` with `{:unknown_base}` fallback.
- **Subjects** — JSON scalars normalized to string form on both sides.
- **Upsert-by-id, idempotent delete.**
- **Monotonic per-store `version/2`** bumped on every write.
- `list/3` is `inserted_at desc` — the "most recent negotiation wins"
  rule reads off list order. Filters are exact-match; unknown filter
  keys exclude.

One shared encode/decode pipeline (`encode_record`/`revive_record`)
serves structured and blob stores alike — columns rebuilt or
JSON-round-tripped — so wire shape and stored shape cannot drift.

## Selection (D3, lazy)

Provider resolution happens per call: explicit
`opts[:providers][:persistence]` → per-server `:persistent_term` stash
(`{server, :persistence}`) → Application env (read at call time) →
`:memory`. One resolution per server is made at boot and stashed;
per-call explicit opts still win.

## Store — host write facade (§4.7)

`Noizu.MCP.Store` is the only sanctioned write path. The order is
normative:

    provider put (version bumps internally)
      → Toolset.Cache.invalidate (per-toolset slug)
      → notify_changed(:tools) fan-out

Notify is **best-effort by contract (D5)**: the write already
succeeded, so fan-out failures are logged, never raised.
`server: :all` (default) fans out over `running_servers/0`; a delete
that only knows the id invalidates ALL cached toolsets (correctness
over cost). Store renders nothing to the wire (D2) — the toolset
context pass is the only reader of persisted records.

## Boot gate (D4)

`Persistence.Ping` is a permanent child started by the server
supervisor for every resolved provider except the Memory/Disabled
built-ins (Memory cannot fail boot; Disabled is a policy, nothing to
ping). `init/1` pings the provider (Ecto shape: `{:tables_missing,
names}`); failure ⇒ `{:stop, reason}` ⇒ the server **does not boot**.
A misconfigured store must not degrade into a server pretending
persistence works. The gate survives as a `:ping` `handle_call` for
post-boot health checks.

## Migrations

Lib-owned tables ship as change sets, not per-table Ecto migrations.
Host integration is Oban-shaped: the host writes ONE Ecto migration
whose `up`/`down` delegate to `Migration.Runner.up/down(repo, registry,
to: ...)`.

- Registry = a `change_sets/0` callback returning
  `%ChangeSet{name, version, up, down, note}` thunks of raw SQL.
  `Noizu.MCP.Migrations` is the shipped default (`V1Toolsets`); hosts
  extend it, versions strictly increasing after the lib's.
- The ledger `noizu_mcp_schema_versions` is created BEFORE anything
  else (no change set references it in its own DDL).
- Each set applies in its own Postgres transaction
  (whole-or-rollback). `up` applies pending sets ascending to `to:`
  (re-runs no-op); `down` reverts descending — a missing `down` is an
  explicit `{:no_down, name}` error, never a silent skip.
- `applied/1` / `status/2` expose ledger introspection.

OAuth authorization-server tables are separate: `priv/liquibase/`
(Liquibase owns schema deployment there).
