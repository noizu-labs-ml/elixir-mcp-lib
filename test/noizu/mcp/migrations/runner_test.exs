db_url = System.get_env("MCP_OAUTH_TEST_DATABASE_URL")

if db_url do
  defmodule Noizu.MCP.Migrations.RunnerTest do
    @moduledoc """
    The migration Runner matrix (PRD-4 AC-4.7): fresh-DB status, up/down
    ledger rows, idempotent re-runs, out-of-order `to:` guards, and the
    rollback assertion — a crash mid-transaction leaves no partial set.

    **DB-gated** on `MCP_OAUTH_TEST_DATABASE_URL` (same scratch database as
    the auth-store Ecto battery; the table sets are disjoint).
    """
    use ExUnit.Case, async: false
    use Noizu.MCP.Fixtures.PersistenceDB

    alias Noizu.MCP.Migrations
    alias Noizu.MCP.Migrations.ChangeSet
    alias Noizu.MCP.Migration.Runner

    setup do
      # Fresh database per test: cleanup on the way IN (house pattern —
      # on_exit runs with the repo already being torn down, and a failed run
      # leaves its tables around for inspection).
      Noizu.MCP.Fixtures.PersistenceDB.drop_lib_tables!(TestRepo)
      :ok
    end

    defmodule TwoSets do
      @moduledoc false
      # A host-shaped extension: the lib set plus a fake v2 to exercise
      # ordering and `to:` guards.
      def change_sets do
        set2 = %ChangeSet{
          name: "v2_fake",
          version: 2,
          up: fn repo, _opts ->
            repo.query!("create table if not exists noizu_mcp_runner_test_v2 (id int)", [])
            :ok
          end,
          down: fn repo, _opts ->
            repo.query!("drop table if exists noizu_mcp_runner_test_v2", [])
            :ok
          end,
          note: "runner test only"
        }

        [Migrations.V1Toolsets.change_set(), set2]
      end
    end

    defmodule NoDownSet do
      @moduledoc false
      def change_sets do
        [
          %ChangeSet{
            name: "v1_no_down",
            version: 1,
            up: fn repo, _opts ->
              repo.query!("create table if not exists noizu_mcp_runner_test_nodown (id int)", [])
              :ok
            end
          }
        ]
      end
    end

    defmodule BrokenSet do
      @moduledoc false
      # Statement 1 succeeds, statement 2 raises — the ROLLBACK assertion's
      # instrument: after the failure, statement 1's effect must be absent.
      def change_sets do
        [
          %ChangeSet{
            name: "v1_broken",
            version: 1,
            up: fn repo, _opts ->
              repo.query!("create table noizu_mcp_runner_test_partial (id int)", [])
              repo.query!("create table this_is_not_valid_sql ()", [])
              :ok
            end
          }
        ]
      end
    end

    describe "up" do
      test "a fresh database reports all-pending status", %{test: _} do
        assert {:ok, [%{name: "v1_toolsets", version: 1, state: :pending}]} =
                 Runner.status(TestRepo, Migrations)
      end

      test "up applies in order and records the ledger" do
        assert {:ok, [%{name: "v1_toolsets", version: 1}]} = Runner.up(TestRepo, Migrations)

        assert {:ok, [%{name: "v1_toolsets", version: 1, applied_at: %DateTime{}}]} =
                 Runner.applied(TestRepo)

        assert "noizu_mcp_toolsets" in Noizu.MCP.Fixtures.PersistenceDB.existing_tables(TestRepo)
      end

      test "re-running up is a no-op (idempotence)" do
        assert {:ok, [_]} = Runner.up(TestRepo, Migrations)
        assert {:ok, []} = Runner.up(TestRepo, Migrations)
        assert {:ok, []} = Runner.up(TestRepo, Migrations)
      end

      test "host-extended sets apply after the lib set; to: stops the line" do
        assert {:ok, [%{name: "v1_toolsets"}]} = Runner.up(TestRepo, TwoSets, to: 1)
        assert {:ok, []} = Runner.up(TestRepo, TwoSets, to: 1)

        assert {:ok, [%{name: "v2_fake"}]} = Runner.up(TestRepo, TwoSets, to: :latest)

        assert {:ok,
                [%{name: "v1_toolsets", state: :applied}, %{name: "v2_fake", state: :applied}]} =
                 Runner.status(TestRepo, TwoSets)
      end

      test "up(to: 0) applies nothing (out-of-order to: guard)" do
        assert {:ok, []} = Runner.up(TestRepo, TwoSets, to: 0)
        assert {:ok, []} = Runner.applied(TestRepo)
      end
    end

    describe "down" do
      test "down(to: 0) reverts everything cleanly" do
        {:ok, _} = Runner.up(TestRepo, Migrations)

        assert {:ok, [%{name: "v1_toolsets", version: 1}]} =
                 Runner.down(TestRepo, Migrations, to: 0)

        assert {:ok, []} = Runner.applied(TestRepo)

        tables = Noizu.MCP.Fixtures.PersistenceDB.existing_tables(TestRepo)
        refute "noizu_mcp_toolsets" in tables
        refute "noizu_mcp_toolset_grants" in tables
        refute "noizu_mcp_toolset_negotiations" in tables
        refute "noizu_mcp_store_versions" in tables
        # The Runner's own ledger survives a down-to-zero — history is not lost.
        assert "noizu_mcp_schema_versions" in tables
      end

      test "down(to: n) keeps sets at or below the target" do
        {:ok, _} = Runner.up(TestRepo, TwoSets)

        assert {:ok, [%{name: "v2_fake"}]} = Runner.down(TestRepo, TwoSets, to: 1)

        assert {:ok, [%{name: "v1_toolsets", version: 1}]} = Runner.applied(TestRepo)
      end

      test "down(to: :latest) reverts nothing" do
        {:ok, _} = Runner.up(TestRepo, Migrations)
        assert {:ok, []} = Runner.down(TestRepo, Migrations, to: :latest)
        assert {:ok, [_]} = Runner.applied(TestRepo)
      end

      test "a set without a down thunk fails loudly with {name, :no_down}" do
        {:ok, _} = Runner.up(TestRepo, NoDownSet)
        assert {:error, {"v1_no_down", :no_down}} = Runner.down(TestRepo, NoDownSet, to: 0)
      end
    end

    describe "transactionality" do
      test "a crash mid-set rolls back WHOLE — no partial set survives" do
        assert {:error, {"v1_broken", _message}} = Runner.up(TestRepo, BrokenSet)

        # Statement 1 succeeded inside the transaction; the ROLLBACK must
        # have erased it.
        refute "noizu_mcp_runner_test_partial" in Noizu.MCP.Fixtures.PersistenceDB.existing_tables(
                 TestRepo
               )

        # ...and nothing was recorded in the ledger.
        assert {:ok, []} = Runner.applied(TestRepo)

        # The failed run left the runner usable: a good set applies after.
        assert {:ok, [%{name: "v1_toolsets"}]} = Runner.up(TestRepo, Migrations)
      end

      test "an earlier applied set survives a later set's failure" do
        {:ok, _} = Runner.up(TestRepo, Migrations)

        defmodule BrokenAfter do
          @moduledoc false
          def change_sets do
            [Migrations.V1Toolsets.change_set() | BrokenSet.change_sets()]
          end
        end

        assert {:error, {"v1_broken", _}} = Runner.up(TestRepo, BrokenAfter)

        assert {:ok, [%{name: "v1_toolsets"}]} = Runner.applied(TestRepo)
      end
    end
  end
else
  defmodule Noizu.MCP.Migrations.RunnerTest do
    @moduledoc false
    # DB-gated: collapses to one skipped test without a database, so an
    # absent run is visible, never silent (house pattern).
    use ExUnit.Case, async: false

    @tag :skip
    test "Runner suite skipped without MCP_OAUTH_TEST_DATABASE_URL", do: :ok
  end
end
