db_url = System.get_env("MCP_OAUTH_TEST_DATABASE_URL")

if db_url do
  defmodule Noizu.MCP.Migrations.V1ToolsetsTest do
    @moduledoc """
    The shipped v1 DDL (PRD-4 FR-4.7 / AC-4.8): table/column/index presence
    post-up via information_schema, idempotent re-run. The boot-gate BOTH-WAYS
    proof (missing tables ⇒ boot raise; migrated ⇒ boot ok) lives in the
    Ecto persistence suite (it needs the provider).

    **DB-gated** on `MCP_OAUTH_TEST_DATABASE_URL`.
    """
    use ExUnit.Case, async: false
    use Noizu.MCP.Fixtures.PersistenceDB

    alias Noizu.MCP.Migrations
    alias Noizu.MCP.Migration.Runner
    alias Noizu.MCP.Fixtures.PersistenceDB

    setup do
      # Cleanup on the way IN (house pattern — see the auth-store battery).
      Noizu.MCP.Fixtures.PersistenceDB.drop_lib_tables!(TestRepo)
      :ok
    end

    defp columns(repo, table) do
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          repo,
          "SELECT column_name, data_type, is_nullable FROM information_schema.columns " <>
            "WHERE table_schema = current_schema() AND table_name = $1",
          [table]
        )

      Map.new(rows, fn [name, type, nullable] -> {name, {type, nullable}} end)
    end

    defp indexes(repo, table) do
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          repo,
          "SELECT indexname FROM pg_indexes WHERE schemaname = current_schema() AND tablename = $1",
          [table]
        )

      MapSet.new(List.flatten(rows))
    end

    describe "v1_toolsets up" do
      test "creates the three store tables + the version counters" do
        assert {:ok, [_]} = Runner.up(TestRepo, Migrations)

        tables = PersistenceDB.existing_tables(TestRepo)

        assert "noizu_mcp_toolsets" in tables
        assert "noizu_mcp_toolset_grants" in tables
        assert "noizu_mcp_toolset_negotiations" in tables
        assert "noizu_mcp_store_versions" in tables
      end

      test "noizu_mcp_toolsets columns match the shipped DDL" do
        {:ok, _} = Runner.up(TestRepo, Migrations)
        cols = columns(TestRepo, "noizu_mcp_toolsets")

        assert {"text", "NO"} = cols["slug"]
        assert {"text", "YES"} = cols["title"]
        assert {"text", "NO"} = cols["base"]
        assert {"boolean", "NO"} = cols["immutable"]
        assert {"jsonb", "YES"} = cols["include"]
        assert {"jsonb", "NO"} = cols["exclude"]
        assert {"jsonb", "NO"} = cols["tools"]
        assert {"jsonb", "NO"} = cols["metadata"]
        assert {"timestamp with time zone", "NO"} = cols["inserted_at"]
        assert {"timestamp with time zone", "NO"} = cols["updated_at"]
      end

      test "noizu_mcp_toolset_grants columns + check + lookup index" do
        {:ok, _} = Runner.up(TestRepo, Migrations)
        cols = columns(TestRepo, "noizu_mcp_toolset_grants")

        assert {"text", "NO"} = cols["id"]
        assert {"text", "NO"} = cols["toolset_slug"]
        assert {"text", "NO"} = cols["authenticator"]
        assert {"text", "NO"} = cols["subject"]
        assert {"text", "NO"} = cols["effect"]
        assert {"jsonb", "NO"} = cols["scopes"]
        assert {"jsonb", "NO"} = cols["tool_overrides"]
        assert {"timestamp with time zone", "YES"} = cols["expires_at"]

        assert MapSet.member?(
                 indexes(TestRepo, "noizu_mcp_toolset_grants"),
                 "noizu_mcp_grants_lookup_idx"
               )

        # The effect check constraint is the DDL's own policy statement.
        assert {:error, _} =
                 Ecto.Adapters.SQL.query(
                   TestRepo,
                   "INSERT INTO noizu_mcp_toolset_grants (id, toolset_slug, authenticator, subject, effect) VALUES ('x','t','a','s','maybe')",
                   []
                 )
      end

      test "noizu_mcp_toolset_negotiations columns + lookup index" do
        {:ok, _} = Runner.up(TestRepo, Migrations)
        cols = columns(TestRepo, "noizu_mcp_toolset_negotiations")

        assert {"text", "NO"} = cols["tool"]
        assert {"jsonb", "NO"} = cols["required_scopes"]
        assert {"boolean", "NO"} = cols["granted"]
        assert {"jsonb", "NO"} = cols["metadata_overrides"]

        assert MapSet.member?(
                 indexes(TestRepo, "noizu_mcp_toolset_negotiations"),
                 "noizu_mcp_negotiations_lookup_idx"
               )
      end

      test "re-running up is idempotent (if not exists guards)" do
        {:ok, _} = Runner.up(TestRepo, Migrations)
        # Belt-and-braces: run the raw DDL again, not just the ledger skip.
        Enum.each(Migrations.V1Toolsets.up_statements(), fn sql ->
          assert {:ok, _} = Ecto.Adapters.SQL.query(TestRepo, sql, [])
        end)
      end

      test "down removes the v1 tables" do
        {:ok, _} = Runner.up(TestRepo, Migrations)
        {:ok, _} = Runner.down(TestRepo, Migrations, to: 0)

        tables = PersistenceDB.existing_tables(TestRepo)
        refute "noizu_mcp_toolsets" in tables
        refute "noizu_mcp_toolset_grants" in tables
        refute "noizu_mcp_toolset_negotiations" in tables
        refute "noizu_mcp_store_versions" in tables
      end
    end
  end
else
  defmodule Noizu.MCP.Migrations.V1ToolsetsTest do
    @moduledoc false
    use ExUnit.Case, async: false

    @tag :skip
    test "V1 DDL suite skipped without MCP_OAUTH_TEST_DATABASE_URL", do: :ok
  end
end
