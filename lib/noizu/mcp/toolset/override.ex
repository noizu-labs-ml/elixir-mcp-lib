defmodule Noizu.MCP.Toolset.Override do
  @moduledoc """
  One entry in the closed override vocabulary (0.3.0 toolset architecture).

  Ops are pure descriptors — `Noizu.MCP.Toolset.Overrides.apply/3` materializes
  them onto a spec. Field-level ops (`:set_arg_description`, `:prune_enum`,
  `:hide_field`, `:rename_field`, `:pin_default`) target a field *atom* and are
  rejected for raw-schema tools; tool-level ops target the tool's wire name.

  `weight`/`layer`/`inherit?` are inert on the single-layer static path
  (PRD-1); the PRD-3 merge engine (`Noizu.MCP.Toolset.Merge.fold/2`) honors
  them — a layer normalizes each op's `weight`/`layer` to its own at fold
  time, and `inherit?` at weight w clears all opinions ≤ w for the slot.

  `tool` is the base canonical name a FIELD-level op belongs to (set by
  `%Noizu.MCP.Toolset.Custom{}` flattening and by context-layer authors;
  `%Noizu.MCP.Toolset.Overrides.apply/3` ignores it — field ops keep their
  field atom in `target`). Tool-level ops carry the tool name in `target`,
  so `tool` mirrors it when the layer is flattened under a tools map.
  """

  @field_ops [:set_arg_description, :prune_enum, :hide_field, :rename_field, :pin_default]

  @enforce_keys [:op]
  defstruct [:op, :target, :value, weight: 100, layer: nil, inherit?: false, tool: nil]

  @type op ::
          :set_name
          | :set_description
          | :set_title
          | :set_arg_description
          | :prune_enum
          | :hide_field
          | :rename_field
          | :pin_default
          | :set_visible
          | :set_callable
          | :set_input_schema

  @type t :: %__MODULE__{
          op: op(),
          target: term(),
          value: term(),
          weight: integer(),
          layer: term(),
          inherit?: boolean(),
          tool: String.t() | nil
        }

  @doc "True for field-level ops (their `target` is a field atom, not a tool name)."
  @spec field_op?(op()) :: boolean()
  # ⟦𓊪𓍿𓆄𓎡⟧ field_op? :: True for field-level ops (their `target` is a field atom, not a tool name).
  def field_op?(op) when op in @field_ops, do: true
  def field_op?(_op), do: false
end
