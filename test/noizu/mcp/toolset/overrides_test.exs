defmodule Noizu.MCP.Toolset.OverridesTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.RenderCtx
  alias Noizu.MCP.Fixtures
  alias Noizu.MCP.Server.Tool.Spec
  alias Noizu.MCP.Toolset.{Override, Overrides}
  alias Noizu.MCP.Toolset.Validator.Issue
  alias Noizu.MCP.Types.{Tool, ToolResult}
  alias Noizu.MCP.{Toolset, Description}

  # Echo: DSL tool — message (string, required), repeat (integer, default 1),
  # mode (enum [:plain, :loud], default :plain).
  defp echo_spec, do: hd(Fixtures.Echo.__mcp_tools__())
  defp raw_spec, do: hd(Fixtures.RawSchema.__mcp_tools__())
  defp op(op_name, target, value), do: %Override{op: op_name, target: target, value: value}

  defp apply!(spec, ops) do
    assert {:ok, applied} = Overrides.apply(spec, ops)
    applied
  end

  defp issue_codes(spec, ops) do
    assert {:error, issues} = Overrides.apply(spec, ops)
    Enum.map(issues, & &1.code)
  end

  describe "tool-level ops" do
    test ":set_name renames the wire name" do
      spec = apply!(echo_spec(), [op(:set_name, "echo", "echo_v2")])
      assert spec.definition.name == "echo_v2"
    end

    test ":set_description / :set_title set definition fields" do
      spec =
        apply!(echo_spec(), [
          op(:set_description, "echo", "new words"),
          op(:set_title, "echo", "Echo!")
        ])

      assert spec.definition.description == "new words"
      assert spec.definition.title == "Echo!"
    end

    test ":set_title accepts nil" do
      spec = apply!(echo_spec(), [op(:set_title, "echo", nil)])
      assert spec.definition.title == nil
    end

    test ":set_visible flips spec.hidden (Entry projects it back)" do
      spec = apply!(echo_spec(), [op(:set_visible, "echo", false)])
      assert spec.hidden

      spec = apply!(spec, [op(:set_visible, "echo", true)])
      refute spec.hidden
    end

    test ":set_callable flips spec.callable" do
      spec = apply!(echo_spec(), [op(:set_callable, "echo", false)])
      assert spec.callable == false
    end

    test ":set_input_schema replaces the schema on a RAW-schema tool" do
      schema = %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}}
      spec = apply!(raw_spec(), [op(:set_input_schema, "raw_schema", schema)])

      assert spec.definition.input_schema == schema
      assert spec.definition.input_fields == nil
    end
  end

  describe "field-level ops (schema + cast plan materialize together)" do
    test ":rename_field moves the schema property + required, marks the plan wire-only" do
      spec = apply!(echo_spec(), [op(:rename_field, :message, "msg")])
      props = spec.definition.input_schema["properties"]

      assert Map.has_key?(props, "msg")
      refute Map.has_key?(props, "message")
      assert spec.definition.input_schema["required"] == ["msg"]

      plan = Enum.find(spec.cast_plan, &(&1.name == :message))
      assert plan.wire_key == "msg"
      # The emitting key stays the original atom (wire-only rename).
      assert plan.name == :message
      # Field ops clear input_fields so the effective schema is authoritative.
      assert spec.definition.input_fields == nil
    end

    test ":rename_field keeps untouched field descriptions intact" do
      spec = apply!(echo_spec(), [op(:rename_field, :message, "msg")])

      assert spec.definition.input_schema["properties"]["msg"]["description"] ==
               "Message to echo"
    end

    test ":prune_enum removes values from schema AND plan" do
      spec = apply!(echo_spec(), [op(:prune_enum, :mode, [:plain])])

      assert spec.definition.input_schema["properties"]["mode"]["enum"] == ["loud"]

      plan = Enum.find(spec.cast_plan, &(&1.name == :mode))
      assert plan.type == {:enum, [:loud]}
    end

    test ":set_arg_description replaces the rendered description" do
      spec = apply!(echo_spec(), [op(:set_arg_description, :repeat, "how many times")])

      assert spec.definition.input_schema["properties"]["repeat"]["description"] ==
               "how many times"
    end

    test ":hide_field removes the property (+ required) but keeps the plan default" do
      spec = apply!(echo_spec(), [op(:hide_field, :repeat, true)])

      refute Map.has_key?(spec.definition.input_schema["properties"], "repeat")
      refute "repeat" in (spec.definition.input_schema["required"] || [])

      # The handler still receives its default — the plan entry survives.
      plan = Enum.find(spec.cast_plan, &(&1.name == :repeat))
      assert plan.default == 1
    end

    test ":hide_field on a required field empties `required` entirely" do
      spec = apply!(echo_spec(), [op(:hide_field, :message, true)])
      assert spec.definition.input_schema["required"] == nil
    end

    test ":pin_default writes schema default + plan default (string atoms encoded)" do
      spec = apply!(echo_spec(), [op(:pin_default, :mode, :loud)])

      assert spec.definition.input_schema["properties"]["mode"]["default"] == "loud"

      plan = Enum.find(spec.cast_plan, &(&1.name == :mode))
      assert plan.default == :loud
    end
  end

  describe "structural issue codes" do
    test "unknown op is an issue, not a crash (FR-1.7)" do
      assert issue_codes(echo_spec(), [%Override{op: :explode, target: "echo", value: 1}]) ==
               [:unknown_op]
    end

    test "unknown tool target" do
      assert issue_codes(echo_spec(), [op(:set_name, "other_tool", "x")]) == [:unknown_tool]
    end

    test "unknown field target" do
      assert issue_codes(echo_spec(), [op(:rename_field, :nope, "x")]) == [:unknown_field]
      assert issue_codes(echo_spec(), [op(:pin_default, :nope, 1)]) == [:unknown_field]
    end

    test "field-level op on a raw-schema tool" do
      assert issue_codes(raw_spec(), [op(:hide_field, :query, true)]) ==
               [:field_op_on_raw_schema]
    end

    test ":set_input_schema on a DSL tool (the rejection matrix)" do
      assert issue_codes(echo_spec(), [op(:set_input_schema, "echo", %{"type" => "object"})]) ==
               [:input_schema_on_dsl_tool]
    end

    test "rename collision with an existing field" do
      assert issue_codes(echo_spec(), [op(:rename_field, :message, "mode")]) ==
               [:rename_collision]
    end

    test "two renames onto the same wire name collide" do
      assert issue_codes(echo_spec(), [
               op(:rename_field, :message, "same"),
               op(:rename_field, :mode, "same")
             ]) == [:rename_collision, :rename_collision]
    end

    test "prune_enum on a non-enum field" do
      assert issue_codes(echo_spec(), [op(:prune_enum, :repeat, [1])]) == [:not_enum]
    end

    test "non-serializable pin_default" do
      assert issue_codes(echo_spec(), [op(:pin_default, :repeat, fn -> :x end)]) ==
               [:default_not_serializable]
    end

    test "invalid op values" do
      assert issue_codes(echo_spec(), [op(:set_name, "echo", 123)]) == [:invalid_value]
      assert issue_codes(echo_spec(), [op(:set_visible, "echo", "yes")]) == [:invalid_value]

      assert issue_codes(raw_spec(), [op(:set_input_schema, "raw_schema", "not a map")]) ==
               [:invalid_value]
    end

    test "non-Override list entries are structural issues" do
      assert issue_codes(echo_spec(), [%{op: :set_name}]) == [:invalid_op]
    end

    test "issues carry op/tool/field context" do
      assert {:error, [%Issue{} = issue]} =
               Overrides.apply(echo_spec(), [op(:rename_field, :nope, "x")])

      assert issue.code == :unknown_field
      assert issue.op == :rename_field
      assert issue.tool == "echo"
      assert issue.field == :nope
      assert is_binary(issue.message)
    end
  end

  describe "purity (FR-1.8)" do
    test "same input ⇒ same output; input spec bit-identical after the call" do
      spec = echo_spec()
      snapshot = :erlang.term_to_binary(spec)
      ops = [op(:rename_field, :message, "msg"), op(:pin_default, :mode, :loud)]

      {:ok, out1} = Overrides.apply(spec, ops)
      {:ok, out2} = Overrides.apply(spec, ops)

      assert :erlang.term_to_binary(out1) == :erlang.term_to_binary(out2)
      assert :erlang.term_to_binary(spec) == snapshot
    end

    test "the empty op set is an identity (shared compile-time Types.Tool untouched)" do
      spec = echo_spec()
      assert {:ok, ^spec} = Overrides.apply(spec, [])
    end
  end

  describe "composition" do
    test "rename + pin_default + prune_enum on one tool" do
      spec =
        apply!(echo_spec(), [
          op(:rename_field, :message, "msg"),
          op(:pin_default, :repeat, 3),
          op(:prune_enum, :mode, [:plain])
        ])

      schema = spec.definition.input_schema
      assert Map.has_key?(schema["properties"], "msg")
      assert schema["properties"]["repeat"]["default"] == 3
      assert schema["properties"]["mode"]["enum"] == ["loud"]

      {:ok, effective} =
        Toolset.resolve(%Toolset.Static{specs: [spec]}, "echo", nil, [])

      # Wire-only end-to-end (FR-1.6 / AC-1.6): the new key is accepted and the
      # handler receives ORIGINAL atom keys.
      result =
        Toolset.invoke(%Toolset.Static{specs: [spec]}, effective, %{"msg" => "hey"}, nil, [])

      assert %ToolResult{is_error: false} = result
      assert [%{text: "heyheyhey"}] = result.content

      # The old key no longer satisfies the effective schema (required msg).
      assert %ToolResult{is_error: true} =
               Toolset.invoke(
                 %Toolset.Static{specs: [spec]},
                 effective,
                 %{"message" => "hey"},
                 nil,
                 []
               )
    end
  end

  describe "description-variant survival (FR-1.14)" do
    test "tool-level Description.t variants still render through to_map/2 after a non-touching pass" do
      spec = hd(Fixtures.VerboseTool.__mcp_tools__())
      assert %Description{} = spec.definition.description

      spec = apply!(spec, [op(:set_name, "verbose", "verbose_renamed")])
      assert %Description{} = spec.definition.description

      terse = Tool.to_map(spec.definition, %{RenderCtx.default() | verbosity: 0})
      rich = Tool.to_map(spec.definition, %{RenderCtx.default() | verbosity: 9})

      assert terse["description"] != rich["description"]
      assert terse["description"] == "terse tool"
      assert rich["description"] == "verbose tool"
    end
  end

  test "apply/3 opts argument is accepted (PRD-3 merge engine seam)" do
    assert {:ok, %Spec{}} = Overrides.apply(echo_spec(), [], verbose: true)
  end
end
