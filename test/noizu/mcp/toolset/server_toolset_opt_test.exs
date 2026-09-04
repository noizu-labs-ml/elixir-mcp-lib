defmodule Noizu.MCP.Server.ToolsetOptTest do
  @moduledoc """
  §4.7 / AC-3.7: per-request `toolset:` selection — static, MFA, `:none`;
  bad-return fallback; FR-3.8 ACL×toolset composition; AP-9 (no static
  bypass through the dispatch shim; the Catalog protocol mode audits the
  SELECTED toolset).
  """

  use ExUnit.Case, async: true

  alias Noizu.MCP.{Ctx, Error, Fixtures, Toolset}
  alias Noizu.MCP.Server.Features.Tools
  alias Noizu.MCP.Server.Tools.Catalog

  defp ctx(server \\ Fixtures.Server, assigns \\ %{}),
    do: %Ctx{server: server, assigns: assigns}

  defp names({:ok, tools, _cursor}), do: Enum.map(tools, & &1.name)

  describe "static toolset value (§4.7)" do
    test "the selected toolset replaces listing AND dispatch (AC-3.1 shape)" do
      server = Fixtures.Custom.StaticToolsetServer

      assert names(server.handle_list_tools(nil, ctx(server))) == ["ping", "get_weather"]

      # renamed wire name dispatches; wire-only field rename delivers
      # original-keyed args to the handler
      {:ok, wire} =
        Tools.call(server, %{"name" => "ping", "arguments" => %{"text" => "hey"}}, ctx(server))

      assert [%{"text" => "hey"}] = wire["content"]
    end

    test "the base surface is not reachable by its pre-rename name" do
      server = Fixtures.Custom.StaticToolsetServer

      assert {:error, %Error{reason: :invalid_params}} =
               Tools.call(server, %{"name" => "echo", "arguments" => %{}}, ctx(server))
    end
  end

  describe "MFA per-request selection (AC-3.7 — the NPL per-key model)" do
    test "two request fixtures see their respective surfaces through the SAME server" do
      server = Fixtures.Custom.MFAToolsetServer

      assert names(server.handle_list_tools(nil, ctx(server, %{surface: :minimal}))) == [
               "echo"
             ]

      assert names(server.handle_list_tools(nil, ctx(server, %{surface: :weather}))) == [
               "get_weather"
             ]

      # :none ⇒ self fallback
      assert Enum.any?(
               names(server.handle_list_tools(nil, ctx(server, %{surface: :unset}))),
               &(&1 == "echo")
             )
    end

    test "dispatch through the MFA-selected surface executes the right handler" do
      server = Fixtures.Custom.MFAToolsetServer

      {:ok, wire} =
        Tools.call(
          server,
          %{"name" => "echo", "arguments" => %{"message" => "m"}},
          ctx(server, %{surface: :minimal})
        )

      assert [%{"text" => "m"}] = wire["content"]

      assert {:error, %Error{reason: :invalid_params}} =
               Tools.call(
                 server,
                 %{"name" => "echo", "arguments" => %{}},
                 ctx(server, %{surface: :weather})
               )
    end

    test "garbage MFA return ⇒ warn + self fallback (fail-open per server)" do
      server = Fixtures.Custom.GarbageToolsetServer

      assert {:ok, tools, _} = server.handle_list_tools(nil, ctx(server))
      assert Enum.any?(tools, &(&1.name == "echo"))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, _, _} = server.handle_list_tools(nil, ctx(server))
        end)

      assert log =~ "toolset:"
    end

    test "raising MFA ⇒ warn + self fallback" do
      server = Fixtures.Custom.RaisingToolsetServer

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, tools, _} = server.handle_list_tools(nil, ctx(server))
          assert Enum.any?(tools, &(&1.name == "echo"))
        end)

      assert log =~ "resolver exploded"
    end
  end

  describe "FR-3.8: `toolset:` + ACL compose correctly" do
    test "ACL denies apply to the SELECTED toolset's entries" do
      server = Fixtures.Custom.ACLCustomServer
      ctx = ctx(server)

      # listing hides the ACL-denied tool even though the slice includes it
      assert names(server.handle_list_tools(nil, ctx)) == ["get_weather"]

      # uncallable — resolves like an absent tool (existence-hiding)
      assert {:error, %Error{reason: :invalid_params, message: "Unknown tool: echo"}} =
               Tools.call(server, %{"name" => "echo", "arguments" => %{}}, ctx)

      # permissions/3 reports it — audited through the SELECTED surface
      selected = Tools.select_toolset(server, ctx)

      assert {:ok, %{tools: tools}} = Toolset.permissions(selected, ctx, [])
      assert Enum.map(tools, & &1.name) == ["echo", "get_weather"]

      echo = Enum.find(tools, &(&1.name == "echo"))
      assert echo.visible == false and echo.callable == false

      weather = Enum.find(tools, &(&1.name == "get_weather"))
      assert weather.visible == true and weather.callable == true
    end

    test "immutable slice: ACL deny still folds (security invariant, §4.1)" do
      server = Fixtures.Custom.ImmutableACLServer
      ctx = ctx(server)

      assert names(server.handle_list_tools(nil, ctx)) == ["get_weather"]
    end
  end

  describe "AP-9: no bypass surface with `toolset:` configured" do
    test "the dispatch SHIM honors the selection (PRD-2's AP-5 through composition)" do
      server = Fixtures.Custom.StaticToolsetServer

      # get_weather is included; "slow" is excluded from the slice — the shim
      # must NOT fall back to the raw registry for it
      assert {:error, %Error{reason: :invalid_params, message: "Unknown tool: slow"}} =
               Tools.dispatch(server.__mcp__(:tools), "slow", %{}, ctx(server))

      # the included, renamed tool still dispatches through the same shim
      assert %Noizu.MCP.Types.ToolResult{} =
               Tools.dispatch(server.__mcp__(:tools), "ping", %{"text" => "x"}, ctx(server))
    end

    test "Catalog protocol mode enumerates the SELECTED toolset; static mode stays raw (§4.8)" do
      server = Fixtures.Custom.CatalogProbeServer
      ctx = ctx(server)

      {:ok, %{"tools" => protocol}} = Catalog.call(%{"type" => "tools"}, ctx)
      by_name = Map.new(protocol, &{&1["name"], &1})

      assert MapSet.new(Map.keys(by_name)) == MapSet.new(["echo", "catalog"])
      assert by_name["echo"]["description"] == "Echo via probe"
      # the audit surface carries effective per-caller state
      assert by_name["catalog"]["visible"] == false
      assert by_name["catalog"]["callable"] == true

      {:ok, %{"tools" => static}} = Catalog.call(%{"type" => "tools", "mode" => "static"}, ctx)
      assert Enum.any?(static, &(&1["name"] == "echo"))
      assert Enum.find(static, &(&1["name"] == "catalog"))["hidden"] == true
      refute Map.has_key?(Enum.find(static, &(&1["name"] == "echo")), "visible")
    end
  end

  describe "select_toolset/2 unit matrix (FR-3.7)" do
    test "non-server toolset values pass through untouched" do
      custom = %Toolset.Custom{slug: "s", base: Fixtures.Server}
      assert Tools.select_toolset(custom, ctx()) == custom

      ref = %Toolset.Ref{target: Fixtures.Server}
      assert Tools.select_toolset(ref, ctx()) == ref
    end

    test "servers without the opt resolve to themselves" do
      assert Tools.select_toolset(Fixtures.Server, ctx()) == Fixtures.Server
    end

    test "modules lacking __mcp__ resolve to themselves (no probing)" do
      assert Tools.select_toolset(Fixtures.NotAToolset, ctx()) == Fixtures.NotAToolset
    end
  end
end
