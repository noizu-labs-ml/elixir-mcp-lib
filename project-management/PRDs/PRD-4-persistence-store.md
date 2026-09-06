# PRD-4: Persistence, Migrations, Grant/Negotiation Records & Store

**Series**: noizu_mcp 0.3.0 toolset architecture (PRD-4 of 5)
**Repo**: `Portfolio/Libs/ai/elixir-mcp` (anchors relative to this root)
**Version policy**: **this is the final lib PR of the series** — merges on `main` AND bumps `mix.exs` `@version` `"0.2.0"` → `"0.3.0"` (`mix.exs:4`). Single hex publish happens AFTER this PR (user-run, 2FA OTP — INDEX.md publish plan).
**Depends on**: PRD-1, PRD-2, PRD-3 — cumulative state green
**Status**: Draft
**Design rules**: D1–D5; anti-pattern target here: **multi-layer persistence combinatorics** — ONE persistence abstraction + ONE shared provider conformance suite; no per-provider behavior forks
**Freeze**: interfaces specified here are FROZEN for 0.3.0 (see §10)

---

## 1. Goal

Give toolsets durable, lib-owned state and a host-facing write path:

1. `Noizu.MCP.Persistence` behaviour + three built-in providers: `Memory` (ETS), `Disabled`, `Ecto` (raw-SQL over lib-owned Postgres tables; `ecto_sql` stays an optional dep — `mix.exs:50`).
2. `Noizu.MCP.Migrations` behaviour + `Migration.Runner` (Oban-style host entry) + shipped `Migrations.V1Toolsets` DDL for `noizu_mcp_toolsets`, `noizu_mcp_toolset_grants`, `noizu_mcp_toolset_negotiations` (+ versions/store-version tables).
3. `Noizu.MCP.Permission.Grant` / `Noizu.MCP.Permission.Negotiation` records — the policy payloads the context pass folds as weight-200 layers (PRD-3 §4.2 seam filled).
4. `Noizu.MCP.Store` — host write facade: provider write → version bump → cache invalidate → `notify_changed(:tools)` chain to live sessions.
5. Provider selection/precedence resolved per architecture (per-server > Application env READ AT CALL TIME > `:memory`).

**Out of scope**: NPL providers over NPL tables (PRD-5 — permanent disposition, decision 2: lib-owned tables serve ONLY lib-default/non-NPL consumers).

---

## 2. Decision log applied

| Rule | Binding |
|------|---------|
| D1 one resolver | The context pass remains the only place policy meets tools; PRD-3's `Context.layers/3` default gains its persisted layers here. Listing/dispatch/manifests see grants ONLY as merged ops — never via a side-channel. |
| D2 effective materialization | Grants/negotiations produce ops; materialization still happens once, in pass 3. Records are never rendered to the wire. |
| D3 runtime-only | `Application.get_env(:noizu_mcp, :persistence)` is read at CALL time (test proves live env mutation takes effect); supervisor init resolves the per-server value once into session opts. |
| D4 explicit participation | Providers are named explicitly (opts or app env). No auto-detection of repos/tables. Ecto provider hard-fails at startup if tables are absent — never silently degrades. |
| D5 fail-closed per set / fail-open per server | Persistence provider failure ⇒ toolsets that NEED persisted layers degrade to their static+ACL surface (logged + telemetry), server healthy; EXCEPT the Ecto provider's startup table check (config error ⇒ boot failure, by design). |
| Decision 1 (publish) | Version bump + changelog land in this PR; publish is a user-run step AFTER merge (INDEX.md checklist). |
| Decision 2 (NPL disposition) | Lib-owned tables are for lib-default and non-NPL consumers. NPL NEVER migrates `mcp_custom_scopes`/`toolset_config` data into them (PRD-5 reads and translates at resolution time instead). |

---

## 3. Background

PRD-3 shipped the weighted merge engine and left `Context.layers/3` returning only the ACL layer. Hosts need: DB-defined toolsets (slug-addressable), per-caller grants carrying per-tool overrides, and a consent (negotiation) gate for scope-gated tools. The auth server already has its own ETS/Ecto store pair (`lib/noizu/mcp/auth/server/store.ex` + `store/ecto.ex`, `store/ets.ex`) — this PRD follows its shape (shared conformance suite precedent: `test/support/store_conformance_case.ex`) but stays a SEPARATE subsystem: toolset policy storage, not token storage.

NPL's permanent disposition (decision 2) means the lib tables serve the generic case; NPL's PRD-5 provider implements this same behaviour over NPL's own tables and the lib tables stay empty in NPL deployments.

---

## 4. Public surface

### 4.1 `lib/noizu/mcp/persistence.ex` — behaviour

```elixir
defmodule Noizu.MCP.Persistence do
  @store_keys ["toolsets", "toolset_grants", "toolset_negotiations"]

  @callback put(store_key, id :: String.t(), record :: map() | struct(), opts) :: :ok | {:error, term()}
  @callback get(store_key, id :: String.t(), opts) :: {:ok, record} | :error | {:error, term()}
  @callback list(store_key, filter :: map(), opts) :: {:ok, [record]} | {:error, term()}
  #   filter keys: exact-match terms per store (e.g. %{toolset_slug: s, authenticator: a,
  #   subject: subj}) plus :at (DateTime, default now) — records with expires_at <= at
  #   are EXCLUDED by every provider (expiry is a store invariant, not caller logic).
  @callback delete(store_key, id :: String.t(), opts) :: :ok | {:error, term()}
  @callback version(store_key, opts) :: {:ok, String.t()} | {:error, term()}
  #   monotonic per-store version string feeding catalog_version / cache keys.
  @callback ping(opts) :: :ok | {:error, term()}   # default: version(store_key) roundtrip
end
```

Records are LIB structs / normalized maps, JSON-encoded by the provider (`Jason` round-trip is the conformance contract — atoms flatten to strings; providers must `json_decode_with_atoms!` on read).

### 4.2 Built-in providers

```elixir
# lib/noizu/mcp/persistence/memory.ex
Noizu.MCP.Persistence.Memory
# single public ETS (`:noizu_mcp_persistence`), lazy-created; rows {store_key, id, json, meta};
# version = in-ETS monotonic counter per store_key. Default provider.

# lib/noizu/mcp/persistence/disabled.ex
Noizu.MCP.Persistence.Disabled
# every call ⇒ {:error, :persistence_disabled}. The `:disabled` alias resolves here.
# Context pass treats this as "no persisted layers" (D5-correct: not a failure, a policy).

# lib/noizu/mcp/persistence/ecto.ex  (compiled only when ecto_sql present)
Noizu.MCP.Persistence.Ecto
# opts: [repo: MyApp.Repo]. Raw SQL only (parameterized) — no Ecto schemas over lib
# tables (host repo ownership stays clean; mirrors auth/server/store/ecto.ex philosophy).
# init/ping: verifies noizu_mcp_schema_versions + the three tables exist
# (information_schema query). Absent ⇒ {:error, {:tables_missing, [names]}} and the
# supervisor child spec RAISES at boot (D4: config errors must not boot).
```

### 4.3 Selection & precedence (normative)

```elixir
# (1) per-server opts (highest):
use Noizu.MCP.Server,
  persistence: :memory | :disabled | Provider | {Provider, opts}
  # or the combined form — providers: WINS over individual keys when both present:
  providers: [persistence: Provider | {Provider, opts}, acl: Provider | {Provider, opts}]

# (2) Application env — READ AT CALL TIME (D3):
Application.get_env(:noizu_mcp, :persistence)          # same value shapes
Application.get_env(:noizu_mcp, :providers)            # combined form

# (3) default: :memory
```

- **Supervisor init**: `Noizu.MCP.Server.Supervisor.init/1` (`lib/noizu/mcp/server/supervisor.ex:24-34`) resolves the provider once: Ecto-backed providers add a `ping` child that boots the supervisor (hard-fail, §4.2); the resolved provider + opts are passed into session init opts and stashed in a `:persistent_term` (`{__MODULE__, :persistence}`) for non-session callers.
- **Lazy re-resolution**: `Noizu.MCP.Persistence.resolved(opts)` — explicit `opts[:persistence]`/`opts[:providers]` > per-server persistent_term (when called in a server ctx) > Application env (call time) > `:memory`. Used by Store, Context pass, and direct `Toolset` calls without a session.
- ACL analog: `providers: [acl: ...]` overrides the `acl:` opt from PRD-2 when `providers:` is present (the combined form wins per §4.3). `Noizu.MCP.ACL.current_provider/2` (PRD-2 §4.6) extends its lookup with the same chain.

### 4.4 Permission records — `lib/noizu/mcp/permission.ex`

```elixir
defmodule Noizu.MCP.Permission.Grant do
  @derive Jason.Encoder
  @enforce_keys [:id, :toolset_slug, :authenticator, :subject, :effect]
  defstruct [
    :id,                # String.t() — host-assigned (uuid/slug)
    :toolset_slug,      # String.t()
    :authenticator,     # String.t() | atom() — matches Principal.authenticator
    :subject,           # JSON scalar — matches Principal.subject (persistence requires
                        #   subjects be JSON scalars: string | integer; provider validates on put)
    :effect,            # :allow | :deny
    scopes: [],         # [String.t()] — :allow grants ADD to effective scopes (§4.6)
    tool_overrides: %{},# %{String.t() base-tool-name => [%Override{}]} — folded at weight 200
    expires_at: nil,    # DateTime.t() | nil
    inserted_at: nil,   # DateTime.t() — set by provider on put
    metadata: %{}
  ]
end

defmodule Noizu.MCP.Permission.Negotiation do
  @derive Jason.Encoder
  @enforce_keys [:id, :toolset_slug, :authenticator, :tool]
  defstruct [
    :id, :toolset_slug, :authenticator,
    :tool,                 # String.t() base tool name
    required_scopes: [],   # [String.t()]
    granted: false,        # consent recorded?
    metadata_overrides: %{},  # %{String.t() key => term} — folded as ops ONLY when granted (§4.6)
    expires_at: nil, inserted_at: nil, metadata: %{}
  ]
end
```

`toolsets` store records: normalized maps matching `%Toolset.Custom{}` fields (`slug, title, description, base (module-name STRING — restored to atom on read via `String.to_existing_atom` with a `:unknown_base` error fallback), immutable, include, exclude, tools (ops serialized per PRD-1 §4.5 encoding), metadata`). Slug-addressable: `%Custom{}` with `base: "other-slug"`… NOT in 0.3.0 — slug references resolve ONLY at the `toolset:` MFA level (host resolves slug → record → `%Custom{}` via `Store.get`); the lib never chases slug chains (D4).

### 4.5 Context-pass persisted layers (fills PRD-3 §4.2 seam)

`Noizu.MCP.Toolset.Context.layers/3` default implementation, when the resolved provider is enabled and `toolset.immutable` is false:

- **Grant layer** — `list("toolset_grants", %{toolset_slug: t.slug, authenticator: p.authenticator, subject: p.subject})` (no principal ⇒ skip, no grant layers):
  - `:allow` grants ⇒ `tool_overrides` become `%Override{}` ops at `weight: 200, layer: {:persisted, grant_id}`; grant `scopes` join the caller's effective scope set.
  - `:deny` grants ⇒ `%Override{op: :set_visible, value: false, ...}` + `:set_callable false` ops at weight 200 — overrides static (100), overridden by ACL (300).
  - **Grants never HIDE what the static pass shows.** Absence of a grant is not a denial; visibility gating belongs to ACL (weight 300, provider-configured default-deny). This is the explicit-participation boundary between the two mechanisms — asserted by AP-10.
- **Negotiation layer** — `list("toolset_negotiations", %{toolset_slug: t.slug, authenticator: p.authenticator})`; per tool with a negotiation record:
  - satisfied when `granted == true` **or** `required_scopes ⊆ effective_scopes` (effective = `Principal.granted_scopes` ∪ allow-grant scopes);
  - satisfied + `granted == true` ⇒ `metadata_overrides` fold as ops (weight 200);
  - unsatisfied ⇒ entry stays `visible: true`, `callable: false`, `reason: {:negotiation_required, missing_scopes}` (weight 200);
  - `resolve/4` on a `{:negotiation_required, _}` entry ⇒ `{:error, Error.forbidden("tool requires scopes", %{tool: name, required_scopes: required, missing: missing, negotiation: negotiation | nil})}` where `negotiation = %{id, metadata}` is the matched negotiation record (metadata passthrough — hosts carry consent artifacts such as elevation URIs here; PRD-5 §5 depends on this field). The ONE `:forbidden` resolve path (PRD-1's existence-hiding invalid_params remains the rule for ACL-hidden/absent tools; a consent gate is honest, an ACL denial is silent).
  - multiple negotiations for one tool: most recent `inserted_at` wins (store list order is `inserted_at desc` — provider conformance case).
- Layer fingerprint (PRD-3 §4.4 version): `{grant_layer_id, 200, provider.version("toolset_grants")}` and negotiations analog — Store-driven version bumps therefore rotate catalog_version without record reads.

### 4.6 `Noizu.MCP.Migrations` + `Migration.Runner` — `lib/noizu/mcp/migrations.ex`, `lib/noizu/mcp/migration/runner.ex`

```elixir
defmodule Noizu.MCP.Migrations.ChangeSet do
  @enforce_keys [:name, :version, :up]
  defstruct [:name, :version, :up, :down, note: nil]
  # up/down: (repo, opts) -> result thunks (raw SQL inside; Runner wraps each set in a
  # Postgres transaction and records the row in noizu_mcp_schema_versions on success)
end

defmodule Noizu.MCP.Migrations do
  @callback change_sets() :: [%ChangeSet{}]   # order = apply order; versions strictly increasing
end

defmodule Noizu.MCP.Migration.Runner do
  @spec up(repo, migrations :: module(), to: :latest | integer()) :: {:ok, [applied]} | {:error, term()}
  @spec down(repo, migrations :: module(), to: integer()) :: {:ok, [reverted]} | {:error, term()}
  @spec applied(repo) :: {:ok, [%{name: String.t(), version: integer(), applied_at: DateTime.t()}]}
  @spec status(repo, migrations :: module()) :: {:ok, [%{name, version, state: :applied | :pending}]}
end
# tracking table: noizu_mcp_schema_versions (name text pk, version integer not null, applied_at timestamptz not null default now())
```

Host usage (Oban shape — one host migration file delegates to the lib):

```elixir
defmodule MyApp.Repo.Migrations.NoizuMcpToolsets do
  use Ecto.Migration
  def up,   do: Noizu.MCP.Migration.Runner.up(MyApp.Repo, Noizu.MCP.Migrations, to: :latest)
  def down, do: Noizu.MCP.Migration.Runner.down(MyApp.Repo, Noizu.MCP.Migrations, to: 0)
end
```

Shipped set — `lib/noizu/mcp/migrations/v1_toolsets.ex`, `Noizu.MCP.Migrations.V1Toolsets` (name `"v1_toolsets"`, version `1`), registered in the default `Noizu.MCP.Migrations` module (`change_sets/0` = `[V1Toolsets.change_set()]`). Raw-SQL DDL (Postgres; `if not exists` guards make re-runs idempotent):

```sql
create table if not exists noizu_mcp_toolsets (
  slug text primary key,
  title text, description text,
  base text not null,
  immutable boolean not null default false,
  include jsonb, exclude jsonb not null default '[]'::jsonb,
  tools jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  inserted_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists noizu_mcp_toolset_grants (
  id text primary key,
  toolset_slug text not null,
  authenticator text not null,
  subject text not null,
  effect text not null check (effect in ('allow','deny')),
  scopes jsonb not null default '[]'::jsonb,
  tool_overrides jsonb not null default '{}'::jsonb,
  expires_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  inserted_at timestamptz not null default now()
);
create index if not exists noizu_mcp_grants_lookup_idx
  on noizu_mcp_toolset_grants (toolset_slug, authenticator, subject);
create table if not exists noizu_mcp_toolset_negotiations (
  id text primary key,
  toolset_slug text not null,
  authenticator text not null,
  tool text not null,
  required_scopes jsonb not null default '[]'::jsonb,
  granted boolean not null default false,
  metadata_overrides jsonb not null default '{}'::jsonb,
  expires_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  inserted_at timestamptz not null default now()
);
create index if not exists noizu_mcp_negotiations_lookup_idx
  on noizu_mcp_toolset_negotiations (toolset_slug, authenticator, tool);
create table if not exists noizu_mcp_store_versions (
  store_key text primary key,
  version bigint not null default 0,
  bumped_at timestamptz not null default now()
);
```

(`noizu_mcp_schema_versions` is created by `Runner` itself before applying sets — bootstrap-first ordering, so `Migrations.V1Toolsets` never references it in its own DDL.)

### 4.7 `lib/noizu/mcp/store.ex` — host write facade

```elixir
defmodule Noizu.MCP.Store do
  @kind_store [toolset: "toolsets", grant: "toolset_grants", negotiation: "toolset_negotiations"]

  @spec put(kind, record, opts) :: :ok | {:error, term()}
  #   opts: [persistence: ...] | [providers: [...]] (lazy re-resolution §4.3)
  #         [server: module() | :all]  — default :all
  @spec delete(kind, id :: String.t(), opts) :: :ok | {:error, term()}
  @spec get(kind, id, opts) :: {:ok, record} | :error | {:error, term()}
  @spec list(kind, filter, opts) :: {:ok, [record]} | {:error, term()}
  @spec version(kind | store_key, opts) :: {:ok, String.t()} | {:error, term()}
end
```

Write path (normative order): provider.put/delete → provider version auto-bumps (Memory counter; Ecto `noizu_mcp_store_versions` upsert) → `Toolset.Cache.invalidate(record toolset_slug)` (grants/negotiations carry `toolset_slug`; toolsets their own) → notify. Notify: `opts[:server]` module(s) or `:all` → `Noizu.MCP.Server.Supervisor.running_servers/0` (NEW helper; supervisors self-register in a `:persistent_term` registry at `init/1`, deregister on terminate — supervisor.ex `:18-34`) → each server's existing `notify_changed(:tools)` (generated def, `lib/noizu/mcp/server.ex:180-186`) → each session's `handle_cast({:notify_changed, :tools})` (`lib/noizu/mcp/server/session.ex:173-186`) → `notifications/tools/list_changed` on the wire. Notify failures are logged, never raised (D5 — the write already succeeded).

---

## 5. Requirements

**FR-4.1** `Persistence` behaviour per §4.1 with the three store keys; expiry exclusion is a provider invariant (conformance suite).
**FR-4.2** `Memory`, `Disabled`, `Ecto` providers per §4.2; `:memory` default; `:disabled` alias ⇒ `{:error, :persistence_disabled}`; Ecto hard-fails boot on missing tables via supervisor `ping` child (§4.3).
**FR-4.3** Selection/precedence per §4.3 including `providers:`-wins, call-time Application env reads, supervisor-init resolution into session opts, lazy `resolved/1` for direct calls.
**FR-4.4** `%Permission.Grant`/`%Permission.Negotiation` per §4.4 (Jason round-trip; subject JSON-scalar validation on put).
**FR-4.5** Persisted context layers per §4.5: grant ops at weight 200 (`:allow` adds scopes + ops; `:deny` hides/disables below ACL), negotiation satisfaction/unsatisfaction semantics, `forbidden` resolve path for `{:negotiation_required, missing}`, effective-scope union (`Principal.has_scope?/2` glob from PRD-2 applies).
**FR-4.6** `Migrations` behaviour + `ChangeSet` + `Runner.up/down/applied/status` per §4.6 with transactional application and the `noizu_mcp_schema_versions` ledger.
**FR-4.7** `Migrations.V1Toolsets` ships the §4.6 DDL exactly; idempotent re-run; `Runner.status` reports it `:pending` before, `:applied` after.
**FR-4.8** `Store` per §4.7: write → version bump → `Cache.invalidate/1` → `notify_changed(:tools)` chain; `running_servers/0` registry; notify-never-raises.
**FR-4.9** `providers:` combined opt wins over `persistence:`/`acl:` individual opts; per-server wins over Application env; Application env read at call time (D3 test).
**FR-4.10** Persistence-outage behavior: provider `{:error, _}` during context-pass layer fetch ⇒ that toolset composes WITHOUT persisted layers (Logger.warning + `[:noizu_mcp, :persistence, :error]` telemetry), catalog still serves static+ACL (D5). `Disabled` provider is NOT an outage (silent skip).
**FR-4.11** Catalog version rotation: a Store write to `toolset_grants` changes `Toolset.catalog/3` version for provider-backed toolsets without any record-content change (version-string plumbing proof).
**FR-4.12** Version/changelog: `mix.exs` `@version` → `"0.3.0"` (`:4`), CHANGELOG entry covering PRD-1..4 (public surface summary + compat notes).

**Acceptance criteria**

**AC-4.1** Shared conformance suite (`test/support/persistence_conformance_case.ex`, modeled on `test/support/store_conformance_case.ex`) passes for Memory AND Ecto: put/get/list/delete/version/expiry/JSON-round-trip/filter-combos — proving no per-provider forks (AP-8 extension).
**AC-4.2** E2E grant flow: static-hidden-but-callable tool + `:allow` grant with `tool_overrides` rename ⇒ listed under new name for THAT principal only; second principal without grant sees the base surface (grants-never-hide assertion AP-10 included).
**AC-4.3** Negotiation flow: tool with negotiation `required_scopes: ["pm:write"]` — anonymous ⇒ resolve `forbidden` with missing-scopes data; principal with matching scope ⇒ callable; `granted: true` negotiation ⇒ callable + metadata_overrides folded.
**AC-4.4** `:deny` grant beats static `:set_visible true`, loses to ACL deny (weight sandwich test at 100/200/300).
**AC-4.5** `immutable: true` toolset ignores grants/negotiations (PRD-3 §4.1), still ACL-checked — re-asserted with real persisted layers now available.
**AC-4.6** Store write rotates catalog_version and live fixture sessions receive `notifications/tools/list_changed` (session.ex `:173` path) — capture via test transport sink.
**AC-4.7** Runner: fresh DB ⇒ status all-pending → up ⇒ applied ledger rows → down(to: 0) ⇒ clean; crash mid-transaction leaves no partial set (rollback assertion).
**AC-4.8** Ecto provider against a DB without tables: supervisor boot raises `{:tables_missing, _}`; after `Runner.up` boot succeeds (D4 proven both ways).
**AC-4.9** Cumulative suite (PRD-1..3) green; no-provider servers byte-identical (snapshot).

---

## 6. Internal work checklist (anchors)

| Step | File | Detail |
|------|------|--------|
| 6.1 | `lib/noizu/mcp/persistence.ex` | behaviour + `resolved/1` precedence (§4.1, §4.3) |
| 6.2 | `lib/noizu/mcp/persistence/{memory,disabled,ecto}.ex` | providers (§4.2) |
| 6.3 | `lib/noizu/mcp/permission.ex` | records (§4.4) |
| 6.4 | `lib/noizu/mcp/migrations.ex` + `lib/noizu/mcp/migration/runner.ex` + `lib/noizu/mcp/migrations/v1_toolsets.ex` + default `Noizu.MCP.Migrations` | §4.6 |
| 6.5 | `lib/noizu/mcp/store.ex` | facade + notify chain (§4.7) |
| 6.6 | `lib/noizu/mcp/toolset/context.ex` | persisted layers fill the PRD-3 seam (§4.5) |
| 6.7 | `lib/noizu/mcp/server/supervisor.ex` | resolve provider at `init/1` (`:24-34`); ping child for Ecto; `running_servers/0` persistent_term registry |
| 6.8 | `lib/noizu/mcp/server/session.ex` | accept resolved provider via init opts (`:100-116` region) — sessions pass it into ctx-facing calls; no behavior change when `:memory` default |
| 6.9 | `lib/noizu/mcp/toolset/cache.ex` | `invalidate/1` calls from Store (§4.7); grant-fingerprint in version (§4.5) |
| 6.10 | `mix.exs` | `@version "0.3.0"` (`:4`); CHANGELOG.md entry |

---

## 7. Test plan

New files under `test/noizu/mcp/`:

- **`support/persistence_conformance_case.ex`** + **`persistence/memory_test.exs`** + **`persistence/ecto_test.exs`** (Ecto cases tagged `:ecto`, run in CI against a scratch Postgres; skip-with-message locally without DB — matching the auth store suite's pattern) — AC-4.1.
- **`persistence/selection_test.exs`** — precedence matrix (§4.3), `providers:` wins, call-time env mutation (D3), lazy `resolved/1`, Disabled error shape, memory default.
- **`migrations/runner_test.exs`** — AC-4.7 matrix incl. idempotent re-run + out-of-order `to:` guards.
- **`migrations/v1_toolsets_test.exs`** — table/column/index presence post-up (information_schema assertions), AC-4.8 both ways.
- **`toolset/persisted_layers_test.exs`** — AC-4.2/4.3/4.4/4.5 matrix; outage degradation (FR-4.10); effective-scope union + glob (`has_scope?/2` from PRD-2 reused).
- **`store/store_test.exs`** — write path ordering (version bump observable, cache invalidated, notify delivered — AC-4.6); `server: :all` vs single; notify-failure isolation.
- **`store/version_rotation_test.exs`** — FR-4.11.

**Anti-pattern regression tests (series-persistent):**

- **AP-10 (grants are not ACL):** no grant configured + ACL unconfigured ⇒ base surface fully visible (absence ≠ denial). Paired with: ACL provider configured + no verdict ⇒ denied. The two mechanisms never invert each other's defaults — this test is the canary for the "decorative ACL / silent fail-open" family.
- **AP-11 (no data-plane side channels):** the ONLY reader of the three lib tables is the persistence provider (source-level assertion: no direct `repo.query` on `noizu_mcp_toolset*` outside `persistence/ecto.ex` + migrations) — hosts and future layers must go through the behaviour, keeping the NPL permanent-disposition boundary auditable.
- **AP-8 extension:** conformance suite is the single source of provider truth — a fourth provider added later must implement the same case module to claim support (documented in the behaviour moduledoc; enforced by review convention + a test alias running Memory through the case module as the executable example).

---

## 8. Compat & rollback

- Additive: no provider/no Store usage ⇒ zero behavior delta (default `:memory` is only consulted by the context pass, which in PRD-3 returned no persisted layers anyway — the persisted-layer branch activates ONLY when records exist, so existing test fixtures see no change).
- `mix.exs` version bump is the series' single publish gate (decision 1). If PRD-4 must be rolled back post-publish: hex yank/retract is user-run; treat 0.3.0 as immutable and ship fixes as 0.3.1 — never re-publish 0.3.0 with different content.
- Ecto provider boot hard-fail (§4.2) is intentional startup coupling: hosts opting into `:ecto`/Ecto-backed providers MUST run `Runner.up` first — documented in moduledoc + CHANGELOG.
- **Rollback:** revert PR + restore `@version "0.2.0"`. Tables, once created, are harmless (unused by 0.2.0 code). No host data migration exists to unwind (lib tables start empty in NPL deployments per decision 2).

---

## 9. Open questions

1. **Q1 (lead confirm):** grants-never-hide (§4.5) — grants adjust/extend, ACL gates visibility. The alternative (grant-absence ⇒ hidden per-caller surface) would make grants a second ACL with combinatorial semantics — rejected per the anti-pattern list. Confirm the division of labor.
2. **Q2:** Negotiation visibility — spec keeps negotiation-gated tools VISIBLE with `forbidden`-on-resolve (consent UX needs discovery). Alternative: hide them like ACL denies. Current spec chosen because consent flows require the client to see the tool to request scopes. Confirm.
3. **Q3:** `subject` restricted to JSON scalars for persistence (§4.4) — NPL keys are string ids, fine; structured subjects (maps) excluded until a real consumer needs them. Confirm.
4. **Q4:** `toolsets` store `base` as module-name string with `String.to_existing_atom` restore (§4.4) — atoms must pre-exist (the host's server module always does). `:unknown_base` error otherwise. Acceptable? (Alternative: store only `%Custom{}` whose base is another slug — rejected: D4 slug-chasing.)
5. **Q5:** `running_servers/0` via `:persistent_term` registry vs a `Registry` — spec picks persistent_term (single write at boot, read on Store writes only). If dynamic server start/stop mid-run matters (it doesn't today — supervisors are long-lived), revisit.

---

## 10. Interface freeze (normative for the series)

Upon this PR's merge, the following are FROZEN for the 0.3.0 release: `Toolset` protocol callbacks and structs (PRD-1 §4), `Principal`/`ACL` shapes and the `acl:`/`principal:` opts (PRD-2 §4), `%Custom{}`/`Layer`/merge/Validator/Cache and the `toolset:` opt (PRD-3 §4), `Persistence`/providers/records/DDL/Store and the `providers:` opt (this §4). PRD-5 consumes them as-is; any post-freeze change requires a lead-approved ADR amendment and a 0.4.0 target — not a 0.3.0 re-publish.
