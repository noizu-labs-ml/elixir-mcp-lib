# PRD-9: elixir-mcp `sql/*` Feature & Dataset DSL

**Series**: pg_mcp — MCP servers as Postgres structures (PRD-9 of 6)
**Repo**: `Portfolio/Libs/ai/elixir-mcp` (Elixir library). All anchors relative to the lib root.
**Version policy**: no bump here. The single `0.4.0` bump moved to **PRD-11**, which is the last PRD touching library code — `sql/*` and the Dataset behaviour ship in the same release as the Engine that is their first consumer. `mix.exs:4` stays `@version "0.3.0"` through this PR.
**Depends on**: PRD-6 only (its spike gates the series). Sequenced **before** PRD-11, which is `sql/*`'s first consumer — the Engine's upstream registry is a `Dataset` defined here — and before the Rust PRDs, which consume `mode 'sql'`.
**Date**: 2026-09-05 · **Author**: npl-prd-editor (Loom weave)
**Status**: Draft

---

## 1. Goal

Let an MCP server describe relations it *wants* projected into SQL — not merely the tables the FDW can infer from tools, prompts and resources — and let the FDW consume that description when the server offers it.

Deliverables:

1. An experimental method family `sql/schema`, `sql/scan`, `sql/modify`, served by a new `Noizu.MCP.Server.Features.SQL`.
2. A `Noizu.MCP.Server.Dataset` behaviour and a `dataset/2` registration macro beside `tool/2`.
3. Support modules `Noizu.MCP.SQL.Schema`, `.Types`, `.Quals`.
4. Capability advertisement `%{"experimental" => %{"sql" => %{"version" => 1}}}`.
5. A derived default schema: when a server registers no datasets, `sql/schema` still answers, describing the tools/prompts/resources surface from the existing protocols so `mode 'sql'` is never worse than `mode 'generic'`.
6. FDW consumption: `mode 'sql'` and `auto` probing.
7. Conformance tests, docs, CHANGELOG, and the `0.4.0` bump.

**Explicitly OUT of scope**: the Rust side of `mode 'sql'` table creation beyond the probe (specified here in §4.6, implemented in this PRD's Rust companion commit); packaging, CI and the e2e harness (PRD-10).

---

## 2. Decision log applied to this PRD

| ADR / rule | How it binds this PRD |
|---|---|
| **ADR-007** engine federation | The Dataset behaviour defined here is what makes PRD-11's upstream registry expressible: attaching an MCP server is `sql/modify` on a dataset named `servers`, not a bespoke registry protocol. This PRD is therefore sequenced immediately before the Engine, and the two ship in one release. |
| **ADR-005** `sql/*` experimental + FDW mode | The methods live under `experimental.sql` in capabilities, version-tagged, and carry no stability promise before MCP standardizes anything comparable. A server that does not implement them is fully served by `mode 'generic'`. |
| **ADR-003** SQL projection model | The Dataset DSL describes *relations*; it does not describe tools. Tool projection stays PRD-8's job, derived from `inputSchema`/`outputSchema`. A dataset is for data a server holds that is not naturally a tool call. |
| **ADR-004** identity | `sql/scan` and `sql/modify` receive the same `%Noizu.MCP.Ctx{}` every other method does, carrying the request's `%Principal{}` (`lib/noizu/mcp/auth/principal.ex:24`). A dataset filters by principal exactly as a tool does. Nothing in this PRD introduces a second auth path. |
| **D1 one resolver** | `sql/schema`'s tool section derives from `Noizu.MCP.Toolset.catalog/3` (`lib/noizu/mcp/toolset.ex:41`) — the series-1 protocol — never from a parallel registry. Prompts and resources derive from `Features.Prompts` and `Features.Resources`. Datasets are the *only* new source, and they are explicitly registered. |
| **D2 effective materialization** | The tool section describes *effective* tools for the requesting principal, post-override, exactly as `tools/list` does. |
| **D3 runtime-only resolution** | `dataset/2` registers a module reference at compile time; every column list and every scan is resolved at call time. |
| **D4 explicit participation** | No `Any` implementations, no `function_exported?` probing for dataset discovery. A dataset participates by being registered with `dataset/2` and implementing the behaviour. Optional callbacks are declared `@optional_callbacks` and checked with `defines?`-style compile-time guards, not runtime probes. |
| **D5 fail-closed per set, fail-open per server** | A dataset that raises during `scan/3` yields `{:error, %Error{}}` for that relation; `sql/schema` and every other dataset keep working. A dataset whose `columns/0` is malformed is rejected at compile time by `use Noizu.MCP.Server.Dataset`. |

---

## 3. Background

PRD-7's `mode 'generic'` gives a fixed set of nine tables derived from methods every MCP server has. PRD-8 adds per-tool objects derived from schemas every tool has. Both are inferences the *client* makes about the server.

Some servers hold relations that neither inference reaches. NoizuPromptLingo holds prompt versions, sessions, artifacts, and chat rooms; the VFS backends (`lib/noizu/mcp/server/vfs.ex`, routed at `lib/noizu/mcp/transport/vfs_ws.ex:274` and `lib/noizu/mcp/transport/vfs_socket.ex:262`) hold directory trees. Projecting those through `tools/call` works but is a poor fit: there is no pushdown, no column list, no cursor, and the shape is whatever the tool author chose.

The library already has the precedent for adding a method family outside the core spec. The `vfs/*` operations are dispatched by their own routing table in the WebSocket and socket transports, with capability flags derived at `lib/noizu/mcp/server/vfs.ex:34`. `sql/*` follows the same pattern, but goes through the ordinary session dispatch so it works over every transport including Streamable HTTP, which is the one the FDW uses.

`Session.dispatch/4` already has the exact seam needed: each method is a `defp dispatch(state, "<method>", id, params)` clause delegating to `dispatch_feature/6` (`lib/noizu/mcp/server/session.ex:525`), which checks `function_exported?(state.server, callback, arity)` and answers `method_not_found` when the server does not implement the callback. That means an `sql/*` clause added beside `completion/complete` (`session.ex:515`) is automatically absent from servers that do not opt in — fail-closed by construction, no extra guard needed.

---

## 4. Public surface

### 4.1 `lib/noizu/mcp/server/dataset.ex` — behaviour

```elixir
defmodule Noizu.MCP.Server.Dataset do
  @moduledoc "A relation a server projects into SQL via the `sql/*` methods."

  @type column :: %{
          name: String.t(),
          type: Noizu.MCP.SQL.Types.t(),
          nullable: boolean(),
          description: String.t() | nil
        }

  @type qual :: %{
          column: String.t(),
          op: :eq | :ne | :lt | :lte | :gt | :gte | :in | :not_in | :like | :is_null | :is_not_null,
          value: term()
        }

  @type scan_opts :: %{
          optional(:quals) => [qual()],
          optional(:columns) => [String.t()],
          optional(:sort) => [{String.t(), :asc | :desc}],
          optional(:limit) => pos_integer(),
          optional(:cursor) => String.t()
        }

  @type row :: %{String.t() => term()}

  @doc "Static column list. Called at schema time; must be pure and cheap."
  @callback columns() :: [column()]

  @doc "Descriptive metadata: name, title, description, primary_key, writable?."
  @callback info() :: %{
              name: String.t(),
              title: String.t() | nil,
              description: String.t() | nil,
              primary_key: [String.t()],
              writable: boolean()
            }

  @doc """
  Scan the relation. `opts` carries quals/columns/sort/limit/cursor; a dataset
  MAY ignore any of them — the caller re-checks every qual — but MUST NOT return
  rows excluded by a qual it claims to have applied.
  """
  @callback scan(args :: map(), ctx :: Noizu.MCP.Ctx.t(), opts :: scan_opts()) ::
              {:ok, [row()], cursor :: String.t() | nil} | {:error, Noizu.MCP.Error.t()}

  @callback insert(rows :: [row()], ctx :: Noizu.MCP.Ctx.t()) ::
              {:ok, [row()]} | {:error, Noizu.MCP.Error.t()}

  @callback update(quals :: [qual()], changes :: row(), ctx :: Noizu.MCP.Ctx.t()) ::
              {:ok, [row()]} | {:error, Noizu.MCP.Error.t()}

  @callback delete(quals :: [qual()], ctx :: Noizu.MCP.Ctx.t()) ::
              {:ok, non_neg_integer()} | {:error, Noizu.MCP.Error.t()}

  @optional_callbacks insert: 2, update: 3, delete: 2

  defmacro __using__(opts) do
    # injects @behaviour, a __mcp_dataset__/1 introspection function, and a
    # compile-time validation of columns/0 against Noizu.MCP.SQL.Types.
  end
end
```

**Qual contract, normative.** The FDW re-checks every qual locally. A dataset therefore need not implement any of them, and the honest minimum implementation ignores `opts` entirely and returns every row. The one thing a dataset must never do is *drop* rows a qual it did not apply would have kept, or return rows a qual it did apply would have excluded. `scan/3` returns the quals it actually applied? — no: it does not, deliberately. Postgres re-checks unconditionally, which makes the contract one-directional and removes a whole class of correctness bug.

### 4.2 `dataset/2` registration macro — `lib/noizu/mcp/server.ex`

Added beside `tool/2` (`lib/noizu/mcp/server.ex:219`) in the registration-macro block that runs through `prompt/2` (`:245`):

```elixir
@doc "Register a dataset module (see `Noizu.MCP.Server.Dataset`)."
defmacro dataset(module, opts \\ []) do
  quote do
    @__mcp_datasets__ {unquote(module), unquote(opts)}
  end
end
```

`opts`: `:name` (overrides `info().name`), `:hidden` (excluded from `sql/schema`, still scannable by exact name — mirroring the tool `hidden` semantics). Accumulated into `__mcp__(:datasets)` alongside `:tools`, `:resources`, `:prompts`, `:vfs`.

### 4.3 `lib/noizu/mcp/sql/types.ex`

A closed vocabulary, chosen to be exactly what the PRD-8 map can express so the two never disagree:

```elixir
@type t ::
        :text | :bigint | :double | :boolean
        | :timestamptz | :date | :uuid
        | :jsonb
        | {:enum, [String.t()]}
```

`Noizu.MCP.SQL.Types.to_sql/1` renders each to its PostgreSQL name; `from_field_type/2` maps the tool field DSL's types (`lib/noizu/mcp/server/tool/fields.ex:16` scalars, `:133` arrays, `:150-163` enum/object/array) onto this vocabulary, so a dataset column and a generated tool column of the same logical type always get the same PG type. This is the single point of agreement between the Elixir and Rust sides; PRD-8 §4.1 is its mirror and the two are asserted equal by a shared fixture table in §7.5.

### 4.4 `lib/noizu/mcp/sql/schema.ex` and `.quals.ex`

`Schema.build(server, ctx, opts)` produces the `sql/schema` payload:

```json
{
  "version": 1,
  "relations": [
    {"name": "tools", "kind": "catalog", "columns": [...], "primary_key": ["name"],
     "writable": false, "qual_columns": ["name"], "sort": false, "limit": true},
    {"name": "prompt_messages", "kind": "prompt", "columns": [...], "primary_key": ["prompt","idx"],
     "writable": false, "qual_columns": ["prompt","arguments"], "required_quals": ["prompt"]},
    {"name": "resource_contents", "kind": "resource", "columns": [...], "primary_key": ["uri","idx"],
     "writable": false, "qual_columns": ["uri"], "required_quals": []},
    {"name": "tool_search_docs", "kind": "tool", "columns": [...], "tool": "search_docs",
     "writable": true, "read_only": true, "qual_columns": ["query","limit"]},
    {"name": "prompt_versions", "kind": "dataset", "columns": [...], "primary_key": ["id"],
     "writable": true, "qual_columns": ["id","slug"], "sort": true, "limit": true}
  ]
}
```

Per ADR-005 each relation declares its **invoke kind** — `catalog`, `dataset`, `tool`, `resource` or `prompt` — plus which columns accept pushed quals, which quals are required, and whether sort and limit are honored. That is what lets `mode 'sql'` build tables without inferring anything: `qual_columns` becomes the pushdown set, `required_quals` becomes the read-through requirement PRD-7 §4.4–4.6 hardcodes in generic mode, and `kind: "tool"` plus `read_only` drives PRD-8 §4.2's SELECT-invocation gate directly from the server's declaration rather than from an annotation the client re-reads.

- `kind: "catalog"` relations are derived: tools from `Noizu.MCP.Toolset.catalog/3` (`lib/noizu/mcp/toolset.ex:41`), prompts from `Features.Prompts.list_registered/3` (`lib/noizu/mcp/server/features/prompts.ex:50`), resources from `Features.Resources.list_registered/5` (`lib/noizu/mcp/server/features/resources.ex:74`) and `list_registered_templates/3` (`:118`). Their column lists match PRD-7 §4.2–§4.4 exactly, so a `mode 'sql'` client and a `mode 'generic'` client see the same catalog tables.
- `kind: "dataset"` relations come from `__mcp__(:datasets)`.
- A dataset name colliding with a catalog name is a compile-time error from `use Noizu.MCP.Server`.

**ACL subject (ADR-005).** A `sql/scan` over a tool-derived relation is authorized exactly as `tools/call` on that tool — same subject, same provider, same verdict, so there is no way to read through SQL what one may not call. A **dataset** takes an ACL subject of its own, `{:dataset, name}`, because a dataset is not a tool and has no tool to borrow a verdict from. A provider that does not recognize the dataset subject falls to the provider's own default, which for a configured provider is deny (series-1 PRD-2).

`Quals.decode/2` parses the wire qual list into `[Dataset.qual()]`, rejecting unknown operators with `invalid_params`. `Quals.apply/2` is a pure local re-filter used by the conformance suite to prove a dataset's own filtering agrees with a reference implementation.

### 4.5 Methods and dispatch

| Method | Params | Result |
|---|---|---|
| `sql/schema` | `{}` | `Schema.build/3` payload (§4.4) |
| `sql/scan` | `{"relation": string, "quals": [...], "columns": [...], "sort": [...], "limit": int, "cursor": string}` | `{"columns": [...], "rows": [[...]], "nextCursor": string \| null}` |
| `sql/modify` | `{"relation": string, "op": "insert"\|"update"\|"delete", "rows": [...], "quals": [...], "changes": {...}}` | `{"rows": [...]}` for insert/update, `{"count": int}` for delete |

A `Dataset.scan/3` callback returns **map rows** (`%{String.t() => term()}`, §4.1), because that is what is pleasant to write by hand. `Features.SQL.scan/3` converts them to positional arrays in `columns` order before they reach the wire, filling `nil` for any column a dataset omitted. Datasets never build positional rows themselves.

On the wire, rows are **positional** against the returned `columns` array, not objects — one array per row. For a 10-column, 1000-row scan that removes roughly 60% of the JSON payload, which matters because this is the hot path of every FDW scan.

Dispatch clauses go into `lib/noizu/mcp/server/session.ex` immediately after the `completion/complete` clause (`session.ex:515`), using the existing `dispatch_feature/6` seam (`session.ex:525`):

```elixir
defp dispatch(state, "sql/schema", id, params) do
  dispatch_feature(state, "sql/schema", id, params, {:handle_sql_schema, 2}, run: &Features.SQL.schema/3)
end

defp dispatch(state, "sql/scan", id, params) do
  dispatch_feature(state, "sql/scan", id, params, {:handle_sql_scan, 3}, run: &Features.SQL.scan/3)
end

defp dispatch(state, "sql/modify", id, params) do
  dispatch_feature(state, "sql/modify", id, params, {:handle_sql_modify, 3}, run: &Features.SQL.modify/3)
end
```

Because `dispatch_feature/6` answers `method_not_found` when the callback is not exported (`session.ex:526-531`), a server that registers no datasets and does not opt in gets `-32601` for all three — which PRD-7 §4.9 already maps to "table scans as empty" for list methods and to a clean `mode 'auto'` fallback in §4.6.

Optional server callbacks `handle_sql_schema/2`, `handle_sql_scan/3`, `handle_sql_modify/3` are generated by `use Noizu.MCP.Server` **only when the server registers at least one dataset or passes `sql: true`**, and are `defoverridable` so a host can replace them wholesale — the same precedent as `handle_call_tool`.

### 4.6 Capability and FDW mode

`build_capabilities/2` (`lib/noizu/mcp/server.ex:756`) folds in:

```elixir
|> then(fn caps ->
  if flags.sql?, do: put_in_experimental(caps, "sql", %{"version" => 1}), else: caps
end)
```

producing `%{"experimental" => %{"sql" => %{"version" => 1}}}` merged with any existing `experimental` map rather than replacing it.

FDW consumption (Rust companion commit, `pg/pg_mcp/src/mode.rs`):

| `mode` | Behavior |
|---|---|
| `generic` | Never calls `sql/*`. PRD-7/PRD-8 tables only. |
| `sql` | Requires `experimental.sql` in the `initialize` result; its absence raises `0A000` at first use. Foreign tables are created from `sql/schema`; scans call `sql/scan`; writes call `sql/modify`. |
| `auto` (default) | Reads `experimental.sql` from the cached `initialize` result — **no extra round trip**. Present and `version == 1` → behaves as `sql`. Absent → behaves as `generic`. The resolved mode is visible in `mcp.server.mode` (PRD-7 §4.1). |

`sql` mode does not remove `tool_calls` or the per-tool objects: tool invocation stays `tools/call` in every mode. `sql/*` projects *relations*, and `tools` is one of them, so in `sql` mode the `tools` table is served by `sql/scan` instead of `tools/list` — with identical columns, which §7.5 asserts.

---

## 5. Requirements

**FR-9.1** `Noizu.MCP.Server.Dataset` exists with the §4.1 callbacks; `insert/2`, `update/3`, `delete/2` are optional.
**FR-9.2** `use Noizu.MCP.Server.Dataset` validates `columns/0` against `SQL.Types` at compile time and injects `__mcp_dataset__/1`.
**FR-9.3** `dataset/2` registers into `__mcp__(:datasets)` with `:name` and `:hidden` options.
**FR-9.4** `SQL.Types` implements exactly the §4.3 vocabulary, with `to_sql/1` and `from_field_type/2`.
**FR-9.5** `SQL.Schema.build/3` produces the §4.4 payload; catalog relations derive from the Toolset protocol, `Features.Prompts` and `Features.Resources` — no parallel registry (D1).
**FR-9.17** Every relation declares `kind` ∈ `catalog | dataset | tool | resource | prompt`, `qual_columns`, `required_quals`, `sort` and `limit`; `kind: "tool"` relations additionally declare `tool` and `read_only`.
**FR-9.18** `sql/scan` over a tool-derived relation is authorized identically to `tools/call` on that tool; a dataset is authorized under its own `{:dataset, name}` subject.
**FR-9.6** A dataset name colliding with a catalog relation name is a compile-time error.
**FR-9.7** `SQL.Quals.decode/2` rejects unknown operators with `invalid_params`; `apply/2` is pure.
**FR-9.8** `sql/schema`, `sql/scan`, `sql/modify` dispatch through `dispatch_feature/6` and answer `-32601` on servers that did not opt in.
**FR-9.9** `sql/scan` returns positional rows against a `columns` array, with `nextCursor` honoring `limit`.
**FR-9.10** `sql/modify` maps `insert`/`update`/`delete` to the optional callbacks; an op whose callback is not implemented returns `-32601` naming the relation and op.
**FR-9.11** Capabilities carry `%{"experimental" => %{"sql" => %{"version" => 1}}}` when and only when the server opted in, merged non-destructively into an existing `experimental` map.
**FR-9.12** Every `sql/*` handler receives the request's `%Ctx{}` with its `%Principal{}`; a dataset may filter on it (ADR-004).
**FR-9.13** A dataset raising in `scan/3` yields `{:error, %Error{reason: :internal_error}}` for that relation only; `sql/schema` and other relations keep working (D5).
**FR-9.14** FDW `mode 'auto'` resolves from the cached `initialize` capabilities with no extra round trip; `mode 'sql'` against a non-SQL server raises `0A000`.
**FR-9.15** `mix.exs` `@version` is unchanged at `"0.3.0"`; the CHANGELOG's unreleased section gains the `sql/*` and Dataset entries, folded into the `0.4.0` section by PRD-11.
**FR-9.16** Docs: `guides/postgres.md` (operator-facing: install, `CREATE SERVER`, `IMPORT`, per-tool generation, datasets), `docs/arch/sql.md` (protocol-facing: the three methods, wire shapes, versioning), README section, CHANGELOG.

**Acceptance criteria**

**AC-9.12** A principal denied a tool by ACL gets the same denial scanning that tool's `sql/schema` relation as calling it — asserted for both paths against one provider.
**AC-9.13** `sql/schema`'s `required_quals` for `prompt_messages` and `completions` match the qual requirements PRD-7 §4.5–4.6 hardcodes in generic mode, so a `sql`-mode and a `generic`-mode client enforce the same thing.
**AC-9.1** A fixture server registering one dataset answers `sql/schema` with that dataset plus the three catalog relations, and its `tools` relation columns are byte-identical to PRD-7 §4.2's column list.
**AC-9.2** A fixture server registering no datasets and not passing `sql: true` answers `-32601` to all three methods and advertises no `experimental.sql`.
**AC-9.3** `sql/scan` on a dataset with `limit: 2` returns 2 rows and a non-nil `nextCursor`; following the cursor returns the rest and a nil cursor; the union equals an unpaginated scan.
**AC-9.4** A dataset that ignores all quals still produces correct end-to-end results, because Postgres re-checks (asserted in PRD-10 §7).
**AC-9.5** `sql/modify` with `op: "delete"` on a dataset implementing only `scan/3` returns `-32601` naming the relation and op; the same server's `sql/scan` still works.
**AC-9.6** A dataset filtering on `ctx.auth` returns different rows for two different principals over the same transport.
**AC-9.7** A dataset raising in `scan/3` returns an error for that relation; a second dataset on the same server scans normally in the same session.
**AC-9.8** `SQL.Types.to_sql/1` output equals PRD-8 §4.1's Rust map for every member of the vocabulary, asserted against a shared fixture table checked into both trees.
**AC-9.9** Existing suites stay green unmodified: `mix test` fully green, no new warnings, no deprecations.
**AC-9.10** `mix.exs` still reports `0.3.0`; `mix hex.build` succeeds and the resulting tarball contains no `pg/` path.
**AC-9.11** `mix format --check-formatted`, `mix credo`, `mix dialyzer` clean.

---

## 6. Internal work checklist (with anchors)

| Step | File | Anchor / detail |
|---|---|---|
| 9.1 | `lib/noizu/mcp/server/dataset.ex` | new; §4.1 behaviour + `__using__` compile-time column validation |
| 9.2 | `lib/noizu/mcp/sql/types.ex` | new; §4.3 vocabulary; `from_field_type/2` consuming `lib/noizu/mcp/server/tool/fields.ex:16,133,150-163` |
| 9.3 | `lib/noizu/mcp/sql/quals.ex` | new; `decode/2`, `apply/2` |
| 9.4 | `lib/noizu/mcp/sql/schema.ex` | new; `build/3`; catalog relations from `lib/noizu/mcp/toolset.ex:41`, `server/features/prompts.ex:50`, `server/features/resources.ex:74,118` |
| 9.5 | `lib/noizu/mcp/server/features/sql.ex` | new; `schema/3`, `scan/3`, `modify/3` mirroring the shape of `features/completion.ex:13` |
| 9.6 | `lib/noizu/mcp/server.ex` | `dataset/2` macro beside `tool/2` (`:219`), in the block ending at `prompt/2` (`:245`); `@__mcp_datasets__` accumulator; `__mcp__(:datasets)`; generated `handle_sql_*` + `defoverridable`; `sql?` flag |
| 9.7 | `lib/noizu/mcp/server.ex` | `build_capabilities/2` (`:756`) folds `experimental.sql` non-destructively |
| 9.8 | `lib/noizu/mcp/server/session.ex` | three `dispatch/4` clauses after `completion/complete` (`:515`), each via `dispatch_feature/6` (`:525`) |
| 9.9 | `test/support/fixture_sql.ex` | new; dataset fixtures (empty, paginated, principal-filtered, raising, write-capable) |
| 9.10 | `lib/noizu/mcp/test.ex` | add `sql_schema/1`, `sql_scan/3`, `sql_modify/3` client helpers beside the existing in-memory transport helpers |
| 9.11 | `pg/pg_mcp/src/mode.rs` | Rust companion: §4.6 mode resolution; `sql`-mode table creation from `sql/schema`; scan → `sql/scan`; modify → `sql/modify` |
| 9.12 | `guides/postgres.md`, `docs/arch/sql.md`, `README.md`, `CHANGELOG.md` | FR-9.16 |
| 9.13 | `mix.exs` | **no version change**; confirm `pg` excluded from `package.files` (added in PRD-6 step 6.10). The `0.4.0` bump lands in PRD-11 step 11.12. |

---

## 7. Test plan

New tests under `test/noizu/mcp/sql/`:

- **`types_test.exs`** — the §4.3 vocabulary; `from_field_type/2` over every `fields.ex` type including `{:array, :object}` and `:enum` with values; the shared fixture table asserting agreement with PRD-8 §4.1 (AC-9.8).
- **`quals_test.exs`** — decode of every operator; unknown operator → `invalid_params`; `apply/2` purity and correctness against a property-based reference (`stream_data` is already a dep, `mix.exs:59`).
- **`schema_test.exs`** — catalog relations derived from the Toolset protocol, not a literal list (mutate the fixture's tools and assert the schema follows); dataset relations; hidden datasets excluded; name-collision compile failure asserted with `Code.compile_string/1` in a `capture_io` block.
- **`dataset_behaviour_test.exs`** — compile-time column validation rejects an unknown type; optional callbacks absent → `-32601`; raising `scan/3` → per-relation error with siblings healthy (AC-9.7).
- **`sql_methods_test.exs`** — end-to-end through `Noizu.MCP.Test` (`lib/noizu/mcp/test.ex`): all three methods, pagination (AC-9.3), positional rows, principal filtering (AC-9.6).
- **`opt_out_test.exs`** — a plain `use Noizu.MCP.Server` fixture answers `-32601` and advertises no `experimental.sql` (AC-9.2).

### 7.5 Conformance suite

`test/support/sql_conformance_case.ex`, following the pattern of the existing `persistence_conformance_case.ex` and `store_conformance_case.ex` in `test/support/`. Any host implementing datasets can `use` it and get: schema well-formedness, positional-row consistency, cursor totality (paginated union equals unpaginated), qual honesty (rows returned must satisfy every qual the dataset claims nothing about — the re-check contract), and error shape.

### 7.6 Anti-pattern regression tests

- **AP-P9 (parallel registry):** `sql/schema`'s `tools` relation must change when the fixture's tool set changes, proving it reads the Toolset protocol rather than a snapshot (D1).
- **AP-P10 (auth bypass):** `sql/scan` on a principal-filtered dataset with a hand-built `%Ctx{}` carrying no principal returns the anonymous row set, never the privileged one. There is no trusted-context escape hatch (mirrors series-1 AP-3).
- **AP-P11 (silent opt-in):** a server that registers no datasets must not gain `sql/*`. Asserted both by capability absence and by `-32601`.
- **AP-P12 (qual trust):** the FDW must re-check every qual. Asserted in PRD-10 §7 with a deliberately lying dataset that returns extra rows; the SQL result must still be correct.

---

## 8. Compat & rollback

- **Additive to the library.** No existing module changes shape. `server.ex` gains one macro, one accumulator and one capability fold; `session.ex` gains three dispatch clauses. Every existing callback, `__mcp__/1` key and wire response is unchanged.
- Servers that do not opt in are byte-identical on the wire, including their `capabilities` map — asserted by AC-9.2 and by the existing conformance suites staying green unmodified.
- **No publish in this PR.** Nothing reaches hex until PRD-11 carries the `0.4.0` bump and the user-run publish. That means `sql/*` and the Engine that consumes it are released together, and no version of the library ever ships a Dataset behaviour with no consumer.
- **Rollback**: revert the PR. There is no persisted data, no migration, no wire-format change for non-opted-in servers, and nothing published to un-publish.
- **Risk watch**: `experimental.sql` is version-tagged `1`. If MCP later standardizes a comparable family, `sql/*` becomes a compatibility shim and the version integer is the migration lever. Documented in `docs/arch/sql.md`.

---

## 9. Open questions

1. **Q1 (blocking the Rust companion commit):** In `mode 'sql'`, should `tool_calls` and the per-tool objects still be created? The spec above says yes — `sql/*` projects relations, not invocation. Confirm, because the alternative (a server fully describing its own invocation surface) is a materially larger protocol.
2. **Q2:** Positional rows over object rows (§4.5). Positional is smaller and is the hot path; object rows are self-describing and easier to debug. Recommend positional, with `sql/scan` accepting an optional `"format": "objects"` for humans. Lead's call on whether that escape hatch ships in 0.4.0.
3. **Q3:** Should `dataset/2` support inline column declaration (a `do` block, like the tool field DSL) rather than requiring a module? A module is more testable; an inline block is much less ceremony for a three-column relation. Recommend module-only for 0.4.0.
4. **Q4:** `sql/modify` transactionality. The wire has no transaction concept, so a multi-row insert that fails halfway leaves partial state. Should `sql/modify` require all-or-nothing from the dataset, or document best-effort? Recommend documenting best-effort and returning the rows actually written.
5. **Q5:** `SQL.Types` deliberately has no array type, matching PRD-8 §4.1's `jsonb` choice. If PRD-8 Q2 resolves toward `text[]`, this vocabulary must gain `{:array, t}` in the same change. The two decisions are one decision.
6. **Q6:** The `0.4.0` bump moved to PRD-11 so `sql/*` and its first consumer release together. That makes PRD-11 the last library-touching PR, and PRD-7, 8 and 10 all merge after the publish against a version already on hex. Confirm that ordering.
