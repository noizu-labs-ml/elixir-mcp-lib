defmodule Noizu.MCP.ACL.ACLRegistrationTest do
  @moduledoc """
  `use Noizu.MCP.Server, acl: ...` — compile-time validation (§4.7) and the
  end-to-end enforcement guarantees (AC-2.2 / AC-2.3 / AC-2.4).
  """

  use ExUnit.Case, async: true

  import Noizu.MCP.Test

  alias Noizu.MCP.ACL
  alias Noizu.MCP.Ctx
  alias Noizu.MCP.Fixtures

  @await timeout: 2_000

  defp compile_ok?(code) do
    case Code.compile_string(code) do
      modules when is_list(modules) -> {:ok, modules}
      other -> {:ok, other}
    end
  rescue
    e in CompileError -> {:error, e}
  end

  describe "compile-time `acl:` validation (FR-2.8)" do
    test "a module without the Provider callbacks fails at use expansion" do
      uid = System.unique_integer([:positive])

      code = """
      defmodule Noizu.MCP.Fixtures.ACL.NotAProvider#{uid} do
        def check(_s, _r, _a, _c, _o), do: :allow
      end

      defmodule Noizu.MCP.Fixtures.ACL.BadServer#{uid} do
        use Noizu.MCP.Server,
          name: "bad-#{uid}",
          version: "1.0.0",
          acl: Noizu.MCP.Fixtures.ACL.NotAProvider#{uid}
      end
      """

      assert {:error, %CompileError{description: description}} = compile_ok?(code)
      assert description =~ "Noizu.MCP.ACL.Provider"
      assert description =~ "missing callbacks"
    end

    test "an unavailable provider module fails at use expansion" do
      uid = System.unique_integer([:positive])

      code = """
      defmodule Noizu.MCP.Fixtures.ACL.GhostServer#{uid} do
        use Noizu.MCP.Server,
          name: "ghost-#{uid}",
          version: "1.0.0",
          acl: Noizu.MCP.Fixtures.ACL.NeverDefined#{uid}
      end
      """

      assert {:error, %CompileError{description: description}} = compile_ok?(code)
      assert description =~ "not available"
    end

    test "every literal form is accepted and stored raw in __mcp_server_opts__" do
      assert Fixtures.ACL.DisabledServer.__mcp__(:opts)[:acl] == :disabled
      assert Fixtures.ACL.DenyAllServer.__mcp__(:opts)[:acl] == :deny_all

      assert Fixtures.ACL.PartialServer.__mcp__(:opts)[:acl] ==
               Fixtures.ACL.PartialBatchProvider

      assert Fixtures.ACL.FlakyServer.__mcp__(:opts)[:acl] == Fixtures.ACL.FlakyProvider
    end

    test "the Provider behaviour satisfies the callback check itself" do
      behaviours =
        Fixtures.ACL.PartialBatchProvider.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Noizu.MCP.ACL.Provider in behaviours
      assert function_exported?(Fixtures.ACL.PartialBatchProvider, :check_all, 5)
    end
  end

  describe "acl: :deny_all end to end (AC-2.2)" do
    test "tools/list is empty and tools/call is indistinguishable from an unknown tool" do
      client = connect(Fixtures.ACL.DenyAllServer)

      assert {:ok, %{"tools" => []}} = request(client, "tools/list", nil, @await)

      denied = request(client, "tools/call", %{"name" => "echo", "arguments" => %{}}, @await)

      unknown =
        request(client, "tools/call", %{"name" => "not_a_tool", "arguments" => %{}}, @await)

      assert {:error, denied_error} = denied
      assert {:error, unknown_error} = unknown

      # Existence-hiding: the same constructor, same code/reason — only the
      # requested name differs (echoed in the message exactly like an absent
      # tool's).
      assert denied_error["code"] == unknown_error["code"]
      assert denied_error["reason"] == unknown_error["reason"]
      assert denied_error["message"] == "Unknown tool: echo"
      assert unknown_error["message"] == "Unknown tool: not_a_tool"
      assert denied_error["code"] == -32_602
    end

    test "permissions/3 audits every tool as invisible+uncallable; catalog carries the reason" do
      server = Fixtures.ACL.DenyAllServer
      ctx = %Ctx{server: server, assigns: %{}}

      assert {:ok, %{tools: tools, version: version}} = server.permissions(server, ctx, [])
      assert version != nil

      assert Enum.map(tools, &{&1.name, &1.visible, &1.callable}) == [
               {"echo", false, false},
               {"get_weather", false, false}
             ]

      assert {:ok, entries, _version} = server.catalog(server, ctx, [])

      for entry <- entries do
        assert entry.reason == {:acl, ACL.Providers.DenyAll}
      end
    end

    test "the shim paths are governed too (AP-5: ACL can never be decorative)" do
      server = Fixtures.ACL.DenyAllServer
      ctx = %Ctx{server: server, assigns: %{}}

      # dispatch shim (ctx carries the server registration)
      assert {:error, %Noizu.MCP.Error{reason: :invalid_params, message: "Unknown tool: echo"}} =
               Noizu.MCP.Server.Features.Tools.dispatch(
                 server.__mcp__(:tools),
                 "echo",
                 %{},
                 ctx
               )

      # list_registered shim (per-call opts carry the provider — the shim has no
      # ctx); it returns the paginated definition list shape.
      assert {:ok, [], nil} =
               Noizu.MCP.Server.Features.Tools.list_registered(
                 server.__mcp__(:tools),
                 nil,
                 acl: ACL.Providers.DenyAll
               )

      # a Static toolset holding the registration opts is governed the same way
      assert {:ok, entries, _} =
               Noizu.MCP.Toolset.catalog(
                 %Noizu.MCP.Toolset.Static{
                   specs: Noizu.MCP.Server.Features.Tools.expand(server.__mcp__(:tools)),
                   opts: [acl: ACL.Providers.DenyAll]
                 },
                 ctx,
                 []
               )

      assert Enum.all?(entries, &(&1.visible == false and &1.callable == false))
    end
  end

  describe "custom provider end to end (AC-2.3)" do
    test "denied and absent tools vanish; the allowed tool works" do
      client = connect(Fixtures.ACL.PartialServer)

      assert {:ok, %{"tools" => tools}} = request(client, "tools/list", nil, @await)
      assert Enum.map(tools, & &1["name"]) == ["tool_b"]

      assert {:error, _} =
               request(client, "tools/call", %{"name" => "tool_a", "arguments" => %{}}, @await)

      assert {:error, _} =
               request(client, "tools/call", %{"name" => "tool_c", "arguments" => %{}}, @await)

      assert {:ok, result} =
               request(client, "tools/call", %{"name" => "tool_b", "arguments" => %{}}, @await)

      assert [%{"text" => "b"}] = result["content"]
    end

    test "AP-6 (named standalone): a missing verdict is a DENY, not an allow" do
      client = connect(Fixtures.ACL.PartialServer)

      # tool_c has NO verdict in the provider's batch map. If a future
      # "optimization" turns map misses into allows, this fails loudly.
      assert {:error, error} =
               request(client, "tools/call", %{"name" => "tool_c", "arguments" => %{}}, @await)

      assert error["message"] == "Unknown tool: tool_c"
    end
  end

  describe "provider crash recovery (AC-2.4, D5)" do
    setup do
      Fixtures.ACL.FlakyProvider.reset()
      :ok
    end

    test "a raising provider denies the surface; the server stays alive and recovers" do
      client = connect(Fixtures.ACL.FlakyServer)

      # First listing: the provider raises on its first check — every entry
      # denied, the surface fails closed, the server process lives.
      assert {:ok, %{"tools" => []}} = request(client, "tools/list", nil, @await)

      # Second listing: healthy provider ⇒ normal surface.
      assert {:ok, %{"tools" => tools}} = request(client, "tools/list", nil, @await)
      assert Enum.map(tools, & &1["name"]) == ["echo"]

      # The session (and server) never went down: the same session serves both.
      assert Process.alive?(client.session)
    end

    test "a denied-by-crash call is an unknown tool, and works after recovery" do
      client = connect(Fixtures.ACL.FlakyServer)

      assert {:error, crash_error} =
               request(client, "tools/call", %{"name" => "echo", "arguments" => %{}}, @await)

      assert crash_error["reason"] == :invalid_params

      assert {:ok, %{"content" => [%{"text" => "hi"}]}} =
               request(
                 client,
                 "tools/call",
                 %{
                   "name" => "echo",
                   "arguments" => %{"message" => "hi", "repeat" => 1, "mode" => "plain"}
                 },
                 @await
               )
    end
  end

  describe "inert by default (AC-2.1)" do
    test "an acl: :disabled server behaves exactly like an unconfigured one" do
      disabled_ctx = %Ctx{server: Fixtures.ACL.DisabledServer, assigns: %{}}
      plain_ctx = %Ctx{server: Fixtures.ACL.UnconfiguredServer, assigns: %{}}

      assert {:ok, disabled_entries, disabled_version} =
               Fixtures.ACL.DisabledServer.catalog(Fixtures.ACL.DisabledServer, disabled_ctx, [])

      assert {:ok, plain_entries, plain_version} =
               Fixtures.ACL.UnconfiguredServer.catalog(
                 Fixtures.ACL.UnconfiguredServer,
                 plain_ctx,
                 []
               )

      # Same fixture tool ⇒ byte-identical entries and version hash.
      assert disabled_entries == plain_entries
      assert disabled_version == plain_version

      client = connect(Fixtures.ACL.DisabledServer)
      assert {:ok, %{"tools" => tools}} = request(client, "tools/list", nil, @await)
      assert Enum.map(tools, & &1["name"]) == ["auth_echo"]
    end
  end
end
