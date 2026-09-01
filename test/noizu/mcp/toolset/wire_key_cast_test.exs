defmodule Noizu.MCP.Toolset.WireKeyCastTest do
  use ExUnit.Case, async: true

  # Extends test/noizu/mcp/server/tool_test.exs coverage: cast/2 wire_key
  # semantics (FR-1.9) — input lookup under the wire key, emission under the
  # original atom; missing-field behavior identical to the name-missing path.
  alias Noizu.MCP.Server.Tool.Fields

  defp plan do
    Fields.to_cast_plan(
      Fields.from_spec(
        orig: [type: :string, wire_key: "renamed", required: true],
        count: [type: :integer, default: 3],
        mode: [type: :enum, values: [:plain, :loud], default: :plain]
      )
    )
  end

  test "opts[:wire_key] flows into the compiled cast plan" do
    assert Enum.any?(plan(), &match?(%{key: "orig", name: :orig, wire_key: "renamed"}, &1))
    assert Enum.any?(plan(), &match?(%{key: "count", name: :count, wire_key: nil}, &1))
  end

  test "input is looked up under the wire key, emitted under the original atom" do
    assert %{orig: "v"} = Fields.cast(plan(), %{"renamed" => "v"})
  end

  test "the original wire key no longer feeds the field" do
    assert %{} = Fields.cast(plan(), %{"orig" => "v"})
  end

  test "wire-key missing ⇒ default semantics identical to the name-missing path" do
    assert %{orig: "d", count: 3, mode: :plain} = Fields.cast(plan(), %{"renamed" => "d"})
    assert %{count: 3, mode: :plain} = Fields.cast(plan(), %{})
  end

  test "enum values cast through the wire key" do
    assert %{mode: :loud} = Fields.cast(plan(), %{"renamed" => "a", "mode" => "loud"})
  end

  test "plans without wire keys behave exactly as before (back-compat)" do
    legacy = Enum.map(plan(), &Map.delete(&1, :wire_key))
    assert %{orig: "v"} = Fields.cast(legacy, %{"orig" => "v"})
    assert %{} = Fields.cast(legacy, %{"renamed" => "v"})
  end

  test "atom wire_key opts are normalized to strings" do
    plan = Fields.to_cast_plan(Fields.from_spec(field: [type: :string, wire_key: :renamed]))

    assert Enum.any?(plan, &match?(%{wire_key: "renamed"}, &1))
  end
end
