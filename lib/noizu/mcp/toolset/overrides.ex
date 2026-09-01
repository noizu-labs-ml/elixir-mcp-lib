defmodule Noizu.MCP.Toolset.Overrides do
  @moduledoc """
  Pure override materializer: applies `[%Noizu.MCP.Toolset.Override{}]` ops
  onto a `%Noizu.MCP.Server.Tool.Spec{}` and returns the effective triple —
  fresh `%Noizu.MCP.Types.Tool{}`, effective `input_schema`, effective
  `cast_plan`. Never touches DB/ETS/env, and never mutates the input (Elixir
  immutability makes the "fresh" guarantee literal — `%Types.Tool{}` is shared
  compile-time data, so a new definition map is built for every changed field).

  Field-level ops rewrite the compiled JSON Schema map and the cast plan
  together: property names, `required`, enum lists, and defaults change on the
  wire while the cast-plan entry keeps emitting the ORIGINAL field atom —
  `wire_key` marks the rename as wire-only, so handlers always receive
  original-keyed args. After any field-level op the definition's
  `input_fields` are cleared, so the effective schema (not a re-render of
  stale fields) is what `Types.Tool.to_map/2` advertises.

  Structural problems come back as `[%Noizu.MCP.Toolset.Validator.Issue{}]`,
  never raised.
  """

  alias Noizu.MCP.Server.Tool.{Fields, Spec}
  alias Noizu.MCP.Toolset.Override
  alias Noizu.MCP.Toolset.Validator.Issue

  @tool_ops [
    :set_name,
    :set_description,
    :set_title,
    :set_visible,
    :set_callable,
    :set_input_schema
  ]
  @field_ops [:set_arg_description, :prune_enum, :hide_field, :rename_field, :pin_default]

  @doc """
  Materialize ops onto `spec`. Returns `{:ok, %Spec{}}` with the effective
  definition/schema/plan, or `{:error, [%Validator.Issue{}]}` for structural
  problems (unknown op, unknown tool/field target, field-level op on a
  raw-schema tool, `:set_input_schema` on a DSL tool, rename collision,
  `prune_enum` on a non-enum field, non-serializable `pin_default`). Pure:
  same input ⇒ same output; the input spec is unchanged after the call.

  The raw-schema/DSL matrix: `:set_input_schema` is allowed only when
  `definition.input_fields == nil`; field-level ops only when it is not.
  """
  @spec apply(Spec.t(), [Override.t()], keyword()) :: {:ok, Spec.t()} | {:error, [Issue.t()]}
  def apply(spec, ops, opts \\ [])

  def apply(%Spec{} = spec, [], _opts), do: {:ok, spec}

  def apply(%Spec{} = spec, ops, _opts) when is_list(ops) do
    # Validate against the ORIGINAL spec before materializing: later field ops
    # clear `input_fields`, but every op in the set is judged on what the
    # author started from.
    issues = Enum.flat_map(ops, &validate_op(&1, spec, ops))

    if issues == [] do
      {:ok, Enum.reduce(ops, spec, &materialize_op(&1, &2))}
    else
      {:error, issues}
    end
  end

  def apply(%Spec{} = spec, ops, _opts),
    do: {:error, [issue(:invalid_op, nil, spec, meta: %{got: ops})]}

  # ── validation ────────────────────────────────────────────────────────────

  defp validate_op(%Override{op: op} = override, spec, _all) when op in @tool_ops do
    cond do
      override.target != spec.definition.name ->
        [issue(:unknown_tool, override, spec)]

      op == :set_name and not is_binary(override.value) ->
        [issue(:invalid_value, override, spec)]

      op == :set_description and not is_binary(override.value) ->
        [issue(:invalid_value, override, spec)]

      op == :set_title and not (is_binary(override.value) or is_nil(override.value)) ->
        [issue(:invalid_value, override, spec)]

      op in [:set_visible, :set_callable] and not is_boolean(override.value) ->
        [issue(:invalid_value, override, spec)]

      op == :set_input_schema ->
        cond do
          is_list(spec.definition.input_fields) ->
            [issue(:input_schema_on_dsl_tool, override, spec)]

          not is_map(override.value) ->
            [issue(:invalid_value, override, spec)]

          true ->
            []
        end

      true ->
        []
    end
  end

  defp validate_op(%Override{op: op, target: field} = override, spec, all)
       when op in @field_ops do
    fields = spec.definition.input_fields

    cond do
      not is_list(fields) ->
        [issue(:field_op_on_raw_schema, override, spec)]

      not field_defined?(fields, field) ->
        [issue(:unknown_field, override, spec, field)]

      op == :rename_field ->
        rename_issues(override, spec, fields, all)

      op == :prune_enum and not enum_field?(fields, field) ->
        [issue(:not_enum, override, spec, field)]

      op == :prune_enum and not is_list(override.value) ->
        [issue(:invalid_value, override, spec, field)]

      op == :pin_default and not json_serializable?(override.value) ->
        [issue(:default_not_serializable, override, spec, field)]

      op == :set_arg_description and not (is_binary(override.value) or is_nil(override.value)) ->
        [issue(:invalid_value, override, spec, field)]

      true ->
        []
    end
  end

  defp validate_op(%Override{} = override, spec, _all), do: [issue(:unknown_op, override, spec)]

  defp validate_op(other, spec, _all), do: [issue(:invalid_op, nil, spec, meta: %{got: other})]

  defp rename_issues(override, spec, fields, all) do
    value = override.value

    cond do
      not is_binary(value) ->
        [issue(:invalid_value, override, spec, override.target)]

      Enum.any?(fields, fn field ->
        field.name != override.target and to_string(field.name) == value
      end) ->
        [issue(:rename_collision, override, spec, override.target)]

      Enum.count(all, &match?(%Override{op: :rename_field, value: ^value}, &1)) > 1 ->
        [issue(:rename_collision, override, spec, override.target)]

      true ->
        []
    end
  end

  defp field_defined?(fields, field), do: Enum.any?(fields, &(&1.name == field))

  defp enum_field?(fields, field) do
    Enum.any?(fields, &(&1.name == field and &1.type == :enum))
  end

  defp json_serializable?(value) do
    match?({:ok, _}, Jason.encode(value))
  rescue
    _ -> false
  end

  # ── materialization ───────────────────────────────────────────────────────

  defp materialize_op(%Override{op: :set_name, value: name}, %Spec{} = spec),
    do: %{spec | definition: %{spec.definition | name: name}}

  defp materialize_op(%Override{op: :set_description, value: description}, %Spec{} = spec),
    do: %{spec | definition: %{spec.definition | description: description}}

  defp materialize_op(%Override{op: :set_title, value: title}, %Spec{} = spec),
    do: %{spec | definition: %{spec.definition | title: title}}

  defp materialize_op(%Override{op: :set_visible, value: visible}, %Spec{} = spec),
    do: %{spec | hidden: not visible}

  defp materialize_op(%Override{op: :set_callable, value: callable}, %Spec{} = spec),
    do: %{spec | callable: callable}

  defp materialize_op(%Override{op: :set_input_schema, value: schema}, %Spec{} = spec),
    do: %{spec | definition: %{spec.definition | input_schema: schema, input_fields: nil}}

  defp materialize_op(%Override{op: op, target: field, value: value}, %Spec{} = spec)
       when op in @field_ops do
    definition = spec.definition

    %{
      spec
      | cast_plan: field_op_plan(op, field, value, plan_for(spec)),
        definition: %{
          definition
          | input_schema: field_op_schema(op, field, value, definition.input_schema),
            input_fields: nil
        }
    }
  end

  # The effective plan: the compiled plan when present (already carries any
  # earlier op's effects), else rebuilt from the DSL fields.
  defp plan_for(%Spec{cast_plan: plan}) when is_list(plan), do: plan
  defp plan_for(%Spec{definition: %{input_fields: fields}}), do: Fields.to_cast_plan(fields)

  # ── schema patches (wire surface) ────────────────────────────────────────

  defp field_op_schema(:rename_field, field, new_name, schema) do
    old = to_string(field)

    schema
    |> Map.update("properties", %{}, fn props ->
      case Map.fetch(props, old) do
        {:ok, value} -> props |> Map.delete(old) |> Map.put(new_name, value)
        :error -> props
      end
    end)
    |> update_required(&Enum.map(&1, fn name -> if(name == old, do: new_name, else: name) end))
  end

  defp field_op_schema(:prune_enum, field, values, schema) do
    drop = MapSet.new(values, &to_string/1)

    update_property(schema, field, fn prop ->
      case Map.fetch(prop, "enum") do
        {:ok, enum} -> Map.put(prop, "enum", Enum.reject(enum, &(&1 in drop)))
        :error -> prop
      end
    end)
  end

  defp field_op_schema(:set_arg_description, field, description, schema) do
    update_property(schema, field, fn prop ->
      if description,
        do: Map.put(prop, "description", description),
        else: Map.delete(prop, "description")
    end)
  end

  defp field_op_schema(:hide_field, field, _value, schema) do
    name = to_string(field)

    schema
    |> Map.update("properties", %{}, &Map.delete(&1, name))
    |> update_required(&List.delete(&1, name))
  end

  defp field_op_schema(:pin_default, field, value, schema) do
    update_property(schema, field, &Map.put(&1, "default", encode_default(value)))
  end

  defp update_property(schema, field, fun) do
    Map.update(schema, "properties", %{}, fn props ->
      Map.update(props, to_string(field), %{}, fun)
    end)
  end

  # `required` disappears entirely when emptied — matching the compiled shape.
  defp update_required(schema, fun) do
    case Map.fetch(schema, "required") do
      {:ok, required} ->
        case fun.(required) do
          [] -> Map.delete(schema, "required")
          rest -> Map.put(schema, "required", rest)
        end

      :error ->
        schema
    end
  end

  defp encode_default(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: to_string(value)

  defp encode_default(value), do: value

  # ── cast plan patches (wire-only renames) ────────────────────────────────

  defp field_op_plan(:rename_field, field, new_name, plan) do
    key = to_string(field)

    Enum.map(plan, fn
      %{key: ^key} = entry -> Map.put(entry, :wire_key, new_name)
      entry -> entry
    end)
  end

  defp field_op_plan(:pin_default, field, value, plan) do
    key = to_string(field)

    Enum.map(plan, fn
      %{key: ^key} = entry -> Map.put(entry, :default, value)
      entry -> entry
    end)
  end

  defp field_op_plan(:prune_enum, field, values, plan) do
    key = to_string(field)
    drop = MapSet.new(values, &to_string/1)

    Enum.map(plan, fn
      %{key: ^key, type: {:enum, enum}} = entry ->
        %{entry | type: {:enum, Enum.reject(enum, &(to_string(&1) in drop))}}

      entry ->
        entry
    end)
  end

  defp field_op_plan(_op, _field, _value, plan), do: plan

  # ── issue construction ───────────────────────────────────────────────────

  defp issue(code, override, spec, field \\ nil, meta \\ nil) do
    %Issue{
      code: code,
      message: message(code, override, spec, field),
      op: override && override.op,
      tool: spec.definition.name,
      field: field,
      meta: meta
    }
  end

  defp message(:unknown_op, %{op: op}, _spec, _field), do: "unknown override op #{inspect(op)}"

  defp message(:invalid_op, _override, _spec, _field),
    do: "override list entries must be %Noizu.MCP.Toolset.Override{} structs"

  defp message(:unknown_tool, %{target: target}, spec, _field),
    do:
      "override targets tool #{inspect(target)} but is being materialized onto " <>
        "#{inspect(spec.definition.name)}"

  defp message(:unknown_field, %{target: field}, _spec, _field_name),
    do: "unknown field target #{inspect(field)}"

  defp message(:field_op_on_raw_schema, %{op: op}, _spec, _field),
    do: "field-level op #{inspect(op)} is not allowed on a raw-schema tool"

  defp message(:input_schema_on_dsl_tool, _override, _spec, _field),
    do: ":set_input_schema is only allowed on raw-schema tools"

  defp message(:rename_collision, %{value: value}, _spec, field),
    do: "renaming field #{inspect(field)} to #{inspect(value)} collides with an existing field"

  defp message(:not_enum, _override, _spec, field),
    do: "prune_enum target #{inspect(field)} is not an :enum field"

  defp message(:default_not_serializable, _override, _spec, field),
    do: "pin_default value for field #{inspect(field)} is not JSON-serializable"

  defp message(:invalid_value, %{op: op, value: value}, _spec, _field),
    do: "#{inspect(op)} got invalid value #{inspect(value)}"
end
