defmodule Noizu.MCP.Toolset.Validator.Issue do
  @moduledoc """
  One structural problem found while materializing overrides onto a spec or
  compiling a custom toolset.

  Issues are *returned*, never raised — `Noizu.MCP.Toolset.Overrides.apply/3`
  collects them per op and `Noizu.MCP.Toolset.Validator.compile/3` collects
  them per check, so hosts can surface actionable messages.
  """

  defstruct [:code, :message, :op, :tool, :field, :meta]

  @type t :: %__MODULE__{
          code: atom(),
          message: String.t(),
          op: atom() | nil,
          tool: String.t() | nil,
          field: atom() | nil,
          meta: map() | nil
        }
end

defmodule Noizu.MCP.Toolset.Validator do
  @moduledoc """
  Pure, DB-free validation of a `%Noizu.MCP.Toolset.Custom{}` against its
  BASE catalog (PRD-3 §4.5): `compile/3` runs on the first compose of a
  custom toolset per process (positive results memoize by exact layer
  digests; negative results always re-check) and a failing compile disables
  THAT toolset (D5) — validators never take a server down.

  No DB, no ETS, no env: same `(toolset, base_entries, layers)` ⇒ same
  result. Per-op structural checks (unknown field, rename collision,
  `prune_enum` non-enum target, …) stay with
  `Noizu.MCP.Toolset.Overrides.apply/3` (PRD-1); compile/3 owns the
  cross-tool and cross-layer checks of §4.5 — plus the fold-surfaced
  `:weight_conflict`.

  Scope note: the structural checks cover the custom toolset's OWN `tools`
  ops (what the host authored); context-layer ops are their authors'
  contract and are checked at materialization. Winner-dependent checks
  (charset, effective-name collision, same-value redundancy) evaluate the
  folded winners so layering is respected.
  """

  alias Noizu.MCP.Toolset.{Custom, Layer, Merge, Override}
  alias Noizu.MCP.Toolset.Validator.Issue

  @name_charset ~r/^[a-zA-Z0-9_-]{1,64}$/

  # Noizu.MCP.Server.Tool.Fields @scalar_types — duplicated as a literal so
  # the validator stays pure and dependency-free.
  @scalar_types [:string, :integer, :number, :boolean]

  @doc """
  Validate `toolset` against `base_entries` — the EXPANDED, unfiltered base
  catalog (`[%Noizu.MCP.Toolset.Entry{}]`). `opts[:layers]` folds into the
  weight-conflict and winner-dependent checks when the pipeline passes the
  request's layers. Returns `{:ok, warnings}` (non-fatal notes) or
  `{:error, issues}`.
  """
  # ⟦𓋴𓎼𓄿𓆑⟧ compile :: Validate `toolset` against `base_entries` — the EXPANDED, unfiltered base catalog.
  @spec compile(Custom.t(), [Noizu.MCP.Toolset.Entry.t()], keyword()) ::
          {:ok, [String.t()]} | {:error, [Issue.t()]}
  def compile(%Custom{} = toolset, base_entries, opts \\ []) when is_list(base_entries) do
    by_name = Map.new(base_entries, &{&1.definition.name, &1})
    static = static_layer(toolset)
    layers = [static | List.wrap(opts[:layers])]

    {winners, fold_issues} =
      case Merge.fold(layers) do
        {:ok, winners} -> {winners, []}
        {:error, issues} -> {%{}, issues}
      end

    issues =
      fold_issues ++
        cycle_issues(toolset) ++
        unknown_tool_issues(toolset, by_name) ++
        op_issues(toolset, by_name) ++
        name_issues(toolset, by_name, winners)

    warnings = warnings(toolset, by_name, winners, layers)

    if issues == [], do: {:ok, warnings}, else: {:error, issues}
  end

  # ── cycle (§4.1: nested-base slug chain) ──────────────────────────────────

  defp cycle_issues(%Custom{slug: slug, base: base}), do: cycle_issues(base, [slug])

  defp cycle_issues(%Custom{slug: slug, base: base} = _inner, chain) do
    if slug in chain do
      [issue(:cycle, nil, nil, nil, %{chain: Enum.reverse(chain), slug: slug})]
    else
      cycle_issues(base, [slug | chain])
    end
  end

  defp cycle_issues(_terminal, _chain), do: []

  # ── :unknown_tool (tools keys / include / exclude vs the base catalog) ────

  defp unknown_tool_issues(toolset, by_name) do
    tools_issues =
      (toolset.tools || %{})
      |> Map.keys()
      |> Enum.reject(fn name -> is_binary(name) and Map.has_key?(by_name, name) end)
      |> Enum.map(&unknown_tool_issue(&1, :tools))

    include_issues =
      (List.wrap(toolset.include) -- [nil])
      |> Enum.reject(&Map.has_key?(by_name, &1))
      |> Enum.map(&unknown_tool_issue(&1, :include))

    exclude_issues =
      List.wrap(toolset.exclude)
      |> Enum.reject(&Map.has_key?(by_name, &1))
      |> Enum.map(&unknown_tool_issue(&1, :exclude))

    tools_issues ++ include_issues ++ exclude_issues
  end

  defp unknown_tool_issue(name, source) do
    issue(
      :unknown_tool,
      nil,
      if(is_binary(name), do: name, else: nil),
      nil,
      %{source: source, name: name},
      "#{source} references #{inspect(name)} which is not in the base catalog"
    )
  end

  # ── per-op structural checks (own tools map, against the BASE entry) ──────

  defp op_issues(toolset, by_name) do
    (toolset.tools || %{})
    |> Enum.flat_map(fn
      {name, ops} when is_binary(name) and is_list(ops) ->
        case Map.fetch(by_name, name) do
          {:ok, entry} ->
            fields = entry.definition.input_fields

            Enum.flat_map(ops, fn override ->
              op_issue(override, fields, ops)
            end)

          :error ->
            # :unknown_tool already reported this key.
            []
        end

      _other ->
        []
    end)
  end

  defp op_issue(%Override{op: :set_input_schema}, fields, _all_ops) when is_list(fields),
    do: [
      issue(
        :raw_schema_op,
        :set_input_schema,
        nil,
        nil,
        nil,
        ":set_input_schema against a DSL tool (it has input_fields)"
      )
    ]

  defp op_issue(%Override{op: op, target: field} = override, fields, all_ops)
       when op in [:set_arg_description, :prune_enum, :hide_field, :rename_field, :pin_default] do
    cond do
      not is_list(fields) ->
        [
          issue(
            :raw_schema_op,
            op,
            nil,
            field,
            nil,
            "field-level op #{inspect(op)} against a raw-schema tool (no input_fields)"
          )
        ]

      not field_defined?(fields, field) and op == :rename_field ->
        [
          issue(
            :rename_target_missing,
            op,
            nil,
            field,
            nil,
            "rename target field #{inspect(field)} is missing from the tool"
          )
        ]

      not field_defined?(fields, field) ->
        [
          issue(
            :unknown_field,
            op,
            nil,
            field,
            nil,
            "field op #{inspect(op)} targets unknown field #{inspect(field)}"
          )
        ]

      op == :prune_enum ->
        prune_issues(override, fields)

      op == :rename_field ->
        rename_issues(
          override,
          fields,
          Enum.filter(all_ops, &match?(%Override{op: :rename_field}, &1))
        )

      op == :pin_default ->
        pin_issues(
          override,
          fields,
          Enum.filter(all_ops, &match?(%Override{op: :prune_enum}, &1))
        )

      true ->
        []
    end
  end

  defp op_issue(_override, _fields, _all_ops), do: []

  defp prune_issues(%Override{value: values} = override, fields) do
    field = find_field(fields, override.target)

    if enum_field?(field) do
      base = MapSet.new(enum_values(field), &to_string/1)
      extra = Enum.reject(List.wrap(values), &(to_string(&1) in base))

      if extra == [] do
        []
      else
        [
          issue(
            :prune_not_subset,
            :prune_enum,
            nil,
            override.target,
            %{values: extra, base: Enum.sort(enum_values(field))},
            "prune_enum values #{inspect(extra)} are not in the base enum for " <>
              "#{inspect(override.target)}"
          )
        ]
      end
    else
      # Non-enum prune targets stay Overrides.apply/3's (:not_enum, PRD-1).
      []
    end
  end

  defp rename_issues(%Override{value: value} = override, fields, rename_ops) do
    collides? =
      is_binary(value) and
        Enum.any?(fields, fn field ->
          field.name != override.target and to_string(field.name) == value
        end)

    duplicate? =
      Enum.count(rename_ops, &match?(%Override{op: :rename_field, value: ^value}, &1)) > 1

    if collides? or duplicate? or not is_binary(value) do
      [
        issue(
          :rename_collision,
          :rename_field,
          nil,
          override.target,
          %{value: value},
          "renaming field #{inspect(override.target)} to #{inspect(value)} collides with " <>
            "an existing field"
        )
      ]
    else
      []
    end
  end

  defp pin_issues(%Override{value: value} = override, fields, prune_ops) do
    field = find_field(fields, override.target)

    if pin_valid?(value, field, prune_ops) do
      []
    else
      [
        issue(
          :pin_default_invalid,
          :pin_default,
          nil,
          override.target,
          %{value: value},
          "pin_default value #{inspect(value)} for field #{inspect(override.target)} is " <>
            "outside the post-prune enum or incompatible with the field type"
        )
      ]
    end
  end

  # Enum fields: the value must sit in the post-prune enum (base enum minus
  # every prune on the same field); scalar fields: type-compatible per
  # Fields' scalar types; anything else: no check possible.
  defp pin_valid?(value, field, prune_ops) do
    cond do
      enum_field?(field) ->
        pruned =
          MapSet.new(
            Enum.flat_map(prune_ops, fn %Override{value: vs} -> List.wrap(vs) end),
            &to_string/1
          )

        base = MapSet.new(enum_values(field), &to_string/1)
        remaining = MapSet.difference(base, pruned)
        to_string(value) in remaining

      field != nil and field.type in @scalar_types ->
        type_compatible?(field.type, value)

      true ->
        true
    end
  end

  defp type_compatible?(:string, value), do: is_binary(value)
  defp type_compatible?(:integer, value), do: is_integer(value)
  defp type_compatible?(:number, value), do: is_integer(value) or is_float(value)
  defp type_compatible?(:boolean, value), do: is_boolean(value)

  # ── effective-name checks (winners: charset + collision) ─────────────────

  defp name_issues(toolset, by_name, winners) do
    effective = effective_names(toolset, by_name, winners)

    charset_issues =
      for {{tool, :set_name, nil}, {%Override{value: value}, _prov}} <- winners,
          is_binary(value),
          not Regex.match?(@name_charset, value) do
        issue(
          :name_charset,
          :set_name,
          tool,
          nil,
          %{value: value},
          "renamed name #{inspect(value)} violates the MCP wire-name charset"
        )
      end

    collision_issues =
      effective
      |> Enum.group_by(fn {_tool, wire} -> wire end, fn {tool, _wire} -> tool end)
      |> Enum.flat_map(fn
        {_wire, [_tool]} ->
          []

        {wire, tools} ->
          [
            issue(
              :name_collision,
              :set_name,
              hd(tools),
              nil,
              %{tools: tools, wire: wire},
              "effective name #{inspect(wire)} collides across tools #{inspect(tools)}"
            )
          ]
      end)

    charset_issues ++ collision_issues
  end

  # %{base_name => effective_wire_name} over the effective (filtered) set.
  defp effective_names(toolset, by_name, winners) do
    by_name
    |> Map.keys()
    |> keep_effective_set(toolset)
    |> Map.new(fn name ->
      wire =
        case Map.get(winners, {name, :set_name, nil}) do
          {%Override{value: value}, _prov} when is_binary(value) -> value
          _ -> name
        end

      {name, wire}
    end)
  end

  defp keep_effective_set(names, toolset) do
    excluded = MapSet.new(List.wrap(toolset.exclude || []))

    names
    |> Enum.reject(&MapSet.member?(excluded, &1))
    |> then(fn names ->
      if toolset.include == nil do
        names
      else
        wanted = MapSet.new(toolset.include)
        Enum.filter(names, &MapSet.member?(wanted, &1))
      end
    end)
  end

  # ── warnings (non-fatal) ──────────────────────────────────────────────────

  defp warnings(toolset, by_name, winners, layers) do
    redundant_warnings(winners, layers) ++
      pin_default_same_warning(toolset, by_name) ++
      include_exclude_overlap_warning(toolset)
  end

  # A winner whose value another layer already stated on the same slot is a
  # no-op restatement — legal, noted.
  defp redundant_warnings(winners, layers) do
    stated =
      Enum.flat_map(layers, fn %Layer{id: id, ops: ops} ->
        Enum.map(ops, &{slot_for(&1), &1.value, id})
      end)

    for {{tool, op, _field} = slot, {%Override{value: value, layer: winner_layer}, _prov}} <-
          Enum.filter(winners, fn {{_t, op, _f}, _w} -> op in [:set_visible, :set_callable] end),
        {_s, _same, loser_layer} <-
          Enum.filter(stated, fn {s, v, layer} ->
            s == slot and v == value and layer != winner_layer
          end) do
      "redundant: #{op} on #{tool} is already set to the same value by layer " <>
        inspect(loser_layer)
    end
    |> Enum.uniq()
  end

  defp slot_for(%Override{op: op, target: target, tool: tool}) do
    field = if Override.field_op?(op), do: target, else: nil
    {tool || target, op, field}
  end

  defp pin_default_same_warning(toolset, by_name) do
    (toolset.tools || %{})
    |> Enum.flat_map(fn
      {name, ops} when is_binary(name) ->
        case Map.fetch(by_name, name) do
          {:ok, entry} ->
            fields = entry.definition.input_fields || []

            for %Override{op: :pin_default, target: field, value: value} <- ops,
                f = find_field(fields, field),
                f != nil,
                not is_nil(f.opts[:default]),
                f.opts[:default] == value do
              "pin_default on #{name}.#{inspect(field)} equals the field's existing default"
            end

          :error ->
            []
        end

      _other ->
        []
    end)
  end

  defp include_exclude_overlap_warning(toolset) do
    overlap =
      if toolset.include == nil do
        []
      else
        MapSet.intersection(MapSet.new(toolset.include), MapSet.new(List.wrap(toolset.exclude)))
        |> MapSet.to_list()
      end

    if overlap == [] do
      []
    else
      [
        "include/exclude overlap on #{inspect(overlap)} — exclude wins (the names are " <>
          "dropped regardless of include)"
      ]
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp static_layer(toolset) do
    %Layer{
      id: {:static, toolset.slug},
      weight: 100,
      ops: Custom.flatten_tools(toolset.tools)
    }
  end

  defp field_defined?(fields, field), do: Enum.any?(fields, &(&1.name == field))

  defp find_field(fields, field), do: Enum.find(fields, &(&1.name == field))

  defp enum_field?(nil), do: false
  defp enum_field?(field), do: field.type == :enum

  defp enum_values(field), do: List.wrap(field.opts[:values])

  defp issue(code, op, tool, field, meta),
    do: issue(code, op, tool, field, meta, Atom.to_string(code))

  defp issue(code, op, tool, field, meta, message) do
    %Issue{code: code, message: message, op: op, tool: tool, field: field, meta: meta}
  end
end
