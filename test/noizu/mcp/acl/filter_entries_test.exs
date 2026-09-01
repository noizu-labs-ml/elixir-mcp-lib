defmodule Noizu.MCP.ACL.FilterEntriesTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.ACL.Provider
  alias Noizu.MCP.ACL.Resource
  alias Noizu.MCP.Auth.Principal
  alias Noizu.MCP.Ctx
  alias Noizu.MCP.Fixtures
  alias Noizu.MCP.Toolset.Entry
  alias Noizu.MCP.Types.Tool

  @acl_providers Noizu.MCP.ACL.Providers

  defp entry(name, opts \\ []) do
    %Entry{
      definition: %Tool{name: name, description: "#{name} fixture"},
      visible: Keyword.get(opts, :visible, true),
      callable: Keyword.get(opts, :callable, true),
      reason: Keyword.get(opts, :reason)
    }
  end

  defp entries, do: [entry("tool_a"), entry("tool_b"), entry("tool_c")]

  defp ctx_with_auth(server \\ nil) do
    %Ctx{
      server: server,
      auth: %Principal{
        subject: "user-1",
        authenticator: :test,
        granted_scopes: MapSet.new(["mcp"])
      },
      assigns: %{}
    }
  end

  defp telemetry_ref do
    ref = make_ref()

    for event <- [
          [:noizu_mcp, :acl, :check],
          [:noizu_mcp, :acl, :error],
          [:noizu_mcp, :acl, :stale_verdict]
        ] do
      :telemetry.attach(
        {ref, event},
        event,
        fn e, _measurements, metadata, _ ->
          send(self(), {:acl_telemetry, e, metadata})
        end,
        nil
      )
    end

    on_exit(fn ->
      for event <- [
            [:noizu_mcp, :acl, :check],
            [:noizu_mcp, :acl, :error],
            [:noizu_mcp, :acl, :stale_verdict]
          ] do
        :telemetry.detach({ref, event})
      end
    end)
  end

  describe "inert without a provider (FR-2.10, AC-2.1)" do
    test "no server, no opts ⇒ byte-identical entries" do
      before = entries()
      assert Provider.filter_entries(before, nil, ctx_with_auth(), []) == before
    end

    test "server without acl opt ⇒ unchanged (back-compat with PRD-1)" do
      before = entries()

      assert Provider.filter_entries(before, Fixtures.ACL.UnconfiguredServer, ctx_with_auth(), []) ==
               before
    end

    test "explicit acl: :disabled ⇒ unchanged" do
      before = entries()

      assert Provider.filter_entries(before, Fixtures.ACL.UnconfiguredServer, ctx_with_auth(),
               acl: :disabled
             ) == before
    end

    test "empty entries with a provider set ⇒ nothing to check" do
      assert Provider.filter_entries([], Fixtures.ACL.DenyAllServer, ctx_with_auth(), []) == []
    end
  end

  describe "verdict matrix with a provider configured (FR-2.10)" do
    test "deny_all ⇒ every entry invisible, uncallable, reasoned" do
      filtered =
        Provider.filter_entries(entries(), Fixtures.ACL.DenyAllServer, ctx_with_auth(), [])

      for e <- filtered do
        assert e.visible == false
        assert e.callable == false
        assert e.reason == {:acl, @acl_providers.DenyAll}
      end
    end

    test "custom provider: deny / allow / ABSENT (default-DENY proven, AP-6)" do
      filtered =
        Provider.filter_entries(entries(), Fixtures.ACL.PartialServer, ctx_with_auth(), [])

      by_name = Map.new(filtered, &{&1.definition.name, &1})

      a = by_name["tool_a"]
      assert a.visible == false and a.callable == false
      assert a.reason == {:acl, Fixtures.ACL.PartialBatchProvider}

      b = by_name["tool_b"]
      assert b.visible == true and b.callable == true
      assert b.reason == nil

      c = by_name["tool_c"]
      assert c.visible == false and c.callable == false
      assert c.reason == {:acl, Fixtures.ACL.PartialBatchProvider}
    end

    test "map miss and garbage verdicts deny; provider allow passes through" do
      filtered =
        Provider.filter_entries(entries(), nil, ctx_with_auth(),
          acl: Fixtures.ACL.GarbageVerdictProvider
        )

      assert Enum.all?(filtered, &(&1.visible == false and &1.callable == false))

      allowed =
        Provider.filter_entries(entries(), nil, ctx_with_auth(),
          acl: Fixtures.ACL.AllowAllProvider
        )

      assert allowed == entries()
    end

    test "provider raise ⇒ all entries denied, telemetry emitted, server healthy (AC-2.4 surface)" do
      telemetry_ref()

      filtered =
        Provider.filter_entries(entries(), nil, ctx_with_auth(), acl: Fixtures.ACL.CrashProvider)

      assert length(filtered) == 3

      assert Enum.all?(filtered, fn e ->
               e.visible == false and e.callable == false and
                 e.reason == {:acl, Fixtures.ACL.CrashProvider}
             end)

      assert_receive {:acl_telemetry, [:noizu_mcp, :acl, :error],
                      %{provider: Fixtures.ACL.CrashProvider, entries: 3}}
    end

    test "already-denied entries keep their original reason on an ACL deny" do
      hidden = [entry("tool_a", visible: false, reason: :hidden_by_spec), entry("tool_b")]

      filtered =
        Provider.filter_entries(hidden, Fixtures.ACL.DenyAllServer, ctx_with_auth(), [])

      by_name = Map.new(filtered, &{&1.definition.name, &1})
      assert by_name["tool_a"].reason == :hidden_by_spec
      assert by_name["tool_a"].visible == false and by_name["tool_a"].callable == false
      assert by_name["tool_b"].reason == {:acl, @acl_providers.DenyAll}
    end
  end

  describe "resource construction + kind gate (§4.7)" do
    test "filter_entries builds kind: :tool resources over canonical names" do
      # PromptOnlyProvider does not govern :tool — the built resource kind
      # surfaces as a config error rather than a silent allow.
      assert_raise ArgumentError, ~r/kind :tool/, fn ->
        Provider.filter_entries(entries(), nil, ctx_with_auth(),
          acl: Fixtures.ACL.PromptOnlyProvider
        )
      end
    end
  end

  describe "provider resolution precedence (§4.6 current_provider)" do
    test "per-call opts[:acl] wins over the server registration" do
      server = Fixtures.ACL.DenyAllServer

      assert Provider.current_provider(server, acl: Fixtures.ACL.AllowAllProvider) ==
               Fixtures.ACL.AllowAllProvider

      assert Provider.current_provider(server, []) == @acl_providers.DenyAll
    end

    test "explicit :disabled overrides the server registration" do
      assert Provider.current_provider(Fixtures.ACL.DenyAllServer, acl: :disabled) == nil
    end

    test "server module registration resolves; unknown modules resolve nil" do
      assert Provider.current_provider(Fixtures.ACL.DenyAllServer, []) == @acl_providers.DenyAll
      assert Provider.current_provider(nil, []) == nil
      assert Provider.current_provider(String, []) == nil
    end

    test "{provider, opts} form threads check opts (module part surfaces)" do
      assert Provider.current_provider(nil, acl: {Fixtures.ACL.AllowAllProvider, region: :eu}) ==
               Fixtures.ACL.AllowAllProvider

      assert {provider, check_opts} =
               Provider.resolve_provider(nil, acl: {Fixtures.ACL.AllowAllProvider, region: :eu})

      assert provider == Fixtures.ACL.AllowAllProvider
      assert check_opts == [region: :eu]
    end

    test "%Toolset.Static{} carries its own opts" do
      static = %Noizu.MCP.Toolset.Static{specs: [], opts: [acl: @acl_providers.DenyAll]}
      assert Provider.current_provider(static, []) == @acl_providers.DenyAll
    end
  end

  describe "unchanged surface invariants" do
    test "resource kind used by the lib is always :tool for toolset entries" do
      # The only resource the series exercises; ids are canonical wire names.
      r = %Resource{kind: :tool, id: "echo"}
      assert Provider.ensure_kind!(@acl_providers.DenyAll, r) == :ok
    end
  end
end
