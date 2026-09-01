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
  alias Noizu.MCP.Toolset.{Layer, Override}

  require Logger

  @acl_weight 300

  @callback layers(toolset :: term(), ctx :: term(), opts :: keyword()) :: [Layer.t()]

  @doc """
  The persisted/host layers for this request (PRD seam): the toolset module's
  `layers/3` when it defines one, else `[]`. Direct call + UndefinedFunctionError
  normalization — no exported-function probing (house style, D4).
  """
  # ⟦𓃰𓎛𓋴𓄿⟧ layers :: The persisted/host layers for this request (PRD seam).
  @spec layers(toolset :: term(), ctx :: term(), opts :: keyword()) :: [Layer.t()]
  def layers(%{__struct__: module} = toolset, ctx, opts),
    do: toolset_layers(module, toolset, ctx, opts)

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
