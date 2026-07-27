defmodule Noizu.MCP.Auth.Server.Store.EctoTest do
  @moduledoc """
  The raw-SQL adapter against the same conformance battery as the ETS one.

  **DB-gated.** Set `MCP_OAUTH_TEST_DATABASE_URL` to a Postgres database this
  suite may create and drop tables in, then:

      MCP_OAUTH_TEST_DATABASE_URL=postgres://user:pass@localhost:5432/noizu_mcp_test \\
        mix test test/noizu/mcp/auth/server/store_ecto_test.exs

  Without it, the module compiles to a single skipped test. That is deliberate:
  the suite must stay green on a machine with no Postgres, and a silently *absent*
  test is worse than a visibly skipped one — the skip message says what to set.
  """
  use ExUnit.Case, async: false

  @database_url System.get_env("MCP_OAUTH_TEST_DATABASE_URL")

  if @database_url do
    defmodule Repo do
      @moduledoc false
      use Ecto.Repo, otp_app: :noizu_mcp, adapter: Ecto.Adapters.Postgres
    end

    alias Noizu.MCP.Auth.Server.Store
    alias Noizu.MCP.Auth.Server.TestSchema

    setup_all do
      {:ok, pid} = Repo.start_link(url: @database_url, pool_size: 25, log: false)

      Ecto.Adapters.SQL.query!(Repo, TestSchema.drop_sql(), [])
      Enum.each(TestSchema.create_sql(), &Ecto.Adapters.SQL.query!(Repo, &1, []))

      on_exit(fn ->
        if Process.alive?(pid) do
          Ecto.Adapters.SQL.query!(Repo, TestSchema.drop_sql(), [])
          Repo.stop()
        end
      end)

      :ok
    end

    setup do
      # A shared connection pool rather than the sandbox: the concurrency tests
      # need 20 real connections racing one row, which is exactly what the
      # sandbox's single shared transaction would serialize away.
      Ecto.Adapters.SQL.query!(Repo, TestSchema.truncate_sql(), [])
      %{adapter: Store.Ecto, store_opts: [repo: Repo]}
    end

    test "requires a repo", %{store_opts: _opts} do
      assert_raise ArgumentError, fn -> Store.Ecto.get_client("c1", []) end
    end

    use Noizu.MCP.Auth.Server.StoreConformanceCase
  else
    @tag :skip
    test "Store.Ecto conformance (set MCP_OAUTH_TEST_DATABASE_URL to run)" do
      flunk("unreachable — tagged :skip")
    end
  end
end
