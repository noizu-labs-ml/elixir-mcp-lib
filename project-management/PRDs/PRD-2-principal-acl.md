# PRD-2: Principal, Per-Request Claims & ACL Layer

**Series**: noizu_mcp 0.3.0 toolset architecture (PRD-2 of 5)
**Repo**: `Portfolio/Libs/ai/elixir-mcp` (anchors relative to this root; NPL cross-references use the full monorepo path)
**Version policy**: merge on lib `main`; no version bump, no publish (single 0.3.0 release at series end — INDEX.md)
**Depends on**: PRD-1 (protocol core) — cumulative lib state after this PR is green on the union suite
**Status**: Draft
**Design rules**: D1–D5 (see PRD-1 §2); anti-pattern targets here: **forgeable contexts** (typed `%Principal{}`, no system fallback) and **decorative ACL** (enforced in the dispatch path, default-DENY when a provider is configured)

---

## 1. Goal

Give the library a typed request identity and a real authorization seam:

1. `%Noizu.MCP.Auth.Principal{}` — host-owned subject + authenticator + claims + granted scopes.
2. Per-request claims transport: `Session.deliver/3` (optional third arg), plug passes verifier-checked claims per request; stdio/SSE/VFS-WS transports untouched.
3. `Ctx` gains `auth: %Principal{} | nil` — `nil` means anonymous; there is NO system/trusted fallback identity.
4. `Noizu.MCP.ACL` protocol + `ACL.Provider` behaviour + `%ACL.Resource{}`; registration via `use Noizu.MCP.Server, acl: ...`; verdicts enforced inside the behaviour's catalog/resolve defaults (same chokepoint the merge engine will use in PRD-3), so ACL can never be decorative.

**Out of scope**: `%CustomToolset{}` composition and weighted merge (PRD-3), persistence-backed grants/negotiations (PRD-4), NPL provider implementations (PRD-5).

---

## 2. Decision log applied

| Rule | Binding |
|------|---------|
| D1 one resolver | ACL verdicts are applied INSIDE the behaviour defaults (catalog/resolve) — not in a host wrapper, not in the plug. Hosts cannot get an un-ACL'd listing by calling `Features.Tools.list_registered/3` directly: the shim routes through the same defaults (PRD-1 §4.9). |
| D3 runtime-only | Principal resolution happens per request at `build_ctx`; ACL provider is resolved per call from server opts (superseded by `providers:` keyword in PRD-4). |
| D4 explicit participation | ACL participation is explicit config (`acl:` opt). No provider ⇒ inert (back-compat). No reflection-based subject detection. |
| D5 fail-closed per set / fail-open per server | With a provider configured: missing/crashed verdict ⇒ `:deny` for that tool (fail-closed). Provider crash ⇒ affected tools denied, server healthy, telemetry emitted. Invalid `acl:` opt value ⇒ CompileError at `use` time (worse than D5: config errors must not boot). |
| Decision 2 (NPL disposition) | The lib owns NONE of the policy data; providers are the only way policy enters. NPL's tables (`mcp_custom_scopes`, `oauth_clients/mcp_api_keys toolset_config`) stay NPL-owned — PRD-5 implements providers over them. Nothing here reads host tables. |

---

## 3. Background

- Claims today: the streamable-http plug verifies tokens and assigns claims at `lib/noizu/mcp/transport/streamable_http/plug.ex:180-181` (`assign(conn, :mcp_auth_claims, claims)`), then folds them into the session's INITIALIZE assigns at `:387-406` (`conn.assigns[:mcp_auth_claims] → Map.put(assigns, :auth_claims, claims)`). Result: claims are frozen per-SESSION; a token refresh or scope change mid-session is invisible, and non-HTTP transports have no path at all.
- Context today: `%Noizu.MCP.Ctx{}` (`lib/noizu/mcp/ctx.ex:32-44`) has no identity field; handlers infer "who" from `assigns` — untyped, forgeable, transport-dependent.
- Authorization today: none in the lib. Hosts override `handle_call_tool` (NPL's `ToolGuard` + PDP at monorepo `Portfolio/Apps/AI/NoizuPromptLingo/backend/lib/noizu_prompt_lingua/mcp/dispatch.ex:33-52`) — exactly the "decorative/enforcement-outside-the-lib" anti-pattern this PRD closes at the LIB layer for toolsets, while remaining 100% inert when unconfigured.

---

## 4. Public surface

### 4.1 `lib/noizu/mcp/auth/principal.ex`

```elixir
defmodule Noizu.MCP.Auth.Principal do
  @enforce_keys [:subject, :authenticator]
  defstruct [
    :subject,            # host-owned term (binary, ref, struct — opaque to the lib)
    :authenticator,      # atom() — e.g. :api_key, :oauth, :jwt, :test
    :token_id,           # term() | nil — host's token/credential id for audit
    claims: %{},         # map() — raw verifier-checked claims (strings, as verified)
    granted_scopes: MapSet.new(),  # MapSet<String.t()>
    metadata: %{}        # map() — host extension point; never interpreted by the lib
  ]
  @type t :: %__MODULE__{...}

  @spec anonymous?(t() | nil) :: boolean()
  @spec has_scope?(t(), String.t()) :: boolean()  # exact match OR trailing-`*` prefix glob ("pm:*")
  @spec scope_list(t()) :: [String.t()]
end
```

- The lib NEVER constructs a "system" principal. No `Principal.system/0`. Tests assert its absence.
- `has_scope?/2` glob: `"pm:*"` matches any scope starting `pm:`; `*` alone matches everything; otherwise exact.

### 4.2 `Ctx` change — `lib/noizu/mcp/ctx.ex`

- `@type` (`:18-30`) and `defstruct` (`:32-44`) gain `auth: nil` (`%Principal{} | nil`).
- Documentation: `nil` = anonymous. Handlers must treat `nil` and `%Principal{}` uniformly; there is no elevated/implicit identity.

### 4.3 `Error.forbidden` — `lib/noizu/mcp/error.ex`

```elixir
@spec forbidden(String.t(), term()) :: t()
# code: -32000 (MCP server-defined range), reason: :forbidden
def forbidden(message \\ "Forbidden", data \\ nil)
```

Placed with the other constructors (file `:36-90` region). `resolve/4` failures that are authorization-shaped use this (`{:error, %Error{reason: :forbidden}}`), while unknown/non-callable tools keep `invalid_params` per PRD-1 FR-1.5 — the asymmetry is intentional: existence-hiding for tools, honesty for authorization.

### 4.4 Per-request claims transport — `lib/noizu/mcp/server/session.ex`

- KEEP `deliver/2` (`:41`) — stdio (`lib/noizu/mcp/transport/stdio.ex`), SSE (`lib/noizu/mcp/transport/sse.ex`), and VFS-WS (`lib/noizu/mcp/transport/vfs_ws.ex`) call sites are untouched.
- ADD:

```elixir
@spec deliver(GenServer.server(), binary(), map() | nil) :: :ok
def deliver(session, binary, claims), do: GenServer.cast(session, {:deliver, binary, claims})

# new clause, mirrored on :120-136:
def handle_cast({:deliver, binary, claims}, state) do
  state = %{rearm_idle_timer(state) | current_auth: resolve_principal(state, claims)}
  # ... identical JsonRpc.decode → Peer.ingest → run_effects flow ...
  # AFTER run_effects returns (single message processed):
  {:noreply, %{state | current_auth: nil}}   # cleared post-dispatch — never leaks into
end                                          # server-initiated notifications (:173-186)
```

- `state` gains `current_auth: nil` in `init` (the `init/1` return at `:100-116`).
- `build_ctx/4` (`defp`, `:550-564`) sets `auth:` from, in precedence order:
  1. `state.current_auth` (already a `%Principal{}` — resolved at deliver time),
  2. `state.assigns[:mcp_principal]` (host-plugged `%Principal{}` — see §4.5),
  3. `state.assigns[:auth_claims]` (today's initialize-time claims path, `plug.ex:387-406`) mapped through `resolve_principal/2`,
  4. `nil`.
- `resolve_principal/2` (private in session.ex, exported logic in §4.5): claims map → `%Principal{}` via the server's `principal:` opt; `nil`/absent ⇒ `nil`.

### 4.5 Principal mapping — host integration points

Two equivalent seams (both optional; absent ⇒ anonymous):

```elixir
# (a) Server opt — claims → principal, called per request (D3: runtime)
use Noizu.MCP.Server,
  name: "...", version: "...",
  principal: {MyAuth, :to_principal, [some: :opts]}
# invoked as MyAuth.to_principal(claims, some: :opts)
# expected: {:ok, %Principal{}} | %Principal{} | {:error, term()}
#   {:error, term}  ⇒ ctx.auth = nil AND Logger.warning (fail-open to anonymous; the
#   transport-level verifier is the authentication gate — the lib never 401s here)

# (b) Plug seam — assign a ready principal, wins over claims mapping
#     lib/noizu/mcp/transport/streamable_http/plug.ex:
#     :387-406 assigns merge gains: conn.assigns[:mcp_principal] → assigns[:mcp_principal]
```

`resolve_principal/2` built-in mapping when NO `principal:` opt is configured (so per-request claims still flow without host code):

```elixir
%Principal{
  subject: claims["sub"], authenticator: :claims, token_id: nil,
  claims: claims,
  granted_scopes: claims |> Map.get("scope", "") |> split_whitespace() |> MapSet.new()
}
# claims lacking "sub" ⇒ nil principal (anonymous) — never a synthetic subject
```

`Session` gains `Session.put_principal(session, %Principal{} | nil)` (`handle_call`, mirroring `{:put_assign, key, value}` at `:190`) for transports that resolve identity out-of-band.

### 4.6 ACL — `lib/noizu/mcp/acl.ex`, `lib/noizu/mcp/acl/provider.ex`, `lib/noizu/mcp/acl/resource.ex`

```elixir
defmodule Noizu.MCP.ACL.Resource do
  @enforce_keys [:kind, :id]
  defstruct [:kind, :id]   # kind: :tool | :toolset | :prompt | :resource | atom()
                           # id:   term() — for :tool, the canonical wire name (String.t())
end

defprotocol Noizu.MCP.ACL do
  @fallback_to_any true    # fail-closed Any only (same pattern as Toolset, PRD-1 §4.1 note)
  @doc ":allow | :deny — no third verdict. Unregistered kinds at rule/validator time: CompileError (see §4.7)."
  def check(subject, %Resource{} = resource, action, ctx, opts)
end

defmodule Noizu.MCP.ACL.Provider do
  @callback check(subject, Resource.t(), action :: atom() | String.t(), ctx, opts) :: :allow | :deny
  @callback check_all(subject, [Resource.t()], action, ctx, opts) :: %{term() => :allow | :deny}
  # check_all has a DEFAULT impl: Enum into check/5. Providers serving many tools SHOULD
  # override to batch (NPL's PDP does).
end

defimpl Noizu.MCP.ACL, for: Noizu.MCP.Auth.Principal do
  # consults the server-configured provider: ACL.current_provider(ctx.server, opts)
  def check(subject, resource, action, ctx, opts), do: provider_check(:single, ...)
end

defimpl Noizu.MCP.ACL, for: Any do
  def check(_s, _r, _a, _c, _o), do: raise(ArgumentError, "ACL subjects must be explicit participants")
end
```

Built-in providers (`lib/noizu/mcp/acl/providers/`):

```elixir
Noizu.MCP.ACL.Providers.Disabled  # :allow always — the semantic of acl: :disabled
Noizu.MCP.ACL.Providers.DenyAll   # :deny always  — acl: :deny_all
```

Public helpers on `Noizu.MCP.ACL`:

```elixir
@spec current_provider(server :: module(), opts :: keyword()) :: module() | nil
#   reads (in order): per-call opts[:acl] → server __mcp__(:opts)[:acl] → :disabled
#   (Application-env override arrives in PRD-4 with the providers: keyword)
@spec filter_entries([Toolset.Entry.t()], server, ctx, opts) :: [Toolset.Entry.t()]
#   THE enforcement chokepoint (called inside behaviour defaults, see §5).
#   provider nil ⇒ entries unchanged (inert, back-compat).
#   provider set ⇒ check_all/5 over {:resource, :tool, name} for every entry;
#     verdict :deny            ⇒ entry.visible = false, entry.callable = false,
#                                entry.reason = {:acl, provider_module}  (only if not already false)
#     verdict ABSENT (map miss or provider raise) ⇒ :deny (fail-closed, D5)
#     all-allow               ⇒ entries unchanged
#   provider raise ⇒ logged :warning + telemetry [:noizu_mcp, :acl, :error]; entries ALL denied
#     (fail-closed for this surface; server stays healthy — resolve errors are per-tool invalid_params,
#      catalog errors are {:error, %Error{reason: :internal_error}} with the tools section disabled, not a crash)
```

### 4.7 Registration — `use Noizu.MCP.Server, acl: ...`

```elixir
use Noizu.MCP.Server,
  name: "...", version: "...",
  acl: :disabled                      # default — inert, zero behavior change (back-compat)
  # | :deny_all                       # everything denied
  # | MyProvider                      # must implement ACL.Provider
  # | {MyProvider, opts}              # provider + opts passed to check/check_all
```

**Compile-time enforcement:** `__using__` (`lib/noizu/mcp/server.ex`) validates the `acl:` opt at expansion time. For a module literal: read `MyProvider.behaviour_info(:callbacks)` — missing `:check`/`:check_all` ⇒ `raise CompileError`. (This is why the opt must be a compile-time module literal, not an MFA — misconfig fails the build, not a request.) `:disabled`/`:deny_all` map to the built-ins. Stored in `__mcp_server_opts__` and re-exposed via `__mcp__(:opts)` (`:406`).

**Kind registration check:** `check/5` calls with a `%Resource{kind: k}` where the provider's supported kinds (declared via optional `@callback supported_kinds :: [atom()], default: [:tool, :toolset, :prompt, :resource]`) omit `k` ⇒ `raise` at rule/validator time (i.e., when `filter_entries` builds resources — fail-closed config error, surfaces in test runs and on first use, never silently allows). Series scope only exercises `kind: :tool`; the other kinds exist for prompts/resources (PRD-4 Store) and host extension.

---

## 5. Requirements

**FR-2.1** `%Principal{}` per §4.1 with `anonymous?/1`, `has_scope?/2` (exact + trailing-`*` glob), `scope_list/1`. No `system/0` constructor exists (compile-time assert via test grepping `def .*system` in the module — asserted by a test that pattern-matches `Principal.module_info(:exports)`).
**FR-2.2** `Ctx.auth` field added; `build_ctx/4` (`session.ex:550-564`) populates it per §4.4 precedence; `current_auth` is cleared after each `{:deliver, _binary, _claims}` cast completes.
**FR-2.3** `Session.deliver/3` exists (optional-third-arg style: arity-2 clause retained); arity-3 path sets/clears `current_auth`; arity-2 path leaves `current_auth` nil. stdio/sse/vfs_ws sources untouched (verified by grep-based test that those files contain no `deliver(_, _, _)` calls — actually asserted behaviorally: stdio fixture session never sets auth).
**FR-2.4** Plug passes per-request claims: `plug.ex` call/2 path (`:121`) forwards `conn.assigns[:mcp_auth_claims]` into `Session.deliver(session, body, claims)` at the three deliver sites (`:354, :411, :434` — initialize, request, notification paths; initialize keeps folding into base assigns for back-compat via the existing `:387-406` block). A claims change between requests is visible on the NEXT request (test).
**FR-2.5** Principal mapping: `principal:` MFA opt (§4.5a) + `:mcp_principal` assign (§4.5b) + built-in claims mapping when unconfigured (§4.5). Mapping error ⇒ anonymous + `Logger.warning`, never a synthetic principal.
**FR-2.6** `Error.forbidden/2` constructor (code `-32000`, `reason: :forbidden`).
**FR-2.7** `Noizu.MCP.ACL` protocol + `Provider` behaviour + `%Resource{}` + `Disabled`/`DenyAll` built-ins per §4.6, including default `check_all/5` and the fail-closed Any impl.
**FR-2.8** `acl:` opt registration with compile-time callback validation (§4.7); invalid provider module ⇒ CompileError at `use` expansion; `:disabled` default ⇒ byte-identical behavior to PRD-1 (snapshot test).
**FR-2.9** ACL enforcement lives in the behaviour defaults: PRD-1's `catalog/3` and `resolve/4` defaults call `ACL.filter_entries/4` after the static pass. Effects: denied tools vanish from listing AND dispatch (resolve ⇒ `invalid_params`, identical to absent — existence-hiding), with `permissions/3` still reporting them (`visible: false, callable: false`) so hosts can audit WHY (reason tuple).
**FR-2.10** Default-DENY when configured: with a provider configured, a tool with NO verdict (map miss) or a provider exception is denied (§4.6). With NO provider: nothing is denied (inert). Both asserted.
**FR-2.11** Telemetry: `[:noizu_mcp, :acl, :check]` (duration, `%{provider, verdict}`), `[:noizu_mcp, :acl, :error]` (provider crash). Events attach test metadata only; no behavioral coupling.
**FR-2.12** `metadata/3` and `permissions/3` from PRD-1 remain correct under ACL (permissions reports post-ACL state including denied entries; metadata unaffected).

**Acceptance criteria**

**AC-2.1** No-provider servers: full suite from PRD-1 byte-identical (additive guarantee).
**AC-2.2** `acl: :deny_all` server: tools/list empty, tools/call invalid_params (message identical to unknown tool), `permissions/3` lists all tools `visible:false, callable:false, reason: {:acl, Noizu.MCP.ACL.Providers.DenyAll}`.
**AC-2.3** Custom provider fixture: deny tool A, allow tool B, ABSENT tool C ⇒ A and C hidden+uncallable, B normal (default-DENY proven).
**AC-2.4** Provider that RAISES: all tools denied for that request, server process alive, next request with healthy provider works (D5 fail-open-per-server).
**AC-2.5** Per-request claims: two sequential `deliver/3` calls with different claims yield ctx.auth subjects respectively; a following server-initiated `notify_changed` (session.ex `:173`) processes with `current_auth == nil` (no leak into notification builds).
**AC-2.6** `principal:` MFA receives the raw claims map + opts and its result lands in `ctx.auth` for tool handlers (fixture tool echoes `ctx.auth`).
**AC-2.7** stdio transport e2e (`test/noizu/mcp/stdio_e2e_test.exs`) unchanged and green.

---

## 6. Internal work checklist (anchors)

| Step | File | Detail |
|------|------|--------|
| 6.1 | `lib/noizu/mcp/auth/principal.ex` | NEW (§4.1) |
| 6.2 | `lib/noizu/mcp/ctx.ex` | `auth` field (`:18-30` type, `:32-44` struct) |
| 6.3 | `lib/noizu/mcp/error.ex` | `forbidden/2` constructor (constructor block `:36-90`) |
| 6.4 | `lib/noizu/mcp/server/session.ex` | `current_auth` in state (`init` `:100-116`); `deliver/3` + `{:deliver, _, _}` cast (mirror `:120-136`); `resolve_principal/2`; `build_ctx/4` auth precedence (`:550-564`); `put_principal/2` (mirror `:190`); clear-after-dispatch |
| 6.5 | `lib/noizu/mcp/transport/streamable_http/plug.ex` | forward claims at deliver sites `:354/:411/:434`; `:mcp_principal` assign in merge `:387-406`; claims assign already at `:180-181` |
| 6.6 | `lib/noizu/mcp/acl.ex` / `acl/resource.ex` / `acl/provider.ex` / `acl/providers/{disabled,deny_all}.ex` | NEW (§4.6) |
| 6.7 | `lib/noizu/mcp/toolset/behaviour.ex` | catalog/resolve defaults call `ACL.filter_entries/4` post-static-pass (PRD-1 §4.4 extended) |
| 6.8 | `lib/noizu/mcp/server.ex` | `acl:` opt validation in `__using__`/`__before_compile__` (`:241+`), exposure via `__mcp__(:opts)` (`:406`); `principal:` opt passthrough |
| 6.9 | `lib/noizu/mcp/server/toolset.ex` (n/a) | — (enforcement in behaviour, not a new module) |

---

## 7. Test plan

New files under `test/noizu/mcp/`:

- **`auth/principal_test.exs`** — struct defaults, `anonymous?`, scope glob matrix (exact / `pm:*` / `*` / no-match), no `system/0` export (exports reflection).
- **`auth/session_auth_test.exs`** — deliver/2 vs deliver/3; current_auth set/clear; build_ctx precedence (current_auth > `mcp_principal` assign > `auth_claims` assign > nil); notification path carries nil auth (AC-2.5); mapping error ⇒ anonymous (FR-2.5).
- **`transport/streamable_http_per_request_claims_test.exs`** — plug fixtures: claims rotate between requests; `mcp_principal` assign precedence; initialize-path back-compat (`auth_claims` still folded at `:387-406`).
- **`acl/acl_protocol_test.exs`** — Resource/protocol/Any-raise; `check_all` default; `Disabled`/`DenyAll`; `supported_kinds` violation raises.
- **`acl/filter_entries_test.exs`** — verdict matrix (allow/deny/absent/raise × provider-configured/unconfigured); reason tuples; inert-when-nil (AC-2.1).
- **`acl/acl_registration_test.exs`** — `acl:` opt compile errors (missing callbacks ⇒ CompileError with actionable message); `:deny_all` e2e (AC-2.2); custom provider fixture (AC-2.3); crash recovery (AC-2.4).
- **`acl/resolve_hiding_test.exs`** — resolve-on-denied == resolve-on-absent (byte-identical errors); permissions/3 audit surface (FR-2.9).

**Anti-pattern regression tests (MUST exist and stay green through the series):**

- **AP-4 (forgeable contexts):** a tool handler that builds `%Ctx{auth: %Principal{subject: "admin", ...}}` by hand and calls another tool's spec through `Toolset.invoke/5` gains NOTHING — ACL re-checks happen inside catalog/resolve on the CALLER's ctx, and `invoke/5` itself takes an `%Effective{}` that can only come from `resolve/4`. Test: hand-forged Effective (constructed directly) still passes through invoke — assert instead that there is NO lib path from forged ctx to a resolved Effective except through `resolve/4` (the only constructor of `%Effective{}` with populated spec is the behaviour default; documented + asserted).
- **AP-5 (decorative ACL):** calling `Features.Tools.list_registered/3`/`dispatch/4` shims directly (bypassing `handle_*`) STILL applies the server's ACL — because shims route through behaviour defaults (PRD-1 §4.9). Test with `acl: :deny_all`: shim output is filtered too. This is THE regression test that ACL can never be decorative.
- **AP-6 (default-DENY):** covered by AC-2.3's absent-tool-C case; keep as a named, standalone test so a future "performance optimization" that batches provider checks cannot silently turn misses into allows.

---

## 8. Compat & rollback

- **Back-compat invariant:** no `acl:`/`principal:` opts ⇒ zero behavior delta vs PRD-1 (snapshot-tested). Existing `auth_claims` assigns path keeps working (handlers reading `ctx.assigns[:auth_claims]` — NPL does this — continue to work; PRD-5 migrates them).
- NPL on `path:` dep unaffected: its `handle_call_tool` override continues to win; its PDP (ToolGuard) remains authoritative for its servers until PRD-5.
- Transports stdio/sse/vfs_ws: no code change; compile-verified.
- **Rollback:** single-PR revert; `Ctx.auth` is additive (struct default nil), `%Principal{}` unused when unconfigured.
- Sequencing note: `filter_entries` sits inside behaviour defaults NOW so PRD-3's context pass REPLACES its call site with the weighted-layer fold (ACL = weight-300) without changing where hosts observe enforcement.

---

## 9. Open questions

1. **Q1:** Should a provider `check_all` returning EXTRA ids (unknown tools) be an issue (telemetry warn) or ignored? Spec: ignored + `[:noizu_mcp, :acl, :stale_verdict]` debug event. Confirm.
2. **Q2:** `principal:` MFA failure currently fails open to anonymous (authentication is the transport's job). Alternative: fail closed (reject request with `forbidden`). Lead's call — this PRD implements fail-open-to-anonymous because the plug verifier already rejected bad tokens before claims exist.
3. **Q3:** `supported_kinds` default — include only `[:tool]` until PRD-4 wires prompts/resources through ACL? Stricter default surfaces kind-gaps earlier; spec currently defaults to all four kinds. Confirm preference.
4. **Q4:** Scope glob semantics — only trailing `*` (spec) vs full glob. NPL's `mcp_custom_scopes` uses group scopes; trailing-`*` covers them. Confirm no fuller matching needed for 0.3.0.
