defmodule Noizu.MCP.Fixtures.PersistenceDB do
  @moduledoc """
  Shared Postgres plumbing for the PRD-4 DB-gated suites (persistence Ecto
  conformance, migration Runner, V1 DDL, selection boot-gate). Gated on
  `MCP_OAUTH_TEST_DATABASE_URL` — the SAME scratch database the auth-store
  Ecto battery uses (the table sets are disjoint). Cleanup happens on the way
  IN (idempotent DROP of the lib tables), so a failed run leaves its tables
  around for inspection without poisoning the next run.
  """

  @database_url System.get_env("MCP_OAUTH_TEST_DATABASE_URL")

  def database_url, do: @database_url

  def gated?(), do: not is_nil(@database_url)

  defmodule TestRepo do
    @moduledoc false
    use Ecto.Repo, otp_app: :noizu_mcp, adapter: Ecto.Adapters.Postgres
  end

  defmacro __using__(_opts) do
    quote do
      alias Noizu.MCP.Fixtures.PersistenceDB.TestRepo

      setup_all do
        assert Noizu.MCP.Fixtures.PersistenceDB.gated?(), """
        this suite is DB-gated on MCP_OAUTH_TEST_DATABASE_URL and should only
        run when the variable is set (the module collapses to one skipped test
        otherwise — see the module body)
        """

        # start_supervised!, NOT Repo.start_link — the setup_all process is
        # torn down BEFORE on_exit runs, and a linked repo dies with it
        # (same lesson the auth-store battery recorded).
        start_supervised!(
          {TestRepo,
           url: Noizu.MCP.Fixtures.PersistenceDB.database_url(), pool_size: 5, log: false}
        )

        # Way IN, not on_exit: the repo is stopped by then either way.
        Noizu.MCP.Fixtures.PersistenceDB.drop_lib_tables!(TestRepo)
        :ok
      end
    end
  end

  @lib_tables ~w(noizu_mcp_toolsets noizu_mcp_toolset_grants noizu_mcp_toolset_negotiations noizu_mcp_store_versions noizu_mcp_schema_versions)

  def drop_lib_tables!(repo) do
    # Drop EVERY noizu_mcp_% table (ledger included, plus any *test* tables a
    # previous run left behind) — a fresh Runner run must bootstrap from zero.
    # The auth-store battery's tables are mcp_oauth_*-prefixed and untouched.
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT table_name FROM information_schema.tables " <>
          "WHERE table_schema = current_schema() AND table_name LIKE 'noizu\\_%' ESCAPE '\\'",
        []
      )

    Enum.each(List.flatten(rows), fn table ->
      Ecto.Adapters.SQL.query!(repo, "DROP TABLE IF EXISTS #{table} CASCADE", [])
    end)

    :ok
  end

  def truncate_all!(repo) do
    # TRUNCATE has no IF EXISTS in Postgres — enumerate what's actually there.
    existing = existing_tables(repo)

    unless existing == [] do
      Ecto.Adapters.SQL.query!(repo, "TRUNCATE TABLE #{Enum.join(existing, ", ")} CASCADE", [])
    end

    :ok
  end

  @doc "Row counts per lib table — the zero-writes guard helper (AP-11)."
  # ⟦𓎡𓍯𓎲𓈖𓏏𓋴⟧ table_counts :: Row counts per lib table — the zero-writes guard helper (AP-11).
  def table_counts(repo) do
    Enum.into(@lib_tables, %{}, fn table ->
      case Ecto.Adapters.SQL.query(repo, "SELECT count(*) FROM #{table}", []) do
        {:ok, %{rows: [[n]]}} -> {table, n}
        {:error, _} -> {table, :missing}
      end
    end)
  end

  @doc "The lib tables that exist in `information_schema` (sorted)."
  # ⟦𓎼𓄿𓃭𓅱⟧ existing_tables :: The lib tables that exist in `information_schema` (sorted).
  def existing_tables(repo) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        repo,
        "SELECT table_name FROM information_schema.tables " <>
          "WHERE table_schema = current_schema() AND table_name LIKE 'noizu_mcp_%' ORDER BY table_name",
        []
      )

    List.flatten(rows)
  end
end
