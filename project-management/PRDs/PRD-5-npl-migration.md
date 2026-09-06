# PRD-5: NoizuPromptLingua Migration to the noizu_mcp Toolset Stack

**Series**: noizu_mcp 0.3.0 toolset architecture (PRD-5 of 5)
**Repo**: **HOST-side work in `Portfolio/Apps/AI/NoizuPromptLingo`** (all NPL anchors below are relative to `backend/`; lib anchors reference the frozen 0.3.0 interfaces from PRD-1..4)
**Depends on**: lib 0.3.0 merged (PRD-1..4) and PUBLISHED to hex (user-run, 2FA OTP) — the NPL dep flips to hex in THIS PRD (decision 1)
**Status**: Draft
**Scope guard**: this PRD covers the toolset-stack migration ONLY. The broader NPL last-mile — toolset-set CRUD admin, `/org/{org}[/project/{p}]/set/{slug}/mcp` routes, org-pinning columns — is governed by a SEPARATE host-side planning pass and is referenced here only as context. Do not implement it under this PRD.

---

## 1. Goal

Move NPL from its out-of-tree toolset fork (`NoizuPromptLingua.MCP.EffectiveToolset` + `Dispatch` + per-server `handle_*` overrides) onto the lib's frozen 0.3.0 toolset architecture, with NPL's data disposition PERMANENT (decision 2):

1. `NoizuPromptLingua.MCP.ToolsetProvider` — lib `Persistence` behaviour over **NPL's own tables** (`mcp_custom_scopes`, `oauth_clients.toolset_config`, `mcp_api_keys.toolset_config`) — the END STATE, not a transitional shim. Lib-owned tables stay empty in NPL deployments.
2. `NoizuPromptLingua.MCP.AclProvider` — lib `ACL.Provider` over `NoizuPromptLingua.Acl.resolve/4` (`backend/lib/noizu_prompt_lingua/acl.ex:58`).
3. The 5 capability profiles (`full`, `agent-ops`, `pm-dev`, `content`, `comms`) as immutable static `%Toolset.Custom{}` structs.
4. `use NoizuPromptLingua.MCP.Server` **stops emitting** `handle_list_tools/2` / `handle_call_tool/3`; the lib's protocol-generated defaults take over (PRD-1 §4.9) with `toolset:` / `principal:` / `providers:` opts (PRD-3 §4.7, PRD-2 §4.5, PRD-4 §4.3).
5. Legacy data path preserved WITHOUT migration: `toolset_config` jsonb + `mcp_custom_scopes.config` are READ by the provider and translated to grants/overrides at resolution time.
6. NPL's test matrices ported as conformance suites proving behavior parity.

---

## 2. Decision log applied

| Rule | Binding |
|------|---------|
| Decision 2 (PERMANENT disposition) | `ToolsetProvider` reads/writes NPL's own schemas; it is the final architecture. No ETL into `noizu_mcp_toolset*` tables, ever. The provider's store keys map onto NPL data (§5); nothing writes lib-owned tables. |
| Decision 1 (dep protocol) | NPL develops against the lib via relative `path:` dep through PRD-1..4; THIS PRD's final commit flips `mix.exs` to `{:noizu_mcp, "~> 0.3.0"}` (§9 flip checklist). |
| D1 one resolver | `EffectiveToolset`'s resolution cascade is RETIRED; listing, dispatch, `Session_Manifest`, OAuth consent surfaces all consume the lib Toolset protocol through the providers. No NPL-side resolution engine remains. |
| D2 effective materialization | Overrides (name/description/visibility) materialize inside the lib merge engine; NPL renders only effective results. |
| D3 runtime-only | Provider reads happen per resolution (lib `Context.layers/3`), versioned by cheap fingerprints — no boot-time snapshots of NPL config. |
| D4 explicit participation | Profiles and the `toolset:` MFA are explicit; the provider never scans NPL modules. |
| D5 fail-closed per set / fail-open per server | Provider/AclProvider failures degrade to the static+ACL-less profile surface per lib rules; a broken scope config disables THAT scope's toolset, other scopes/keys unaffected. |

**Anti-pattern targets** (from prior-art analysis, each with a named regression test in §8): decorative ACL (AclProvider answers for EVERY tool — no default-deny surprises, no bypass path), forgeable contexts (`PrincipalMapper` is the only claims→principal path; NPL code stops reading `ctx.assigns[:auth_claims]` for authz), compile-time monoliths (all resolution runtime), registry brittleness (no module scans in providers).

---

## 3. Background — what exists today (NPL, verified anchors)

| Module | Path (`backend/lib/noizu_prompt_lingua/mcp/`) | Role | Post-migration |
|--------|--------------------------------|------|----------------|
| `NoizuPromptLingua.MCP.Server` | `server.ex` | Shared base; hosts declare `handle_call_tool/3` + `handle_list_tools/2` BEFORE `use Noizu.MCP.Server` (`:22-30`) so the lib `defines?` guard (`lib/noizu/mcp/server.ex:258,276,284`) skips generation | Base macro re-emits with `toolset:`/`principal:`/`providers:` opts; host `handle_*` DELETED |
| `EffectiveToolset` | `effective_toolset.ex` | THE resolution interface: cascade `mcp_custom_scopes.config` → client `toolset_config`; per-tool `%{enabled, visible, name_override, description_override, expires_at}`; absent ⇒ enabled+visible (inverted default); ACL pass final-override | RETIRED — replaced by lib `Toolset` protocol + provider layers |
| `EffectiveToolset.Behaviour` | `effective_toolset/behaviour.ex` | Seam for consumers | RETIRED — consumers use lib `Toolset` directly |
| `Dispatch` | `dispatch.ex` | `tools/call` with `ToolGuard` + PDP; canonical-name matching (`ToolNames`); PRIVATE `run_spec` copy (`:24-52`); step-up `elevation_uri` tool-result (`:40-52`) | RETIRED — lib `protocol_call` path; canonicalization at registration (§6.4); step-up via negotiations (§6.5) |
| `Custom` | `custom.ex` | `tobor_custom` dynamic include-set server, `catalog_specs/1` | Becomes a `%Toolset.Custom{}` over the domain server via provider records |
| `SessionManifest` | `session_manifest.ex` | `Session_Manifest` tool via `EffectiveToolset.Behaviour` | Rewritten over lib `Toolset.permissions/3` + `catalog/3` |
| `ToolsetConfig` / `KeyToolsets` / `ToolsetCache` / `ToolGuard` / `ToolNames` / `Window` / `LegacyKeys` | `toolset_config.ex`, `key_toolsets.ex`, `toolset_cache.ex`, `tool_guard.ex`, `tool_names.ex`, `window.ex`, `legacy_keys.ex` | Config access, per-key toolsets, cache, guard, names, expiry | Config+keys+window fold into the provider; cache → lib `Toolset.Cache` (TTL reconciliation §6.6); `ToolNames` stays as registration canonicalizer (§6.4) |
| Schemas | `schema/mcp_custom_scope.ex`, `schema/oauth_client.ex`, `schema/mcp_api_key.ex` | `config` / `toolset_config` jsonb — NPL-OWNED | UNCHANGED (decision 2) |

Tests to port (verified paths, `backend/test/`): `noizu_prompt_lingua/mcp/effective_toolset_test.exs`, `effective_toolset_acl_test.exs`, `effective_toolset_matrix_test.exs`, `key_toolset_guard_test.exs`, `noizu_prompt_lingua/oauth/client_toolsets_test.exs` (primary); `custom_key_toolset_test.exs`, `key_toolsets_test.exs`, `toolset_cache_test.exs`, `noizu_prompt_lingua_web/controllers/mcp_key_toolset_rest_test.exs` (secondary).

---

## 4. Public surface (new NPL modules)

All paths relative to `backend/lib/noizu_prompt_lingua/`.

### 4.1 `mcp/toolset_provider.ex` — `NoizuPromptLingua.MCP.ToolsetProvider`

Implements the frozen lib behaviour (`Noizu.MCP.Persistence`, PRD-4 §4.1) over NPL tables. Store mapping:

| store_key | NPL source | record shape produced |
|-----------|-----------|----------------------|
| `"toolsets"` | `Schema.MCPCustomScope` (`config` jsonb) + `KeyToolsets` custom sets | `%{slug, title, description, base: <domain server module>, immutable: false, include, exclude, tools: %{name => [%Override{}]}, metadata}` — scope config groups translate: enabled+visible tools ⇒ included with `:set_name`/`:set_description` ops from `name_override`/`description_override`; disabled ⇒ excluded from the record's include AND carried as deny-ops at grant level (§4.2) |
| `"toolset_grants"` | `Schema.McpApiKey.toolset_config` + `Schema.OauthClient.toolset_config` (per key/client) | `Noizu.MCP.Permission.Grant{toolset_slug, authenticator: :api_key \| :oauth, subject: key_id \| client_id, effect: :allow, tool_overrides: translated, expires_at: Window-extracted}` — **inverted-default preservation**: NPL's "absent ⇒ enabled+visible" maps to "no grant row ⇒ no ops" (the lib's static/base surface IS enabled+visible for these sets — the profiles' include lists define participation, so semantics hold without lib changes) |
| `"toolset_negotiations"` | scope `required_scopes` + consent state + `MCP.Window` | `Noizu.MCP.Permission.Negotiation{tool, required_scopes, granted, metadata_overrides, expires_at}` — feeds the lib's `forbidden` consent gate (PRD-4 §4.5) |

Contract details:

- **Translation at resolution time** — every `list/3` reads NPL tables and translates (D3). No cache of translated records beyond the lib `Toolset.Cache`, keyed by the provider's `version/2` fingerprint: `max(updated_at) + record_count` per source table (cheap, index-friendly), mixed with `Application.spec(:noizu_prompt_lingua, :vsn)`.
- `put/get/delete` on `"toolsets"` delegate to `MCPCustomScopes`/`KeyToolsets` context APIs (the provider is the lib's view of NPL's existing write paths — it does not create new tables).
- Subject validity: NPL key/client ids are strings — satisfies PRD-4 §4.4's JSON-scalar rule.
- Provider failures behave per lib D5 (§2): degraded compose, never a server crash.

### 4.2 `mcp/acl_provider.ex` — `NoizuPromptLingua.MCP.AclProvider`

Implements frozen `Noizu.MCP.ACL.Provider` (PRD-2 §4.6) over `NoizuPromptLingua.Acl.resolve/4` (`acl.ex:58`), preserving NPL's documented semantics (`effective_toolset.ex` moduledoc "ACL layer" section):

- `check_all/5` OVERRIDES the default: enumerates the offered tools and resolves `Acl.resolve(subject_ref, "mcp.tool", {:ref, Schema.McpTool, canonical_name}, default: :allow)` per tool — **it always answers for every tool**, so the lib's fail-closed default-deny (PRD-2 FR-2.10) never fires spuriously and NPL's default-allow posture is preserved exactly.
- `:deny` verdicts map to the lib deny (visible+callable false, weight-300 — beats all lower layers); per-tool resources `{:ref, Schema.McpTool, name}`, kind wildcard `{:ref, Schema.McpTool, :any}`, global `{:ref, :any, :any}`, and scope-wide `{:ref, Schema.MCPCustomScope, scope_id}` (scope denials surface as denies on every tool the scope serves — the provider knows the scope from `toolset_slug`).
- `allow` / no-match ⇒ `:allow` no-op (config cascade state survives — parity with the legacy ACL pass).
- Resource kinds supported: `[:tool, :toolset]` (declares `supported_kinds` — PRD-2 §4.7).

### 4.3 `mcp/toolsets/profiles.ex` — the 5 capability profiles

```elixir
defmodule NoizuPromptLingua.MCP.Toolsets.Profiles do
  # Compile-time immutable literals (D3-legal: static code, not env capture):
  #   full       — the domain server's complete surface
  #   agent-ops  — ops/automation slice
  #   pm-dev     — project-management + development slice
  #   content    — content-authoring slice
  #   comms      — messaging/communication slice
  @profiles %{"full" => %Noizu.MCP.Toolset.Custom{slug: "profile:full", ...},
              "agent-ops" => ..., "pm-dev" => ..., "content" => ..., "comms" => ...}
  def get(slug), do: Map.get(@profiles, slug)
  def all, do: Map.values(@profiles)
end
```

- Every profile: `base: NoizuPromptLingua.MCP.<Domain>Server` (explicit module), `immutable: true`, `include:` the profile's tool list, `tools: %{}`
  (profiles carry NO ops — slicing only). `immutable: true` means grants/negotiations never
  mutate them (PRD-3 §4.1); **ACL still applies** (security invariant).
- The 5 slugs are the allow-list for `toolset:` MFA resolution (§6.2); unknown slugs ⇒ resolver
  falls back to `:none` (server static surface) + `Logger.warning` — never an error response.

### 4.4 `mcp/principal_mapper.ex` — `NoizuPromptLingua.MCP.PrincipalMapper`

`use Noizu.MCP.Server, principal: {NoizuPromptLingua.MCP.PrincipalMapper, :from_claims, []}`:

- API-key path (`dual_token_verifier.ex` verified tokens): `%Principal{subject: api_key_id, authenticator: :api_key, token_id: key.id, granted_scopes: key scopes, claims: claims, metadata: %{key: key_record_ref}}`.
- OAuth path (`oauth/clients.ex`): `subject: client_id, authenticator: :oauth, granted_scopes: granted scopes`.
- Reads today's `ctx.assigns` seams (the values NPL's verifier already stashed — `assigns[:auth_claims]` per `plug.ex:387-406` and NPL's own assigns) and converts ONCE; NPL handlers stop doing their own claims→identity inference (AP-13).

### 4.5 `mcp/toolset_resolver.ex` — `NoizuPromptLingua.MCP.ToolsetResolver`

`use Noizu.MCP.Server, toolset: {NoizuPromptLingua.MCP.ToolsetResolver, :resolve, []}` — per ctx (PRD-3 §4.7 MFA form):

1. `%Principal{}` from `ctx.auth` (guaranteed by `principal:` opt ordering — resolver runs post-mapping).
2. authenticator `:api_key`/`:oauth` ⇒ look up that key/client's `toolset_slug` (`key_toolsets.ex` data, read via the provider): profile slug ⇒ `Profiles.get/1`; custom slug ⇒ `%Toolset.Custom{}` assembled from the provider's `"toolsets"` record with `base:` the domain server.
3. No toolset binding ⇒ `:none` (server static surface — today's fallback).
4. Server opts injected at base-macro expansion: `providers: [persistence: NoizuPromptLingua.MCP.ToolsetProvider, acl: NoizuPromptLingua.MCP.AclProvider]` (PRD-4 §4.3 combined form wins — exactly one provider pair for all NPL servers).

---

## 5. Legacy data translation (normative table)

| NPL legacy field | Translation at resolution | Where it lands in lib semantics |
|---|---|---|
| `toolset_config[tool].enabled == false` | `:set_callable false` + `:set_visible false` ops (weight 200 grant) | hidden+uncallable for that key/client only |
| `toolset_config[tool].visible == false` (enabled stays true) | `:set_visible false` op | hidden-but-callable (lib first-class state, PRD-1 §4.3) |
| `toolset_config[tool].name_override` / `description_override` | `:set_name` / `:set_description` ops | wire-only rename (PRD-1 wire_key: handlers keep original args) |
| `toolset_config[tool].expires_at` (via `MCP.Window`) | grant `expires_at` | provider expiry exclusion (PRD-4 §4.1 invariant) |
| `mcp_custom_scopes.config` groups | the scope's `"toolsets"` record (include/tools) | static layer of the scope's `%Custom{}` |
| scope `required_scopes` + consent | `"toolset_negotiations"` records | lib consent gate: unsatisfied ⇒ visible + `resolve` ⇒ `forbidden` with `%{tool, required_scopes, missing, negotiation}` data (PRD-4 §4.5 as amended: `negotiation: %{id, metadata}` included) |
| `ToolGuard` `elevation_uri` step-up (`dispatch.ex:40-52`) | negotiation record `metadata.elevation_uri` (recorded at consent-request time) | lib `forbidden` error data carries `negotiation.metadata` — clients complete elevation via NPL's existing REST/consent endpoints, then re-call; the legacy `insufficient_authorization` tool-result envelope is REPLACED by the MCP-level `forbidden` error (wire change — see §8 compat note) |
| `legacy_keys.ex` / dual-token fallbacks | `PrincipalMapper` authenticator tags (`:api_key_legacy` etc.) | grant matching on authenticator — legacy keys keep their distinct grants |

NO data migration: zero rows move; `noizu_mcp_toolset*` tables remain unpopulated in NPL deployments (decision 2 asserted by a test — §8).

---

## 6. Internal work checklist (anchors)

| Step | File (NPL unless noted) | Detail |
|------|------------------------|--------|
| 6.1 | `mcp/toolset_provider.ex` | §4.1 — persistence behaviour over NPL schemas |
| 6.2 | `mcp/acl_provider.ex` | §4.2 — always-answers ACL provider |
| 6.3 | `mcp/toolsets/profiles.ex` | §4.3 — 5 immutable profiles |
| 6.4 | `mcp/principal_mapper.ex`, `mcp/toolset_resolver.ex` | §4.4, §4.5 |
| 6.5 | `mcp/server.ex` | base macro: DELETE shared `handle_call_tool/3` (`:24-27`) + `handle_list_tools/2` (`:29-...`); emit `use Noizu.MCP.Server, toolset: {ToolsetResolver, :resolve, []}, principal: {PrincipalMapper, :from_claims, []}, providers: [persistence: ToolsetProvider, acl: AclProvider]`, `toolset_cache: true`; registration-time name canonicalization: feed `__mcp__(:tools)` through `ToolNames.canonical_spec/1` equivalents pre-expand so wire names are underscore-canonical (lib matches exactly; dotted aliases retire) |
| 6.6 | `mcp/toolset_cache.ex` | RETIRE — lib `Toolset.Cache` with `toolset_cache: true`; port NPL's cache-policy test expectations (TTL/invalidate parity; reconcile against PRD-3 Q4 default 60s — if NPL's policy differs, set `ttl:` explicitly in the server opts rather than forking the lib) |
| 6.7 | `mcp/session_manifest.ex` | rewrite over `Toolset.permissions/3` (effective visible/callable per caller) + `metadata/3`; canonical underscore names preserved; output shape UNCHANGED (client-facing contract) |
| 6.8 | `mcp/dispatch.ex`, `mcp/effective_toolset.ex`, `mcp/effective_toolset/behaviour.ex` | DELETE after suites pass (§7); grep-guard test prevents reintroduction (AP-12) |
| 6.9 | `mix.exs` (backend) | dep flip: `{:noizu_mcp, "~> 0.3.0"}` (§9 checklist; `path:` until then) |
| 6.10 | `mcp/custom.ex` | `tobor_custom` refactors to a provider-backed `%Toolset.Custom{}` (scope slug from ctx.auth metadata → provider record); discovery tools unchanged |

---

## 7. Test plan — ported conformance suites

Each ported suite asserts **behavior parity** with the legacy engine using the SAME fixtures, now exercised through the lib stack (provider + resolver + lib protocol). Location mirrors the originals under `backend/test/noizu_prompt_lingua/mcp/` (files RENAMED with `_conformance` suffix so old and new never shadow each other during the transition; originals deleted at flip).

1. **`effective_toolset_conformance_test.exs`** (from `effective_toolset_test.exs`) — cascade semantics: scope config vs key `toolset_config`, most-specific wins, tool-beats-group (per-tool ops beat scope-level), inverted-default (absent ⇒ enabled+visible via profiles' include).
2. **`effective_toolset_acl_conformance_test.exs`** (from `effective_toolset_acl_test.exs`) — AclProvider parity: per-tool deny hides+disables; `:any` wildcards (tool-kind and global); scope-wide deny; allow/no-match no-op; ACL beats grant ops (300 > 200) — legacy's "final override" reproduced by weights.
3. **`effective_toolset_matrix_conformance_test.exs`** (from `effective_toolset_matrix_test.exs`) — full matrix end-to-end per principal × scope × tool; the NPL-case mapping table in PRD-3 §7 is the checklist; expires_at windows via Window-extracted grant expiry.
4. **`client_toolsets_conformance_test.exs`** (from `oauth/client_toolsets_test.exs`) — OAuth client `toolset_config` translation parity (§5 rows 1-4).
5. **`key_toolset_guard_conformance_test.exs`** (from `key_toolset_guard_test.exs`) — API-key guard parity: hidden tool call ⇒ `invalid_params` identical-to-absent (existence-hiding preserved); visible-but-scope-gated ⇒ `forbidden` with required/missing scopes (+ `negotiation.metadata.elevation_uri` — replaces the legacy `insufficient_authorization` tool-result; asserted as the ONE deliberate wire delta); allowed tools execute with original-atom args (wire_key proof).
6. **Secondary**: `toolset_cache_conformance_test.exs` (policy parity), `custom_key_toolset_conformance_test.exs` + `key_toolsets_conformance_test.exs` (custom sets through provider), `mcp_key_toolset_rest_test.exs` (REST surface unchanged).
7. **Permanent-disposition guard**: test asserting `noizu_mcp_toolsets`/`_grants`/`_negotiations` tables receive ZERO rows during the full suite run (decision 2 — the providers never write lib tables).
8. **Retirement guard**: source-level test grepping `backend/lib` for `EffectiveToolset`/`Dispatch.run_spec` references post-flip (AP-12).

**Anti-pattern regression tests (series-persistent, NPL-side):**

- **AP-12 (fork reintroduction):** grep-guard — `effective_toolset|defp run_spec|ToolGuard.before_call` must not reappear in `backend/lib`; the lib path is the only dispatch path.
- **AP-13 (forgeable context):** NPL handlers read identity ONLY via `ctx.auth` (`%Principal{}`); grep-guard forbids `assigns[:auth_claims]` / `assigns[:mcp_auth_claims]` reads outside `principal_mapper.ex`.
- **AP-14 (decorative ACL):** the Catalog tool + `Session_Manifest` (lib-path consumers) reflect ACL denies identically to `tools/list`/`tools/call` — no consumer sees an un-ACL'd surface (PRD-2 AP-5/PRD-3 AP-9 re-proven at NPL scale).

---

## 8. Compat & rollback

- **Staged lanes**: NPL develops the migration on a branch with the `path:` dep (decision 1 protocol) while production NPL keeps hex `0.1.5`/`0.2.x` behavior — zero exposure until the flip commit.
- **Deliberate wire deltas** (each asserted in the conformance suites, listed in the CHANGELOG):
  1. step-up denial envelope: legacy `insufficient_authorization` tool-result → MCP-level `forbidden` error carrying `negotiation.metadata.elevation_uri` (§5; requires the PRD-4 §4.5 data amendment — already reflected there).
  2. dotted tool-name aliases retire at the wire; canonical underscore names only (NPL `ToolNames` canonicalization moves to registration time).
  3. Catalog tool `tools` section defaults to protocol mode (PRD-3 §4.8) — NPL's Discovery tools' `Session_Manifest` remains the caller-effective view.
- **Rollback**: pre-flip = drop the branch. Post-flip (dep pinned hex `~> 0.3.0`): revert the NPL flip commit — lib 0.3.0 stays published and harmless to NPL's old path; NPL's old engine files are restored by the revert (they are deleted only IN the flip commit, keeping the revert atomic).
- **Never**: re-point NPL at lib-owned tables; hand-edit lib 0.3.0 post-publish (freeze, PRD-4 §10).

---

## 9. Flip-to-hex checklist (final commit of this PRD)

1. Lib `main` has PRD-1..4 merged; `mix.exs` `@version` = `"0.3.0"` (PRD-4 §6.10); cumulative suite green.
2. **User-run** (2FA): `cd Portfolio/Libs/ai/elixir-mcp && mix hex.publish` (OTP prompt) — verify hex shows 0.3.0 with correct docs/links. (Agents do NOT publish — no key rotation, per standing rules.)
3. NPL branch: `mix.exs` `path:` dep → `{:noizu_mcp, "~> 0.3.0"}`; `mix deps.update noizu_mcp`; full conformance suite (§7) + `key_toolset_guard` REST tests green.
4. Delete legacy engine modules + original test files (§6.8); AP-12/13 guards green.
5. Monorepo housekeeping: NPL submodule commit on its `main` (standing rules: push once green); update monorepo gitlink; note the flip in NPL CHANGELOG.
6. Post-flip smoke: `effective_toolset_matrix_conformance` + `client_toolsets_conformance` against staging NPL (session-domain server + `tobor_custom`).

---

## 10. Open questions

1. **Q1 (lead confirm):** step-up wire delta §8.1 — replacing the legacy `insufficient_authorization` tool-result with the lib `forbidden` error is the single client-visible break. Alternative (keep the legacy envelope via a thin NPL `handle_call_tool` override) contradicts the "stops emitting handle_call_tool" goal. Current spec accepts the delta.
2. **Q2:** profile `include` lists are compile-time literals; a domain tool added later is NOT in any profile until the list is updated (explicit participation, D4). Alternative: profile DSL filters by tool category/annotation. Confirm literal-lists for 0.3.0 (matches "immutable static profiles").
3. **Q3:** `tobor_custom` scope-slug transport — today via `ctx.assigns[:custom_scope_slug]`; post-migration the resolver needs it pre-principal or in `Principal.metadata`. Spec: `PrincipalMapper` copies it into `Principal.metadata[:custom_scope_slug]`. Confirm.
4. **Q4:** `Session_Manifest` `expires_at` column — sourced from Window-extracted grant expiry via `permissions/3`? lib `permissions/3` (PRD-1 §4.4) reports name/visible/callable only; expiry surfaces via the catalog `reason`/grant metadata — NPL may need one enrichment read via `Store.list(:grant, ...)`. Confirm acceptable (keeps lib `permissions/3` shape frozen).
5. **Q5:** NPL-side rate/shaping concerns (provider per-request DB reads) — mitigated by lib Cache + version fingerprints (§4.1); if hot paths still hurt, the follow-up is provider-side memoization INSIDE NPL, never lib changes (freeze). Noted, no action in 0.3.0.
