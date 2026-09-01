defmodule Noizu.MCP.Toolset.MergeMatrixTest do
  @moduledoc """
  FR-3.12 — the NPL toolset matrix (monorepo
  `Portfolio/Apps/AI/NoizuPromptLingo/backend/test/noizu_prompt_lingua/mcp/
  effective_toolset_matrix_test.exs`) re-expressed in lib vocabulary against
  the weighted merge engine (§7 mapping table):

    | NPL case shape                                | lib-port assertion                          |
    |-----------------------------------------------|---------------------------------------------|
    | scope layer vs client layer, most-specific    | persisted (200) beats static (100)          |
    | per-tool entry beats its group's flags        | equal-weight per-tool vs blanket ⇒
                                                      :weight_conflict (lib has no implicit
                                                      groups; explicit layers must be
                                                      weight-ordered — the error path NPL
                                                      avoids by convention is LOUD here) |
    | boolean overrides (enabled/visible)           | :set_visible/:set_callable slots merge
                                                      independently                        |
    | name_override / description_override          | :set_name/:set_description + charset/
                                                      uniqueness validation                 |
    | ACL final override (deny hides+disables)      | weight-300 ACL beats 100/200 (AC-3.2)       |
    | absent-from-every-layer ⇒ enabled+visible     | absent slots ⇒ base entry stands            |
    | expires_at window (MCP.Window)                | NOT ported — expiry lives on grant/
                                                      negotiation records (PRD-4 §5)        |

  Semantics preserved from NPL: `enabled: false` blocks execution AND drops
  from listings (callable: false ⇒ also unlisted once the caller filters);
  `visible: false` blocks listing only (still callable); clients never ADD
  tools (the base surface governs — explicit participation, D4).
  """

  use ExUnit.Case, async: true

  alias Noizu.MCP.{Ctx, Fixtures}
  alias Noizu.MCP.Toolset.{Custom, Layer, Merge, Override}

  defp ctx, do: %Ctx{server: Fixtures.Server, assigns: %{}}

  defp compose(toolset, opts \\ []), do: Custom.compose(toolset, ctx(), opts)

  defp static_layer(id, weight, ops), do: %Layer{id: id, weight: weight, ops: ops}

  defp entry_by(entries, name), do: Enum.find(entries, &(&1.definition.name == name))

  # "clients never add tools": every fixture slices the SAME base catalog.

  describe "most-specific-wins across layers (scope vs client port)" do
    test "persisted-shaped layer (200) beats static (100) on the same slot" do
      toolset = %Custom{
        slug: "mm-static-hide",
        base: Fixtures.Server,
        include: ["echo"],
        tools: %{
          "echo" => [%Override{op: :set_visible, target: "echo", value: false, tool: "echo"}]
        }
      }

      client_layer =
        static_layer({:persisted, "key-1"}, 200, [
          %Override{op: :set_visible, target: "echo", value: true, tool: "echo"}
        ])

      assert {:ok, entries, _} = compose(toolset, context_layers: [client_layer])
      # the more-specific (client) layer won: the tool is visible again
      assert entry_by(entries, "echo").visible
    end
  end

  describe "per-tool entry vs its group's flags" do
    test "equal-weight per-tool vs blanket op on the same slot ⇒ :weight_conflict (loud)" do
      # NPL orders group flags below per-tool entries BY CONVENTION; the lib
      # has no implicit groups — equal-weight explicit layers conflict loudly
      # instead of silently picking one (Q5: loud).
      layer_a =
        static_layer({:group_like, "g"}, 100, [
          %Override{op: :set_visible, target: "echo", value: false, tool: "echo"}
        ])

      layer_b =
        static_layer({:tool_like, "t"}, 100, [
          %Override{op: :set_visible, target: "echo", value: true, tool: "echo"}
        ])

      assert {:error, issues} = Merge.fold([layer_a, layer_b])
      assert Enum.any?(issues, &(&1.code == :weight_conflict))
    end

    test "weight-ordered explicit layers reproduce the NPL group/per-tool outcome" do
      # group at 100, per-tool at 150: per-tool wins — the NPL convention,
      # now explicit
      group =
        static_layer({:group_like, "g"}, 100, [
          %Override{op: :set_visible, target: "echo", value: false, tool: "echo"},
          %Override{op: :set_visible, target: "get_weather", value: false, tool: "get_weather"}
        ])

      per_tool =
        static_layer({:tool_like, "t"}, 150, [
          %Override{op: :set_visible, target: "echo", value: true, tool: "echo"}
        ])

      toolset = %Custom{
        slug: "mm-ordered",
        base: Fixtures.Server,
        include: ["echo", "get_weather"]
      }

      assert {:ok, entries, _} = compose(toolset, context_layers: [group, per_tool])
      assert entry_by(entries, "echo").visible
      refute entry_by(entries, "get_weather").visible
      # visible:false hides from listing but stays callable (NPL I4)
      assert entry_by(entries, "get_weather").callable
    end
  end

  describe "boolean overrides merge independently" do
    test "visible and callable flip separately across layers" do
      hide_layer =
        static_layer({:persisted, "a"}, 200, [
          %Override{op: :set_visible, target: "echo", value: false, tool: "echo"}
        ])

      disable_layer =
        static_layer({:persisted, "b"}, 210, [
          %Override{op: :set_callable, target: "echo", value: false, tool: "echo"}
        ])

      toolset = %Custom{slug: "mm-bools", base: Fixtures.Server, include: ["echo"]}

      # visible:false alone ⇒ hidden but callable (NPL I4)
      assert {:ok, [entry], _} = compose(toolset, context_layers: [hide_layer])
      assert %{visible: false, callable: true} = Map.take(entry, [:visible, :callable])

      # callable:false alone ⇒ callable dropped from dispatch; visible stays
      assert {:ok, [entry], _} = compose(toolset, context_layers: [disable_layer])
      assert %{visible: true, callable: false} = Map.take(entry, [:visible, :callable])
    end
  end

  describe "name_override / description_override" do
    test "set_name/set_description slots compose; charset + uniqueness validated" do
      toolset = %Custom{
        slug: "mm-names",
        base: Fixtures.Server,
        include: ["echo", "get_weather"],
        tools: %{
          "echo" => [
            %Override{op: :set_name, target: "echo", value: "ping_it"},
            %Override{op: :set_description, target: "echo", value: "The renamed echo"}
          ]
        }
      }

      assert {:ok, entries, _} = compose(toolset)
      assert entry_by(entries, "ping_it").definition.description == "The renamed echo"
      # the sibling tool keeps its base name (clients never add tools)
      assert entry_by(entries, "get_weather").definition.name == "get_weather"

      # uniqueness: renaming onto another effective name ⇒ disabled (D5)
      colliding = %Custom{
        slug: "mm-names-bad",
        base: Fixtures.Server,
        include: ["echo", "get_weather"],
        tools: %{"echo" => [%Override{op: :set_name, target: "echo", value: "get_weather"}]}
      }

      assert {:error, %{data: %{issues: issues}}} = compose(colliding)
      assert Enum.any?(issues, &(&1.code == :name_collision))
    end
  end

  describe "ACL final override (deny hides + disables)" do
    test "weight-300 ACL beats 100/200 opinions; allow-no-rules stays a no-op" do
      server = Fixtures.Custom.ACLCustomServer
      ctx = %Ctx{server: server, assigns: %{}}

      toolset = %Custom{slug: "mm-acl", base: Fixtures.Server, include: ["echo", "get_weather"]}

      static_allow =
        static_layer({:static, "t"}, 100, [
          %Override{op: :set_visible, target: "echo", value: true, tool: "echo"}
        ])

      persisted_allow =
        static_layer({:persisted, "k"}, 200, [
          %Override{op: :set_callable, target: "echo", value: true, tool: "echo"}
        ])

      # ACL layer built exactly the way the pipeline builds it
      {provider, check_opts} = Noizu.MCP.ACL.Provider.resolve_provider(server, [])
      {:ok, base_entries, _} = compose(toolset)

      acl =
        Noizu.MCP.Toolset.Context.acl_layer(base_entries, provider, check_opts, ctx)

      assert {:ok, entries, _} =
               compose(toolset, context_layers: [static_allow, persisted_allow, acl])

      denied = entry_by(entries, "echo")
      assert denied.visible == false and denied.callable == false
      assert denied.reason == {:acl, Fixtures.Custom.DenyEchoProvider}

      # no ACL opinion on get_weather — the lower layers' world stands
      allowed = entry_by(entries, "get_weather")
      assert allowed.visible and allowed.callable
    end
  end

  describe "absent from every layer ⇒ base stands (inverted defaults)" do
    test "tools with no opinions anywhere keep their base state" do
      toolset = %Custom{
        slug: "mm-absent",
        base: Fixtures.Server,
        include: ["echo", "get_weather", "whoami"],
        tools: %{
          "echo" => [%Override{op: :set_visible, target: "echo", value: false, tool: "echo"}]
        }
      }

      assert {:ok, entries, _} = compose(toolset)

      # only the op'd tool changed; the others inherit enabled+visible
      assert entry_by(entries, "whoami").visible and entry_by(entries, "whoami").callable
      assert entry_by(entries, "get_weather").visible
      refute entry_by(entries, "echo").visible
    end
  end

  # expires_at windows are NOT ported: grant/negotiation records (PRD-4 §5)
  # own temporal state; the merge engine stays policy-agnostic (Decision 2).
end
