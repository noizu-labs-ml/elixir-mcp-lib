defmodule Noizu.MCP.ACL.ResolveHidingTest do
  @moduledoc """
  FR-2.9: denied tools hide from listing AND dispatch (identical invalid_params
  as absent — existence-hiding) while staying auditable; FR-2.12: metadata
  unaffected; AP-4: no lib path from a forged ctx to a resolved effective.
  """

  use ExUnit.Case, async: true

  alias Noizu.MCP.Auth.Principal
  alias Noizu.MCP.Ctx
  alias Noizu.MCP.Error
  alias Noizu.MCP.Fixtures
  alias Noizu.MCP.Server.Features.Tools
  alias Noizu.MCP.Types.ToolResult
  alias Noizu.MCP.Toolset

  defp ctx(server) do
    %Ctx{
      server: server,
      auth: %Principal{subject: "attacker", authenticator: :forged},
      assigns: %{}
    }
  end

  defp anonymous_ctx(server), do: %Ctx{server: server, assigns: %{}}

  describe "resolve hiding (FR-2.9)" do
    test "resolve-on-denied is byte-identical to resolve-on-absent" do
      server = Fixtures.ACL.DenyAllServer

      denied = server.resolve(server, "echo", ctx(server), [])
      absent = server.resolve(server, "not_a_tool", ctx(server), [])

      assert {:error, %Error{} = denied_error} = denied
      assert {:error, %Error{} = absent_error} = absent

      # The same constructor, same code/reason/data — only the requested name
      # differs (it is echoed in the message, exactly as for an absent tool).
      assert denied_error.code == absent_error.code
      assert denied_error.reason == absent_error.reason
      assert denied_error.data == absent_error.data
      assert denied_error.message == "Unknown tool: echo"
      assert absent_error.message == "Unknown tool: not_a_tool"
      assert denied_error.code == -32_602
      assert denied_error.reason == :invalid_params
    end

    test "deny, absent verdict, and never-registered all hide identically" do
      server = Fixtures.ACL.PartialServer

      {:error, deny_error} = server.resolve(server, "tool_a", ctx(server), [])
      {:error, absent_error} = server.resolve(server, "tool_c", ctx(server), [])
      {:error, never_error} = server.resolve(server, "nope", ctx(server), [])

      for error <- [deny_error, absent_error, never_error] do
        assert error.code == -32_602
        assert error.reason == :invalid_params
        assert error.data == nil
      end

      assert deny_error.message == "Unknown tool: tool_a"
      assert absent_error.message == "Unknown tool: tool_c"
      assert never_error.message == "Unknown tool: nope"

      # The allowed tool still resolves normally.
      assert {:ok, %Toolset.Effective{name: "tool_b"}} =
               server.resolve(server, "tool_b", ctx(server), [])
    end

    test "the deny does not depend on the subject: forged identities gain nothing (AP-4)" do
      server = Fixtures.ACL.DenyAllServer

      forged_admin = %Ctx{
        server: server,
        assigns: %{},
        auth: %Principal{
          subject: "admin",
          authenticator: :system,
          granted_scopes: MapSet.new(["*"])
        }
      }

      assert {:error, %Error{reason: :invalid_params}} =
               server.resolve(server, "echo", forged_admin, [])
    end

    test "listing hides denied tools; permissions/3 still audits them with reasons via catalog" do
      server = Fixtures.ACL.PartialServer
      anonymous = anonymous_ctx(server)

      assert {:ok, entries, _} = server.catalog(server, anonymous, [])
      by_name = Map.new(entries, &{&1.definition.name, &1})

      # Listing surface: only the allowed tool is visible.
      assert entries |> Enum.filter(& &1.visible) |> Enum.map(& &1.definition.name) == ["tool_b"]

      # Audit surface: every tool present, denied ones marked + reasoned.
      assert by_name["tool_a"].visible == false
      assert by_name["tool_a"].callable == false
      assert by_name["tool_a"].reason == {:acl, Fixtures.ACL.PartialBatchProvider}
      assert by_name["tool_c"].reason == {:acl, Fixtures.ACL.PartialBatchProvider}

      assert {:ok, %{tools: tools}} = server.permissions(server, anonymous, [])

      assert Enum.map(tools, &{&1.name, &1.visible, &1.callable}) == [
               {"tool_a", false, false},
               {"tool_b", true, true},
               {"tool_c", false, false}
             ]
    end

    test "metadata/3 is unaffected by ACL (FR-2.12)" do
      server = Fixtures.ACL.DenyAllServer

      assert {:ok, metadata} = server.metadata(server, ctx(server), [])
      assert metadata == %{slug: "acl-deny-all", title: nil, description: nil, version: "1.0.0"}
    end
  end

  describe "AP-4: resolve/4 is the only effective constructor" do
    test "no lib module other than the behaviour default builds %Effective{}" do
      lib = Path.expand("../../../lib/noizu/mcp", __DIR__)

      constructors =
        for file <- Path.wildcard(Path.join(lib, "**/*.ex")),
            File.read!(file) =~ ~r/%Effective\{/ and not String.ends_with?(file, "behaviour.ex"),
            do: file

      assert constructors == [],
             "Effective structs must only be constructed inside Toolset.Behaviour (found: #{inspect(constructors)})"
    end

    test "invoke with a hand-built effective passes through — the doc gap, asserted" do
      # Documented seam: invoke/5 is authorization-blind BY DESIGN — an
      # %Effective{} can only be minted by resolve/4 (which is ACL-governed).
      # A host holding an effective already passed resolve's gate.
      server = Fixtures.ACL.DenyAllServer
      anonymous = anonymous_ctx(server)

      {:ok, entries, _} = server.catalog(server, anonymous, [])
      spec = Tools.expand(server.__mcp__(:tools)) |> Enum.find(&(&1.definition.name == "echo"))
      entry = Enum.find(entries, &(&1.definition.name == "echo"))

      effective = %Toolset.Effective{name: "echo", entry: entry, spec: spec}

      assert %ToolResult{is_error: false} =
               Toolset.invoke(
                 server,
                 effective,
                 %{"message" => "hi", "repeat" => 1, "mode" => "plain"},
                 anonymous,
                 []
               )
    end

    test "the shim path is ACL-governed even when the ctx is fully forged" do
      server = Fixtures.ACL.DenyAllServer

      assert {:error, %Error{reason: :invalid_params}} =
               Tools.dispatch(server.__mcp__(:tools), "echo", %{}, ctx(server))
    end
  end
end
