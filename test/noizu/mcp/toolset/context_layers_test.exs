defmodule Noizu.MCP.Toolset.ContextLayersTest do
  @moduledoc """
  §4.2 seam: %Layer{} + Context.layers — the ACL re-home is behavior-identical
  to PRD-2's filter_entries (the PRD-2 suite stays green unmodified; this file
  pins the equivalence directly), the persisted seam defaults to [], and the
  host layers/3 callback is honored.
  """

  use ExUnit.Case, async: true

  alias Noizu.MCP.ACL.Provider
  alias Noizu.MCP.{Ctx, Fixtures, Toolset}
  alias Noizu.MCP.Toolset.{Context, Entry, Layer, Override}
  alias Noizu.MCP.Types.Tool

  @providers Noizu.MCP.ACL.Providers

  defp entry(name, opts \\ []) do
    %Entry{
      definition: %Tool{name: name, description: "#{name} fixture"},
      visible: Keyword.get(opts, :visible, true),
      callable: Keyword.get(opts, :callable, true),
      reason: Keyword.get(opts, :reason)
    }
  end

  defp entries, do: [entry("tool_a"), entry("tool_b"), entry("tool_c")]

  defp ctx(server \\ nil, auth \\ nil) do
    %Ctx{server: server, auth: auth, assigns: %{}}
  end

  defp ctx_with_auth(server \\ nil),
    do:
      ctx(
        server,
        %Noizu.MCP.Auth.Principal{
          subject: "u1",
          authenticator: :test,
          granted_scopes: MapSet.new(["mcp"])
        }
      )

  describe "layers/3 (persisted seam)" do
    test "defaults to [] — no persisted layers in PRD-3" do
      toolset = %Fixtures.StructToolset{}
      assert Context.layers(toolset, ctx(), []) == []
    end

    test "a host module's layers/3 callback is honored (the PRD-4 seam)" do
      toolset = %Fixtures.Custom.LayeredToolset{specs: []}
      ctx = ctx(nil, nil) |> Map.put(:assigns, %{host_layer: true})

      assert [%Layer{id: {:host, "persisted-shaped"}, weight: 250, ops: [_op]}] =
               Context.layers(toolset, ctx, [])
    end

    test "the host callback returning [] keeps the seam silent" do
      toolset = %Fixtures.Custom.LayeredToolset{specs: []}
      assert Context.layers(toolset, ctx(), []) == []
    end
  end

  describe "layers/4 (the composition entry: ACL + persisted)" do
    test "no provider ⇒ no ACL layer, persisted only" do
      toolset = %Fixtures.StructToolset{}
      assert Context.layers(toolset, entries(), ctx_with_auth(), []) == []
    end

    test "provider set ⇒ weight-300 ACL layer with both ops per denied tool" do
      server = Fixtures.ACL.DenyAllServer

      assert [%Layer{id: {:acl, @providers.DenyAll}, weight: 300, ops: ops}] =
               Context.layers(%Fixtures.StructToolset{}, entries(), ctx_with_auth(server), [])

      denied = Enum.map(ops, & &1.target) |> Enum.uniq() |> Enum.sort()
      assert denied == ["tool_a", "tool_b", "tool_c"]

      for op <- ops do
        assert op.weight == 300
        assert op.layer == {:acl, @providers.DenyAll}
        assert op.op in [:set_visible, :set_callable]
        assert op.value == false
      end
    end

    test "per-call opts[:acl] resolves the same as filter_entries (§4.6 precedence)" do
      opts = [acl: @providers.DenyAll]

      assert [%Layer{id: {:acl, @providers.DenyAll}}] =
               Context.layers(%Fixtures.StructToolset{}, entries(), ctx_with_auth(), opts)
    end
  end

  describe "ACL re-home equivalence (PRD-2 filter_entries, byte-identical)" do
    test "acl_layer + project_acl == filter_entries for the same request" do
      server = Fixtures.ACL.PartialServer
      ctx = ctx_with_auth(server)

      through_layer =
        Context.layers(%Fixtures.StructToolset{}, entries(), ctx, [])
        |> Enum.filter(&match?(%Layer{id: {:acl, _}}, &1))
        |> Enum.reduce(entries(), fn layer, acc -> Context.project_acl(acc, layer) end)

      through_chokepoint = Provider.filter_entries(entries(), server, ctx, [])

      assert through_layer == through_chokepoint
    end

    test "provider crash denies the whole set with PRD-2 telemetry" do
      ref = make_ref()

      :telemetry.attach(
        {ref, :acl_error},
        [:noizu_mcp, :acl, :error],
        fn _e, _m, meta, _ -> send(self(), {:acl_error, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach({ref, :acl_error}) end)

      layer =
        Context.acl_layer(entries(), Fixtures.ACL.CrashProvider, [], ctx_with_auth())

      denied = Context.project_acl(entries(), layer)

      assert Enum.all?(denied, fn e ->
               e.visible == false and e.callable == false and
                 e.reason == {:acl, Fixtures.ACL.CrashProvider}
             end)

      assert_receive {:acl_error, %{provider: Fixtures.ACL.CrashProvider, entries: 3}}
    end

    test "already-denied entries keep their reason; fresh denies attribute to {:acl, provider}" do
      hidden = [entry("tool_a", visible: false, reason: :hidden_by_spec), entry("tool_b")]
      server = Fixtures.ACL.DenyAllServer

      layer =
        Context.layers(%Fixtures.StructToolset{}, hidden, ctx_with_auth(server), [])
        |> Enum.find(&match?(%Layer{id: {:acl, _}}, &1))

      by_name = Map.new(Context.project_acl(hidden, layer), &{&1.definition.name, &1})
      assert by_name["tool_a"].reason == :hidden_by_spec
      assert by_name["tool_b"].reason == {:acl, @providers.DenyAll}
    end

    test "supported_kinds violation raises through (config error, §4.7)" do
      assert_raise ArgumentError, ~r/kind :tool/, fn ->
        Context.acl_layer(entries(), Fixtures.ACL.PromptOnlyProvider, [], ctx_with_auth())
      end
    end

    test "empty entries ⇒ no ACL layer (nothing to check)" do
      assert Context.acl_layer([], @providers.DenyAll, [], ctx_with_auth()) == nil
    end
  end

  describe "the layer participates in the generic merge (no special casing)" do
    test "ACL deny at 300 beats static 100 and persisted 200; layers compose via Merge" do
      static = %Layer{
        id: {:static, "t"},
        weight: 100,
        ops: [%Override{op: :set_visible, target: "echo", tool: "echo", value: false}]
      }

      acl =
        Context.layers(
          %Fixtures.StructToolset{},
          [entry("echo")],
          ctx_with_auth(Fixtures.ACL.DenyAllServer),
          []
        )
        |> Enum.find(&match?(%Layer{id: {:acl, _}}, &1))

      assert {:ok, winners} = Toolset.Merge.fold([static, acl])

      assert {%Override{}, {{:acl, @providers.DenyAll}, 300}} =
               winners[{"echo", :set_visible, nil}]
    end
  end
end
