defmodule Noizu.MCP.Toolset.Override do
  @moduledoc """
  One entry in the closed override vocabulary (0.3.0 toolset architecture).

  Ops are pure descriptors — `Noizu.MCP.Toolset.Overrides.apply/3` materializes
  them onto a spec. Field-level ops (`:set_arg_description`, `:prune_enum`,
  `:hide_field`, `:rename_field`, `:pin_default`) target a field *atom* and are
  rejected for raw-schema tools; tool-level ops target the tool's wire name.

  `weight`/`layer`/`inherit?` are inert in PRD-1 (single-layer static path);
  the merge engine that honors them lands with `%CustomToolset{}`.
  """

  @enforce_keys [:op]
  defstruct [:op, :target, :value, weight: 100, layer: nil, inherit?: false]

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
          inherit?: boolean()
        }
end
