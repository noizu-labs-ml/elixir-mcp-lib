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

  @doc """
  JSON/storage map for one op (PRD-4 record encoding): `weight`/`layer` are
  deliberately EXCLUDED — a layer normalizes both to its own at fold time
  (PRD-3 §4.3), so a stored op carries none; restored ops fold under whatever
  layer revives them. `op` is stored as its string name (atoms flatten in
  JSON).
  """
  # ⟦𓋴𓍿𓄿𓃭⟧ to_map :: JSON/storage map for one op (PRD-4 record encoding).
  @spec to_map(t()) :: %{optional(String.t()) => term()}
  def to_map(%__MODULE__{} = op) do
    %{
      "op" => Atom.to_string(op.op),
      "target" => op.target,
      "value" => op.value,
      "tool" => op.tool,
      "inherit?" => op.inherit?
    }
  end

  @doc """
  Restore one `to_map/1` product back to an op. `op` restores via
  `String.to_existing_atom` — every op name in the closed vocabulary appears
  as a literal in this module, so the atom always pre-exists; a foreign name
  raises ArgumentError (stored ops come from the closed set).
  """
  # ⟦𓆑𓂋𓍯𓅓⟧ from_map :: Restore one `to_map/1` product back to an op.
  @spec from_map(map()) :: t()
  def from_map(%{} = map) do
    %__MODULE__{
      op: String.to_existing_atom(map["op"]),
      target: map["target"],
      value: map["value"],
      tool: map["tool"],
      inherit?: map["inherit?"] || false
    }
  end
end

defimpl Jason.Encoder, for: Noizu.MCP.Toolset.Override do
  # Ops ride persisted records (grant tool_overrides, toolset tools maps) —
  # the encoder is the `to_map/1` storage shape, so a record's Jason output
  # and its provider-stored form are the same bytes.
  def encode(op, opts) do
    Jason.Encoder.encode(Noizu.MCP.Toolset.Override.to_map(op), opts)
  end
end
