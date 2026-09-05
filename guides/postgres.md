# Postgres: projecting an MCP server into SQL

Operator-facing guide for the `mcp_fdw` foreign-data wrapper and the
Elixir-side features it consumes. The FDW itself, its modes and packaging are
specified in the pg_mcp series (PRD-6..10, `pg/pg_mcp`); this page covers the
part a **server author** writes: opt-in, and datasets.

Related: [the `sql/*` protocol reference](../docs/arch/sql.md) ·
[ADR-005](../docs/adrs/ADR-005-sql-extension-methods.md).

## How it works

The FDW wraps any MCP server as foreign tables:

* **`mode 'generic'`** (always available) builds catalog tables from the
  standard list methods and invokes tools through INSERT-into-`tool_calls`.
  Nothing in your server changes.
* **`mode 'sql'`** (requires opt-in) builds tables from `sql/schema`, reads
  them with `sql/scan` and writes them with `sql/modify` — typed columns,
  predicate pushdown, cursors.
* **`mode 'auto'`** (the default) reads the cached `initialize` capabilities:
  if your server advertises `experimental.sql`, the FDW uses `sql/*`; if not,
  it falls back to generic. No extra round trip.

## Opting in

Two ways — either is sufficient:

```elixir
defmodule MyApp.MCP do
  use Noizu.MCP.Server,
    name: "myapp",
    version: "1.0.0",
    sql: true   # advertise the derived surface: catalogs + per-tool relations
end
```

…or simply register a dataset; that opts the server in on its own.

With `sql: true` and no datasets, the FDW already gets: the catalog relations
(`tools`, `prompts`, `resources`, read-through `prompt_messages`,
`resource_contents`, `completions`, derived `prompt_arguments`,
`resource_templates`) and one relation per tool with typed columns derived
from its input/output schemas. Per-tool relations accept pushed quals on
input-schema columns, and scanning one is authorized exactly like calling the
tool — a tool a principal cannot call has no relation at all.

## Datasets: relations that are not tools

A dataset describes tabular data a server holds that is not naturally a tool
call — sessions, prompt versions, a directory tree, an upstream registry.
Participation is explicit: a module `use`s the behaviour and the server
registers it. There is no discovery and no probing.

```elixir
defmodule MyApp.MCP.Sessions do
  use Noizu.MCP.Server.Dataset

  @impl true
  def info do
    %{
      name: "sessions",
      title: "Sessions",
      description: "Live sessions for the calling principal.",
      primary_key: ["id"],
      writable: false
    }
  end

  @impl true
  def columns do
    [
      %{name: "id", type: :uuid, nullable: false, description: "Session id"},
      %{name: "started_at", type: :timestamptz, nullable: false, description: nil},
      %{name: "agent", type: :text, nullable: true, description: nil}
    ]
  end

  @impl true
  def scan(_args, ctx, _opts), do: {:ok, MyApp.sessions_for(ctx.auth), nil}
end

defmodule MyApp.MCP do
  use Noizu.MCP.Server, name: "myapp", version: "1.0.0"

  dataset MyApp.MCP.Sessions
  # Options: name: "other_name" overrides info().name on the wire;
  # hidden: true keeps it out of sql/schema while still scannable by name.
end
```

`columns/0` and `info/0` are validated at **compile time** against
`Noizu.MCP.SQL.Types` — an unknown column type, duplicate names, a name
colliding with a derived relation (`tools`, `prompts`, …) or two datasets
sharing a name are build failures, never runtime surprises.

### The scan contract

`scan(args, ctx, opts)` returns `{:ok, rows, cursor}` — **map rows** keyed by
column name (the runtime converts to positional wire rows and fills `nil`
for columns you omit), plus an opaque cursor string or `nil`.

`opts` may carry `quals`, `columns`, `sort`, `limit` and `cursor`. You MAY
ignore any of them — the FDW re-checks every qual locally, so the honest
minimum implementation ignores `opts` entirely. The one prohibition: never
return a row that a qual you *did* apply would have excluded, and never drop
a row a qual you ignored would have kept. See
[`Noizu.MCP.SQL.Quals`](../docs/arch/sql.md#the-qual-honesty-contract).

`ctx.auth` carries the request's `%Principal{}` — filter on it exactly as a
tool would. There is no anonymous-with-privileges path: claim-less requests
arrive with `ctx.auth = nil`.

### Writes (optional)

`insert/2`, `update/3`, `delete/2` are optional. `sql/schema` reports the
relation `writable` when you implement any of them and `info().writable` is
not `false`. An FDW op you do not implement answers `method_not_found`
naming the relation and op. Writes are best-effort: return the rows actually
written (or the delete count), not a promise of atomicity.

### Conformance

Make your dataset prove itself — the shared battery asserts schema
well-formedness, positional rows, cursor totality, qual honesty and error
shape:

```elixir
defmodule MyApp.MCPSQLConformanceTest do
  use ExUnit.Case, async: false
  use Noizu.MCP.Test.SQLConformanceCase, server: MyApp.MCP
end
```

## ACL

Datasets authorize under a subject of their own, `{:dataset, name}`. An
`acl:` provider that does not list `:dataset` in `supported_kinds` denies
dataset scans (its own default), so bolt a dataset onto an ACL-configured
server only when the provider knows the subject. Tool-derived relations need
nothing: they borrow the tool's verdict.
