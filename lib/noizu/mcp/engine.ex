defmodule Noizu.MCP.Engine do
  @moduledoc """
  The federation server (PRD-11, ADR-007): an MCP server whose content is
  other MCP servers.

  Install once, attach as needed. An operator mounts `Noizu.MCP.Engine`
  behind the ordinary Streamable HTTP plug, points `pg_mcp` at it once, and
  every subsequent upstream — including stdio-only ones on private networks —
  is attached with a `servers` row insert (`sql/modify`, or the
  `engine.attach` tool, or static config). The engine holds upstream
  connections and credentials; Postgres never speaks to an upstream directly.

  Federation enters through the ONE toolset resolution path (D1): each ready
  upstream contributes one `%Noizu.MCP.Toolset.Context.Layer{}` at weight 100
  under `{:upstream, name}` (`Noizu.MCP.Engine.Toolset`), folded by the
  existing merge engine beneath persisted overrides (200) and ACL (300) — so
  operator overrides and ACL filter federated tools exactly like local ones,
  with no federation-specific precedence code (D2). Upstream tools, prompts
  and resources are namespaced `<server>.<name>`; resource URIs gain a
  `mcp+engine://<server>/` prefix.

  Failure is per upstream (D5): a down upstream sets `status = 'error'` and
  contributes an empty layer; the engine and every healthy upstream keep
  serving, and `tools/list` never fails because one upstream did.

  Configuration is runtime-only (D3) under `:noizu_mcp, :engine` — see
  `Noizu.MCP.Engine.Config`. Run standalone with `mix mcp.engine`.
  """

  use Noizu.MCP.Server,
    name: "noizu-mcp-engine",
    version: Mix.Project.config()[:version],
    instructions:
      "MCP federation engine. Attached upstream servers appear as <server>.<tool> " <>
        "entries; manage upstreams with engine.attach, engine.detach and engine.refresh.",
    sql: true,
    acl: Noizu.MCP.Engine.ACL

  @behaviour Noizu.MCP.Toolset.Behaviour

  alias Noizu.MCP.Error
  alias Noizu.MCP.Engine.{Session, Toolset}
  alias Noizu.MCP.Server.Features
  alias Noizu.MCP.Toolset.Behaviour
  alias Noizu.MCP.Toolset.{Custom, Effective}
  alias Noizu.MCP.Types.ToolResult

  dataset(Noizu.MCP.Engine.Servers, name: "servers")

  tool(Noizu.MCP.Engine.Tools.Attach)
  tool(Noizu.MCP.Engine.Tools.Detach)
  tool(Noizu.MCP.Engine.Tools.Refresh)

  # ── the toolset protocol (federation composes like any other layer) ───────

  # The base surface (D3 — read per request from live session state): local
  # registrations plus every ready upstream's namespaced catalog. The upstream
  # layers themselves ride in as weight-100 context layers so the merge engine
  # folds federation, persisted overrides and ACL in one pass.
  @impl Noizu.MCP.Toolset.Behaviour
  def __toolset_specs__(_toolset, _ctx, _opts), do: Toolset.specs()

  @impl Noizu.MCP.Toolset.Behaviour
  def layers(_toolset, _ctx, _opts), do: Toolset.layers()

  @impl Noizu.MCP.Toolset.Behaviour
  def catalog(_toolset, ctx, opts) do
    Custom.catalog(federated_custom(), ctx, federated_opts(opts))
  end

  @impl Noizu.MCP.Toolset.Behaviour
  def resolve(_toolset, name, ctx, opts) do
    Custom.resolve(federated_custom(), name, ctx, federated_opts(opts))
  end

  @impl Noizu.MCP.Toolset.Behaviour
  def permissions(_toolset, ctx, opts) do
    Custom.permissions(federated_custom(), ctx, federated_opts(opts))
  end

  # Local tools dispatch through the behaviour default (the relocated
  # run_spec); federated entries proxy to their upstream session and return
  # the upstream's CallToolResult unmodified, isError included (FR-11.11).
  @impl Noizu.MCP.Toolset.Behaviour
  def invoke(_toolset, %Effective{name: name, entry: entry} = effective, args, ctx, opts) do
    case Toolset.split(name) do
      {prefix, tool} when prefix != "engine" ->
        with {:ok, pid} <- Noizu.MCP.Engine.Supervisor.invoke_session(prefix, ctx),
             :ok <- validate(entry, name, args),
             {:ok, result} <- Session.call_tool(pid, tool, args) do
          Session.touch(pid)
          result
        else
          {:error, reason} -> proxy_error(reason)
        end

      _other ->
        Behaviour.invoke(__MODULE__, effective, args, ctx, opts)
    end
  end

  defp federated_custom, do: %Custom{slug: "noizu-mcp-engine", base: __MODULE__}

  defp federated_opts(opts) do
    (opts || [])
    |> Keyword.put(:context_layers, Toolset.layers())
  end

  # SEP-1303: argument validation failures are execution errors the model can
  # fix — same shape the behaviour default produces before dispatch.
  defp validate(entry, name, args) do
    case Noizu.MCP.Schema.validate(entry.input_schema, args) do
      :ok -> :ok
      {:error, message} -> {:error, "Invalid arguments for tool #{name}: #{message}"}
    end
  end

  defp proxy_error(reason) when is_binary(reason), do: ToolResult.error(reason)

  defp proxy_error(:forbidden) do
    {:error, Error.forbidden("pass-through upstream requires a caller credential")}
  end

  defp proxy_error(reason) when is_exception(reason),
    do: {:error, Error.internal(Exception.message(reason))}

  defp proxy_error(reason),
    do: {:error, Error.internal("upstream request failed: #{inspect(reason)}")}

  # ── federated prompts & resources (FR-11.8) ───────────────────────────────

  @impl Noizu.MCP.Server
  def handle_list_prompts(cursor, _ctx) do
    with {:ok, local, nil} <- Features.Prompts.list_registered(__mcp__(:prompts), cursor) do
      {:ok, local ++ Toolset.prompts(), nil}
    end
  end

  @impl Noizu.MCP.Server
  def handle_get_prompt(name, args, ctx) do
    case Toolset.split(name) do
      {prefix, prompt} when prefix != "engine" ->
        proxy_prompt(prefix, prompt, args)

      _other ->
        Features.Prompts.dispatch_get(__mcp__(:prompts), name, args, ctx)
    end
  end

  defp proxy_prompt(server, prompt, args) do
    case Toolset.session_for(server) do
      nil ->
        Error.invalid_params("Unknown prompt: #{server}.#{prompt}")

      pid ->
        case Session.get_prompt(pid, prompt, args) do
          {:ok, _result} = ok -> ok
          {:error, reason} -> upstream_error(reason)
        end
    end
  end

  @impl Noizu.MCP.Server
  def handle_list_resources(cursor, ctx) do
    with {:ok, local, nil} <-
           Features.Resources.list_registered(
             __mcp__(:resources),
             __mcp__(:resource_templates),
             cursor,
             ctx
           ) do
      {:ok, local ++ Toolset.resources(), nil}
    end
  end

  @impl Noizu.MCP.Server
  def handle_list_resource_templates(cursor, _ctx) do
    local = Features.Resources.list_registered_templates(__mcp__(:resource_templates), cursor)

    case local do
      {:ok, items, nil} -> {:ok, items ++ Toolset.resource_templates(), nil}
      other -> other
    end
  end

  @impl Noizu.MCP.Server
  def handle_read_resource(uri, ctx) do
    case Toolset.split_resource_uri(uri) do
      {server, original} ->
        proxy_read(server, original, uri)

      nil ->
        Features.Resources.dispatch_read(
          __mcp__(:resources),
          __mcp__(:resource_templates),
          uri,
          ctx
        )
    end
  end

  defp proxy_read(server, original, wire_uri) do
    case Toolset.session_for(server) do
      nil ->
        Error.resource_not_found(wire_uri)

      pid ->
        case Session.read_resource(pid, original) do
          {:ok, contents} ->
            {:ok, Enum.map(contents, &%{&1 | uri: wire_uri})}

          {:error, reason} ->
            upstream_error(reason)
        end
    end
  end

  # ── federated sql/* relations (FR-11.19) ──────────────────────────────────

  # An upstream advertising `experimental.sql` re-exports its relations as
  # <server>.<relation>; sql/scan on one proxies to that upstream. Everything
  # else falls through to the derived default (datasets, tools, catalogs).
  @impl Noizu.MCP.Server
  def handle_sql_schema(params, ctx) do
    with {:ok, payload} <- Features.SQL.default_schema(__MODULE__, params, ctx) do
      {:ok, Map.update(payload, "relations", [], &(&1 ++ Toolset.sql_relations()))}
    end
  end

  @impl Noizu.MCP.Server
  def handle_sql_scan(relation, opts, ctx) do
    case federated_relation(relation) do
      {server, upstream_relation} ->
        proxy_sql_scan(server, upstream_relation, opts)

      nil ->
        Features.SQL.default_scan(__MODULE__, relation, opts, ctx)
    end
  end

  defp federated_relation(relation) do
    case Toolset.split(relation) do
      {prefix, rest} when prefix != "engine" ->
        if Toolset.session_for(prefix), do: {prefix, rest}, else: nil

      _other ->
        nil
    end
  end

  defp proxy_sql_scan(server, relation, opts) do
    case Toolset.session_for(server) do
      nil ->
        Error.invalid_params("Unknown relation: #{server}.#{relation}")

      pid ->
        wire_opts = %{
          "quals" => Map.get(opts, "quals") || [],
          "columns" => Map.get(opts, "columns"),
          "sort" => Map.get(opts, "sort"),
          "limit" => Map.get(opts, "limit"),
          "cursor" => Map.get(opts, "cursor")
        }

        case Session.sql_scan(pid, relation, wire_opts) do
          {:ok, result} -> sql_scan_rows(result)
          {:error, reason} -> upstream_error(reason)
        end
    end
  end

  # The upstream's positional rows are re-keyed to maps so the shared
  # positional renderer stays the ONE wire encoder (PRD-9 §4.5).
  defp sql_scan_rows(%{"columns" => columns, "rows" => rows} = result) do
    maps = Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)
    {:ok, columns, maps, result["nextCursor"]}
  end

  defp sql_scan_rows(_other), do: Error.internal("upstream sql/scan returned an unexpected shape")

  defp upstream_error(reason) when is_binary(reason), do: Error.internal(reason)
  defp upstream_error(reason), do: Error.internal("upstream request failed: #{inspect(reason)}")

  # ── boot ───────────────────────────────────────────────────────────────────

  @doc """
  Seed `:static_servers` config rows into the `servers` store (idempotent).
  Static config seeds rows — it never bypasses them (D3). Called by
  `mix mcp.engine`; embedded hosts call it once at boot.
  """
  @spec seed_static() :: :ok | {:error, term()}
  defdelegate seed_static(), to: Noizu.MCP.Engine.Servers
end
