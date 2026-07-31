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

      # `track_access_tokens: true`, explicitly. Whether tracking is on is a
      # store *option* for this adapter, not an adapter capability, so without
      # the flag the shared battery asserted tracked semantics while exercising
      # the untracked path — and the tracked Ecto path had no passing coverage
      # at all. The untracked path keeps its own coverage in the describe block
      # above.
      %{adapter: Store.Ecto, store_opts: [repo: Repo, track_access_tokens: true]}
    end

    describe "revoke_access_token/2 and an absent :track_access_tokens" do
      test "raises rather than reporting a revocation it did not perform", %{
        store_opts: store_opts
      } do
        # Silent-success revocation is the failure this guards. A caller who has
        # not said whether tracking is on has not decided, and `:ok` here would
        # tell an admin a credential was killed when it was not.
        opts = Keyword.delete(store_opts, :track_access_tokens)

        assert_raise ArgumentError, ~r/requires an explicit `:track_access_tokens`/, fn ->
          Store.Ecto.revoke_access_token(Store.generate_token(), opts)
        end
      end

      test "an explicit false is still a deliberate no-op", %{store_opts: store_opts} do
        opts = Keyword.put(store_opts, :track_access_tokens, false)
        assert :ok = Store.Ecto.revoke_access_token(Store.generate_token(), opts)
      end

      test "an explicit true actually revokes", %{store_opts: store_opts} do
        opts = Keyword.put(store_opts, :track_access_tokens, true)
        client = put_absent_flag_client(opts)
        jti = Store.generate_token()

        :ok =
          Store.Ecto.put_access_token(
            %Store.AccessToken{
              jti: jti,
              client_id: client,
              subject: "user-1",
              scope: ["mcp"],
              resource: "https://app.example.com/mcp",
              expires_at: DateTime.add(DateTime.utc_now(), 900, :second)
            },
            opts
          )

        refute Store.Ecto.access_token_revoked?(jti, opts)
        assert :ok = Store.Ecto.revoke_access_token(jti, opts)
        assert Store.Ecto.access_token_revoked?(jti, opts)
      end
    end

    # `mcp_oauth_access_tokens.client_id` is a real FK, so the token needs a
    # real client behind it.
    defp put_absent_flag_client(opts) do
      client_id = "client-" <> Store.generate_token()

      {:ok, _} =
        Store.Ecto.put_client(
          %Noizu.MCP.Auth.Server.Client{
            client_id: client_id,
            client_id_kind: :registered,
            client_name: "Revoke guard",
            redirect_uris: ["https://claude.ai/cb"],
            scope: ["mcp"]
          },
          opts
        )

      client_id
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

        # An error TUPLE, not a raise: `query/3` converts every SQL failure to
        # `{:error, {:store_error, reason}}` and the adapter never raises for
        # one. Matched to that exact shape rather than a bare `{:error, _}` —
        # the property being pinned is that a missing table with tracking ON
        # surfaces rather than being swallowed, so a `{:ok, counts}` return has
        # to fail this test.
        assert {:error, {:store_error, %Postgrex.Error{}}} =
                 Store.Ecto.purge_expired(DateTime.utc_now(), opts)
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
