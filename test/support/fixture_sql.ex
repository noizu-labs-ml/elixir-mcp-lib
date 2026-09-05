defmodule Noizu.MCP.Fixtures.SQL do
  @moduledoc """
  Dataset fixtures and SQL-enabled servers for the `sql/*` suite (PRD-9 §7.9).
  """
end

defmodule Noizu.MCP.Fixtures.SQL.Empty do
  @moduledoc "A dataset that declares two columns and never has rows."
  use Noizu.MCP.Server.Dataset

  @impl true
  def info do
    %{
      name: "empty_rows",
      title: "Empty Rows",
      description: "A relation that is always empty.",
      primary_key: ["id"],
      writable: false
    }
  end

  @impl true
  def columns do
    [
      %{name: "id", type: :text, nullable: false, description: "Row id"},
      %{name: "note", type: :text, nullable: true, description: nil}
    ]
  end

  @impl true
  def scan(_args, _ctx, _opts), do: {:ok, [], nil}
end

defmodule Noizu.MCP.Fixtures.SQL.Paged do
  @moduledoc "A dataset that honors limit and cursor so pagination can be asserted."
  use Noizu.MCP.Server.Dataset

  @rows 7
  @default_page 3

  @impl true
  def info do
    %{name: "paged_rows", primary_key: ["id"], writable: false}
  end

  @impl true
  def columns do
    [
      %{name: "id", type: :bigint, nullable: false, description: "Sequence position"},
      %{name: "label", type: :text, nullable: false, description: "Row label"}
    ]
  end

  @impl true
  def scan(_args, _ctx, opts) do
    rows = Enum.map(1..@rows, &%{"id" => &1, "label" => "row-#{&1}"})
    offset = decode_cursor(opts[:cursor])
    limit = opts[:limit] || @default_page
    page = Enum.slice(rows, offset, limit)

    next =
      if offset + limit < length(rows),
        do: encode_cursor(offset + limit),
        else: nil

    {:ok, page, next}
  end

  defp decode_cursor(nil), do: 0

  defp decode_cursor(cursor) when is_binary(cursor) do
    case Base.url_decode64(cursor, padding: false) do
      {:ok, "pg:" <> rest} -> String.to_integer(rest)
      _other -> 0
    end
  end

  defp encode_cursor(offset), do: Base.url_encode64("pg:#{offset}", padding: false)
end

defmodule Noizu.MCP.Fixtures.SQL.ByPrincipal do
  @moduledoc """
  A dataset that filters on `ctx.auth` (PRD-9 FR-9.12): each principal sees
  only its own rows; anonymous sessions see the public row and never any
  principal's private rows (AP-P10 — there is no trusted-context escape).
  """
  use Noizu.MCP.Server.Dataset

  @rows %{
    "alice" => [
      %{"id" => "a1", "owner" => "alice", "secret" => "alice-private"},
      %{"id" => "a2", "owner" => "alice", "secret" => "alice-second"}
    ],
    "bob" => [%{"id" => "b1", "owner" => "bob", "secret" => "bob-private"}]
  }

  @impl true
  def info, do: %{name: "principal_rows", primary_key: ["id"], writable: false}

  @impl true
  def columns do
    [
      %{name: "id", type: :text, nullable: false, description: "Row id"},
      %{name: "owner", type: :text, nullable: false, description: "Owning principal"},
      %{name: "secret", type: :text, nullable: false, description: "Principal-visible value"}
    ]
  end

  @impl true
  def scan(_args, ctx, _opts) do
    subject =
      case ctx do
        %{auth: %{__struct__: Noizu.MCP.Auth.Principal, subject: subject}} -> subject
        _other -> "anonymous"
      end

    rows =
      Map.get(@rows, subject, [
        %{"id" => "public", "owner" => subject, "secret" => "public-data"}
      ])

    {:ok, rows, nil}
  end
end

defmodule Noizu.MCP.Fixtures.SQL.Renamed do
  @moduledoc "Registered under a `name:` that overrides `info().name`."
  use Noizu.MCP.Server.Dataset

  @impl true
  def info, do: %{name: "internal_name", primary_key: ["id"], writable: false}

  @impl true
  def columns do
    [%{name: "id", type: :text, nullable: false, description: nil}]
  end

  @impl true
  def scan(_args, _ctx, _opts), do: {:ok, [%{"id" => "renamed"}], nil}
end

defmodule Noizu.MCP.Fixtures.SQL.Hidden do
  @moduledoc "Registered `hidden: true` — out of sql/schema, scannable by name."
  use Noizu.MCP.Server.Dataset

  @impl true
  def info, do: %{name: "hidden_rows", primary_key: ["id"], writable: false}

  @impl true
  def columns do
    [%{name: "id", type: :text, nullable: false, description: nil}]
  end

  @impl true
  def scan(_args, _ctx, _opts), do: {:ok, [%{"id" => "hidden"}], nil}
end

defmodule Noizu.MCP.Fixtures.SQL.Boom do
  @moduledoc "A dataset that raises in scan/3 — exercises D5 per-relation failure."
  use Noizu.MCP.Server.Dataset

  @impl true
  def info, do: %{name: "boom_rows", primary_key: ["id"], writable: false}

  @impl true
  def columns do
    [%{name: "id", type: :text, nullable: false, description: nil}]
  end

  @impl true
  def scan(_args, _ctx, _opts), do: raise("boom dataset exploded")
end

defmodule Noizu.MCP.Fixtures.SQL.Writable do
  @moduledoc """
  A dataset implementing all three optional write callbacks over
  `:persistent_term` state. Tests using it must not run async (global state)
  and should call `reset/0` in setup.
  """
  use Noizu.MCP.Server.Dataset

  @state_key {:noizu_mcp_fixture_sql, :writable_rows}

  @impl true
  def info, do: %{name: "writable_rows", primary_key: ["id"], writable: true}

  @impl true
  def columns do
    [
      %{name: "id", type: :text, nullable: false, description: "Row id"},
      %{name: "value", type: :text, nullable: true, description: "Row value"}
    ]
  end

  @doc "Clear the dataset's state between tests."
  def reset, do: :persistent_term.put(@state_key, [%{"id" => "seed", "value" => "seed-value"}])

  @impl true
  def scan(_args, _ctx, _opts), do: {:ok, :persistent_term.get(@state_key, []), nil}

  @impl true
  def insert(rows, _ctx) when is_list(rows) do
    written =
      Enum.map(rows, fn row ->
        Map.put(row, "id", "w-#{:erlang.unique_integer([:positive])}")
      end)

    :persistent_term.put(@state_key, :persistent_term.get(@state_key, []) ++ written)
    {:ok, written}
  end

  @impl true
  def update(quals, changes, _ctx) do
    {matched, rest} =
      Enum.split_with(
        :persistent_term.get(@state_key, []),
        &Noizu.MCP.SQL.Quals.satisfies?(&1, quals)
      )

    changed = Enum.map(matched, &Map.merge(&1, changes))
    :persistent_term.put(@state_key, rest ++ changed)
    {:ok, changed}
  end

  @impl true
  def delete(quals, _ctx) do
    {matched, rest} =
      Enum.split_with(
        :persistent_term.get(@state_key, []),
        &Noizu.MCP.SQL.Quals.satisfies?(&1, quals)
      )

    :persistent_term.put(@state_key, rest)
    {:ok, length(matched)}
  end
end

defmodule Noizu.MCP.Fixtures.SQL.Server do
  @moduledoc """
  The primary sql/* fixture: a full server with tools, prompts, resources and
  seven datasets covering empty, paginated, principal-filtered, renamed,
  hidden, raising and write-capable behaviour.
  """
  use Noizu.MCP.Server,
    name: "sql-fixture",
    version: "1.0.0",
    instructions: "SQL fixture server."

  tool Noizu.MCP.Fixtures.Echo
  tool Noizu.MCP.Fixtures.Weather
  tool Noizu.MCP.Fixtures.RawSchema

  prompt Noizu.MCP.Fixtures.CodeReviewPrompt

  resource Noizu.MCP.Fixtures.ConfigResource
  resource_template Noizu.MCP.Fixtures.TableSchema

  dataset(Noizu.MCP.Fixtures.SQL.Empty)
  dataset(Noizu.MCP.Fixtures.SQL.Paged)
  dataset(Noizu.MCP.Fixtures.SQL.ByPrincipal)
  dataset(Noizu.MCP.Fixtures.SQL.Renamed, name: "renamed_rows")
  dataset(Noizu.MCP.Fixtures.SQL.Hidden, hidden: true)
  dataset(Noizu.MCP.Fixtures.SQL.Boom)
  dataset(Noizu.MCP.Fixtures.SQL.Writable)
end

defmodule Noizu.MCP.Fixtures.SQL.ReadOnlyServer do
  @moduledoc """
  `sql: true` with NO datasets: the derived tool/prompt/resource surface is
  the whole story, proving a server can opt in for projection alone (§4.4).
  """
  use Noizu.MCP.Server,
    name: "sql-readonly",
    version: "1.0.0",
    sql: true

  tool Noizu.MCP.Fixtures.Echo
end

# ── ACL fixtures (FR-9.18 / AC-9.12) ─────────────────────────────────────────

defmodule Noizu.MCP.Fixtures.SQL.ConformanceServer do
  @moduledoc "Healthy-dataset server for the shared SQL conformance battery."
  use Noizu.MCP.Server,
    name: "sql-conformance",
    version: "1.0.0"

  tool Noizu.MCP.Fixtures.Echo

  dataset(Noizu.MCP.Fixtures.SQL.Empty)
  dataset(Noizu.MCP.Fixtures.SQL.Paged)
  dataset(Noizu.MCP.Fixtures.SQL.ByPrincipal)
  dataset(Noizu.MCP.Fixtures.SQL.Writable)
end

defmodule Noizu.MCP.Fixtures.SQL.HostSQLServer do
  @moduledoc "A host-defined handle_sql_schema alone opts in and wins the defines? race."
  use Noizu.MCP.Server,
    name: "sql-host",
    version: "1.0.0"

  tool Noizu.MCP.Fixtures.Echo

  @impl Noizu.MCP.Server
  def handle_sql_schema(_params, _ctx), do: {:ok, %{"custom" => true}}
end

defmodule Noizu.MCP.Fixtures.SQL.EchoDenyProvider do
  @moduledoc "Denies the echo tool for everyone; allows weather and datasets."
  @behaviour Noizu.MCP.ACL.Provider

  alias Noizu.MCP.ACL.Resource

  @impl true
  def check(_subject, %Resource{kind: :tool, id: "echo"}, _action, _ctx, _opts), do: :deny
  def check(_subject, _resource, _action, _ctx, _opts), do: :allow

  @impl true
  def supported_kinds, do: [:tool, :toolset, :dataset]
end

defmodule Noizu.MCP.Fixtures.SQL.NoDatasetKindProvider do
  @moduledoc """
  Governs tools but does NOT list `:dataset` in supported_kinds — a dataset
  check against it must deny (the provider's own default, §4.4), and the lib
  must never raise the §4.7 kind-gap error past the method boundary.
  """
  @behaviour Noizu.MCP.ACL.Provider

  alias Noizu.MCP.ACL.Resource

  @impl true
  def check(_subject, %Resource{kind: :tool, id: "echo"}, _action, _ctx, _opts), do: :deny
  def check(_subject, _resource, _action, _ctx, _opts), do: :allow

  @impl true
  def supported_kinds, do: [:tool, :toolset]
end

defmodule Noizu.MCP.Fixtures.SQL.ACLServer do
  @moduledoc """
  `sql: true` behind `EchoDenyProvider`: scanning the echo relation must fail
  exactly like calling the tool (AC-9.12), and datasets authorize under their
  own `{:dataset, name}` subject.
  """
  use Noizu.MCP.Server,
    name: "sql-acl",
    version: "1.0.0",
    sql: true,
    acl: Noizu.MCP.Fixtures.SQL.EchoDenyProvider

  tool Noizu.MCP.Fixtures.Echo
  tool Noizu.MCP.Fixtures.Weather

  dataset(Noizu.MCP.Fixtures.SQL.ByPrincipal)
end

defmodule Noizu.MCP.Fixtures.SQL.NoDatasetKindServer do
  @moduledoc "Same shape as ACLServer but the provider has no :dataset kind."
  use Noizu.MCP.Server,
    name: "sql-acl-nods",
    version: "1.0.0",
    sql: true,
    acl: Noizu.MCP.Fixtures.SQL.NoDatasetKindProvider

  tool Noizu.MCP.Fixtures.Echo
  dataset(Noizu.MCP.Fixtures.SQL.Empty)
end
