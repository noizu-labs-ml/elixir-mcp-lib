defmodule Noizu.MCP.Toolset.ServerProtocolIntegrationTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.{Ctx, Error, Toolset}
  alias Noizu.MCP.Fixtures
  alias Noizu.MCP.Server.Features.Tools
  alias Noizu.MCP.Types.ToolResult

  defp ctx(server \\ Fixtures.Server), do: %Ctx{server: server, assigns: %{}}

  describe "AC-1.1: wire parity between the protocol path and the static path" do
    test "generated handle_list_tools output == list_registered output" do
      {:ok, tools_protocol, cursor_protocol} = Fixtures.Server.handle_list_tools(nil, ctx())

      {:ok, tools_static, cursor_static} =
        Tools.list_registered(Fixtures.Server.__mcp__(:tools), nil)

      assert tools_protocol == tools_static
      assert cursor_protocol == cursor_static
    end

    test "paginated parity: cursor handling identical to the static path" do
      # Under the default page size the fixture fits one page (nil cursor on
      # both paths), and an invalid cursor fails identically on both paths.
      {:ok, _tools, protocol_cursor} = Fixtures.Server.handle_list_tools(nil, ctx())

      {:ok, _tools, static_cursor} =
        Tools.list_registered(Fixtures.Server.__mcp__(:tools), nil)

      assert protocol_cursor == static_cursor

      assert {:error, protocol_error} = Fixtures.Server.handle_list_tools("bogus", ctx())

      assert {:error, static_error} =
               Tools.list_registered(Fixtures.Server.__mcp__(:tools), "bogus")

      assert protocol_error.message == static_error.message
    end

    test "generated handle_call_tool output == dispatch output (full wire map)" do
      {:ok, wire} =
        Tools.call(
          Fixtures.Server,
          %{"name" => "echo", "arguments" => %{"message" => "hey", "mode" => "loud"}},
          ctx()
        )

      result =
        Tools.dispatch(
          Fixtures.Server.__mcp__(:tools),
          "echo",
          %{"message" => "hey", "mode" => "loud"},
          ctx()
        )

      assert %ToolResult{} = result
      assert wire == ToolResult.to_map(result)
    end

    test "raw-schema and toolkit tools route identically through the protocol" do
      {:ok, wire} =
        Tools.call(
          Fixtures.Server,
          %{"name" => "raw_schema", "arguments" => %{"query" => "k8s"}},
          ctx()
        )

      assert [%{"text" => "raw:k8s"}] = wire["content"]

      kit_args = %{"name" => "kit.echo", "arguments" => %{"message" => "yo"}}

      {:ok, kit_wire} = Tools.call(Fixtures.KitServer, kit_args, ctx(Fixtures.KitServer))

      assert kit_wire ==
               Fixtures.KitServer.__mcp__(:tools)
               |> Tools.dispatch("kit.echo", %{"message" => "yo"}, ctx(Fixtures.KitServer))
               |> ToolResult.to_map()
    end

    test "hidden tools stay off tools/list but callable on the wire (HiddenServer)" do
      server = Fixtures.HiddenServer
      {:ok, tools, _} = server.handle_list_tools(nil, ctx(server))
      refute Enum.any?(tools, &(&1.name == "hidden_tool"))

      {:ok, wire} =
        Tools.call(server, %{"name" => "hidden_tool", "arguments" => %{}}, ctx(server))

      assert [%{"text" => "hidden result"}] = wire["content"]
    end
  end

  describe "FR-1.4: host handle_* overrides keep winning (defines? guards)" do
    test "host-defined handle_call_tool intercepts its own names" do
      assert {:ok, "host:host_ping"} =
               Fixtures.HostOverrideServer.handle_call_tool("host_ping", %{}, ctx())
    end

    test "host handler defers to the lib shim for registry tools" do
      assert %ToolResult{is_error: false, content: [%{text: "here"}]} =
               Fixtures.HostOverrideServer.handle_call_tool("echo", %{"message" => "here"}, ctx())
    end

    test "host server still gets generated protocol listing (no handle_list_tools override)" do
      assert {:ok, tools, _} = Fixtures.HostOverrideServer.handle_list_tools(nil, ctx())
      assert Enum.any?(tools, &(&1.name == "echo"))
    end
  end

  describe "D5: broken toolsets disable the set, not the server (AP-1)" do
    test "a Ref to a module lacking behaviour functions normalizes to a protocol error" do
      assert {:error, %Error{reason: :internal}} =
               Tools.protocol_list(%Toolset.Ref{target: Fixtures.NotAToolset}, nil, ctx())

      assert {:error, %Error{reason: :internal}} =
               Tools.protocol_call(
                 %Toolset.Ref{target: Fixtures.NotAToolset},
                 "echo",
                 %{},
                 ctx()
               )
    end

    test "the server's other surfaces are unaffected after a broken-toolset failure" do
      assert {:error, %Error{}} =
               Tools.protocol_list(%Toolset.Ref{target: Fixtures.NotAToolset}, nil, ctx())

      {:ok, tools, _} = Fixtures.Server.handle_list_tools(nil, ctx())
      assert Enum.any?(tools, &(&1.name == "echo"))
    end

    test "the protocol path never probes user modules for discovery" do
      # AP-1 letter: no Code.ensure_loaded?/function_exported? anywhere in the
      # toolset dispatch path. Asserted against the source, not just behavior.
      root = Path.expand("../../../../lib/noizu/mcp/toolset", __DIR__)

      for file <- Path.wildcard(Path.join(root, "*.ex")) do
        source = File.read!(file)
        refute source =~ "function_exported?", file
        refute source =~ "Code.ensure_loaded?", file
      end
    end
  end

  describe "struct/server duality (AC-1.2)" do
    test "a behaviour-backed struct is catalogable/resolvable/invokable like a server module" do
      toolset = %Fixtures.StructToolset{}

      assert {:ok, entries, version} = Toolset.catalog(toolset, ctx(), [])
      assert Enum.any?(entries, &(&1.definition.name == "echo"))
      assert String.length(version) == 16

      assert {:ok, effective} = Toolset.resolve(toolset, "echo", ctx(), [])

      assert %ToolResult{is_error: false, content: [%{text: "hey"}]} =
               Toolset.invoke(toolset, effective, %{"message" => "hey"}, ctx(), [])
    end

    test "cataloging a server and its equivalent Static agree byte-for-byte" do
      {:ok, server_entries, server_version} = Toolset.catalog(Fixtures.Server, ctx(), [])

      {:ok, static_entries, static_version} =
        Toolset.catalog(
          %Toolset.Static{specs: Tools.expand(Fixtures.Server.__mcp__(:tools))},
          ctx(),
          []
        )

      assert server_entries == static_entries
      assert server_version == static_version
    end
  end
end
