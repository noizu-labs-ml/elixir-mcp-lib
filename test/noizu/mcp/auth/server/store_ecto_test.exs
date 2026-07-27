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
      # `start_supervised!`, not `Repo.start_link`. A linked repo is owned by the
      # setup_all process, which ExUnit terminates *before* running on_exit — the
      # teardown DROP then dies with `DBConnection.Holder.checkout ... (EXIT)
      # shutdown`, ExUnit reports "failure on setup_all callback", and every test
      # in this module is invalidated. That turns a 2-failure run into a
      # 36-failure one and buries whatever actually broke.
      start_supervised!({Repo, url: @database_url, pool_size: 25, log: false})

      # Cleanup happens HERE, on the way in, not in an on_exit on the way out.
      # By the time an on_exit callback runs the repo is already stopped — linked
      # or supervised, either way — so a teardown `DROP` raises ("could not lookup
      # Ecto repo ... because it was not started"), ExUnit reports "failure on
      # setup_all callback", and all 31 tests in this module are invalidated.
      # Dropping first is idempotent and leaves the tables around afterwards for
      # inspection when something fails.
      Ecto.Adapters.SQL.query!(Repo, TestSchema.drop_sql(), [])
      Enum.each(TestSchema.create_sql(), &Ecto.Adapters.SQL.query!(Repo, &1, []))

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

    describe "purge_expired with no access-tokens table" do
      setup do
        # The template calls `mcp_oauth_access_tokens` optional and tells hosts
        # running `track_access_tokens: false` they may drop it. Prove a sweep
        # survives that, because naming the table unconditionally made the
        # host's 15-minute purge job fail forever on an undefined relation.
        Ecto.Adapters.SQL.query!(Repo, "DROP TABLE mcp_oauth_access_tokens", [])

        on_exit(fn ->
          Ecto.Adapters.SQL.query!(Repo, TestSchema.access_tokens_sql(), [])
        end)

        :ok
      end

      test "succeeds and reports no access-token count", %{store_opts: store_opts} do
        opts = Keyword.put(store_opts, :track_access_tokens, false)

        assert {:ok, counts} = Store.Ecto.purge_expired(DateTime.utc_now(), opts)
        refute Map.has_key?(counts, :access_tokens)
        assert Map.has_key?(counts, :refresh_tokens)
      end

      test "answers untracked tokens without touching the table", %{store_opts: store_opts} do
        opts = Keyword.put(store_opts, :track_access_tokens, false)

        refute Store.Ecto.access_token_revoked?(Store.generate_token(), opts)
        assert :ok = Store.Ecto.revoke_access_token(Store.generate_token(), opts)
      end

      test "still fails loudly when tracking is on and the table is gone", %{
        store_opts: store_opts
      } do
        # The flag must not become a blanket try/rescue: with tracking on, a
        # missing table is a real misconfiguration and has to surface.
        opts = Keyword.put(store_opts, :track_access_tokens, true)

        assert_raise Postgrex.Error, fn ->
          Store.Ecto.purge_expired(DateTime.utc_now(), opts)
        end
      end
    end

    use Noizu.MCP.Auth.Server.StoreConformanceCase
  else
    @tag :skip
    test "Store.Ecto conformance (set MCP_OAUTH_TEST_DATABASE_URL to run)" do
      flunk("unreachable — tagged :skip")
    end
  end
end
