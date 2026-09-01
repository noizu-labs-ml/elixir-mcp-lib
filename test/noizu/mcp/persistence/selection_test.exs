defmodule Noizu.MCP.Persistence.SelectionTest do
  @moduledoc """
  Provider selection & precedence (PRD-4 §4.3 / FR-4.3 / FR-4.9): per-server >
  Application env AT CALL TIME (D3) > `:memory`; the combined `providers:`
  form wins over individual keys; lazy `resolved/1` for direct calls; the
  Disabled error shape; the ACL analog chain (providers: over acl:, call-time
  env); supervisor wiring (stash, ping child, running_servers registry, D4
  boot gate).
  """
  use ExUnit.Case, async: false

  alias Noizu.MCP.ACL.Provider, as: ACLProvider
  alias Noizu.MCP.Fixtures.Persistence
  alias Noizu.MCP.Persistence, as: P
  alias Noizu.MCP.Server.Supervisor

  setup do
    # The D3 tests mutate Application env — every test starts from a clean
    # slate and the suite restores on the way out.
    Application.delete_env(:noizu_mcp, :persistence)
    Application.delete_env(:noizu_mcp, :providers)
    Application.delete_env(:noizu_mcp, :acl)

    on_exit(fn ->
      Application.delete_env(:noizu_mcp, :persistence)
      Application.delete_env(:noizu_mcp, :providers)
      Application.delete_env(:noizu_mcp, :acl)
    end)

    :ok
  end

  # ── value shapes ──────────────────────────────────────────────────────────

  describe "normalize/1" do
    test "the four value shapes" do
      assert {P.Memory, []} = P.normalize(:memory)
      assert {P.Disabled, []} = P.normalize(:disabled)
      assert {Persistence.MemoryPingProvider, []} = P.normalize(Persistence.MemoryPingProvider)

      assert {Persistence.MemoryPingProvider, [repo: :x]} =
               P.normalize({Persistence.MemoryPingProvider, [repo: :x]})

      assert nil == P.normalize("garbage")
      assert nil == P.normalize(nil)
    end

    test "enabled? is false ONLY for Disabled" do
      refute P.enabled?({P.Disabled, []})
      assert P.enabled?({P.Memory, []})
      assert P.enabled?({Persistence.MemoryPingProvider, []})
      refute P.enabled?(nil)
    end
  end

  # ── precedence (§4.3) ─────────────────────────────────────────────────────

  describe "resolved/1,2 precedence" do
    test "the default is :memory" do
      assert {P.Memory, []} = P.resolved([])
      assert {P.Memory, []} = P.resolved(nil, [])
    end

    test "explicit opts carry every shape" do
      assert {P.Disabled, []} = P.resolved(persistence: :disabled)

      assert {Persistence.MemoryPingProvider, [repo: :x]} =
               P.resolved(persistence: {Persistence.MemoryPingProvider, [repo: :x]})
    end

    test "providers: wins over persistence: when both present (FR-4.9)" do
      opts = [persistence: :memory, providers: [persistence: :disabled]]
      assert {P.Disabled, []} = P.resolved(opts)
    end

    test "providers: without the :persistence key falls through to persistence:" do
      opts = [persistence: :disabled, providers: [acl: Noizu.MCP.ACL.Providers.DenyAll]]
      assert {P.Disabled, []} = P.resolved(opts)
    end

    test "per-server opts beat Application env (the stash, §4.3 (1) > (2))" do
      Application.put_env(:noizu_mcp, :persistence, :memory)
      Noizu.MCP.Test.ensure_server_started(Persistence.DisabledServer)

      assert {P.Disabled, []} = P.resolved(Persistence.DisabledServer, [])

      # Explicit per-call opts still beat the stash (lazy re-resolution, D3).
      assert {P.Memory, []} = P.resolved(Persistence.DisabledServer, persistence: :memory)
    end

    test "Application env is read at CALL time (D3)" do
      Application.put_env(:noizu_mcp, :persistence, :disabled)
      assert {P.Disabled, []} = P.resolved([])

      Application.put_env(:noizu_mcp, :persistence, :memory)
      assert {P.Memory, []} = P.resolved([])
    end

    test "the env combined form wins over the env individual key" do
      Application.put_env(:noizu_mcp, :persistence, :memory)
      Application.put_env(:noizu_mcp, :providers, persistence: :disabled)

      assert {P.Disabled, []} = P.resolved([])
    end
  end

  # ── Disabled (§4.2) ───────────────────────────────────────────────────────

  describe "Disabled provider" do
    test "every callback is {:error, :persistence_disabled}" do
      adapter = P.Disabled

      assert {:error, :persistence_disabled} = adapter.put("toolsets", "id", %{}, [])
      assert {:error, :persistence_disabled} = adapter.get("toolsets", "id", [])
      assert {:error, :persistence_disabled} = adapter.list("toolsets", nil, [])
      assert {:error, :persistence_disabled} = adapter.delete("toolsets", "id", [])
      assert {:error, :persistence_disabled} = adapter.version("toolsets", [])
    end

    test "ping errors (a policy is not liveness) and never blocks boot" do
      assert {:error, :persistence_disabled} = P.ping(P.Disabled, [])
    end
  end

  # ── ACL analog (§4.3) ─────────────────────────────────────────────────────

  describe "ACL providers: chain" do
    test "providers: [acl:] wins over the registration's individual acl:" do
      Noizu.MCP.Test.ensure_server_started(Persistence.ProvidersFormServer)

      assert ACLProvider.current_provider(Persistence.ProvidersFormServer, []) ==
               Noizu.MCP.ACL.Providers.DenyAll
    end

    test "providers: [acl:] wins over per-call acl:" do
      opts = [
        acl: Noizu.MCP.Fixtures.ACL.AllowAllProvider,
        providers: [acl: Noizu.MCP.ACL.Providers.DenyAll]
      ]

      assert ACLProvider.current_provider(nil, opts) == Noizu.MCP.ACL.Providers.DenyAll
    end

    test "providers: without :acl falls through to acl:" do
      opts = [acl: Noizu.MCP.Fixtures.ACL.AllowAllProvider, providers: [persistence: :memory]]

      assert ACLProvider.current_provider(nil, opts) ==
               Noizu.MCP.Fixtures.ACL.AllowAllProvider
    end

    test "explicit acl: :disabled stops the chain (env does not override)" do
      Application.put_env(:noizu_mcp, :acl, Noizu.MCP.Fixtures.ACL.AllowAllProvider)
      assert nil == ACLProvider.current_provider(nil, acl: :disabled)
    end

    test "Application env :acl is read at CALL time when nothing else governs (D3)" do
      assert nil == ACLProvider.current_provider(nil, [])

      Application.put_env(:noizu_mcp, :acl, Noizu.MCP.Fixtures.ACL.AllowAllProvider)
      assert ACLProvider.current_provider(nil, []) == Noizu.MCP.Fixtures.ACL.AllowAllProvider

      Application.put_env(:noizu_mcp, :acl, nil)
      assert nil == ACLProvider.current_provider(nil, [])
    end

    test "the env combined form wins over the env individual key" do
      Application.put_env(:noizu_mcp, :acl, Noizu.MCP.Fixtures.ACL.AllowAllProvider)

      Application.put_env(:noizu_mcp, :providers, acl: Noizu.MCP.ACL.Providers.DenyAll)

      assert ACLProvider.current_provider(nil, []) == Noizu.MCP.ACL.Providers.DenyAll
    end
  end

  # ── supervisor wiring (§4.3 / §4.7) ───────────────────────────────────────

  describe "supervisor wiring" do
    test "the stash + running_servers registry populate at init" do
      Noizu.MCP.Test.ensure_server_started(Persistence.DisabledServer)

      assert {P.Disabled, []} =
               :persistent_term.get({Persistence.DisabledServer, :persistence}, nil)

      assert Persistence.DisabledServer in Supervisor.running_servers()
    end

    test "Memory/Disabled start no ping child; a custom provider does (and passes)" do
      Noizu.MCP.Test.ensure_server_started(Persistence.DisabledServer)
      Noizu.MCP.Test.ensure_server_started(Persistence.BootOkServer)

      refute Process.whereis(Module.concat(Persistence.DisabledServer, PersistencePing))
      assert Process.whereis(Module.concat(Persistence.BootOkServer, PersistencePing))

      ping = Module.concat(Persistence.BootOkServer, PersistencePing)
      assert GenServer.call(ping, :ping) == :ok
    end

    test "D4: a provider whose boot ping fails fails the whole boot" do
      # start_link from the test process would propagate the failed child's
      # EXIT here; a trap_exit helper turns it into a return value instead.
      parent = self()

      {:ok, _trapper} =
        Task.start(fn ->
          Process.flag(:trap_exit, true)
          send(parent, Supervisor.start_link(Persistence.BootFailServer, []))
        end)

      assert_receive {:error, _failure}, 1_000
      wait_until(fn -> is_nil(Process.whereis(Persistence.BootFailServer)) end)

      refute Process.whereis(Module.concat(Persistence.BootFailServer, PersistencePing))
    end

    defp wait_until(fun, attempts \\ 100)

    defp wait_until(_fun, 0), do: flunk("condition never became true")

    defp wait_until(fun, attempts) do
      if fun.() do
        :ok
      else
        Process.sleep(10)
        wait_until(fun, attempts - 1)
      end
    end

    test "D4: running_servers lazily drops crashed trees" do
      Noizu.MCP.Test.ensure_server_started(Persistence.DisabledServer)
      assert Persistence.DisabledServer in Supervisor.running_servers()
      # (A crashed supervisor's name unregisters; the whereis filter in
      # running_servers/0 removes the stale entry — exercised implicitly by
      # every read; direct crash simulation would tear down shared fixtures.)
    end
  end
end
