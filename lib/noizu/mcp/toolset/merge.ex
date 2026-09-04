defmodule Noizu.MCP.Toolset.Merge do
  @moduledoc """
  The ONE weighted merge engine (PRD-3 §4.3, anti-pattern AP-8): folds
  `[%Noizu.MCP.Toolset.Layer{}]` into per-slot winners. There is no per-layer
  special casing — a new layer type is a new `%Layer{}`, not new logic.

  Slot: `{tool :: String.t(), op :: Override.op(), field :: atom() | nil}` —
  every override opinion lands in exactly one slot (field-level ops slot on
  their field atom; tool-level ops slot with `field: nil`), and different
  slots compose independently (`:set_name` + `:set_visible` both apply).

  Normative resolution per slot:

    * the max-weight NON-`inherit?` op wins;
    * ties at max weight ⇒ `{:error, [%Validator.Issue{code: :weight_conflict}]}` —
      returned, never raised (Q5: two EQUAL ops at equal weight conflict too —
      loud by spec);
    * an `inherit?` op at weight w clears ALL opinions ≤ w (its own included)
      and applies nothing — the slot ends empty and the base value stands,
      unless a >w opinion exists;
    * no surviving opinion ⇒ no winner for the slot (base value stands).

  Returns `%{slot => {%Override{}, provenance}}` where provenance =
  `{layer_id, weight}` — the map `%Noizu.MCP.Toolset.Effective.provenance`
  is populated from (PRD-1 §4.3/PRD-3 §4.3), keyed per applied op.
  """

  alias Noizu.MCP.Toolset.{Layer, Override}
  alias Noizu.MCP.Toolset.Validator.Issue

  @type slot :: {tool :: String.t(), op :: Override.op(), field :: atom() | nil}
  @type winners :: %{optional(slot()) => {Override.t(), {term(), integer()}}}

  @doc """
  Fold `layers` into per-slot winners. Layers arrive unordered — weights
  decide. Pure: same layers ⇒ same winners.
  """
  # ⟦𓏊𓅱𓆑𓋹⟧ fold :: Fold `layers` into per-slot winners. Layers arrive unordered — weights decide. Pure: same layers ⇒ same winners.
  @spec fold([Layer.t()], keyword()) :: {:ok, winners()} | {:error, [Issue.t()]}
  def fold(layers, _opts \\ []) when is_list(layers) do
    # Collect normalized opinions per slot; ops that aren't Override structs
    # surface as :invalid_op issues instead of crashing the fold.
    {by_slot, shape_issues} =
      Enum.reduce(layers, {%{}, []}, fn %Layer{id: id, weight: weight, ops: ops}, {acc, bad} ->
        Enum.reduce(List.wrap(ops), {acc, bad}, fn
          %Override{} = op0, {acc, bad} ->
            op = %{op0 | weight: weight, layer: id}
            slot = slot_for(op)
            {Map.update(acc, slot, [{op, id, weight}], &[{op, id, weight} | &1]), bad}

          other, {acc, bad} ->
            {acc, [op_shape_issue(other) | bad]}
        end)
      end)

    # Resolve every slot; conflicts collect into the issue list.
    {winners, conflict_issues} =
      Enum.map_reduce(by_slot, [], fn {slot, opinions}, issues ->
        case resolve_slot(opinions) do
          {:ok, {op, id, weight}} ->
            {{slot, {op, {id, weight}}}, issues}

          :empty ->
            {nil, issues}

          {:conflict, meta} ->
            {nil, [conflict_issue(slot, meta) | issues]}
        end
      end)

    issues = Enum.reverse(shape_issues) ++ Enum.reverse(conflict_issues)

    if issues == [] do
      {:ok, winners |> Enum.reject(&is_nil/1) |> Map.new()}
    else
      {:error, issues}
    end
  end

  # ── slot resolution ───────────────────────────────────────────────────────

  # (op, layer_id, weight) opinions → winner | :empty | {:conflict, meta}.
  defp resolve_slot(opinions) do
    clear_at =
      opinions
      |> Enum.filter(fn {op, _id, _w} -> op.inherit? end)
      |> Enum.map(fn {_op, _id, w} -> w end)
      |> case do
        [] -> nil
        weights -> Enum.max(weights)
      end

    candidates =
      Enum.reject(opinions, fn {op, _id, w} ->
        op.inherit? or (clear_at != nil and w <= clear_at)
      end)

    case candidates do
      [] ->
        :empty

      candidates ->
        max = candidates |> Enum.map(fn {_op, _id, w} -> w end) |> Enum.max()

        case Enum.filter(candidates, fn {_op, _id, w} -> w == max end) do
          [{op, id, weight}] ->
            {:ok, {op, id, weight}}

          tied ->
            {:conflict, %{weight: max, layers: Enum.map(tied, fn {_o, id, _w} -> id end)}}
        end
    end
  end

  defp slot_for(%Override{op: op, target: target, tool: tool}) do
    field = if Override.field_op?(op), do: target, else: nil
    {tool || target, op, field}
  end

  # ── issue construction ───────────────────────────────────────────────────

  defp conflict_issue({tool, op, field}, meta) do
    %Issue{
      code: :weight_conflict,
      message:
        "equal max-weight (#{meta.weight}) non-inherit opinions on slot " <>
          "{#{inspect(tool)}, #{inspect(op)}, #{inspect(field)}} from layers " <>
          "#{inspect(meta.layers)}",
      op: op,
      tool: tool,
      field: field,
      meta: meta
    }
  end

  defp op_shape_issue(other) do
    %Issue{
      code: :invalid_op,
      message: "layer ops must be %Noizu.MCP.Toolset.Override{} structs, got: #{inspect(other)}",
      op: nil,
      tool: nil,
      field: nil,
      meta: %{got: other}
    }
  end
end
