defmodule Noizu.MCP.Toolset.Layer do
  @moduledoc """
  One opinion-set in the composition context pass (PRD-3 §4.2): a batch of
  override ops that all speak with one `weight` under one `id`.

    * `id` — `term()`, provenance identity (e.g. `{:static, slug}`,
      `{:persisted, grant_id}`, `{:acl, provider_module}`);
    * `weight` — integer(); built-in defaults: static 100, persisted 200,
      ACL 300;
    * `ops` — `[%Noizu.MCP.Toolset.Override{}]` targeting base canonical
      names; the fold normalizes each op's `weight`/`layer` to the layer's,
      so authors set them here, not on the op. Field-level ops must carry the
      base tool name in the op's `tool` field.
  """

  @enforce_keys [:id, :weight, :ops]
  defstruct [:id, :weight, :ops]

  @type t :: %__MODULE__{
          id: term(),
          weight: integer(),
          ops: [Noizu.MCP.Toolset.Override.t()]
        }
end

defmodule Noizu.MCP.Toolset.Context do
  @moduledoc """
  The context pass seam (PRD-3 §4.2): the layers a request folds on top of the
  static surface.

  Two layers of API:

    * `layers/3` — the PRD seam. Returns the toolset module's PERSISTED
      layers (the `layers/3` behaviour callback — `[]` until PRD-4's
      persistence wiring provides a richer default). Hosts and PRD-4
      override the callback on their toolset module; the lib never scans
      for implementors (D4).
    * `layers/4` — the composition entry: the ACL layer built over
      `entries` (always — immutability never defeats authorization) plus the
      persisted layers. `%Noizu.MCP.Toolset.Custom{}`'s pipeline calls this.
    * `acl_layer/4` + `project_acl/2` — the ACL re-home (§4.2): PRD-2's
      `ACL.Provider.filter_entries/4` denial vocabulary — per denied tool,
      `:set_visible false` + `:set_callable false` at weight 300 under
      `{:acl, provider}` — is defined HERE, once, and both the PRD-2 choke
      point and the PRD-3 composition consume it.
  """

  alias Noizu.MCP.ACL.Provider
  alias Noizu.MCP.Auth.Principal
  alias Noizu.MCP.ACL.Resource
  alias Noizu.MCP.Persistence
  alias Noizu.MCP.Toolset.{Layer, Override}

  require Logger

  @acl_weight 300
  @persisted_weight 200

  @callback layers(toolset :: term(), ctx :: term(), opts :: keyword()) :: [Layer.t()]

  @doc """
  The persisted/host layers for this request (PRD seam): the toolset module's
  `layers/3` when it defines one — plus the PERSISTED layers (PRD-4 §4.5:
  grant + negotiation layers at weight 200) whenever the resolved provider is
  enabled and the toolset is mutable. Direct call + UndefinedFunctionError
  normalization — no exported-function probing (house style, D4).
  """
  # ⟦𓃰𓎛𓋴𓄿⟧ layers :: The persisted/host layers for this request (PRD seam).
  @spec layers(toolset :: term(), ctx :: term(), opts :: keyword()) :: [Layer.t()]
  def layers(%{__struct__: module} = toolset, ctx, opts),
    do: toolset_layers(module, toolset, ctx, opts) ++ persisted(toolset, ctx, opts).layers

  def layers(toolset, ctx, opts) when is_atom(toolset),
    do: toolset_layers(toolset, toolset, ctx, opts)

  def layers(_toolset, _ctx, _opts), do: []

  @doc """
  The full default seam for one request (§4.2): the ACL layer built over
  `entries` — ALWAYS (security invariant; `immutable` handling is the
  pipeline's concern, not the seam's) — plus the persisted layers. Layers
  arrive unordered; weights decide.
  """
  # ⟦𓋹𓊽𓂝𓆗⟧ layers :: The full default seam for one request (§4.2).
  @spec layers(toolset :: term(), entries :: list(), ctx :: term(), opts :: keyword()) ::
          [Layer.t()]
  def layers(toolset, entries, ctx, opts) do
    server = if is_map(ctx), do: Map.get(ctx, :server)

    acl =
      case Provider.resolve_provider(server, opts) do
        nil -> nil
        {provider, check_opts} -> acl_layer(entries, provider, check_opts, ctx)
      end

    List.wrap(acl) ++ layers(toolset, ctx, opts)
  end

  @doc """
  ACL as a weight-300 override layer (PRD-2 re-home, §4.2): one
  `:set_visible false` + one `:set_callable false` op per DENIED entry,
  `nil` when no provider governs the call (inert, back-compat).

  Provider crash ⇒ deny EVERY entry for this call (fail-closed, D5) with the
  `[:noizu_mcp, :acl, :error]` telemetry PRD-2 established. A
  `supported_kinds` violation raises through — configuration error (§4.7).
  """
  # ⟦𓂝𓎸𓊨𓄢⟧ acl_layer :: ACL as a weight-300 override layer (PRD-2 re-home, §4.2).
  @spec acl_layer(
          entries :: list(),
          provider :: module(),
          check_opts :: keyword(),
          ctx :: term()
        ) ::
          Layer.t() | nil
  def acl_layer([], _provider, _check_opts, _ctx), do: nil

  def acl_layer(entries, provider, check_opts, ctx) do
    # Kind gate raises THROUGH (config error, §4.7) — only provider crashes
    # are denied-and-logged below. The resource id is irrelevant to the gate.
    Provider.ensure_kind!(provider, %Resource{kind: :tool, id: ""})

    resources = Enum.map(entries, &%Resource{kind: :tool, id: &1.definition.name})
    verdicts = verdicts(provider, subject_for(ctx), resources, ctx, check_opts, entries)

    denied? = fn entry -> Map.get(verdicts, entry.definition.name) != :allow end

    ops =
      Enum.flat_map(entries, fn entry ->
        if denied?.(entry) do
          name = entry.definition.name

          [
            %Override{
              op: :set_visible,
              target: name,
              tool: name,
              value: false,
              weight: @acl_weight,
              layer: {:acl, provider}
            },
            %Override{
              op: :set_callable,
              target: name,
              tool: name,
              value: false,
              weight: @acl_weight,
              layer: {:acl, provider}
            }
          ]
        else
          []
        end
      end)

    %Layer{id: {:acl, provider}, weight: @acl_weight, ops: ops}
  end

  @doc """
  Project an `acl_layer/4` result onto entries (PRD-2 `filter_entries`
  semantics, byte-identical): denied entries become `visible: false,
  callable: false`; a pre-existing non-nil denial reason is preserved, else
  the reason is `{:acl, provider}`. `nil` layer (no provider) is identity.
  """
  # ⟦𓋴𓄿𓂝𓎼⟧ project_acl :: Project an `acl_layer/4` result onto entries (PRD-2 `filter_entries` semantics, byte-identical).
  @spec project_acl(entries :: list(), layer :: Layer.t() | nil) :: list()
  def project_acl(entries, nil), do: entries

  def project_acl(entries, %Layer{id: {:acl, provider}, ops: ops}) do
    denied = MapSet.new(ops, & &1.target)

    Enum.map(entries, fn entry ->
      if MapSet.member?(denied, entry.definition.name) do
        already_denied? = entry.visible == false or entry.callable == false

        %{
          entry
          | visible: false,
            callable: false,
            reason:
              if(already_denied? and not is_nil(entry.reason),
                do: entry.reason,
                else: {:acl, provider}
              )
        }
      else
        entry
      end
    end)
  end

  # ── persisted layers (PRD-4 §4.5) ─────────────────────────────────────────

  @doc """
  The persisted state for one request (§4.5, PRD-4): the grant and
  negotiation layers at weight 200 PLUS the per-tool negotiation state and
  per-store versions the composition needs (reasons, the honest `:forbidden`
  error data, and version rotation without record reads — FR-4.11). One
  provider pass per compose.

  Shape:

      %{
        layers: [Layer.t()],           # weight-200 persisted layers
        versions: %{store_key => v},   # provider version strings (fingerprint)
        negotiations: %{tool => %{required:, missing:, granted:, metadata_overrides:, negotiation: %{id, metadata} | nil}},
        disabled?: boolean,            # the Disabled policy — silent skip (D5)
        degraded?: boolean             # provider FAILURE — degraded, logged + telemetry (D5)
      }

  D5 fail-closed-per-set: an enabled provider's `{:error, _}` or raise means
  this toolset composes WITHOUT persisted layers (Logger.warning +
  `[:noizu_mcp, :persistence, :error]` telemetry), server healthy. The
  Disabled provider is NOT an outage — a policy of no persisted layers,
  skipped silently.
  """
  # ⟦𓊪𓅱𓂋𓋴𓇋𓋴𓏏𓅂𓂧⟧ persisted :: The persisted state for one request (§4.5, PRD-4).
  @spec persisted(toolset :: term(), ctx :: term(), opts :: keyword()) :: %{
          layers: [Layer.t()],
          versions: map(),
          negotiations: map(),
          disabled?: boolean(),
          degraded?: boolean()
        }
  def persisted(toolset, ctx, opts)

  def persisted(%{immutable: true}, _ctx, _opts) do
    # PRD-3 §4.1: immutable toolsets ignore grants/negotiations (still
    # ACL-checked — the ACL layer never runs through here).
    empty_persisted()
  end

  def persisted(%{slug: slug} = toolset, ctx, opts) when is_binary(slug) do
    server = if is_map(ctx), do: Map.get(ctx, :server)

    case Persistence.resolved(server, opts) do
      nil ->
        empty_persisted()

      {provider, popts} ->
        if Persistence.enabled?({provider, popts}) do
          build_persisted(toolset, provider, popts, ctx)
        else
          %{empty_persisted() | disabled?: true}
        end
    end
  end

  def persisted(_toolset, _ctx, _opts), do: empty_persisted()

  defp empty_persisted do
    %{layers: [], versions: %{}, negotiations: %{}, disabled?: false, degraded?: false}
  end

  defp build_persisted(toolset, provider, popts, ctx) do
    slug = toolset.slug
    principal = subject_for(ctx)

    # Grants are per-principal (§4.5: no principal ⇒ NO grant layers at all —
    # an unkeyed filter would leak every subject's grants into an anonymous
    # composition). Negotiations gate TOOLS (consent is about the tool):
    # keyed by authenticator with a principal, toolset-wide for anonymous
    # callers (AC-4.3's anonymous ⇒ forbidden flow).
    grant_filter =
      case principal do
        %Principal{} = p ->
          %{toolset_slug: slug, authenticator: p.authenticator}
          |> put_subject(p)

        _anonymous ->
          :skip
      end

    negotiation_filter =
      case principal do
        %Principal{} = p ->
          %{toolset_slug: slug, authenticator: p.authenticator}

        _anonymous ->
          %{toolset_slug: slug}
      end

    grants_result =
      case grant_filter do
        :skip -> {:ok, []}
        filter -> fetch(provider, "toolset_grants", filter, popts, slug)
      end

    with {:ok, grants} <- grants_result,
         {:ok, negotiations} <-
           fetch(provider, "toolset_negotiations", negotiation_filter, popts, slug),
         {:ok, grants_version} <- store_version(provider, "toolset_grants", popts),
         {:ok, negotiations_version} <-
           store_version(provider, "toolset_negotiations", popts),
         {:ok, toolsets_version} <- store_version(provider, "toolsets", popts) do
      allow_grants = Enum.filter(grants, &(&1.effect == :allow))
      deny_grants = Enum.filter(grants, &(&1.effect == :deny))

      # Effective scopes = Principal.granted_scopes ∪ allow-grant scopes
      # (§4.5) — negotiation satisfaction checks against the union, glob rules
      # per Principal.has_scope?/2.
      effective =
        effective_scopes(principal, Enum.flat_map(allow_grants, & &1.scopes))

      layers =
        Enum.flat_map(allow_grants, &allow_layer/1) ++
          Enum.flat_map(deny_grants, &deny_layer/1)

      {negotiation_layers, negotiation_state} =
        negotiation_ops(negotiations, effective)

      %{
        layers: layers ++ negotiation_layers,
        versions: %{
          "toolsets" => toolsets_version,
          "toolset_grants" => grants_version,
          "toolset_negotiations" => negotiations_version
        },
        negotiations: negotiation_state,
        disabled?: false,
        degraded?: false
      }
    else
      {:error, reason} ->
        degrade(provider, slug, reason)
    end
  rescue
    e -> degrade(provider, toolset.slug, e)
  end

  defp fetch(provider, store_key, filter, popts, _slug) do
    case provider.list(store_key, filter, popts) do
      {:ok, records} -> {:ok, records}
      {:error, reason} -> {:error, {store_key, reason}}
    end
  catch
    kind, reason -> {:error, {store_key, {kind, reason}}}
  end

  defp put_subject(filter, %Principal{subject: nil}), do: filter
  defp put_subject(filter, %Principal{subject: subject}), do: Map.put(filter, :subject, subject)

  defp store_version(provider, store_key, popts) do
    case provider.version(store_key, popts) do
      {:ok, version} -> {:ok, version}
      {:error, reason} -> {:error, {store_key, reason}}
    end
  catch
    kind, reason -> {:error, {store_key, {kind, reason}}}
  end

  # :allow grants ADD to the surface — their ops (renames, re-descriptions,
  # field-level adjustments) land at weight 200 under {:persisted, grant_id};
  # grant scopes joined the effective scope set above. Grants NEVER HIDE
  # (AP-10): an allow grant only adjusts/extends. Tool-level ops may omit
  # `target` in the record — the tools-map key supplies it (same shape as
  # %Custom{} tools maps).
  defp allow_layer(grant) do
    ops =
      grant.tool_overrides
      |> Enum.flat_map(fn {tool, op_maps} ->
        Enum.map(List.wrap(op_maps), fn op ->
          %Override{
            op: op.op,
            target: op.target || if(Override.field_op?(op.op), do: op.target, else: tool),
            value: op.value,
            tool: tool,
            inherit?: op.inherit?
          }
        end)
      end)

    [%Layer{id: {:persisted, grant.id}, weight: @persisted_weight, ops: ops}]
  end

  # :deny grants deny EXACTLY the tools their tool_overrides target (explicit
  # participation — an empty map denies nothing; inventing whole-surface
  # semantics from an absent target list would contradict D4). Weight 200
  # overrides static (100); ACL (300) still wins over them.
  defp deny_layer(grant) do
    ops =
      grant.tool_overrides
      |> Enum.flat_map(fn {tool, _ops} ->
        [
          %Override{op: :set_visible, target: tool, tool: tool, value: false},
          %Override{op: :set_callable, target: tool, tool: tool, value: false}
        ]
      end)

    [%Layer{id: {:persisted, grant.id}, weight: @persisted_weight, ops: ops}]
  end

  # Per tool: most recent negotiation wins (list order is inserted_at desc —
  # the store's contract). Unsatisfied ⇒ the tool stays VISIBLE (consent UX
  # needs discovery, Q2) but callable false at weight 200; satisfaction by
  # scope or by granted ⇒ callable, and metadata_overrides fold ONLY when
  # granted.
  defp negotiation_ops(negotiations, effective) do
    negotiations
    |> Enum.uniq_by(& &1.tool)
    |> Enum.reduce({[], %{}}, fn neg, {layers, state} ->
      missing = Enum.reject(neg.required_scopes, &scope_covered?(&1, effective))
      satisfied? = neg.granted == true or missing == []

      cond do
        satisfied? and neg.granted == true ->
          {layers,
           Map.put(state, neg.tool, %{
             required: neg.required_scopes,
             missing: [],
             granted: true,
             metadata_overrides: neg.metadata_overrides,
             negotiation: %{id: neg.id, metadata: neg.metadata}
           })}

        satisfied? ->
          {layers,
           Map.put(state, neg.tool, %{
             required: neg.required_scopes,
             missing: [],
             granted: false,
             metadata_overrides: %{},
             negotiation: %{id: neg.id, metadata: neg.metadata}
           })}

        true ->
          ops = [
            %Override{
              op: :set_callable,
              target: neg.tool,
              tool: neg.tool,
              value: false
            }
          ]

          layer = %Layer{id: {:negotiation, neg.id}, weight: @persisted_weight, ops: ops}

          {[layer | layers],
           Map.put(state, neg.tool, %{
             required: neg.required_scopes,
             missing: missing,
             granted: false,
             metadata_overrides: %{},
             negotiation: %{id: neg.id, metadata: neg.metadata}
           })}
      end
    end)
  end

  # Provider failure ⇒ this toolset composes static+ACL only, loudly (D5).
  defp degrade(provider, slug, reason) do
    Logger.warning(
      "Persistence provider #{inspect(provider)} failed for toolset #{inspect(slug)} — " <>
        "composing without persisted layers: #{inspect(reason)}"
    )

    :telemetry.execute([:noizu_mcp, :persistence, :error], %{}, %{
      provider: provider,
      toolset: slug,
      reason: reason
    })

    %{empty_persisted() | degraded?: true}
  end

  # Principal scopes ∪ allow-grant scopes, as a list of strings.
  defp effective_scopes(nil, grant_scopes), do: grant_scopes

  defp effective_scopes(%Principal{} = principal, grant_scopes) do
    Enum.uniq(Principal.scope_list(principal) ++ grant_scopes)
  end

  # Requirement satisfaction over the effective scope LIST: a required scope
  # is covered by an exact match, a granted bare `*`, or a granted trailing-`*`
  # prefix glob ("pm:*" covers "pm:write") — the glob lives on the GRANTED
  # side, mirroring Principal.has_scope?/2 semantics.
  defp scope_covered?(required, effective) when is_binary(required) do
    Enum.any?(effective, fn granted ->
      cond do
        granted == "*" ->
          true

        String.ends_with?(granted, "*") ->
          prefix = binary_part(granted, 0, byte_size(granted) - 1)
          String.starts_with?(required, prefix)

        true ->
          granted == required
      end
    end)
  end

  # ── internals ─────────────────────────────────────────────────────────────

  # The toolset module's layers/3 when defined, else [] (house style, D4:
  # direct call, normalize only the expected miss).
  defp toolset_layers(module, toolset, ctx, opts) do
    module.layers(toolset, ctx, opts)
  rescue
    e in UndefinedFunctionError ->
      if e.module == module and e.function == :layers and e.arity == 3 do
        []
      else
        reraise e, __STACKTRACE__
      end
  end

  # Provider crash ⇒ deny the set, not the server (D5) — same rescue
  # boundary and telemetry shape PRD-2's filter_entries established.
  defp verdicts(provider, subject, resources, ctx, check_opts, entries) do
    Provider.check_all(provider, subject, resources, :call, ctx, check_opts)
  rescue
    e ->
      Logger.warning(
        "ACL provider #{inspect(provider)} raised — denying #{length(entries)} entries: " <>
          Exception.message(e)
      )

      :telemetry.execute([:noizu_mcp, :acl, :error], %{}, %{
        provider: provider,
        entries: length(entries),
        message: Exception.message(e)
      })

      %{}
  end

  defp subject_for(%{auth: %Principal{} = principal}), do: principal
  defp subject_for(_ctx), do: nil
end
