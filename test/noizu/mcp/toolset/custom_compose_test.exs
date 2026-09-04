defmodule Noizu.MCP.Toolset.CustomComposeTest do
  @moduledoc """
  §4.4 pipeline: static → context → materialize. AC-3.1 (filtered/renamed
  surface + wire_key e2e through composition), AC-3.5 (immutable vs persisted
  vs ACL), nested bases, cycles, D5 disables, telemetry, and the AP-7
  registry-brittleness regression.
  """

  use ExUnit.Case, async: true

  alias Noizu.MCP.{Ctx, Error, Toolset}
  alias Noizu.MCP.Fixtures
  alias Noizu.MCP.Toolset.{Custom, Layer, Override}

  defp ctx(server \\ Fixtures.Server, assigns \\ %{}),
    do: %Ctx{server: server, assigns: assigns}

  defp names({:ok, entries, _version}), do: Enum.map(entries, & &1.definition.name)

  defp slice(opts \\ []),
    do:
      %Custom{slug: "slice", base: Fixtures.Server, tools: %{}}
      |> struct!(opts)

  # ── AC-3.1: static pass matrix ─────────────────────────────────────────────

  describe "exclude/include + per-tool ops (AC-3.1)" do
    test "listing shows the filtered, renamed, re-described surface" do
      toolset = %Custom{
        slug: "echo-ping",
        base: Fixtures.Server,
        include: ["echo", "get_weather"],
        tools: %{
          "echo" => [
            %Override{op: :set_name, target: "echo", value: "ping"},
            %Override{op: :set_description, target: "echo", value: "Ping via custom"},
            %Override{op: :rename_field, target: :message, value: "text"}
          ]
        }
      }

      {:ok, entries, version} = Custom.compose(toolset, ctx(), [])
      assert String.length(version) == 16

      # base registration order preserved through include+rename
      assert Enum.map(entries, & &1.definition.name) == ["ping", "get_weather"]
      ping = Enum.find(entries, &(&1.definition.name == "ping"))
      assert ping.definition.description == "Ping via custom"
      # Wire-only field rename: the wire schema advertises "text"...
      assert Map.has_key?(ping.definition.input_schema["properties"], "text")
      refute Map.has_key?(ping.definition.input_schema["properties"], "message")
      # ...and the cast plan still emits the ORIGINAL field atom.
      assert Enum.any?(ping.cast_plan, &(&1.wire_key == "text" and &1.key == "message"))

      # excluded tools are GONE (not visible: false)
      refute Enum.any?(entries, &(&1.definition.name in ["echo", "slow", "fail"]))
    end

    test "invocation works under the renamed wire name; handler receives original-keyed args" do
      toolset = %Custom{
        slug: "echo-ping",
        base: Fixtures.Server,
        tools: %{
          "echo" => [%Override{op: :rename_field, target: :message, value: "text"}]
        }
      }

      {:ok, effective} = Toolset.resolve(toolset, "echo", ctx(), [])

      assert %Noizu.MCP.Types.ToolResult{is_error: false, content: [%{text: "HEY"}]} =
               Toolset.invoke(toolset, effective, %{"text" => "hey", "mode" => "loud"}, ctx(), [])
    end

    test "resolve is by POST-rename wire name; base name stops resolving" do
      toolset = %Custom{
        slug: "renamer",
        base: Fixtures.Server,
        tools: %{"echo" => [%Override{op: :set_name, target: "echo", value: "ping"}]}
      }

      assert {:ok, %Toolset.Effective{name: "ping"}} = Toolset.resolve(toolset, "ping", ctx(), [])

      assert {:error, %Error{reason: :invalid_params, message: "Unknown tool: echo"}} =
               Toolset.resolve(toolset, "echo", ctx(), [])

      assert {:error, %Error{reason: :invalid_params}} =
               Toolset.resolve(toolset, "never_there", ctx(), [])
    end

    test "exclude removes entirely and runs BEFORE include (overlap ⇒ excluded)" do
      toolset = slice(include: ["echo", "get_weather", "slow"], exclude: ["echo", "slow"])

      assert names(Custom.compose(toolset, ctx(), [])) == ["get_weather"]
    end

    test "include: nil keeps the whole base" do
      {:ok, entries, _} = Custom.compose(slice(), ctx(), [])
      assert "echo" in names({:ok, entries, nil})
      assert "get_weather" in names({:ok, entries, nil})
      assert "whoami" in names({:ok, entries, nil})
    end

    test "permissions/3 exposes name/visible/callable only (no reason leakage)" do
      toolset =
        slice(tools: %{"echo" => [%Override{op: :set_visible, target: "echo", value: false}]})

      assert {:ok, %{tools: tools, version: version}} = Toolset.permissions(toolset, ctx(), [])

      echo = Enum.find(tools, &(&1.name == "echo"))
      assert echo == %{name: "echo", visible: false, callable: true}
      assert is_binary(version)
    end

    test "metadata/3 reports the custom toolset identity + composed version" do
      toolset = %Custom{
        slug: "meta-slice",
        base: Fixtures.Server,
        include: ["echo"],
        title: "Meta",
        description: "Meta slice"
      }

      assert {:ok, %{slug: "meta-slice", title: "Meta", description: "Meta slice", version: v}} =
               Toolset.metadata(toolset, ctx(), [])

      assert String.length(v) == 16
    end

    test "composition never mutates the base specs (FR-3.4 purity at scale)" do
      before = Fixtures.Echo.__mcp_tools__() |> hd()

      toolset = %Custom{
        slug: "purity",
        base: Fixtures.Server,
        tools: %{
          "echo" => [
            %Override{op: :set_name, target: "echo", value: "ping"},
            %Override{op: :hide_field, target: :repeat, value: true}
          ]
        }
      }

      {:ok, _, _} = Custom.compose(toolset, ctx(), [])
      assert Fixtures.Echo.__mcp_tools__() |> hd() == before
    end
  end

  # ── nested bases ───────────────────────────────────────────────────────────

  describe "nested %Custom{} bases (FR-3.9)" do
    test "inner ops fold at weight 100 under {:static, inner_slug}" do
      inner = %Custom{
        slug: "inner",
        base: Fixtures.Server,
        include: ["echo"],
        tools: %{"echo" => [%Override{op: :set_description, target: "echo", value: "inner says"}]}
      }

      outer = %Custom{
        slug: "outer",
        base: inner,
        tools: %{"echo" => [%Override{op: :set_name, target: "echo", value: "ping"}]}
      }

      {:ok, effective} = Toolset.resolve(outer, "ping", ctx(), [])

      # The outer op won its slot; the inner op won its own — both applied (D2).
      assert effective.name == "ping"
      assert effective.entry.definition.description == "inner says"

      # provenance records WHICH layer won each op
      assert effective.provenance[{"echo", :set_name, nil}] == {{:static, "outer"}, 100}

      assert effective.provenance[{"echo", :set_description, nil}] ==
               {{:static, "inner"}, 100}
    end

    test "inner include/exclude apply within the inner scope; outer filter applies on top" do
      inner = %Custom{slug: "inner", base: Fixtures.Server, include: ["echo", "get_weather"]}
      outer = %Custom{slug: "outer", base: inner, exclude: ["get_weather"]}

      assert names(Custom.compose(outer, ctx(), [])) == ["echo"]
    end

    test "the inner context pass never runs: top-level layers apply ONCE (no per-inner re-pass)" do
      inner = %Custom{slug: "inner", base: Fixtures.Server, include: ["echo"], immutable: true}

      outer = %Custom{slug: "outer", base: inner}

      layers = [
        %Layer{
          id: {:persisted, "g1"},
          weight: 200,
          ops: [%Override{op: :set_visible, target: "echo", value: false, tool: "echo"}]
        }
      ]

      # Context layers belong to the TOP-LEVEL invocation only — the inner
      # never runs its own context pass, and the op applies exactly once.
      {:ok, entries, _} = Custom.compose(outer, ctx(), context_layers: layers)

      assert %{visible: false} =
               Enum.find(entries, &(&1.definition.name == "echo")) |> Map.take([:visible])
    end

    test "slug cycle ⇒ :cycle issue, toolset disabled (D5)" do
      c = %Custom{slug: "self", base: nil}
      cyclic = %{c | base: %{c | base: c}}

      assert {:error, %Error{reason: :internal, data: %{toolset: "self", issues: issues}}} =
               Custom.compose(cyclic, ctx(), [])

      assert Enum.any?(issues, &(&1.code == :cycle))
    end
  end

  # ── AC-3.5: immutable vs persisted vs ACL ──────────────────────────────────

  describe "immutability (AC-3.5)" do
    defp persisted_show_layer do
      %Layer{
        id: {:persisted, "grant-7"},
        weight: 200,
        ops: [%Override{op: :set_visible, target: "echo", value: true, tool: "echo"}]
      }
    end

    test "persisted layers do NOT apply to an immutable toolset" do
      toolset = %Custom{
        slug: "imm",
        base: Fixtures.Server,
        include: ["echo"],
        immutable: true,
        tools: %{"echo" => [%Override{op: :set_visible, target: "echo", value: false}]}
      }

      {:ok, entries, _} = Custom.compose(toolset, ctx(), context_layers: [persisted_show_layer()])
      refute Enum.find(entries, &(&1.definition.name == "echo")).visible
    end

    test "the SAME layer DOES apply when the toolset is mutable (weights decide)" do
      toolset = %Custom{
        slug: "mut",
        base: Fixtures.Server,
        include: ["echo"],
        tools: %{"echo" => [%Override{op: :set_visible, target: "echo", value: false}]}
      }

      {:ok, entries, _} = Custom.compose(toolset, ctx(), context_layers: [persisted_show_layer()])
      assert Enum.find(entries, &(&1.definition.name == "echo")).visible
    end

    test "ACL deny STILL applies to an immutable toolset (security invariant)" do
      toolset = %Custom{
        slug: "imm-acl",
        base: Fixtures.Server,
        include: ["echo"],
        immutable: true
      }

      {:ok, entries, _} = Custom.compose(toolset, ctx(Fixtures.Custom.ImmutableACLServer), [])

      echo = Enum.find(entries, &(&1.definition.name == "echo"))
      assert echo.visible == false and echo.callable == false
      assert echo.reason == {:acl, Fixtures.Custom.DenyEchoProvider}
    end
  end

  # ── D5 disables + AP-7 ─────────────────────────────────────────────────────

  describe "D5: invalid toolsets disable themselves, the server stays healthy" do
    test "bad base module ⇒ internal error carrying the toolset slug" do
      toolset = %Custom{slug: "broken", base: :no_such_module_anywhere}

      assert {:error, %Error{reason: :internal, data: %{toolset: "broken", issues: issues}}} =
               Custom.compose(toolset, ctx(), [])

      assert Enum.any?(issues, &(&1.code == :unknown_base))
    end

    test "validator-invalid toolset ⇒ disabled with issues; other surfaces unaffected (AC-3.4 e2e shape)" do
      toolset = %Custom{
        slug: "collider",
        base: Fixtures.Server,
        include: ["echo", "get_weather"],
        tools: %{"echo" => [%Override{op: :set_name, target: "echo", value: "get_weather"}]}
      }

      assert {:error, %Error{reason: :internal, data: %{toolset: "collider", issues: issues}}} =
               Custom.compose(toolset, ctx(), [])

      assert Enum.any?(issues, &(&1.code == :name_collision))

      # the server's other surfaces stay healthy
      assert {:ok, tools, _} = Fixtures.Server.handle_list_tools(nil, ctx())
      assert Enum.any?(tools, &(&1.name == "echo"))
    end

    test "compose failure surfaces through protocol surfaces as a protocol error" do
      toolset = %Custom{slug: "broken", base: :no_such_module_anywhere}

      assert {:error, %Error{reason: :internal}} =
               Toolset.catalog(toolset, ctx(), [])

      assert {:error, %Error{reason: :internal}} =
               Toolset.resolve(toolset, "echo", ctx(), [])
    end
  end

  # ── telemetry (FR-3.11) ────────────────────────────────────────────────────

  describe "telemetry" do
    defp attach(event, ref) do
      :telemetry.attach(
        {ref, event},
        event,
        fn _e, measurements, meta, _ ->
          send(self(), {:toolset_event, event, measurements, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach({ref, event}) end)
    end

    test "[:noizu_mcp, :toolset, :compose] carries toolset/layers/cached" do
      attach([:noizu_mcp, :toolset, :compose], make_ref())

      {:ok, _, _} = Custom.compose(slice(include: ["echo"]), ctx(), [])

      assert_receive {:toolset_event, [:noizu_mcp, :toolset, :compose], %{duration: d}, meta}
      assert is_integer(d)
      assert meta.toolset == "slice"
      assert is_integer(meta.layers) and meta.layers > 0
      assert meta.cached == false
    end

    test "[:noizu_mcp, :toolset, :compose_error] on D5 disables" do
      attach([:noizu_mcp, :toolset, :compose_error], make_ref())

      assert {:error, %Error{}} = Custom.compose(%Custom{slug: "boom", base: :missing}, ctx(), [])

      assert_receive {:toolset_event, [:noizu_mcp, :toolset, :compose_error], _,
                      %{toolset: "boom"}}
    end
  end

  # ── AP-7: registry brittleness ─────────────────────────────────────────────

  describe "AP-7: compose never scans modules" do
    test "no module scanning in the toolset source tree (source-level regression)" do
      root = Path.expand("../../../../lib/noizu/mcp/toolset", __DIR__)

      for file <- Path.wildcard(Path.join(root, "*.ex")) do
        source = File.read!(file)
        refute source =~ "function_exported?", file
        refute source =~ "Code.ensure_loaded?", file
        refute source =~ "Code.ensure_compiled?", file
        refute source =~ ":application.which_applications", file
        refute source =~ "Application.loaded_applications", file
      end
    end

    test "%Custom{base: :nonexistent_mod} disables THAT toolset; the server is healthy" do
      toolset = %Custom{slug: "ghost", base: :nonexistent_mod}

      assert {:error, %Error{reason: :internal}} = Toolset.catalog(toolset, ctx(), [])

      {:ok, entries, _} = Toolset.catalog(Fixtures.Server, ctx(), [])
      assert Enum.any?(entries, &(&1.definition.name == "echo"))
    end
  end
end
