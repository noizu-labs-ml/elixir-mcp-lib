defmodule Noizu.MCP.Toolset.Custom do
  @moduledoc """
  Declarative per-caller toolset (PRD-3 §4.1): a base surface + include/exclude
  + per-tool override ops, composed per request through the SAME
  `Noizu.MCP.Toolset` protocol every other participant serves (D1 — there is
  no parallel "custom listing" API).

  Composition is the three-pass pipeline (§4.4):

    1. **static** — expand `base` (module / `%Ref{}` / nested `%Custom{}`),
       drop `exclude`, apply `include`; the `tools` map flattens into a
       weight-100 layer under `{:static, slug}`;
    2. **context** — fold the ACL layer (always — immutability never defeats
       authorization) plus persisted layers (none in PRD-3; PRD-4's Store
       wires them at weight 200; `immutable: true` skips persisted layers
       but NEVER the ACL) on top through `Noizu.MCP.Toolset.Merge.fold/2`;
    3. **materialize** — the winning op set per tool materializes ONCE via
       `Noizu.MCP.Toolset.Overrides.apply/3` (D2); provenance attaches per
       applied op.

  Semantics (normative):

    * `tools` map keys are BASE canonical names (pre-rename); `:set_name`
      changes the wire name only — later layers still key the tool by base
      name; handlers still receive original-keyed args (wire-only rename).
    * `exclude` removes entries entirely (applied BEFORE `include`;
      `include: nil` = no filter).
    * Nested `%Custom{}` bases contribute their filtered specs plus their
      ops as a weight-100 layer under `{:static, inner_slug}`; their context
      pass never runs (one ACL pass per request); a slug cycle in the base
      chain ⇒ a `:cycle` issue (D5 disable).
    * `metadata` is a host extension map the lib never interprets — except
      the opt-in `cache: true | [ttl: ms]` read by `Noizu.MCP.Toolset.Cache`.

  Participation is explicit (D4, PRD-1 house style): `@derive` would delegate
  to the protocol's fail-closed `Any` impl, so the protocol impl below is
  written out delegating to this module's behaviour functions.
  """

  use Noizu.MCP.Toolset.Behaviour

  alias Noizu.MCP.Error
  alias Noizu.MCP.ACL.Provider

  alias Noizu.MCP.Toolset.{
    Behaviour,
    Cache,
    Context,
    Custom,
    Entry,
    Effective,
    Layer,
    Merge,
    Override,
    Overrides,
    Ref,
    Validator
  }

  @enforce_keys [:slug, :base]
  defstruct [
    :slug,
    :base,
    :title,
    :description,
    immutable: false,
    include: nil,
    exclude: [],
    tools: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          slug: String.t(),
          base: module() | Noizu.MCP.Toolset.Custom.t() | Ref.t(),
          title: String.t() | nil,
          description: String.t() | nil,
          immutable: boolean(),
          include: [String.t()] | nil,
          exclude: [String.t()],
          tools: %{optional(String.t()) => [Override.t()]},
          metadata: map() | list()
        }

  @default_weights [static: 100, persisted: 200, acl: 300]

  # ── the pipeline (§4.4) ───────────────────────────────────────────────────

  @doc """
  Compose the effective catalog: `{:ok, entries, version}` or
  `{:error, %Error{reason: :internal, data: %{toolset: slug, issues: [...]}}}`
  (D5 — an invalid custom toolset disables ITSELF, never the server).
  """
  # ⟦𓎼𓅱𓋴𓄿⟧ compose :: Compose the effective catalog.
  @spec compose(t(), term(), keyword()) ::
          {:ok, [Entry.t()], String.t()} | {:error, Error.t()}
  def compose(%Custom{} = toolset, ctx, opts) do
    case compose_full(toolset, ctx, opts) do
      {:ok, composed} -> {:ok, composed.entries, composed.version}
      {:error, %Error{}} = error -> error
    end
  end

  @doc """
  Full composition result: `{:ok, %{entries:, version:, provenance:, specs:}}`
  — the map `resolve/4` and the cache consume (entries + version are the PRD
  `compose/3` shape; provenance feeds `%Effective{}`; the materialized specs
  back `invoke/5`). Telemetry: `[:noizu_mcp, :toolset, :compose]` /
  `[:noizu_mcp, :toolset, :compose_error]` (FR-3.11).
  """
  # ⟦𓎼𓅱𓋴𓆑⟧ compose_full :: Full composition result.
  @spec compose_full(t(), term(), keyword()) ::
          {:ok,
           %{
             entries: [Entry.t()],
             version: String.t(),
             provenance: %{term() => %{Merge.slot() => {term(), integer()}}},
             specs: %{String.t() => Noizu.MCP.Server.Tool.Spec.t()}
           }}
          | {:error, Error.t()}
  def compose_full(%Custom{} = toolset, ctx, opts) do
    started = System.monotonic_time()

    case run(toolset, ctx, opts) do
      {:ok, composed, layer_count, cached?} ->
        :telemetry.execute(
          [:noizu_mcp, :toolset, :compose],
          %{duration: System.monotonic_time() - started},
          %{toolset: toolset.slug, layers: layer_count, cached: cached?}
        )

        {:ok, composed}

      {:error, issues, layer_count} ->
        :telemetry.execute(
          [:noizu_mcp, :toolset, :compose_error],
          %{duration: System.monotonic_time() - started},
          %{toolset: toolset.slug, layers: layer_count}
        )

        {:error,
         Error.internal("toolset composition failed for #{toolset.slug}", %{
           toolset: toolset.slug,
           issues: issues
         })}
    end
  end

  # ── protocol overrides ────────────────────────────────────────────────────

  @impl true
  def catalog(%Custom{} = toolset, ctx, opts) do
    case compose(toolset, ctx, opts) do
      {:ok, entries, version} -> {:ok, entries, version}
      {:error, %Error{}} = error -> error
    end
  end

  @impl true
  def resolve(%Custom{} = toolset, name, ctx, opts) do
    case compose_full(toolset, ctx, opts) do
      {:ok, %{entries: entries, provenance: provenance, specs: specs, version: version}} ->
        case Enum.find(entries, fn entry -> entry.definition.name == name end) do
          %Entry{callable: true} = entry ->
            {:ok,
             %Effective{
               name: name,
               entry: entry,
               spec: Map.fetch!(specs, name),
               provenance: Map.get(provenance, name),
               version: version,
               reason: nil
             }}

          _ ->
            # Identical error for absent and non-callable — no discovery
            # oracle (existence-hiding, PRD-1).
            {:error, Error.invalid_params("Unknown tool: #{name}")}
        end

      {:error, %Error{}} = error ->
        error
    end
  end

  @impl true
  def permissions(%Custom{} = toolset, ctx, opts) do
    case compose_full(toolset, ctx, opts) do
      {:ok, %{entries: entries, version: version}} ->
        tools =
          Enum.map(entries, fn entry ->
            %{name: entry.definition.name, visible: entry.visible, callable: entry.callable}
          end)

        {:ok, %{tools: tools, version: version}}

      {:error, %Error{}} = error ->
        error
    end
  end

  @impl true
  def metadata(%Custom{} = toolset, ctx, opts) do
    case compose_full(toolset, ctx, opts) do
      {:ok, %{version: version}} ->
        {:ok,
         %{
           slug: toolset.slug,
           title: toolset.title,
           description: toolset.description,
           version: version
         }}

      {:error, %Error{}} = error ->
        error
    end
  end

  # invoke/5 keeps the behaviour default — it consumes only the %Effective{}
  # this module's resolve/4 produces (D2).

  # ── internals: passes ─────────────────────────────────────────────────────

  # Returns {:ok, composed, layer_count, cached?} |
  #         {:error, issues, layer_count}
  defp run(toolset, ctx, opts) do
    case expand_base(toolset.base, ctx, opts, [toolset.slug]) do
      {:error, issues} ->
        {:error, issues, 0}

      {:ok, base_specs, nested_layers} ->
        filtered = filter_specs(base_specs, toolset.exclude, toolset.include)
        static_version = Behaviour.catalog_version(filtered)
        static_layer = static_layer(toolset)
        cache_cfg = cache_config(toolset, ctx, opts)

        cache_key =
          cache_cfg &&
            {toolset.slug, Cache.principal_hash(subject_for(ctx)),
             pre_version(toolset, static_version, nested_layers, ctx, opts)}

        # Opt-in memo (§4.6); validator errors and compose failures are never
        # cached (always re-checked — D5 paths stay observable).
        case cache_key && Cache.get(cache_key) do
          {:ok, composed} ->
            {:ok, composed, nil, true}

          _ ->
            case compose_passes(toolset, ctx, opts, filtered, nested_layers ++ [static_layer],
                   static_version: static_version,
                   base_specs: base_specs
                 ) do
              {:ok, composed, layer_count} ->
                if cache_key, do: Cache.put(cache_key, composed, cache_cfg)
                {:ok, composed, layer_count, false}

              {:error, issues, layer_count} ->
                {:error, issues, layer_count}
            end
        end
    end
  end

  # Passes 2+3: context fold → validate → materialize (§4.4 order).
  defp compose_passes(toolset, ctx, opts, filtered, static_and_nested, metadata) do
    static_version = Keyword.fetch!(metadata, :static_version)
    base_specs = Keyword.fetch!(metadata, :base_specs)

    context = context_layers(toolset, ctx, opts, filtered)
    layers = context ++ static_and_nested
    layer_count = length(layers)

    with {:ok, winners} <- Merge.fold(layers),
         # the Validator re-folds [static | context] itself — it must receive
         # ONLY the context layers or the static layer would fold twice
         :ok <- validated(toolset, base_specs, context, static_version) do
      case materialize(toolset, filtered, winners, layers, static_version) do
        {:ok, composed} ->
          {:ok, composed, layer_count}

        {:error, issues} ->
          {:error, issues, layer_count}
      end
    else
      {:error, issues} ->
        {:error, issues, layer_count}
    end
  end

  # ACL always; persisted layers (the toolset's layers/3 seam + explicit
  # `:context_layers` opts) only when the toolset is mutable.
  defp context_layers(toolset, ctx, opts, filtered) do
    acl = acl_layer(filtered, ctx, opts)

    persisted =
      if toolset.immutable do
        []
      else
        Context.layers(toolset, ctx, opts) ++ Keyword.get(opts, :context_layers, [])
      end

    List.wrap(acl) ++ persisted
  end

  defp acl_layer(entries, ctx, opts) do
    server = if is_map(ctx), do: Map.get(ctx, :server)

    case Provider.resolve_provider(server, opts) do
      nil -> nil
      {provider, check_opts} -> Context.acl_layer(entries, provider, check_opts, ctx)
    end
  end

  defp static_layer(toolset) do
    %Layer{
      id: {:static, toolset.slug},
      weight: @default_weights[:static],
      ops: flatten_tools(toolset.tools)
    }
  end

  # ── internals: base expansion (pass 1) ────────────────────────────────────

  # Module bases expand via __toolset_specs__/3 (D3 — per compose call, never
  # compile-captured); nested %Custom{} bases recurse STATIC-ONLY with cycle
  # detection over the slug chain.
  defp expand_base(base, ctx, opts, chain)

  defp expand_base(%Ref{target: target}, ctx, opts, chain),
    do: expand_base(target, ctx, opts, chain)

  defp expand_base(%Custom{} = inner, ctx, opts, chain) do
    if inner.slug in chain do
      {:error, [cycle_issue(chain, inner.slug)]}
    else
      with {:ok, specs, layers} <- expand_base(inner.base, ctx, opts, [inner.slug | chain]) do
        filtered = filter_specs(specs, inner.exclude, inner.include)
        {:ok, filtered, layers ++ [static_layer(inner)]}
      end
    end
  end

  defp expand_base(base, ctx, opts, _chain) when is_atom(base) and base != nil do
    case base.__toolset_specs__(base, ctx, opts) do
      specs when is_list(specs) -> {:ok, specs, []}
      other -> {:error, [base_issue("toolset specs must be a list, got: #{inspect(other)}")]}
    end
  rescue
    e in UndefinedFunctionError ->
      if e.module == base and e.function == :__toolset_specs__ do
        {:error, [base_issue("#{inspect(base)} does not implement __toolset_specs__/3")]}
      else
        reraise e, __STACKTRACE__
      end
  end

  defp expand_base(other, _ctx, _opts, _chain) do
    {:error, [base_issue("unsupported toolset base: #{inspect(other)}")]}
  end

  defp cycle_issue(chain, slug) do
    %Validator.Issue{
      code: :cycle,
      message: "nested-base slug cycle at #{inspect(slug)} (chain: #{inspect(chain)})",
      op: nil,
      tool: nil,
      field: nil,
      meta: %{chain: Enum.reverse(chain), slug: slug}
    }
  end

  defp base_issue(message) do
    %Validator.Issue{
      code: :unknown_base,
      message: message,
      op: nil,
      tool: nil,
      field: nil,
      meta: nil
    }
  end

  # ── internals: filtering, flattening, validation ──────────────────────────

  # exclude first, then include (nil = no filter). Names are base canonical
  # names — renames never participate (§4.1).
  defp filter_specs(specs, exclude, include) do
    excluded = MapSet.new(List.wrap(exclude || []))

    specs
    |> Enum.reject(fn spec -> MapSet.member?(excluded, spec.definition.name) end)
    |> then(fn specs ->
      if include == nil do
        specs
      else
        wanted = MapSet.new(include)
        Enum.filter(specs, fn spec -> MapSet.member?(wanted, spec.definition.name) end)
      end
    end)
  end

  # %{base-name => [%Override{}]} → flat ops carrying their tool context.
  # Non-Override entries pass through for Merge to flag (:invalid_op).
  # Public: the Validator folds the same static layer the pipeline does.
  # ⟦𓆋𓃭𓏏𓏏⟧ flatten_tools :: auto-generated pointer for public function flatten_tools
  @doc false
  def flatten_tools(tools)
  def flatten_tools(tools) when tools in [%{}, nil], do: []

  def flatten_tools(tools) when is_map(tools) do
    Enum.flat_map(tools, fn
      {name, ops} when is_binary(name) and is_list(ops) ->
        Enum.flat_map(ops, fn
          %Override{} = op -> [%{op | tool: name}]
          other -> [other]
        end)

      _other ->
        []
    end)
  end

  def flatten_tools(_other), do: []

  # Validator gate: compile/3 on the FIRST compose of a %Custom{} per process
  # (§4.5) — positive results memoize in the process dictionary keyed on the
  # exact layer digests; NEGATIVE results always re-check (never cached).
  defp validated(toolset, base_specs, layers, static_version) do
    key = {__MODULE__, :validator_ok, toolset.slug, static_version, layer_digests(layers)}

    case Process.get(key) do
      :ok ->
        :ok

      _ ->
        base_entries = Enum.map(base_specs, &Behaviour.entry_for/1)

        case Validator.compile(toolset, base_entries, layers: layers) do
          {:ok, _warnings} ->
            Process.put(key, :ok)
            :ok

          {:error, issues} ->
            {:error, issues}
        end
    end
  end

  defp layer_digests(layers) do
    Enum.map(layers, fn %Layer{id: id, weight: weight, ops: ops} ->
      {id, weight, Behaviour.sha16({:ops, id, ops})}
    end)
  end

  # ── internals: materialization (pass 3) ───────────────────────────────────

  # One materialization per tool (D2): the full winning op set applies to a
  # fresh spec; the pre-ACL spec is materialized alongside so ACL-denied
  # entries can preserve a pre-existing denial reason (PRD-2 filter_entries
  # semantics through the layer).
  defp materialize(toolset, filtered, winners, layers, static_version) do
    by_tool =
      Enum.group_by(winners, fn {{tool, _op, _field}, _win} -> tool end, fn {slot, {op, prov}} ->
        {slot, op, prov}
      end)

    {entries, specs, provenance, issues} =
      Enum.reduce(filtered, {[], %{}, %{}, []}, fn spec, {entries, specs, provenance, issues} ->
        name = spec.definition.name
        ops = Map.get(by_tool, name, [])
        op_values = Enum.map(ops, fn {_slot, op, _prov} -> op end)

        acl_ops =
          Enum.filter(ops, fn {_slot, _op, {layer_id, _w}} -> match?({:acl, _}, layer_id) end)

        acl_values = Enum.map(acl_ops, fn {_slot, op, _prov} -> op end)

        with {:ok, final_spec} <- Overrides.apply(spec, op_values),
             {:ok, pre_spec} <- Overrides.apply(spec, op_values -- acl_values) do
          entry =
            final_spec
            |> Behaviour.entry_for()
            |> with_acl_reason(pre_spec, acl_ops)

          tool_provenance =
            Map.new(ops, fn {slot, _op, {layer_id, w}} -> {slot, {layer_id, w}} end)

          {[entry | entries], Map.put(specs, entry.definition.name, final_spec),
           Map.put(provenance, entry.definition.name, tool_provenance), issues}
        else
          {:error, apply_issues} ->
            {entries, specs, provenance, issues ++ apply_issues}
        end
      end)

    if issues == [] do
      version = compose_version(toolset, layers, static_version)

      {:ok,
       %{
         entries: Enum.reverse(entries),
         version: version,
         provenance: provenance,
         specs: specs
       }}
    else
      {:error, issues}
    end
  end

  # ACL deny ⇒ visible/callable false is already materialized; the reason
  # follows PRD-2's deny_entry: preserve a pre-existing non-nil denial
  # reason, else attribute to {:acl, provider}.
  defp with_acl_reason(entry, _pre_spec, []), do: entry

  defp with_acl_reason(entry, pre_spec, acl_ops) do
    pre_entry = Behaviour.entry_for(pre_spec)
    already_denied? = pre_entry.visible == false or pre_entry.callable == false

    reason =
      cond do
        already_denied? and not is_nil(pre_entry.reason) -> pre_entry.reason
        true -> acl_reason(acl_ops)
      end

    %{entry | reason: reason}
  end

  defp acl_reason([{_slot, _op, {layer_id, _w}} | _rest]), do: layer_id

  defp compose_version(toolset, layers, static_version) do
    fingerprints =
      Enum.map(layers, fn %Layer{id: id, weight: weight, ops: ops} ->
        {id, weight, Behaviour.sha16({:ops, id, ops})}
      end)

    Behaviour.compose_version(toolset.slug, static_version, fingerprints)
  end

  # ── internals: cache (opt-in, §4.6) ───────────────────────────────────────

  # Cache KEY's catalog_version component is the PRE-compose fingerprint
  # ({slug, static_version, layer shapes}): the full composed version needs
  # the folded ops, so it cannot be known before composing; the
  # pre-fingerprint changes whenever the static surface, the principal, or
  # the layer structure changes.
  defp pre_version(toolset, static_version, nested_layers, ctx, opts) do
    acl_shape =
      case provider_shape(ctx, opts) do
        nil -> []
        {provider, _check_opts} -> [{:acl, provider}]
      end

    persisted_shapes =
      if toolset.immutable do
        []
      else
        persisted = Context.layers(toolset, ctx, opts) ++ Keyword.get(opts, :context_layers, [])
        Enum.map(persisted, fn %Layer{id: id, weight: weight} -> {id, weight} end)
      end

    Behaviour.compose_version(
      toolset.slug,
      static_version,
      [{:nested, Enum.map(nested_layers, &{&1.id, &1.weight})}] ++ acl_shape ++ persisted_shapes
    )
  end

  defp provider_shape(ctx, opts) do
    server = if is_map(ctx), do: Map.get(ctx, :server)
    Provider.resolve_provider(server, opts)
  end

  # Opt-in only (FR-3.6): `toolset_cache:` server opt, `metadata` cache key,
  # or explicit `:cache` compose opts — `true` or `[ttl: ms]`.
  defp cache_config(toolset, ctx, opts) do
    configured =
      Keyword.get(opts, :cache) || meta_get(toolset.metadata, :cache) || server_cache_opt(ctx)

    cond do
      configured == true -> [ttl: default_ttl()]
      is_list(configured) and configured != [] -> Keyword.put_new(configured, :ttl, default_ttl())
      true -> nil
    end
  end

  defp default_ttl, do: Application.get_env(:noizu_mcp, :toolset_cache_ttl, 60_000)

  defp server_cache_opt(ctx) do
    server = if is_map(ctx), do: Map.get(ctx, :server)

    if is_atom(server) and server != nil do
      try do
        server.__mcp__(:opts)[:toolset_cache]
      rescue
        _ -> nil
      end
    else
      nil
    end
  end

  defp subject_for(%{auth: principal}), do: principal
  defp subject_for(_ctx), do: nil

  # metadata is a host extension map (§4.1); §4.6 sketches it as either a map
  # or a keyword list — both are read.
  defp meta_get(metadata, key) when is_map(metadata), do: Map.get(metadata, key)
  defp meta_get(metadata, key) when is_list(metadata), do: Keyword.get(metadata, key)
  defp meta_get(_metadata, _key), do: nil
end

defimpl Noizu.MCP.Toolset, for: Noizu.MCP.Toolset.Custom do
  @moduledoc false
  # Explicit delegation to the struct module's behaviour functions (the
  # Behaviour injects them; hosts may override any of them). NOT @derive —
  # derive would delegate to the protocol's fail-closed `Any` impl (D4).

  def coerce(%Noizu.MCP.Toolset.Custom{} = toolset), do: toolset

  def catalog(%Noizu.MCP.Toolset.Custom{} = toolset, ctx, opts),
    do: Noizu.MCP.Toolset.Custom.catalog(toolset, ctx, opts)

  def resolve(%Noizu.MCP.Toolset.Custom{} = toolset, name, ctx, opts),
    do: Noizu.MCP.Toolset.Custom.resolve(toolset, name, ctx, opts)

  def invoke(%Noizu.MCP.Toolset.Custom{} = toolset, effective, args, ctx, opts),
    do: Noizu.MCP.Toolset.Custom.invoke(toolset, effective, args, ctx, opts)

  def permissions(%Noizu.MCP.Toolset.Custom{} = toolset, ctx, opts),
    do: Noizu.MCP.Toolset.Custom.permissions(toolset, ctx, opts)

  def metadata(%Noizu.MCP.Toolset.Custom{} = toolset, ctx, opts),
    do: Noizu.MCP.Toolset.Custom.metadata(toolset, ctx, opts)
end
