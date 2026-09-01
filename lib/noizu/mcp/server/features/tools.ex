defmodule Noizu.MCP.Server.Features.Tools do
  @moduledoc """
  Tools feature plumbing: the helpers behind the generated
  `handle_list_tools/2` and `handle_call_tool/3` defaults.

  Most servers never call this module directly. Reach for it when you
  hand-write those callbacks but still want the registry-driven behavior —
  e.g. session-gated visibility:

      @impl true
      # ⟦𓐯𓄷𓊜𓄶⟧ handle_list_tools :: auto-generated pointer for public function handle_list_tools
      def handle_list_tools(cursor, ctx) do
        Noizu.MCP.Server.Features.Tools.list_registered(
          __mcp__(:tools),
          cursor,
          include_hidden: ctx.assigns[:unlocked] == true
        )
      end

  For finer control, `expand/1` flattens the `__mcp__(:tools)` registration
  list into normalized `Noizu.MCP.Server.Tool.Spec` structs you can filter or
  remap before building the response.

  The generated defaults route through the toolset protocol
  (`protocol_list/3` / `protocol_call/4` — one resolution path for listing,
  dispatch, and the catalog tool); `list_registered/3` and `dispatch/4` are
  thin shims over the same behaviour defaults, so hand-written callbacks and
  generated ones share the effective-materialization semantics.

  Also handled here: pagination, JSON Schema validation (per SEP-1303,
  input-validation failures are `isError` execution results, not protocol
  errors), argument casting for DSL tools, and normalization of handler
  return values to wire maps.
  """

  alias Noizu.MCP.{Error, RenderCtx, Schema, Toolset}
  alias Noizu.MCP.Server.Features.Pagination
  alias Noizu.MCP.Types.{Content, Tool, ToolResult}

  require Logger

  # ── tools/list ────────────────────────────────────────────────────────────

  # ⟦𓌪𓍖𓍍𓋸⟧ list :: auto-generated pointer for public function list
  def list(server, params, ctx) do
    cursor = (params || %{})["cursor"]
    render = render_ctx(ctx)

    case server.handle_list_tools(cursor, ctx) do
      {:ok, tools, next_cursor} ->
        result = %{"tools" => Enum.map(tools, &Tool.to_map(&1, render))}
        result = if next_cursor, do: Map.put(result, "nextCursor", next_cursor), else: result
        {:ok, result}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  # Derive the description render context for a tools/list response.
  #
  # App-layer wiring seam: a fully-built `%RenderCtx{}` dropped into
  # `ctx.assigns[:render_ctx]` (e.g. from a gateway plug or the server's
  # `init/2`, keyed off session `verbosity`/`runner`/`model` or request headers)
  # wins outright. Otherwise a context is assembled from the individual
  # `:verbosity`/`:runner`/`:model` assigns, with the server/global
  # default-verbosity chain resolved via `RenderCtx.server_defaults/1`. With no
  # such assigns this is `RenderCtx.default/0` — single-string tools render
  # exactly as before.
  defp render_ctx(%{assigns: assigns} = ctx) when is_map(assigns) do
    case assigns[:render_ctx] do
      %RenderCtx{} = rc ->
        rc

      _ ->
        %RenderCtx{
          verbosity: assigns[:verbosity],
          runner: assigns[:runner],
          model: assigns[:model],
          defaults: RenderCtx.server_defaults(Map.get(ctx, :server))
        }
    end
  end

  defp render_ctx(_ctx), do: RenderCtx.default()

  @doc """
  Expand a `[{module, opts}]` registration list into flat `[%Spec{}]`.

  Every tool module exports `__mcp_tools__/0` — classic
  `use Noizu.MCP.Server.Tool` modules yield one spec,
  `use Noizu.MCP.Server.Toolkit` modules yield one per `@mcp`-annotated
  function. Registration opts are applied per spec:

    * `:hidden` / `:visible` — override visibility (`visible: false` ≡
      `hidden: true`; an explicit `:hidden` key wins when both are given)
    * `:category` — merged into the definition's `meta` as `"category"`
    * `:name` / `:description` — definition overrides, single-tool modules
      only (raises `ArgumentError` for multi-tool registrations, where the
      override would be ambiguous)
  """
  # ⟦𓄟𓏬𓇓𓇻⟧ expand :: Expand a `[{module, opts}]` registration list into flat `[%Spec{}]`.
  def expand(registered) do
    Enum.flat_map(registered, fn {module, opts} ->
      apply_registration_opts(module.__mcp_tools__(), module, opts)
    end)
  end

  defp apply_registration_opts(specs, module, opts) do
    if length(specs) > 1 and
         (Keyword.has_key?(opts, :name) or Keyword.has_key?(opts, :description)) do
      raise ArgumentError,
            ":name/:description registration overrides are ambiguous for multi-tool " <>
              "module #{inspect(module)} — set them per tool in the @mcp annotation"
    end

    Enum.map(specs, fn spec ->
      spec
      |> override_definition(opts)
      |> override_hidden(opts)
    end)
  end

  defp override_definition(spec, opts) do
    definition =
      Enum.reduce(opts, spec.definition, fn
        {:name, name}, acc ->
          %{acc | name: name}

        {:description, description}, acc ->
          %{acc | description: description}

        {:category, category}, acc ->
          %{acc | meta: Map.put(acc.meta || %{}, "category", category)}

        {_other, _}, acc ->
          acc
      end)

    %{spec | definition: definition}
  end

  defp override_hidden(spec, opts) do
    hidden =
      cond do
        Keyword.has_key?(opts, :hidden) -> opts[:hidden] == true
        Keyword.has_key?(opts, :visible) -> opts[:visible] == false
        true -> spec.hidden
      end

    %{spec | hidden: hidden}
  end

  @doc "Default `handle_list_tools` over the registered tool modules."
  # ⟦𓉶𓌖𓋦𓋢⟧ list_registered :: Default `handle_list_tools` over the registered tool modules.
  def list_registered(registered, cursor, opts \\ []) do
    include_hidden = Keyword.get(opts, :include_hidden, false)
    page_size = Keyword.get(opts, :page_size, Pagination.default_page_size())
    toolset = %Toolset.Static{specs: expand(registered), opts: opts}

    # Thin shim over the behaviour defaults (D1) — same resolution path as the
    # protocol, one code path for the wire.
    case Noizu.MCP.Toolset.Behaviour.catalog(toolset, nil, opts) do
      {:ok, entries, _version} ->
        definitions =
          entries
          |> then(fn entries ->
            if include_hidden, do: entries, else: Enum.filter(entries, & &1.visible)
          end)
          |> Enum.map(& &1.definition)

        Pagination.paginate(definitions, cursor, page_size)

      {:error, %Error{}} = error ->
        error
    end
  end

  # ── tools/call ────────────────────────────────────────────────────────────

  # ⟦𓈩𓅐𓁯𓃫⟧ call :: auto-generated pointer for public function call
  def call(server, params, ctx) do
    name = (params || %{})["name"]
    args = (params || %{})["arguments"] || %{}

    if is_binary(name) do
      case server.handle_call_tool(name, args, ctx) |> normalize(nil) do
        {:error, %Error{} = error} -> {:error, error}
        %ToolResult{} = result -> {:ok, ToolResult.to_map(result)}
      end
    else
      {:error, Error.invalid_params("tools/call requires a tool name")}
    end
  end

  @doc "Default `handle_call_tool`: dispatch to a registered tool spec."
  # ⟦𓇼𓁟𓆋𓇇⟧ dispatch :: Default `handle_call_tool`: dispatch to a registered tool spec.
  def dispatch(registered, name, args, ctx) do
    toolset = %Toolset.Static{specs: expand(registered)}

    # Thin shim over the behaviour defaults (D1): resolve+invoke through the
    # same effective-materialization path the protocol serves. ctx flows to
    # arity-2 handlers exactly as the pre-toolset run_spec did — and through
    # to the ACL pass inside the defaults, so the server's provider governs
    # this shim too (a denied tool resolves like an absent one, PRD-2 AP-5).
    case Noizu.MCP.Toolset.Behaviour.resolve(toolset, name, ctx, []) do
      {:ok, effective} ->
        Noizu.MCP.Toolset.Behaviour.invoke(toolset, effective, args, ctx, [])

      {:error, %Error{}} = error ->
        error
    end
  end

  # ── protocol path (toolset architecture) ─────────────────────────────────

  @doc """
  `handle_list_tools` default over the toolset protocol: coerce the server to
  a toolset, materialize the effective catalog, drop non-visible entries, and
  paginate DEFINITIONS (so `nextCursor` semantics match the static path).
  A toolset whose resolution raises is disabled, not fatal — the failure is
  normalized to a protocol error (D5).
  """
  def protocol_list(toolset, cursor, ctx) do
    case catalog(toolset, ctx) do
      {:ok, entries, _version} ->
        definitions =
          entries
          |> Enum.filter(& &1.visible)
          |> Enum.map(& &1.definition)

        Pagination.paginate(definitions, cursor, Pagination.default_page_size())

      {:error, %Error{}} = error ->
        error
    end
  end

  @doc """
  `handle_call_tool` default over the toolset protocol: coerce → resolve →
  invoke against the effective triple. Invoke raises propagate to the session
  task handler exactly as the static path's handler raises always did; only
  toolset-plumbing failures (coerce/catalog/resolve) normalize to a protocol
  error (D5).
  """
  def protocol_call(toolset, name, args, ctx) do
    case resolve(toolset, name, ctx) do
      {:ok, effective} ->
        Toolset.invoke(toolset, effective, args, ctx, [])

      {:error, %Error{}} = error ->
        error
    end
  end

  # Toolset plumbing rescue boundary (D5): a toolset that fails to materialize
  # disables the set, not the server. Invoke is deliberately OUTSIDE this
  # boundary — handler crashes keep their existing session-level handling.
  defp catalog(toolset, ctx) do
    Toolset.catalog(toolset, ctx, [])
  rescue
    e -> {:error, Error.internal("toolset catalog failed: #{Exception.message(e)}")}
  end

  defp resolve(toolset, name, ctx) do
    Toolset.resolve(toolset, name, ctx, [])
  rescue
    e -> {:error, Error.internal("toolset resolve failed: #{Exception.message(e)}")}
  end

  # ── return normalization ──────────────────────────────────────────────────

  @doc "Normalize a tool handler return value to a `ToolResult`."
  # ⟦𓁧𓀏𓊉𓃜⟧ normalize :: Normalize a tool handler return value to a `ToolResult`.
  def normalize(result, output_schema)

  # Already normalized (e.g. by the DSL dispatch path) — pass through.
  def normalize(%ToolResult{} = result, _), do: result
  def normalize({:error, %Error{}} = error, _), do: error

  def normalize({:ok, %ToolResult{} = result}, output_schema) do
    check_output(result.structured, output_schema)
    result
  end

  def normalize({:ok, %Content{} = content}, _), do: ToolResult.ok(content)
  def normalize({:ok, text}, _) when is_binary(text), do: ToolResult.ok(text)

  def normalize({:ok, [%Content{} | _] = content}, _), do: ToolResult.ok(content)

  def normalize({:ok, %{} = structured}, output_schema) do
    check_output(structured, output_schema)
    ToolResult.structured(structured)
  end

  def normalize({:error, text}, _) when is_binary(text), do: ToolResult.error(text)
  def normalize({:error, %Content{} = content}, _), do: ToolResult.error(content)
  def normalize({:error, [%Content{} | _] = content}, _), do: ToolResult.error(content)

  def normalize(other, _) do
    raise ArgumentError,
          "invalid tool return value: #{inspect(other)} — expected {:ok, _} | {:error, _} " <>
            "(see Noizu.MCP.Server.Tool docs)"
  end

  defp check_output(_structured, nil), do: :ok
  defp check_output(nil, _schema), do: :ok

  defp check_output(structured, schema) do
    # Output is the server author's own contract — log loudly rather than fail
    # the call in production.
    case Schema.validate(schema, normalize_json(structured)) do
      :ok ->
        :ok

      {:error, message} ->
        Logger.warning("MCP tool structured content does not match its outputSchema: #{message}")
    end
  end

  # Round-trip through JSON encoding rules so atom keys/values compare like
  # they will appear on the wire.
  defp normalize_json(value), do: value |> Jason.encode!() |> Jason.decode!()
end
