defmodule Noizu.MCP.Toolset.MergeFoldTest do
  @moduledoc """
  PRD-3 §4.3 engine unit matrix: weights, ties (Q5 — loud even for EQUAL
  ops), `inherit?` clearing (AC-3.3), cross-slot composition, provenance
  shape, and the AP-8 anti-pattern regression (one merge path).
  """

  use ExUnit.Case, async: true

  alias Noizu.MCP.Toolset.{Layer, Merge, Override}

  defp layer(id, weight, ops), do: %Layer{id: id, weight: weight, ops: ops}

  defp op(op, target, value, extra \\ []),
    do: struct!(%Override{op: op, target: target, value: value}, extra)

  defp fold(layers), do: Merge.fold(layers)

  describe "max-weight non-inherit wins" do
    test "a single layer's op wins trivially" do
      {:ok, winners} = fold([layer({:static, "t"}, 100, [op(:set_visible, "echo", false)])])

      assert {%Override{
                op: :set_visible,
                value: false,
                weight: 100,
                layer: {:static, "t"}
              }, {{:static, "t"}, 100}} = winners[{"echo", :set_visible, nil}]
    end

    test "higher weight beats lower weight regardless of layer order" do
      {:ok, winners} =
        fold([
          layer({:static, "t"}, 100, [op(:set_visible, "echo", false)]),
          layer({:persisted, "g1"}, 200, [op(:set_visible, "echo", true)])
        ])

      assert {_, {{:persisted, "g1"}, 200}} = winners[{"echo", :set_visible, nil}]
    end

    test "weights decide — not layer names (AC-3.2 constructive case)" do
      # A "persisted-shaped" layer named anything at 200 flips the static hide.
      {:ok, winners} =
        fold([
          layer({:anything, "x"}, 100, [op(:set_visible, "echo", false)]),
          layer({:whatever, "y"}, 250, [op(:set_visible, "echo", true)])
        ])

      assert {{:whatever, "y"}, 250} = elem(winners[{"echo", :set_visible, nil}], 1)
    end
  end

  describe "ties (Q5: loud, even for equal ops)" do
    test "equal max-weight non-inherit ops ⇒ :weight_conflict" do
      {:error, issues} =
        fold([
          layer({:a, 1}, 200, [op(:set_visible, "echo", true)]),
          layer({:b, 2}, 200, [op(:set_visible, "echo", false)])
        ])

      assert [%{code: :weight_conflict, meta: %{weight: 200, layers: layers}}] = issues
      assert Enum.sort(layers) == [{:a, 1}, {:b, 2}]
    end

    test "two EQUAL ops at equal weight from different layers still conflict (Q5)" do
      {:error, issues} =
        fold([
          layer({:a, 1}, 100, [op(:set_visible, "echo", false)]),
          layer({:b, 2}, 100, [op(:set_visible, "echo", false)])
        ])

      assert [%{code: :weight_conflict}] = issues
    end

    test "a HIGHER opinion resolves above a tied pair below it" do
      {:ok, winners} =
        fold([
          layer({:a, 1}, 100, [op(:set_visible, "echo", false)]),
          layer({:b, 2}, 100, [op(:set_visible, "echo", true)]),
          layer({:c, 3}, 300, [op(:set_visible, "echo", true)])
        ])

      assert elem(winners[{"echo", :set_visible, nil}], 1) == {{:c, 3}, 300}
    end
  end

  describe "inherit? clearing (AC-3.3)" do
    test "inherit? at w clears all opinions ≤ w — base value stands" do
      {:ok, winners} =
        fold([
          layer({:persisted, "g1"}, 200, [op(:set_visible, "echo", true)]),
          layer({:static, "t"}, 100, [op(:set_visible, "echo", false)]),
          layer({:acl_sim}, 200, [
            struct!(op(:set_visible, "echo", true), inherit?: true)
          ])
        ])

      # Slot empty — no winner, base (visible: true) stands.
      refute Map.has_key?(winners, {"echo", :set_visible, nil})
    end

    test "inherit? yields to a strictly higher opinion" do
      {:ok, winners} =
        fold([
          layer({:acl_sim}, 200, [struct!(op(:set_visible, "echo", true), inherit?: true)]),
          layer({:high}, 300, [op(:set_visible, "echo", false)])
        ])

      assert elem(winners[{"echo", :set_visible, nil}], 1) == {{:high}, 300}
    end

    test "inherit? below the max never hides a higher opinion" do
      {:ok, winners} =
        fold([
          layer({:low_inherit}, 100, [struct!(op(:set_visible, "echo", true), inherit?: true)]),
          layer({:persisted, "g1"}, 200, [op(:set_visible, "echo", false)])
        ])

      assert elem(winners[{"echo", :set_visible, nil}], 1) == {{:persisted, "g1"}, 200}
    end

    test "an inherit?-only slot applies nothing" do
      {:ok, winners} =
        fold([layer({:acl_sim}, 300, [struct!(op(:set_callable, "echo", true), inherit?: true)])])

      assert winners == %{}
    end
  end

  describe "cross-slot composition" do
    test "different slots compose independently" do
      {:ok, winners} =
        fold([
          layer({:static, "t"}, 100, [
            op(:set_name, "echo", "ping"),
            op(:set_visible, "echo", false),
            op(:set_description, "echo", "renamed")
          ])
        ])

      assert Map.has_key?(winners, {"echo", :set_name, nil})
      assert Map.has_key?(winners, {"echo", :set_visible, nil})
      assert Map.has_key?(winners, {"echo", :set_description, nil})
    end

    test "set_visible and set_callable merge independently" do
      {:ok, winners} =
        fold([
          layer({:a}, 100, [op(:set_visible, "echo", false)]),
          layer({:b}, 200, [op(:set_callable, "echo", false)])
        ])

      assert elem(winners[{"echo", :set_visible, nil}], 1) == {{:a}, 100}
      assert elem(winners[{"echo", :set_callable, nil}], 1) == {{:b}, 200}
    end

    test "field-level ops slot per {tool, op, field}" do
      {:ok, winners} =
        fold([
          layer({:static, "t"}, 100, [
            op(:rename_field, :message, "text", tool: "echo"),
            op(:prune_enum, :mode, [:plain], tool: "echo"),
            op(:rename_field, :location, "place", tool: "get_weather")
          ])
        ])

      assert Map.has_key?(winners, {"echo", :rename_field, :message})
      assert Map.has_key?(winners, {"echo", :prune_enum, :mode})
      assert Map.has_key?(winners, {"get_weather", :rename_field, :location})
      # Same field atom on a different tool is a DIFFERENT slot.
      refute Map.has_key?(winners, {"get_weather", :rename_field, :message})
    end
  end

  describe "provenance shape (§4.3)" do
    test "%{slot => {%Override{}, {layer_id, weight}}}" do
      {:ok, winners} =
        fold([
          layer({:persisted, "grant-7"}, 200, [
            op(:set_name, "echo", "ping", tool: "echo"),
            op(:set_visible, "echo", false, tool: "echo")
          ])
        ])

      {%Override{op: :set_name, value: "ping"} = override, provenance} =
        winners[{"echo", :set_name, nil}]

      assert provenance == {{:persisted, "grant-7"}, 200}
    end

    test "winning ops are normalized to the layer's weight/layer" do
      {:ok, winners} =
        fold([layer({:x}, 250, [op(:set_visible, "echo", false, weight: 999, layer: :stale)])])

      {%Override{weight: 250, layer: {:x}}, _} = winners[{"echo", :set_visible, nil}]
    end
  end

  describe "malformed layer ops" do
    test "non-Override entries surface as :invalid_op issues, not raises" do
      {:error, issues} = fold([layer({:static, "t"}, 100, [%{"op" => "bogus"}])])
      assert [%{code: :invalid_op}] = issues
    end
  end

  describe "AP-8: the ONLY merge path" do
    test "weight resolution lives in exactly one module; non-identity Overrides.apply has one site" do
      root = Path.expand("../../../../lib/noizu/mcp", __DIR__)

      toolset_sources =
        Path.wildcard(Path.join(root, "toolset/*.ex"))
        |> Map.new(fn file -> {Path.basename(file), File.read!(file)} end)

      # The per-slot weight/inherit? resolution (Enum.max over weights) exists
      # only in merge.ex.
      for {file, source} <- toolset_sources, file != "merge.ex" do
        refute source =~ "Enum.max", "#{file} re-implements weight resolution (AP-8)"
      end

      # Overrides.apply/3 non-identity CALL SITES (not doc mentions): the
      # behaviour identity seam (literal `[]`) and custom.ex pass 3 — nothing else.
      apply_sites =
        for {file, source} <- toolset_sources,
            file != "overrides.ex" and source =~ ~r/Overrides\.apply\(/,
            do: file

      assert Enum.sort(apply_sites) == ["behaviour.ex", "custom.ex"]
      assert toolset_sources["behaviour.ex"] =~ "Overrides.apply(spec, [])"

      # PRD-1's AP-1 stays honest too: no discovery probing anywhere.
      for {file, source} <- toolset_sources do
        refute source =~ "function_exported?", file
        refute source =~ "Code.ensure_loaded?", file
      end
    end
  end
end
