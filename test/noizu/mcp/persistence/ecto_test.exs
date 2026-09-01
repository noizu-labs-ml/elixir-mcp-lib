db_url = System.get_env("MCP_OAUTH_TEST_DATABASE_URL")

if db_url do
  defmodule Noizu.MCP.Persistence.EctoTest do
    @moduledoc """
    The raw-SQL persistence adapter against the SAME conformance battery as
    the ETS one (AC-4.1 — no per-provider forks), plus the D4 boot-gate
    both-ways proof (AC-4.8) and the AP-11 zero-writes guard.

    **DB-gated** on `MCP_OAUTH_TEST_DATABASE_URL` (same scratch database as
    the auth-store Ecto battery; the table sets are disjoint).
    """
    use ExUnit.Case, async: false
    use Noizu.MCP.Fixtures.PersistenceDB

    alias Noizu.MCP.Fixtures.PersistenceDB
    alias Noizu.MCP.Migrations
    alias Noizu.MCP.Migration.Runner
    alias Noizu.MCP.Persistence.Ecto
    alias Noizu.MCP.Server.Supervisor

    setup_all do
      # (the shared __using__ setup_all starts the repo and drops leftovers)
      {:ok, [_]} = Runner.up(TestRepo, Migrations)
      :ok
    end

    setup do
      # Every test starts from a KNOWN schema state on the way IN (house
      # pattern): the D4 boot-gate tests drop the tables mid-suite, so the
      # schema is rebuilt per test rather than assumed.
      PersistenceDB.drop_lib_tables!(TestRepo)
      {:ok, [_]} = Runner.up(TestRepo, Migrations)

      %{adapter: Ecto, store_opts: [repo: TestRepo]}
    end

    use Noizu.MCP.Persistence.ConformanceCase

    # ── Ecto-specific behavior ────────────────────────────────────────────

    describe "ecto-specific" do
      test "missing :repo raises (a misconfigured store must fail loudly, D4)" do
        assert_raise ArgumentError, ~r/requires a `:repo` option/, fn ->
          Ecto.put("toolsets", "id", %{}, [])
        end
      end

      test "the default ping is a version roundtrip when ping/1 is not defined" do
        # MemoryPingProvider delegates version to Memory — the fallback path.
        assert :ok =
                 Noizu.MCP.Persistence.ping(Noizu.MCP.Fixtures.Persistence.MemoryPingProvider, [])
      end
    end

    # ── D4 boot gate, both ways (AC-4.8) ──────────────────────────────────

    defmodule EctoBootServer do
      @moduledoc false
      use Noizu.MCP.Server,
        name: "persistence-ecto-boot",
        version: "1.0.0",
        persistence: {Noizu.MCP.Persistence.Ecto, repo: Noizu.MCP.Fixtures.PersistenceDB.TestRepo}

      tool Noizu.MCP.Fixtures.Echo
    end

    describe "D4 boot gate (AC-4.8)" do
      test "boot RAISES while the tables are missing" do
        PersistenceDB.drop_lib_tables!(TestRepo)

        parent = self()

        {:ok, _trapper} =
          Task.start(fn ->
            Process.flag(:trap_exit, true)
            send(parent, Supervisor.start_link(EctoBootServer, []))
          end)

        assert_receive {:error, _failure}, 1_000
        assert {:error, {:tables_missing, missing}} = Ecto.ping(repo: TestRepo)
        assert "noizu_mcp_toolsets" in missing
        wait_until(fn -> is_nil(Process.whereis(EctoBootServer)) end)
      end

      test "after Runner.up boot succeeds and the ping child is live" do
        PersistenceDB.drop_lib_tables!(TestRepo)
        assert {:ok, [_]} = Runner.up(TestRepo, Migrations)

        Noizu.MCP.Test.ensure_server_started(EctoBootServer)
        assert Process.whereis(EctoBootServer)
        assert Process.whereis(Module.concat(EctoBootServer, PersistencePing))
        assert :ok = Ecto.ping(repo: TestRepo)

        assert {Ecto, [repo: TestRepo]} =
                 :persistent_term.get({EctoBootServer, :persistence}, nil)
      end
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

    # ── AP-11 zero-writes guard ───────────────────────────────────────────

    describe "zero-writes guard (AP-11)" do
      test "a host bringing its own provider leaves the lib tables untouched" do
        PersistenceDB.truncate_all!(TestRepo)
        before = PersistenceDB.table_counts(TestRepo)

        # The context pass + Store resolve to Memory (the default) while the
        # host's DB sits there with its lib tables EMPTY — nothing in the lib
        # ever writes those tables behind the provider's back.
        Noizu.MCP.Test.ensure_server_started(Noizu.MCP.Fixtures.Persistence.GrantServer)

        grant = %Noizu.MCP.Permission.Grant{
          id: "zero-writes-1",
          toolset_slug: "grant-slice",
          authenticator: "claims",
          subject: "user-1",
          effect: :allow
        }

        :ok =
          Noizu.MCP.Store.put(:grant, grant, server: Noizu.MCP.Fixtures.Persistence.GrantServer)

        after_counts = PersistenceDB.table_counts(TestRepo)
        assert after_counts == before
        assert after_counts["noizu_mcp_toolset_grants"] == 0
      end
    end
  end
else
  defmodule Noizu.MCP.Persistence.EctoTest do
    @moduledoc false
    use ExUnit.Case, async: false

    @tag :skip
    test "persistence Ecto suite skipped without MCP_OAUTH_TEST_DATABASE_URL", do: :ok
  end
end
