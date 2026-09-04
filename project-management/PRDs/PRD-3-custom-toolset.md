# PRD-3: CustomToolset, Weighted Merge Engine, Validator & Cache

**Series**: noizu_mcp 0.3.0 toolset architecture (PRD-3 of 5)
**Repo**: `Portfolio/Libs/ai/elixir-mcp` (anchors relative to this root; NPL cross-references carry the full monorepo path)
**Version policy**: merge on lib `main`; no version bump, no publish (single 0.3.0 at series end — INDEX.md)
**Depends on**: PRD-1 (protocol core), PRD-2 (Principal + ACL) — cumulative state green
**Status**: Draft
**Design rules**: D1–D5; anti-pattern targets here: **registry brittleness** (composition strictly per-instance, no runtime module scans) and **multi-layer persistence combinatorics** (ONE layered merge engine, not per-layer special cases)

---

## 1. Goal

Make per-caller tool surfaces a first-class, library-owned concept:

1. `%Noizu.MCP.Toolset.Custom{}` (lead docs: `%CustomToolset{}`) — declarative toolset: base + include/exclude + per-tool override ops.
2. Three-pass composition pipeline: **static** → **context** (weighted layers) → **materialize** — with ONE weighted merge engine (D1/D2).
3. `Toolset.Validator.compile/3` — pure, DB-free validation of a custom toolset against its base catalog.
4. `Toolset.Cache` — optional ETS memoization of composed catalogs.
5. Per-request toolset selection on servers: `use Noizu.MCP.Server, toolset: ...` — the seam PRD-5's NPL migration plugs into.
6. Port the NPL toolset matrix (merge semantics) as lib-level conformance tests.

**Out of scope**: persistence behaviour + grant/negotiation records (PRD-4 — the context pass ships here with its seam; the persisted layers plug in there), host-side NPL providers (PRD-5).

---

## 2. Decision log applied

| Rule | Binding |
|------|---------|
| D1 one resolver | `%Custom{}` composes through the same `Toolset` protocol — listing/dispatch/manifest/Catalog-tool consume composed entries via the behaviour defaults. The server `toolset:` opt routes `handle_list_tools`/`handle_call_tool` through the protocol path; there is no parallel "custom listing" API. |
| D2 effective materialization | Winners are materialized (fresh `%Types.Tool{}`/schema/cast_plan via `Overrides.apply/3`) exactly once, at pass 3, before any validation of the RESULT or wire rendering. `invoke/5` still consumes only `%Effective{}`. |
| D3 runtime-only | `toolset: {m, f, opts}` is invoked per request; base expansion happens per compose call (memoizable, never compile-captured). |
| D4 explicit participation | No registry, no module scan: a `%Custom{}` names its `base` explicitly. Slug strings are NOT resolvable in PRD-3 (slug → record resolution arrives with the persistence provider in PRD-4). |
| D5 fail-closed per set / fail-open per server | Invalid `%Custom{}` (bad base, validator errors, composition raise) disables THAT toolset: catalog ⇒ `{:error, %Error{reason: :internal_error, data: %{toolset: slug}}}`, resolve ⇒ same; the server's other surfaces (and other toolsets) stay healthy; telemetry `[:noizu_mcp, :toolset, :compose_error]`. |
| Decision 2 (NPL disposition) | The lib merge engine is policy-agnostic; NPL's policy tables enter ONLY as provider records in PRD-4/PRD-5. Nothing here reads host schemas. |

---

## 3. Background

PRD-1 made the static surface protocol-driven; PRD-2 gave requests a principal and an ACL chokepoint inside the behaviour defaults. What's missing is the host-facing way to SAY "this caller gets this slice of the surface with these renames/descriptions" without host-side forks of dispatch — today exactly what NPL maintains out-of-tree (`EffectiveToolset` cascade + `Dispatch` + `SessionManifest`, monorepo `Portfolio/Apps/AI/NoizuPromptLingo/backend/lib/noizu_prompt_lingua/mcp/`). This PRD moves the MECHANISM into the lib; NPL keeps the POLICY (which layers exist, what they contain) as provider implementations (PRD-5).

Merge semantics are modeled on NPL's cascade (`effective_toolset.ex` moduledoc: layered config, per-tool entry beats group flags, most-specific-wins-per-key, final ACL override) restated in lib vocabulary: weighted per-op merge with `inherit?` resets, and ACL as the highest built-in weight.

---

## 4. Public surface

### 4.1 `lib/noizu/mcp/toolset/custom.ex` — `%Custom{}`

```elixir
defmodule Noizu.MCP.Toolset.Custom do
  @derive Noizu.MCP.Toolset
  use Noizu.MCP.Toolset.Behaviour       # defaults; catalog/resolve/metadata overridden below

  @enforce_keys [:slug, :base]
  defstruct [
    :slug,            # String.t() — identity (cache key, telemetry, metadata)
    :base,            # module() | %Custom{} | Noizu.MCP.Toolset.Ref.t()
    :title,           # String.t() | nil
    :description,     # String.t() | nil
    immutable: false, # true ⇒ context pass skips PERSISTED layers (PRD-4); ACL ALWAYS applies (security invariant)
    include: nil,     # nil | [String.t()] — base canonical names to keep (nil = all)
    exclude: [],      # [String.t()] — base canonical names to drop (applied BEFORE include)
    tools: %{},       # %{String.t() base-name => [%Override{}]} — static layer, weight 100
    metadata: %{}     # host extension map; lib never interprets
  ]
end
```

Semantics (normative):

- `tools` map keys are **base canonical names** (pre-rename). Rename via `:set_name` changes the wire name only; subsequent layers still key the tool by base name.
- `exclude` removes entries entirely (not `visible: false` — gone). Applied before `include`. `include: nil` = no filter.
- `immutable: true` = the five NPL capability profiles (PRD-5) cannot receive grant/negotiation ops; the ACL layer still folds (fail-closed invariant — immutability must never defeat authorization). Documented in moduledoc.
- Nested base (`%Custom{}` inside `base`): contributes its static ops as a weight-100 layer with `layer_id: {:static, inner_slug}`; its own `include/exclude` apply within its scope; its CONTEXT pass is not run (context layers apply only at the top-level invocation — one ACL pass per request). Cycle detection on slug chain ⇒ `{:error, [%Issue{code: :cycle}]}` from Validator/compose.

### 4.2 Layer struct + context pass — `lib/noizu/mcp/toolset/context.ex`

```elixir
defmodule Noizu.MCP.Toolset.Layer do
  @enforce_keys [:id, :weight, :ops]
  defstruct [:id, :weight, :ops]
  # id: term() (e.g. {:static, slug}, {:persisted, grant_id}, {:acl, provider_module})
  # weight: integer() — built-in defaults: static 100, persisted 200, acl 300
  # ops: [%Override{}] — weight/layer fields on each op are normalized to the layer's
end

defmodule Noizu.MCP.Toolset.Context do
  @doc "Layers for this request, ordered arbitrarily (weights decide). Pure fold input."
  @callback layers(toolset, ctx, opts) :: [%Layer{}]

  @doc """
  Default seam (behaviour, overridable by hosts and by PRD-4):
    * ACL layer — always, re-homing PRD-2: denies become
      [%Override{op: :set_visible, value: false, weight: 300, layer: {:acl, provider}},
       %Override{op: :set_callable, value: false, weight: 300, layer: {:acl, provider}}]
      per denied tool (replaces ACL.filter_entries' direct mutation from PRD-2 —
      filter_entries/4 REMAINS as a public helper delegating through this layer).
    * persisted layers — NONE in PRD-3 (default []); PRD-4's persistence wiring
      injects grant/negotiation layers here at weight 200.
  """
  def layers(toolset, ctx, opts)
end
```

### 4.3 Merge engine — `lib/noizu/mcp/toolset/merge.ex`

```elixir
defmodule Noizu.MCP.Toolset.Merge do
  @type slot :: {tool :: String.t(), op :: Override.op(), field :: atom() | nil}

  @doc """
  Fold layers into winners per slot. Normative:
    * per slot, the max-weight NON-inherit? op wins; ties at max weight ⇒ error
      (returned, not raised: {:error, [%Issue{code: :weight_conflict, ...}]})
    * an inherit? op at weight w clears all opinions ≤ w for the slot and applies
      nothing — the slot ends empty (base value stands) unless a >w opinion exists
    * different slots compose (set_name + set_visible both apply)
    * returns %{slot => {%Override{}, provenance}} where provenance = {layer_id, weight}
  """
  @spec fold([%Layer{}], keyword()) :: {:ok, %{slot() => {%Override{}, {term(), integer()}}}} | {:error, [%Validator.Issue{}]}
end
```

`Effective.provenance` (PRD-1 §4.3) is populated from this map, keyed per applied op: `%{{tool, :set_name, nil} => {{:persisted, "grant-7"}, 200}, ...}`.

### 4.4 Composition pipeline (normative order)

```
compose(%Custom{} = t, ctx, opts):
  pass 1  static:   base_specs = expand(base)            # module: __toolset_specs__/2
                    #   %Custom{}: recurse (static-only, cycle-checked)
                    #   Ref: delegate to target module
                    base_entries = entries(base_specs)    # PRD-1 entry mapping
                    drop exclude → apply include
                    static_layer = %Layer{id: {:static, t.slug}, weight: 100,
                                          ops: flatten(t.tools)}
  pass 2  context:  layers = [static_layer | Context.layers(t, ctx, opts)]
                    # ACL always; persisted layers only when not t.immutable (PRD-4)
                    winners = Merge.fold(layers)
  pass 3  materialize: per tool, Winners.op-set → Overrides.apply(spec, ops)
                       → [%Entry{}] with provenance attached; version = compose_version(t, layers)
  return {:ok, entries, version} | {:error, %Error{}}
```

- `resolve/4` (custom override): compose → find by wire name (post-rename) → `%Effective{name, entry, spec, provenance, version}`. Absent or `callable: false` ⇒ `Error.invalid_params("Unknown tool: " <> name)` — identical to PRD-1 (existence-hiding preserved; missing-SCOPE denials from PRD-4 negotiations are the one `:forbidden` exception, specified there).
- `metadata/3` (custom override): `{:ok, %{slug: t.slug, title: t.title, description: t.description, version: composed_version}}`.
- `catalog_version` for composed sets: sha256 of `{t.slug, static_version, layer_fingerprints}` where each context layer fingerprint is `{layer_id, weight, op_digest}` (PRD-4 grants add their record `version`). Truncated 16 hex chars, matching PRD-1 §4.7.

### 4.5 `lib/noizu/mcp/toolset/validator.ex` — `Validator.compile/3`

```elixir
defmodule Noizu.MCP.Toolset.Validator do
  @doc """
  Pure, no DB: validate a %Custom{} against its BASE catalog (expanded, pre-context).
  Returns {:ok, warnings :: [String.t()]} | {:error, [%Validator.Issue{}]}.
  """
  def compile(%Toolset.Custom{} = toolset, base_entries, opts \\ [])
end
```

Checks (each a distinct `:code`):

| code | check |
|------|-------|
| `:unknown_tool` | `tools` map key / include / exclude name not in base catalog |
| `:unknown_field` | field-op target field absent from that tool's base schema/cast_plan |
| `:prune_not_subset` | `prune_enum` values not ⊆ base enum for the field |
| `:rename_target_missing` / `:rename_collision` | rename field missing; renamed wire name collides with an existing field of the tool |
| `:pin_default_invalid` | `pin_default` value ∉ post-prune enum AND not type-compatible with the field type (`Fields` scalar types `fields.ex:16`) |
| `:raw_schema_op` | field-level op against a raw-schema tool (no `input_fields`) or `:set_input_schema` against a DSL tool (PRD-1 §4.5 matrix, now cross-checked against the BASE) |
| `:name_charset` | `set_name` value violates MCP wire-name charset `^[a-zA-Z0-9_-]{1,64}$` |
| `:name_collision` | effective name collides with another tool in the effective set (incl. other renames) |
| `:weight_conflict` | equal max-weight non-inherit opinions on one slot (surfaced by Merge, reported here) |
| `:cycle` | nested-base slug cycle (§4.1) |

Warnings (non-fatal, `{:ok, warnings}`): `:set_visible`/`:set_callable` overriding another layer's same-value opinion; pin_default equal to the field's existing default; `include` + `exclude` overlapping (exclude wins, noted).

When validation runs: `compose/3` calls `compile/3` on the FIRST compose of a `%Custom{}` per process (cached negative/positive via `Cache`, §4.6); `{:error, issues}` ⇒ toolset disabled per D5 (`{:error, %Error{reason: :internal_error, data: %{toolset: slug, issues: issues}}}`) — validators never take a server down.

### 4.6 `lib/noizu/mcp/toolset/cache.ex` — optional ETS memo

```elixir
defmodule Noizu.MCP.Toolset.Cache do
  # named public ETS `:noizu_mcp_toolset_cache`, lazily created (race-safe catch on
  # :ets.new/2), value rows {key, entries, version, inserted_at}
  @type key :: {toolset_id :: String.t(), principal_hash :: binary(), catalog_version :: String.t()}

  @spec get(key) :: {:ok, entries, version} | :miss
  @spec put(key, entries, version, opts) :: :ok          # opts: [ttl: ms] default 60_000
  @spec invalidate(toolset_id :: String.t()) :: :ok      # match-delete on element 1
  @spec principal_hash(%Noizu.MCP.Auth.Principal{} | nil) :: binary()
  #   sha256(term_to_binary({subject, authenticator, granted_scopes})) — claims/metadata
  #   deliberately EXCLUDED (they don't affect layer selection; avoids unbounded keys)
end
```

- **Opt-in**: `use Noizu.MCP.Server, toolset_cache: true | [ttl: ms]` and/or `%Custom{metadata: [cache: true]}`. Default OFF (correctness first; invalidation story completes in PRD-4 when Store writes call `Cache.invalidate/1` before `notify_changed`).
- Never caches: validator errors (always re-checked), error results (D5 paths stay observable).

### 4.7 Per-request toolset selection — `use Noizu.MCP.Server, toolset: ...`

```elixir
use Noizu.MCP.Server,
  name: "...", version: "...",
  toolset: %Noizu.MCP.Toolset.Custom{...}     # static value
  # | {MyResolver, :resolve, [opt: :val]}     # per-request (D3): called as m.f(ctx, opts)
  # | :none                                   # default — raw self (PRD-1 behavior)
```

- `Features.Tools.protocol_list/protocol_call` (PRD-1 §4.9) change: target = resolve `__mcp__(:opts)[:toolset]` — MFA return: `%Custom{}` | module | `%Ref{}` | `:none` (fall back to self). Anything else ⇒ Logger.warning + self fallback (fail-open-per-server; config error is logged loudly, server healthy).
- The selected toolset replaces the listing AND dispatch surface for every request. PRD-4 adds slug-string returns (resolved via the persistence provider's `toolsets` store).
- Note: with `toolset:` set, the server's own specs remain reachable as the custom toolset's `base:` — the recommended NPL shape is `%Custom{base: __MODULE__, ...}` (literal in the `use` is not `__MODULE__`-safe pre-expansion; hosts pass the module name explicitly).

### 4.8 Catalog tool default flip

`lib/noizu/mcp/server/tools/catalog.ex` `call/2` (`:85`): the `tools` section DEFAULT flips to `"mode" => "protocol"` (PRD-1 §4.10 shipped it opt-in). `"mode" => "static"` retained. With `toolset:` configured, protocol mode enumerates the selected toolset — the Catalog tool becomes the host-facing audit surface for effective per-caller state.

---

## 5. Requirements

**FR-3.1** `%Toolset.Custom{}` struct per §4.1; `@derive`d protocol participant; catalog/resolve/invoke/permissions/metadata functional over the pipeline in §4.4.
**FR-3.2** `%Layer{}` + `Context.layers/3` seam per §4.2; ACL folded as weight-300 layer via overrides (PRD-2's `filter_entries/4` re-homed, behavior-identical — PRD-2's ACL suite stays green unmodified).
**FR-3.3** `Merge.fold/2` per §4.3: max-weight non-inherit wins; `inherit?` at weight w clears ≤w and applies nothing; equal-weight conflict ⇒ `:weight_conflict` issue; cross-slot composition; provenance map populated into `%Effective{}`.
**FR-3.4** Pipeline order: exclude → include → layer fold → single materialization (§4.4); base `%Types.Tool{}` structs never mutated (purity test from PRD-1 §7 applies at composition scale).
**FR-3.5** `Validator.compile/3` per §4.5 with all listed issue codes + warnings; compose disables invalid toolsets per D5 (server healthy — other tools still list/call).
**FR-3.6** `Cache` per §4.6: opt-in only; key per spec; `principal_hash` excludes claims/metadata; `invalidate/1` clears by toolset id; disabled by default and zero ETS writes when off.
**FR-3.7** `toolset:` server opt per §4.7: static and MFA forms; `:none` default; unknown MFA return ⇒ warn + self fallback.
**FR-3.8** `toolset:` + ACL compose correctly: ACL denies apply to the SELECTED toolset's entries (test: deny a base tool visible through a `%Custom{}` include — hidden from listing, uncallable, `permissions/3` reports it).
**FR-3.9** Nested `%Custom{}` base: static-only recursion, inner ops at weight 100 under `{:static, inner_slug}`, cycle ⇒ `:cycle` issue.
**FR-3.10** Catalog tool protocol default flip (§4.8); `mode: "static"` still available.
**FR-3.11** Telemetry: `[:noizu_mcp, :toolset, :compose]` (duration, `%{toolset: slug, layers: n, cached: boolean}`), `[:noizu_mcp, :toolset, :compose_error]` (D5).
**FR-3.12** NPL matrix port: `test/noizu/mcp/toolset/merge_matrix_test.exs` reproduces, in lib vocabulary, the merge-semantics cases of monorepo `Portfolio/Apps/AI/NoizuPromptLingo/backend/test/noizu_prompt_lingua/mcp/effective_toolset_matrix_test.exs` (see §7 mapping table).

**Acceptance criteria**

**AC-3.1** A `%Custom{}` over `FixtureServer` with exclude/include + per-tool ops: listing shows the filtered, renamed, re-described surface; invocation works under the renamed wire name; handler receives original-keyed args with original values (PRD-1 wire_key e2e through composition).
**AC-3.2** Layered merge: static (100) vs ACL (300) deny ⇒ denied regardless; ACL allow + static hide ⇒ hidden (no ACL opinion); `inherit?` demo: ACL layer… (constructive test) static `:set_visible false` + higher-weight persisted-shaped layer `:set_visible true` ⇒ visible (weights, not hardcoded layer names, decide).
**AC-3.3** `inherit?` clearing: persisted-shaped layer (200) `:set_visible true` + static (100) `:set_visible false` + ACL-simulated 200 `inherit?` `:set_visible` ⇒ slot empty ⇒ base (visible: true) stands.
**AC-3.4** Validator rejection e2e: `%Custom{}` renaming a tool to an existing name ⇒ that toolset disabled, `data.issues` carries `:name_collision`, other toolsets + bare tools unaffected (D5).
**AC-3.5** Immutability: `immutable: true` + simulated persisted layer ⇒ persisted ops NOT applied; ACL deny STILL applied (§4.1 invariant).
**AC-3.6** Cache: with `toolset_cache: true`, second compose of same `{slug, principal_hash, version}` hits cache (compose telemetry `cached: true`); `invalidate/1` forces recompose; TTL expiry; cache OFF ⇒ no ETS table writes (assert via ETS info).
**AC-3.7** `toolset:` MFA returning different `%Custom{}` per ctx: two request fixtures see their respective surfaces through the SAME server (the NPL per-key model, proven at the lib level).
**AC-3.8** PRD-1 + PRD-2 suites green unmodified (additive guarantee); no-provider/no-toolset servers byte-identical.

---

## 6. Internal work checklist (anchors)

| Step | File | Detail |
|------|------|--------|
| 6.1 | `lib/noizu/mcp/toolset/custom.ex` | `%Custom{}` + pipeline overrides (§4.1, §4.4) |
| 6.2 | `lib/noizu/mcp/toolset/context.ex` | `%Layer{}` + seam + ACL re-home (§4.2) |
| 6.3 | `lib/noizu/mcp/toolset/merge.ex` | fold engine (§4.3) |
| 6.4 | `lib/noizu/mcp/toolset/validator.ex` | `compile/3` + issue codes (extends PRD-1's `Issue` struct home) |
| 6.5 | `lib/noizu/mcp/toolset/cache.ex` | ETS memo (§4.6) |
| 6.6 | `lib/noizu/mcp/toolset/behaviour.ex` | compose helper shared by `%Custom{}` overrides; version fingerprint helper |
| 6.7 | `lib/noizu/mcp/acl.ex` | `filter_entries/4` becomes a delegate over the ACL layer (§4.2); behavior identical |
| 6.8 | `lib/noizu/mcp/server/features/tools.ex` | `protocol_list/3`/`protocol_call/4` honor `toolset:` opt (PRD-1 §4.9 seam) |
| 6.9 | `lib/noizu/mcp/server.ex` | `toolset:` + `toolset_cache:` opts through `__mcp_server_opts__` (`:242`) → `__mcp__(:opts)` (`:406`) |
| 6.10 | `lib/noizu/mcp/server/tools/catalog.ex` | protocol-mode default flip (§4.8, `call/2` `:85`) |

---

## 7. Test plan

New files under `test/noizu/mcp/toolset/`:

- **`custom_compose_test.exs`** — static pass matrix: exclude/include/nested base/cycle; rename-wire-name e2e; `immutable` semantics (AC-3.5).
- **`merge_fold_test.exs`** — engine unit matrix: weights, ties, `inherit?` (AC-3.3), cross-slot composition, provenance map shape.
- **`context_layers_test.exs`** — ACL-as-layer equivalence vs PRD-2 suite; seam default ([] persisted in PRD-3).
- **`validator_test.exs`** — every §4.5 code as a case + warning cases; `compile/3` purity (no DB/ETS/env touches — asserted by running with Cache disabled and sandboxed code paths).
- **`cache_test.exs`** — AC-3.6 matrix; principal_hash stability/exclusions.
- **`server_toolset_opt_test.exs`** — AC-3.7; static/MFA/`:none`; bad return fallback; Catalog protocol mode reflecting the selected toolset (AC-3.8 adjacent).
- **`merge_matrix_test.exs`** — FR-3.12 port. Mapping from the NPL matrix (monorepo `.../test/noizu_prompt_lingua/mcp/effective_toolset_matrix_test.exs`):

| NPL case shape | Lib-port assertion |
|---|---|
| scope-config layer vs client `toolset_config` layer, most-specific wins | persisted-shaped layer (200) beats static (100) on same slot |
| per-tool entry beats its group's flags | per-tool op beats a toolset-wide blanket op at equal weight ⇒ `:weight_conflict` (lib has no implicit groups; explicit layers must be ordered) — asserts the error path NPL avoids by convention |
| boolean overrides (enabled/visible) | `:set_visible`/`:set_callable` slots merge independently |
| `name_override` / `description_override` | `:set_name`/`:set_description` slots + charset/uniqueness validation |
| ACL final override (deny hides+disables) | weight-300 ACL beats 100/200 (AC-3.2) |
| absent-from-every-layers ⇒ enabled+visible | absent slots ⇒ base entry stands (base wins by default — lib's explicit-participation default) |
| expires_at window (via MCP.Window) | NOT ported here — expiry lives on grant/negotiation records (PRD-4 §5); matrix notes the deferred case |

**Anti-pattern regression tests (series-persistent):**

- **AP-7 (registry brittleness):** compose NEVER scans modules — assert no `Code.ensure_loaded?`/`application`-walk in the compose path (static analysis test: grep the lib source tree for forbidden calls inside `lib/noizu/mcp/toolset/` — a source-level test, so a future regression fails CI); `%Custom{base: :nonexistent_mod}` ⇒ disabled toolset (D5), server healthy.
- **AP-8 (persistence combinatorics):** the ONLY merge path is `Merge.fold/2` — source-level test asserts `Overrides.apply/3` is called from exactly one site (pass 3) and `Enum.sort_by(..., weight)` ordering exists in exactly one module; adding a new layer type requires a new `%Layer{}`, not new logic (asserted by a host-fixture layer at weight 250 behaving per the generic rules — no special-casing).
- **AP-9 (decorative ACL, PRD-3 extension):** with `toolset:` configured, PRD-2's AP-5 shim test is re-run THROUGH the selected toolset — `list_registered/3` shims and the Catalog tool both reflect ACL + composition (no bypass surface).

---

## 8. Compat & rollback

- Additive: `%Custom{}`/`toolset:`/`toolset_cache:` are opt-in; unset ⇒ PRD-2 behavior byte-identical (snapshot suite).
- The one behavior flip: Catalog tool `tools` section defaults to protocol mode (§4.8) — output keys gain `visible/callable/reason` and drop nothing; hosts depending on exact legacy Catalog shapes pass `"mode" => "static"`. Called out in the PR description as the PRD-3-only compat note.
- NPL on `path:` dep: unaffected (its `handle_*` overrides still win; it adopts `toolset:` in PRD-5).
- **Rollback:** revert single PR. `filter_entries/4` re-home (§6.7) is behavior-identical — PRD-2 tests are the rollback gate.

---

## 9. Open questions

1. **Q1 (PRD-1 Q1 resolution):** Catalog protocol-mode default flips HERE (§4.8). Confirm with team-lead before merge.
2. **Q2:** `immutable: true` — current spec skips PERSISTED layers only; ACL always applies (§4.1). Alternative reading (fully static, no context pass at all) would let ACL bypass immutable profiles — rejected as a security hole. Flag for the lead to confirm the security-first reading.
3. **Q3:** `include`/`exclude`/`tools` keyed on BASE names even under rename — alternative (post-rename names) creates order-dependence. Current spec is base-names; confirm.
4. **Q4:** Cache TTL default 60s (§4.6) — NPL's `toolset_cache.ex` (monorepo `.../mcp/toolset_cache.ex`) has its own policy; PRD-5 should reconcile NPL cache expectations with the lib TTL. Noted for PRD-5.
5. **Q5:** Should `Merge.fold` treat two EQUAL ops at equal weight (same value, different layers) as conflict? Current: conflict (loud). Alternative: dedupe silently. Lead's call — current spec prefers loud.
