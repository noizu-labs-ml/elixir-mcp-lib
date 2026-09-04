# PRD-1: Toolset Protocol Core

**Series**: noizu_mcp 0.3.0 toolset architecture (PRD-1 of 5)
**Repo**: `Portfolio/Libs/ai/elixir-mcp` (all anchors below are relative to this root unless prefixed with the full monorepo path for cross-repo references)
**Version policy**: merges as a normal PR on the lib's `main`; `mix.exs` `@version` stays `0.2.0` (single `0.3.0` bump happens in the final PR of the series — see INDEX.md publish plan)
**Depends on**: nothing (series root)
**Status**: Draft
**Design rules**: governed by D1–D5 (see §2)

---

## 1. Goal

Introduce a single, protocol-driven toolset abstraction so that listing (`tools/list`), dispatch (`tools/call`), manifests, and catalog inspection all consume ONE resolution path (D1), and so that per-toolset materialization (effective tool definitions after overrides) happens before validation and wire-rendering (D2).

Deliverables:

1. `Noizu.MCP.Toolset` protocol + `Noizu.MCP.Toolset.Behaviour` default implementations.
2. `%Toolset.Entry{}`, `%Toolset.Effective{}`, `%Toolset.Ref{}` structs.
3. Closed override vocabulary: `%Toolset.Override{}` + pure applier `Noizu.MCP.Toolset.Overrides`.
4. `wire_key` support in `Noizu.MCP.Server.Tool.Fields.cast/2` so field renames are wire-only.
5. Server integration: generated `handle_list_tools`/`handle_call_tool` route through the protocol; `run_spec` relocates from `Noizu.MCP.Server.Features.Tools` (private) into `Toolset.Behaviour` (public).
6. Catalog tool (`Noizu.MCP.Server.Tools.Catalog`) gains a protocol mode.

**Explicitly OUT of scope** (later PRDs): `%Principal{}`/auth plumbing (PRD-2), `%CustomToolset{}` composition/merge/Validator/Cache (PRD-3), persistence/migrations/grants/negotiations/Store (PRD-4), NPL host migration (PRD-5).

---

## 2. Decision log applied to this PRD

| Rule | How it binds this PRD |
|------|----------------------|
| D1 one resolver | `handle_list_tools`, `handle_call_tool`, and the Catalog tool all route through `Toolset.catalog/3` / `resolve/4` / `invoke/5`. `Features.Tools.list_registered/3` and `dispatch/4` become shims over the same behaviour defaults — no second code path. |
| D2 effective materialization | `resolve/4` returns a materialized `%Effective{}` carrying the EFFECTIVE `%Types.Tool{}`, input_schema, and cast_plan. `invoke/5` validates/casts/executes against the effective triple, never against the static spec. |
| D3 runtime-only resolution | No compile-time env capture: behaviour defaults read `__mcp__(:tools)` and opts at call time. |
| D4 explicit participation | No semantic `Any` impl. Protocol impls exist only for: `Atom` (→ `%Ref{}`), `%Toolset.Ref{}` (→ delegate), and `@derive`-ing structs (→ delegate). A single fail-closed `Any` impl exists ONLY to raise `ArgumentError` — see §4.1 note. No `function_exported?` probing anywhere in the dispatch path. |
| D5 fail-closed per set, fail-open per server | A toolset whose resolution raises/returns an error disables that toolset (catalog/resolve return `{:error, %Error{}}` with reason); the server itself stays healthy. Regression-tested (§8.4). |
| Decision 1 (single hex publish) | No version bump, no hex publish in this PR. NPL may compile against `main` via `path:` dep throughout; this PR is additive and must not break NPL's current `handle_call_tool` overrides (host-defined handlers win via the existing `defines?` guard, `lib/noizu/mcp/server.ex:258,276,284`). |

---

## 3. Background

Today a server's tool surface is a static list of `%Noizu.MCP.Server.Tool.Spec{}` structs (`lib/noizu/mcp/server/tool/spec.ex:19-28`: `module, fun, arity, definition, cast_plan, output_schema, hidden, evals`).

- Listing: `Features.Tools.list_registered/3` (`lib/noizu/mcp/server/features/tools.ex:151-162`) expands registrations, drops `hidden` specs, paginates `%Types.Tool{}` definitions.
- Dispatch: `Features.Tools.dispatch/4` (`lib/noizu/mcp/server/features/tools.ex:183-188`) finds by `definition.name == name`, then `run_spec` (private, `lib/noizu/mcp/server/features/tools.ex:190-212`) validates against the STATIC schema, casts with the static cast plan, and applies.
- Hosts that need per-caller surfaces (NoizuPromptLingua) currently override `handle_call_tool`/`handle_list_tools` **before** `use Noizu.MCP.Server` and re-implement `run_spec` privately (monorepo `Portfolio/Apps/AI/NoizuPromptLingo/backend/lib/noizu_prompt_lingua/mcp/dispatch.ex:24-52`) — a fork of dispatch logic the lib can no longer see or secure.

Prior-art anti-patterns this design explicitly rejects (regression-tested in §8.4): decorative ACL layers outside the dispatch path, forgeable ad-hoc contexts, compile-time macro monoliths, and runtime module scans for toolset discovery.

---

## 4. Public surface

All new modules live under `lib/noizu/mcp/` in the lib repo.

### 4.1 `lib/noizu/mcp/toolset.ex` — protocol

```elixir
defprotocol Noizu.MCP.Toolset do
  @fallback_to_any true   # solely to power the fail-closed Any impl; see note

  @doc """
  Enumerate the effective tool entries for this toolset under ctx.
  Returns {:ok, [%Entry{}], catalog_version :: String.t()} | {:error, %Noizu.MCP.Error{}}.
  """
  def catalog(toolset, ctx, opts)

  @doc """
  Resolve one tool by wire name to its effective form.
  Returns {:ok, %Effective{}} | {:error, %Noizu.MCP.Error{reason: :invalid_params | :forbidden}}.
  A non-callable entry resolves to the SAME error as an absent tool (invalid_params,
  identical message) to avoid a discovery oracle for hidden tools.
  """
  def resolve(toolset, name, ctx, opts)

  @doc "Invoke a resolved effective tool. Returns whatever the handler returns (normalized ToolResult / {:error, %Error{}} / raised)."
  def invoke(toolset, effective, args, ctx, opts)

  @doc "Permission projection: {:ok, %{tools: [%{name, visible, callable}], version}} | {:error, %Noizu.MCP.Error{}}."
  def permissions(toolset, ctx, opts)

  @doc "Descriptive metadata: {:ok, %{slug: String.t(), title: String.t() | nil, description: String.t() | nil, version: String.t()}} | {:error, %Noizu.MCP.Error{}}."
  def metadata(toolset, ctx, opts)

  @doc "Coerce a toolset entity reference into a dispatchable toolset value."
  def coerce(toolset)
end
```

**`coerce/1` semantics (normative):**

| Input | Result |
|-------|--------|
| module atom | `%Toolset.Ref{target: atom}` |
| `%Toolset.Ref{}` | itself |
| struct whose module derived the protocol (`@derive Noizu.MCP.Toolset`) | itself (generated impl) |
| anything else (incl. non-deriving structs, maps, integers) | raises `ArgumentError` |

> **D4 note (deliberate deviation, documented):** the lead architecture names `coerce/1` as a plain function on the protocol module. Elixir's `defprotocol` accepts only function heads, so `coerce/1` is a protocol function instead. The `Any` impl is fail-closed — every function raises `ArgumentError("toolset entities must implement Noizu.MCP.Toolset explicitly (derive the protocol or use Noizu.MCP.Toolset.Behaviour)")`. It provides no semantic fallback and cannot make a non-participant dispatchable; it exists purely so `coerce/1` produces the specified error type. This is NOT the forbidden "Any impl" pattern (which is about silent semantic fallbacks).

### 4.2 `lib/noizu/mcp/toolset/ref.ex` — reference wrapper

```elixir
defmodule Noizu.MCP.Toolset.Ref do
  @enforce_keys [:target]
  defstruct [:target]            # target: module() — a server or behaviour-backed toolset module
  @type t :: %__MODULE__{target: module()}
end

defimpl Noizu.MCP.Toolset, for: Noizu.MCP.Toolset.Ref do
  # Delegates unconditionally to the target module's functions — no function_exported? probing.
  # A target lacking the functions raises UndefinedFunctionError, which callers
  # normalize to {:error, %Error{reason: :internal_error}} per D5 (set disabled, server healthy).
  def catalog(%Ref{target: t}, ctx, opts), do: t.catalog(t, ctx, opts)
  def resolve(%Ref{target: t}, name, ctx, opts), do: t.resolve(t, name, ctx, opts)
  def invoke(%Ref{target: t}, eff, args, ctx, opts), do: t.invoke(t, eff, args, ctx, opts)
  def permissions(%Ref{target: t}, ctx, opts), do: t.permissions(t, ctx, opts)
  def metadata(%Ref{target: t}, ctx, opts), do: t.metadata(t, ctx, opts)
  def coerce(%Ref{} = r), do: r
end

defimpl Noizu.MCP.Toolset, for: Atom do
  def coerce(atom) when is_atom(atom), do: %Noizu.MCP.Toolset.Ref{target: atom}
  def catalog(t, ctx, opts), do: (Toolset.coerce(t)).catalog(ctx, opts)  # via Ref delegation
  # ... resolve/invoke/permissions/metadata likewise wrap through coerce/1
end
```

(Implementers may inline the Atom impl through the Ref impl exactly as sketched; the contract is the behavior, not the delegation style.)

### 4.3 Entry / Effective structs — `lib/noizu/mcp/toolset.ex` (same file, below protocol)

```elixir
defmodule Noizu.MCP.Toolset.Entry do
  @enforce_keys [:definition]
  defstruct [
    :definition,        # %Noizu.MCP.Types.Tool{} — EFFECTIVE definition (post-override, post-render-neutral)
    :input_schema,      # map() — effective JSON Schema (defaults to definition.input_schema)
    :cast_plan,         # list() | nil — effective cast plan (Fields-compatible)
    visible: true,      # shown in tools/list?
    callable: true,     # dispatchable?
    reason: nil         # term() — why hidden/uncallable (e.g. :hidden_by_spec, {:acl, provider}, :negotiation_required)
  ]
end

defmodule Noizu.MCP.Toolset.Effective do
  @enforce_keys [:name, :entry, :spec]
  defstruct [
    :name,              # String.t() — canonical wire name
    :entry,             # %Entry{}
    :spec,              # %Noizu.MCP.Server.Tool.Spec{} — execution target (module/fun/arity)
    provenance: nil,    # %{op_key => {layer_id :: term, weight :: integer}} — set by PRD-3 merge engine; nil in PRD-1
    version: nil,       # String.t() — catalog_version this was resolved from
    reason: nil         # term()
  ]
end
```

Hidden-but-callable state is EXPLICIT in `%Entry{}` (`visible: false, callable: true, reason: :hidden_by_spec`) — the current behavior where `dispatch/4` finds tools that `list_registered/3` suppressed, but now first-class.

### 4.4 `lib/noizu/mcp/toolset/behaviour.ex` — duality behaviour

```elixir
defmodule Noizu.MCP.Toolset.Behaviour do
  @moduledoc """
  Protocol+behaviour duality. Structs: `use Noizu.MCP.Toolset.Behaviour` then
  `@derive Noizu.MCP.Toolset`. Servers: `use Noizu.MCP.Server` injects the same
  functions over __mcp__(:tools), so a bare server module IS a toolset entity.
  """

  defmacro __using__(opts)

  # Injected (all wrapped in defoverridable):
  @callback __toolset_specs__(ctx, opts) :: [Noizu.MCP.Server.Tool.Spec.t()]
  @callback catalog(toolset, ctx, opts) :: {:ok, [Entry.t()], String.t()} | {:error, Error.t()}
  @callback resolve(toolset, name, ctx, opts) :: {:ok, Effective.t()} | {:error, Error.t()}
  @callback invoke(toolset, Effective.t(), args, ctx, opts)
  @callback permissions(toolset, ctx, opts)
  @callback metadata(toolset, ctx, opts)
end
```

Default implementations (normative behavior):

- `__toolset_specs__/2` — no default body; `use Noizu.MCP.Server` generates it as `Noizu.MCP.Server.Features.Tools.expand(__mcp__(:tools))` (expand exists at `lib/noizu/mcp/server/features/tools.ex:98`). A struct module that `use`s the behaviour without overriding it gets a `raise` at call time (fail-closed, D5).
- `catalog/3` — take specs, apply `Overrides` merge with NO overrides (identity materialization), map each spec to `%Entry{}` (`spec.hidden ⇒ visible: false, callable: true, reason: :hidden_by_spec`), compute `catalog_version` (§4.7). Skip nothing here — visibility filtering for the wire happens in `protocol_list`.
- `resolve/4` — find entry by canonical name (exact binary match; dotted-name canonicalization is host domain, not lib — NPL's `ToolNames` stays host-side). Absent OR `callable: false` ⇒ `{:error, Error.invalid_params("Unknown tool: " <> name)}` (identical message for both). Callable ⇒ `{:ok, %Effective{name, entry, spec, provenance: nil, version: catalog_version, reason: nil}}`.
- `invoke/5` — **relocated `run_spec`** (body today at `lib/noizu/mcp/server/features/tools.ex:190-212`): `Schema.validate(effective.entry.input_schema, args)` → on success `Fields.cast(effective.entry.cast_plan, args)` → arity-dispatch `apply(spec.module, spec.fun, call_args)` → `Features.Tools.normalize(result, spec.output_schema)`. Validation failure returns `ToolResult.error("Invalid arguments for tool #{effective.name}: #{message}")` (SEP-1303 comment preserved).
- `permissions/3` — `{:ok, %{tools: [%{name: e.definition.name, visible: e.visible, callable: e.callable} | ...], version: v}}`.
- `metadata/3` — servers: `%{slug: opts[:name], title: nil, description: __mcp__(:opts)[:instructions], version: opts[:version]}` (from `__mcp__(:opts)`, `lib/noizu/mcp/server.ex:406`). Struct default: raise until overridden (PRD-3 fills this for `%CustomToolset{}`).

### 4.5 Override vocabulary — `lib/noizu/mcp/toolset/override.ex`

```elixir
defmodule Noizu.MCP.Toolset.Override do
  @enforce_keys [:op]
  defstruct [
    :op,        # see closed vocabulary below
    :target,    # String.t() tool name | atom() field name (for field ops)
    :value,     # op payload (see table)
    weight: 100,# integer — merge weight (defaults in PRD-3: static=100, persisted=200, acl=300)
    layer: nil, # term() — layer id for provenance
    inherit?: false
  ]
  @type op :: :set_name | :set_description | :set_title | :set_arg_description
            | :prune_enum | :hide_field | :rename_field | :pin_default
            | :set_visible | :set_callable | :set_input_schema
end
```

**Field-op encoding (normative):** for `:set_arg_description`, `:prune_enum`, `:hide_field`, `:rename_field`, `:pin_default` — `target` is the FIELD name (atom); payload in `value`:

| op | target | value |
|----|--------|-------|
| `:set_name` | tool name | new wire name `String.t()` |
| `:set_description` | tool name | `String.t()` |
| `:set_title` | tool name | `String.t() \| nil` |
| `:set_arg_description` | field atom | `String.t()` |
| `:prune_enum` | field atom | list of enum values to REMOVE |
| `:hide_field` | field atom | ignored (use `true`) |
| `:rename_field` | field atom (original) | `String.t()` new wire name |
| `:pin_default` | field atom | default value (must be JSON-serializable) |
| `:set_visible` | tool name | boolean |
| `:set_callable` | tool name | boolean |
| `:set_input_schema` | tool name | raw schema map — **rejected unless the tool is raw-schema** (DSL tools with `input_fields` reject field-level ops AND this op on raw-schema tools rejects field-level ops; the matrix: `:set_input_schema` allowed only when `spec.definition.input_fields == nil`; field-level ops allowed only when `spec.definition.input_fields != nil`) |

### 4.6 `lib/noizu/mcp/toolset/overrides.ex` — pure applier

```elixir
defmodule Noizu.MCP.Toolset.Overrides do
  @doc """
  Materialize ops onto a spec. Pure: never touches DB/ETS/env.
  Returns {:ok, %Spec{}} with a FRESH %Types.Tool{} (never mutates the input spec —
  Types.Tool is shared compile-time data) plus effective input_schema and cast_plan,
  | {:error, [%Validator.Issue{}]} for structural problems.
  """
  def apply(%Noizu.MCP.Server.Tool.Spec{} = spec, [%Override{}] = ops, opts \\ []) 
end
```

- Structural issues (returned, not raised): unknown op, unknown tool target (PRD-3's Validator catches cross-tool issues; the applier only sees one spec — a mismatched tool-level target is an issue here), unknown field target, field-level op on raw-schema tool, `:set_input_schema` on DSL tool, rename collision with an existing field, `prune_enum` on a non-enum field.
- `Issue` struct lives in `lib/noizu/mcp/toolset/validator.ex` (defined in this PR; the cross-tool `Validator.compile/3` arrives in PRD-3):

```elixir
defmodule Noizu.MCP.Toolset.Validator.Issue do
  defstruct [:code, :message, :op, :tool, :field, :meta]   # code: atom()
end
```

### 4.7 `catalog_version` (static path, normative)

`version = :crypto.hash(:sha256, :erlang.term_to_binary({Enum.map(specs, &{&1.definition.name, &1.definition.input_schema, materialized}), Application.spec(:noizu_mcp, :vsn)})) |> Base.encode16(case: :lower) |> binary_part(0, 16)`

Stable across processes with identical spec sets; changes when tools change OR the lib version changes. Provider-backed versions arrive in PRD-4.

### 4.8 `wire_key` in `Fields.cast/2`

`lib/noizu/mcp/server/tool/fields.ex` — `Field` defstruct (`:23`: `[:name, :type, :opts, children]`) gains NO new struct field; the wire key is `opts[:wire_key]` (default: field name). `cast/2` (`:427`) changes its input-key resolution: look up incoming args under `opts[:wire_key] || name`, but emit the coerced value under `field.name` (original atom). Net effect: `:rename_field` is wire-only — handlers always receive original-keyed args. The applier (`§4.6`) writes `wire_key` into the cast plan and rewrites the JSON-schema property name in `input_schema` together.

### 4.9 Server integration seams

- `lib/noizu/mcp/server.ex` `__before_compile__/1` (`:241`): the generated defaults at `:276-290` become:

```elixir
unless defines?.({:handle_list_tools, 2}) or tools == [] do
  quote do
    @impl Noizu.MCP.Server
    def handle_list_tools(cursor, ctx) do
      Noizu.MCP.Server.Features.Tools.protocol_list(__MODULE__, cursor, ctx)
    end
  end
end,
unless defines?.({:handle_call_tool, 3}) or tools == [] do
  quote do
    @impl Noizu.MCP.Server
    def handle_call_tool(name, args, ctx) do
      Noizu.MCP.Server.Features.Tools.protocol_call(__MODULE__, name, args, ctx)
    end
  end
end
```

- `__before_compile__` additionally injects `use Noizu.MCP.Toolset.Behaviour` expansions: `__toolset_specs__/2` (`Features.Tools.expand(__mcp__(:tools))`), `catalog/3`, `resolve/4`, `invoke/5`, `permissions/3`, `metadata/3`, each `defoverridable` so hosts may override at the toolset layer too.
- `lib/noizu/mcp/server/features/tools.ex`:
  - NEW `protocol_list(toolset, cursor, ctx)` — `Toolset.coerce(toolset)` → `Toolset.catalog/3` → filter `entry.visible` → `Pagination.paginate(Enum.map(entries, & &1.definition), cursor, page_size)` → same `{:ok, %{tools: [...], nextCursor}}` wire shape as today.
  - NEW `protocol_call(toolset, name, args, ctx)` — coerce → `Toolset.resolve/4` → on `{:ok, eff}` → `Toolset.invoke/5` → normalize exactly like `call/3` (`:167-179`) does today (`{:error, %Error{}}` passthrough; `%ToolResult{}` → `to_map/1`).
  - `list_registered/3` (`:151`) and `dispatch/4` (`:183`) are REIMPLEMENTED as thin shims: expand the given `registered` list, wrap in the new internal `%Toolset.Static{specs: specs}` (below), and delegate to the behaviour defaults. Signatures and return shapes UNCHANGED — existing callers (including NPL's vendored copies via `alias Noizu.MCP.Server.Features.Tools`) keep compiling.
  - `run_spec` (`:190-212`, currently `defp`) — body moves to `Toolset.Behaviour.invoke/5`; `dispatch/4`'s shim calls it through the protocol. The private copy in NPL's `dispatch.ex` is deleted in PRD-5, not here.
- New internal struct `lib/noizu/mcp/toolset/static.ex`:

```elixir
defmodule Noizu.MCP.Toolset.Static do
  @derive Noizu.MCP.Toolset
  defstruct [:specs, :opts]    # %Spec{} list; used by shims and tests
  # `use Noizu.MCP.Toolset.Behaviour` with __toolset_specs__ returning the held specs
end
```

### 4.10 Catalog tool protocol mode — `lib/noizu/mcp/server/tools/catalog.ex`

`call/2` (`:85`) gains `"mode" => "protocol"` on the `tools` section: enumerate via `Toolset.catalog(ctx.server |> Toolset.coerce(), ctx, [])`, rendering each entry as `%{"name", "title", "description" (resolved via RenderCtx), "visible", "callable", "reason"}`. Entries with `callable: false` are omitted; `visible: false` but callable entries are INCLUDED when `include_hidden` is true (default true — `:74-80` today) and labeled. The legacy mode (raw `__mcp__(:tools)` expansion) is retained as `"mode" => "static"` (the default) for this PRD so behavior change is opt-in; PRD-3 flips the default to protocol.

---

## 5. Requirements

**FR-1.1** `Noizu.MCP.Toolset` protocol exists with `catalog/3, resolve/4, invoke/5, permissions/3, metadata/3, coerce/1` and the §4.1 return contracts.
**FR-1.2** `coerce/1` implements the §4.1 table (Atom wrap, Ref identity, derived identity, else ArgumentError).
**FR-1.3** `%Entry{}`, `%Effective{}`, `%Ref{}`, `%Static{}` structs exist with exactly the §4 fields.
**FR-1.4** `Toolset.Behaviour` defaults implement §4.4 semantics; servers get them generated by `use Noizu.MCP.Server` with `defoverridable`; host `handle_*` overrides continue to win (existing `defines?` guard, `lib/noizu/mcp/server.ex:258,276,284`).
**FR-1.5** `resolve/4` on the default impl returns identical invalid_params errors for absent and non-callable tools (message equality asserted in tests).
**FR-1.6** `invoke/5` validates against the EFFECTIVE schema and casts with the EFFECTIVE plan (test: a rename override changes the accepted wire key and the handler still sees the original key).
**FR-1.7** `%Toolset.Override{}` supports exactly the §4.5 closed vocabulary; any other op is a structural issue, not a crash.
**FR-1.8** `Overrides.apply/3` is pure (same input → same output; input spec bit-identical after call) and materializes fresh `%Types.Tool{}`/schema/plan triples.
**FR-1.9** `Fields.cast/2` honors `opts[:wire_key]` for input lookup and always emits original atom keys (fields.ex `:427`).
**FR-1.10** Generated `handle_list_tools`/`handle_call_tool` route through `protocol_list`/`protocol_call` via `Toolset.coerce(__MODULE__)` (server.ex `:276-290` replacement).
**FR-1.11** `list_registered/3` + `dispatch/4` keep their signatures and return shapes (shims over `Static`).
**FR-1.12** Catalog tool accepts `"mode" => "protocol"` per §4.10; default remains `"static"`.
**FR-1.13** `catalog_version` per §4.7: identical spec sets ⇒ identical version strings across processes and runs; any definition/schema change ⇒ different.
**FR-1.14** Description-verbosity composition survives materialization: `%Types.Tool{}` with `%Description.t{}` titles/descriptions still render through `to_map/2` variants after an override pass that does not touch them (types/tool.ex `:9-16` contract).
**FR-1.15** Telemetry: emit `[:noizu_mcp, :toolset, :catalog]` and `[:noizu_mcp, :toolset, :resolve]` (measurements: `%{duration}`, metadata: `%{toolset: slug_or_module}`) — event name basis for D5 telemetry in PRD-3/4; failures additionally logged at `:warning` via Logger.

**Acceptance criteria**

**AC-1.1** A bare `use Noizu.MCP.Server` fixture lists and calls tools through the protocol path with byte-identical `tools/list` and `tools/call` wire output vs. pre-PRD snapshots (existing `test/noizu/mcp/server_integration_test.exs`, `conformance_test.exs` stay green unmodified).
**AC-1.2** A struct fixture deriving the protocol via `use Toolset.Behaviour` is catalogable/resolvable/invokable identically to a server module.
**AC-1.3** Hidden tool (`hidden: true` spec): absent from `handle_list_tools` output, present in catalog entries as `visible:false, callable:true`, and resolvable+invokable through `Toolset.resolve/invoke` directly.
**AC-1.4** Non-callable and absent tools return structurally identical `invalid_params` errors (same message string).
**AC-1.5** Full override vocabulary unit-tested per op (§8.2) including the raw-schema/DSL field-op rejection matrix.
**AC-1.6** Rename-field end-to-end: wire accepts the new key only, rejects the old key per effective schema, handler receives original key.
**AC-1.7** `mix test` fully green; no deprecation warnings introduced.

---

## 6. Internal work checklist (with anchors)

| Step | File | Anchor / detail |
|------|------|-----------------|
| 6.1 | `lib/noizu/mcp/toolset.ex` | protocol + Entry/Effective structs + Atom impl (§4.1-4.3) |
| 6.2 | `lib/noizu/mcp/toolset/ref.ex` | Ref struct + impl (§4.2) |
| 6.3 | `lib/noizu/mcp/toolset/behaviour.ex` | `__using__` + defaults (§4.4) |
| 6.4 | `lib/noizu/mcp/toolset/override.ex`, `overrides.ex` | vocabulary + applier (§4.5-4.6) |
| 6.5 | `lib/noizu/mcp/toolset/validator.ex` | `Issue` struct only in this PR (§4.6) |
| 6.6 | `lib/noizu/mcp/toolset/static.ex` | Static struct (§4.9) |
| 6.7 | `lib/noizu/mcp/server/tool/fields.ex` | `cast/2` wire_key (`:427`), doc note on Field (`:18-24`) |
| 6.8 | `lib/noizu/mcp/server/features/tools.ex` | `protocol_list/3`, `protocol_call/4` new; `list_registered/3` (`:151`) + `dispatch/4` (`:183`) → shims; delete `run_spec` `defp` (`:190-212`) after relocation |
| 6.9 | `lib/noizu/mcp/server.ex` | `__before_compile__` generated defaults (`:276-290`) + inject behaviour functions; keep `defines?` guards |
| 6.10 | `lib/noizu/mcp/server/tools/catalog.ex` | protocol mode in `call/2` (`:85`) |
| 6.11 | `lib/noizu/mcp/error.ex` | no change required in PRD-1 (`forbidden` arrives in PRD-2) |

---

## 7. Test plan

New test files (lib repo, `test/noizu/mcp/toolset/`):

- **`toolset_protocol_test.exs`** — coerce table (§4.1) incl. ArgumentError for non-participants; Atom impl wraps; Ref delegates; protocol-raises for non-participant semantic calls.
- **`behaviour_defaults_test.exs`** — catalog/resolve/invoke/permissions/metadata defaults over `FixtureServer` (`test/support/fixture_server.ex`); version stability/change (FR-1.13); hidden entry state (AC-1.3); absent-vs-non-callable message equality (FR-1.5).
- **`overrides_test.exs`** — every op in the §4.5 table; structural issue codes; purity assertion (input spec unchanged — compare before/after maps); `:set_input_schema` vs field-op matrix; rename+`pin_default`+`prune_enum` composition on one tool; description-variant survival (FR-1.14).
- **`wire_key_cast_test.exs`** — extends `test/noizu/mcp/server/tool_test.exs` coverage: `cast/2` with `opts[:wire_key]` (original-key out, wire-key in, wire-key missing ⇒ missing-field semantics identical to today's name-missing path).
- **`server_protocol_integration_test.exs`** — fixture server through `protocol_list`/`protocol_call`; existing wire snapshots byte-identical (AC-1.1); host-override precedence preserved (fixture declaring `handle_call_tool` before `use` still wins — mirrors NPL's pattern at monorepo `.../noizu_prompt_lingua/mcp/server.ex:22-30`).
- **`catalog_protocol_mode_test.exs`** — `"mode" => "protocol"` section content vs static mode; `include_hidden` interplay.

**Anti-pattern regression tests (§8.4)** — these MUST exist in PRD-1 and stay green for the whole series:

- **AP-1 (registry brittleness):** assert NO runtime module scans — the protocol path never calls `Code.ensure_loaded?`/`function_exported?` on user modules for toolset discovery; a `Ref` to a module lacking behaviour functions surfaces as a disabled toolset (`{:error, %Error{}}` at catalog) with the server's OTHER tools unaffected (D5), not a crash of `handle_list_tools`.
- **AP-2 (compile-time monolith):** catalog/resolve consult ONLY call-time inputs; a test mutates fixture specs between two catalog calls (rebuild fixture) and asserts the second call reflects the change (no cached-at-compile surface).
- **AP-3 (forgeable context):** `Toolset.resolve/4` with a hand-built `%Ctx{}` cannot reach tools the static surface hides (non-callable ⇒ invalid_params) — asserts there is no "system/trusted" ctx escape hatch at this layer (PRD-2 hardens with Principal).

---

## 8. Compat & rollback

- **Additive-only.** Existing public functions keep signatures: `list_registered/3`, `dispatch/4`, `call/3`, all `handle_*` callbacks, `__mcp__/1` (`lib/noizu/mcp/server.ex:400-408`).
- Consumers on hex `0.1.5`/`0.2.0` are untouched (nothing published during PRD-1..4). NPL compiling against `main` via `path:` (decision 1) keeps compiling: its host-defined `handle_call_tool`/`handle_list_tools` win the `defines?` guard race exactly as today.
- **Rollback**: revert the single PR; no data/format migrations exist at this point. No version bump to roll back.
- Risk watch: `Pagination.paginate` input shape change (definitions vs entries) — `protocol_list` must map back to definitions BEFORE paginating so `nextCursor` semantics are unchanged.

---

## 9. Open questions

1. **Q1 (confirm with team-lead):** Catalog protocol-mode default — PRD-1 ships `"mode" => "protocol"` opt-in and PRD-3 flips the default once CustomToolset lands. Confirm the flip point (PRD-3 vs PRD-4).
2. **Q2:** Should `permissions/3` include `reason` per tool (richer, leaks ACL reasons to tool-level consumers) — current spec: name/visible/callable only. Lead's call.
3. **Q3:** `catalog_version` hash input includes materialized definitions (post-override) — for static toolsets with no overrides this equals the spec hash; confirm provider-backed versioning (PRD-4) may be fully independent strings (yes per architecture; noting for the implementer).
4. **Q4:** `resolve/4` dotted-name canonicalization (NPL's `ToolNames.canonical/1` semantics) — stays host-side in the series; revisit post-0.3.0 if a second host needs it.
