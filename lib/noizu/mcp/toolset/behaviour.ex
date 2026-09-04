defmodule Noizu.MCP.Toolset.Behaviour do
  @moduledoc """
  Protocol+behaviour duality for toolsets.

  Structs opt in with `use Noizu.MCP.Toolset.Behaviour` plus an explicit
  `defimpl Noizu.MCP.Toolset, for: MyStruct` delegating each function to the
  module's (see `%Noizu.MCP.Toolset.Static{}` — `@derive` cannot be used, it
  would delegate to the fail-closed `Any` impl); servers get the same functions
  injected by `use Noizu.MCP.Server` over `__mcp__(:tools)` (each
  `defoverridable`, so hosts may specialize at the toolset layer too). A bare
  server module IS a toolset entity.

  The defaults here are the single resolution path behind `tools/list`,
  `tools/call`, and the catalog tool (D1). They read `__toolset_specs__/3` and
  opts at call time only — no compile-time env capture (D3) — and always
  materialize the effective surface before validation and dispatch (D2).

  Note: `__toolset_specs__` takes the toolset as its first argument (the PRD's
  2-arity sketch cannot reach the held specs of a struct instance like
  `%Noizu.MCP.Toolset.Static{}`; the 3-arity form keeps every callback
  toolset-first).
  """

  alias Noizu.MCP.{Error, Schema}
  alias Noizu.MCP.Server.Features.Tools
  alias Noizu.MCP.Server.Tool.{Fields, Spec}
  alias Noizu.MCP.Toolset.{Entry, Effective, Layer, Overrides}
  alias Noizu.MCP.Types.ToolResult

  require Logger

  @doc "Produce the static spec list this toolset serves. No default body — servers get one over `__mcp__(:tools)`; struct modules fail closed (D5)."
  @callback __toolset_specs__(toolset :: term(), ctx :: term(), opts :: keyword()) :: [Spec.t()]

  @callback catalog(toolset :: term(), ctx :: term(), opts :: keyword()) ::
              {:ok, [Entry.t()], version :: String.t()} | {:error, Error.t()}

  @callback resolve(toolset :: term(), name :: term(), ctx :: term(), opts :: keyword()) ::
              {:ok, Effective.t()} | {:error, Error.t()}

  @callback invoke(
              toolset :: term(),
              effective :: Effective.t(),
              args :: term(),
              ctx :: term(),
              opts :: keyword()
            ) ::
              ToolResult.t() | {:error, Error.t()}

  @callback permissions(toolset :: term(), ctx :: term(), opts :: keyword()) ::
              {:ok,
               %{
                 required(:tools) => [
                   %{
                     required(:name) => String.t(),
                     required(:visible) => boolean(),
                     required(:callable) => boolean()
                   }
                 ],
                 required(:version) => String.t()
               }}
              | {:error, Error.t()}

  @callback metadata(toolset :: term(), ctx :: term(), opts :: keyword()) ::
              {:ok,
               %{
                 required(:slug) => String.t(),
                 required(:title) => String.t() | nil,
                 required(:description) => String.t() | nil,
                 required(:version) => String.t()
               }}
              | {:error, Error.t()}

  @callback layers(toolset :: term(), ctx :: term(), opts :: keyword()) :: [Layer.t()]

  defmacro __using__(_opts) do
    quote do
      @behaviour Noizu.MCP.Toolset.Behaviour

      # Fail-closed default for struct modules that don't produce specs (D5).
      def __toolset_specs__(_toolset, _ctx, _opts) do
        raise ArgumentError,
              "#{inspect(__MODULE__)} must implement __toolset_specs__/3 " <>
                "(or be a Noizu.MCP.Server with registered tools)"
      end

      def catalog(toolset, ctx, opts), do: Noizu.MCP.Toolset.Behaviour.catalog(toolset, ctx, opts)

      def resolve(toolset, name, ctx, opts),
        do: Noizu.MCP.Toolset.Behaviour.resolve(toolset, name, ctx, opts)

      def invoke(toolset, effective, args, ctx, opts),
        do: Noizu.MCP.Toolset.Behaviour.invoke(toolset, effective, args, ctx, opts)

      def permissions(toolset, ctx, opts),
        do: Noizu.MCP.Toolset.Behaviour.permissions(toolset, ctx, opts)

      def metadata(toolset, ctx, opts),
        do: Noizu.MCP.Toolset.Behaviour.metadata(toolset, ctx, opts)

      # Protocol-derived impls delegate here; the struct itself is dispatchable.
      def coerce(toolset), do: toolset

      # Context-pass seam (PRD-3 §4.2): no persisted layers until PRD-4's
      # persistence wiring (or a host override) provides them.
      def layers(_toolset, _ctx, _opts), do: []

      defoverridable __toolset_specs__: 3,
                     catalog: 3,
                     resolve: 4,
                     invoke: 5,
                     permissions: 3,
                     metadata: 3,
                     coerce: 1,
                     layers: 3
    end
  end

  # ── default implementations ───────────────────────────────────────────────

  @doc """
  Default catalog: identity materialization of `__toolset_specs__/3` (the
  `Overrides` merge with NO overrides), then the ACL pass
  (`Noizu.MCP.ACL.Provider.filter_entries/4`) — enforcement inside the
  default, so no caller can obtain an ungoverned listing (D1, PRD-2). Nothing
  is skipped here — hidden tools come back as `visible: false` entries; wire
  filtering happens in the callers.
  """
  def catalog(toolset, ctx, opts) do
    instrument(toolset, :catalog, fn ->
      case materialized(toolset, ctx, opts) do
        {:ok, pairs, version} ->
          {:ok, acl_entries(pairs, toolset, ctx, opts), version}

        {:error, %Error{}} = error ->
          error
      end
    end)
  end

  @doc """
  Default resolve: exact canonical-name match over the effective entries
  AFTER the ACL pass — a denied tool resolves to the identical invalid_params
  error as an absent one (existence-hiding), exactly like a hidden tool.
  Absent and non-callable tools return the identical invalid_params error —
  no discovery oracle for hidden tools. Dotted-name canonicalization is host
  domain, not lib.
  """
  def resolve(toolset, name, ctx, opts) do
    instrument(toolset, :resolve, fn ->
      case materialized(toolset, ctx, opts) do
        {:ok, pairs, version} ->
          entries = acl_entries(pairs, toolset, ctx, opts)

          case Enum.find(entries, fn entry -> entry.definition.name == name end) do
            %Entry{callable: true} = entry ->
              {_entry, spec} =
                Enum.find(pairs, fn {entry, _spec} -> entry.definition.name == name end)

              {:ok,
               %Effective{
                 name: entry.definition.name,
                 entry: entry,
                 spec: spec,
                 provenance: nil,
                 version: version,
                 reason: nil
               }}

            _ ->
              {:error, Error.invalid_params("Unknown tool: #{name}")}
          end

        {:error, %Error{}} = error ->
          error
      end
    end)
  end

  @doc """
  Default invoke — the relocated `run_spec`: validate against the EFFECTIVE
  schema, cast with the EFFECTIVE plan (wire-only renames via `wire_key` —
  handlers always receive original atom-keyed args), arity-dispatch, normalize.
  """
  def invoke(_toolset, %Effective{entry: entry, spec: spec} = effective, args, ctx, _opts) do
    case Schema.validate(entry.input_schema, args) do
      :ok ->
        args =
          case entry.cast_plan do
            nil -> args
            plan -> Fields.cast(plan, args)
          end

        call_args =
          case spec.arity do
            0 -> []
            1 -> [args]
            2 -> [args, ctx]
          end

        apply(spec.module, spec.fun, call_args) |> Tools.normalize(spec.output_schema)

      {:error, message} ->
        # SEP-1303: validation failures are execution errors the model can fix.
        ToolResult.error("Invalid arguments for tool #{effective.name}: #{message}")
    end
  end

  @doc "Default permissions: per-tool `{name, visible, callable}` projection over the effective entries — POST-ACL (PRD-2 FR-2.9), so hosts can audit denied tools here."
  def permissions(toolset, ctx, opts) do
    case materialized(toolset, ctx, opts) do
      {:ok, pairs, version} ->
        tools =
          acl_entries(pairs, toolset, ctx, opts)
          |> Enum.map(fn entry ->
            %{name: entry.definition.name, visible: entry.visible, callable: entry.callable}
          end)

        {:ok, %{tools: tools, version: version}}

      {:error, %Error{}} = error ->
        error
    end
  end

  @doc """
  Default metadata: raises until overridden — servers get a `__mcp__(:opts)`-backed
  version from `use Noizu.MCP.Server`; `%CustomToolset{}` fills this in a later PR.
  """
  def metadata(_toolset, _ctx, _opts) do
    raise ArgumentError,
          "Noizu.MCP.Toolset.Behaviour.metadata/3 has no struct default — override it " <>
            "(servers get one over __mcp__(:opts); %Noizu.MCP.Toolset.Custom{} lands in a later PR)"
  end

  @doc """
  Stable content hash over the effective spec set (§4.7): identical spec sets
  yield identical version strings across processes and runs; any
  definition/schema change — or a lib version change — yields a different one.
  """
  @spec catalog_version([Spec.t()]) :: String.t()
  def catalog_version(specs) do
    fingerprint =
      Enum.map(specs, fn spec ->
        {spec.definition.name, spec.definition.input_schema, spec.definition}
      end)

    sha16({:catalog, fingerprint, Application.spec(:noizu_mcp, :vsn)})
  end

  @doc """
  Composed-catalog version fingerprint (PRD-3 §4.4): sha256 over the toolset
  slug, the static version, and per-layer fingerprints (`{layer_id, weight,
  op_digest}` for the full version; `{layer_id, weight}` shapes for the
  pre-compose cache-key fingerprint). Truncated 16 hex chars, matching
  `catalog_version/1`.
  """
  @spec compose_version(String.t(), String.t(), [term()]) :: String.t()
  def compose_version(slug, static_version, layer_fingerprints) do
    sha16({:compose, slug, static_version, layer_fingerprints})
  end

  @doc """
  The PRD-1 entry mapping (§4.1): one `%Noizu.MCP.Toolset.Entry{}` per
  effective spec — definition, schema, cast plan, visibility/callability.
  Public so the `%Noizu.MCP.Toolset.Custom{}` composition shares the exact
  mapping with the behaviour defaults.
  """
  @spec entry_for(Spec.t()) :: Entry.t()
  def entry_for(%Spec{} = spec) do
    %Entry{
      definition: spec.definition,
      input_schema: spec.definition.input_schema,
      cast_plan: spec.cast_plan,
      visible: not spec.hidden,
      callable: spec.callable,
      reason: if(spec.hidden, do: :hidden_by_spec)
    }
  end

  @doc "sha256 of the term, truncated to 16 lowercase hex chars (§4.7)."
  @spec sha16(term()) :: String.t()
  def sha16(term) do
    :crypto.hash(:sha256, :erlang.term_to_binary(term))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  # ── internals ─────────────────────────────────────────────────────────────

  # The ACL enforcement pass over freshly-materialized entries (PRD-2): with
  # no provider configured this is identity (inert, back-compat); with one, it
  # governs listing AND dispatch (denied ⇒ visible/callable false). Called
  # inside the defaults so the shim paths are governed too (never decorative).
  defp acl_entries(pairs, toolset, ctx, opts) do
    entries = Enum.map(pairs, &elem(&1, 0))
    Noizu.MCP.ACL.Provider.filter_entries(entries, toolset, ctx, opts)
  end

  # Materialize the spec set once and pair each effective spec with its entry,
  # so catalog/resolve/permissions share one resolution path (D1).
  defp materialized(toolset, ctx, opts) do
    with {:ok, specs} <- apply_identity(toolset_specs(toolset, ctx, opts)) do
      version = catalog_version(specs)
      {:ok, Enum.map(specs, &{entry_for(&1), &1}), version}
    end
  end

  # Structs route through their module's function (a struct is a map — direct
  # `toolset.__toolset_specs__` would apply map values as funs); modules are atoms.
  defp toolset_specs(%{__struct__: module} = toolset, ctx, opts),
    do: module.__toolset_specs__(toolset, ctx, opts)

  defp toolset_specs(toolset, ctx, opts) when is_atom(toolset),
    do: toolset.__toolset_specs__(toolset, ctx, opts)

  defp toolset_specs(other, _ctx, _opts) do
    # Not a toolset entity at all — fail the set, not the server (D5).
    {:error, Error.internal("not a toolset entity: #{inspect(other)}")}
  end

  # PRD-1: identity materialization — `Overrides.apply(spec, [])` cannot fail
  # (the empty op set validates trivially), so an error arm here would be dead
  # code. PRD-3's merge engine threads real override sets through this seam
  # and owns the issue→Error mapping.
  defp apply_identity(specs) when is_list(specs) do
    {:ok,
     Enum.map(specs, fn spec ->
       {:ok, spec} = Overrides.apply(spec, [])
       spec
     end)}
  end

  defp apply_identity(other) do
    # __toolset_specs__/3 returned something other than a spec list — fail the
    # set, not the server (D5).
    {:error, Error.internal("toolset specs must be a list, got: #{inspect(other)}")}
  end

  defp instrument(toolset, event, fun) do
    started = System.monotonic_time()
    result = fun.()
    slug = telemetry_slug(toolset)

    :telemetry.execute(
      [:noizu_mcp, :toolset, event],
      %{duration: System.monotonic_time() - started},
      %{
        toolset: slug
      }
    )

    case result do
      {:error, %Error{} = error} ->
        # Client errors (unknown tool etc.) are normal traffic; only set-level
        # failures are logged.
        unless error.reason in [:invalid_params] do
          Logger.warning("toolset #{event} failed for #{inspect(slug)}: #{error.message}")
        end

        result

      _ ->
        result
    end
  end

  defp telemetry_slug(toolset) when is_atom(toolset), do: toolset
  defp telemetry_slug(%{__struct__: Noizu.MCP.Toolset.Ref, target: target}), do: target
  defp telemetry_slug(%{__struct__: module}), do: module
  defp telemetry_slug(other), do: other
end
