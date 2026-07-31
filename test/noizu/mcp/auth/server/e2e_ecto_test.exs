defmodule Noizu.MCP.Auth.Server.E2EEctoTest do
  @moduledoc """
  The whole flow over real HTTP against **`Store.Ecto` on real Postgres**, with a
  **uuid** subject.

  `e2e_test.exs` runs the same flow against `Store.ETS`. That is not the same
  test. An ETS-backed flow exercises none of the SQL, none of the uuid encoding,
  and none of the two-statement race handling — which is how a `Store.Ecto` that
  had never performed a single `INSERT` came to be mounted by two applications
  behind a green suite. Everything below is here because it would not have been
  caught there:

    * a uuid `subject`, the shape both host apps use and precisely where the
      adapter failed with "expected a binary of 16 bytes"
    * a code and a refresh token that survive a round trip through Postgres
      rather than a term stored verbatim in an ETS table
    * replay of a persisted code and of a persisted refresh token, which is
      where a SQL adapter's `UPDATE ... WHERE` either detects reuse or does not

  The headline assertion is the same one that makes several MCP mounts on one
  host safe: a token minted for `/mcp` is **rejected** at `/mcp/learning`, and
  vice versa.

  DB-gated on `MCP_OAUTH_TEST_DATABASE_URL` exactly like the conformance battery
  — and, like it, a run without that variable now fails the suite rather than
  skipping in silence (see `test/test_helper.exs`).
  """
  use ExUnit.Case, async: false

  alias Noizu.MCP.Auth.Server.PKCE
  alias Noizu.MCP.Auth.Server.Store
  alias Noizu.MCP.Fixtures

  @database_url System.get_env("MCP_OAUTH_TEST_DATABASE_URL")

  if @database_url do
    defmodule Repo do
      @moduledoc false
      use Ecto.Repo, otp_app: :noizu_mcp, adapter: Ecto.Adapters.Postgres
    end

    alias Noizu.MCP.Auth.Server.TestSchema

    # A real uuid, because the column is a real uuid column.
    @subject "6f9619ff-8b86-d011-b42d-00cf4fc964ff"

    setup_all do
      start_supervised!({Repo, url: @database_url, pool_size: 10, log: false})

      # Cleanup on the way in, never from on_exit — by the time an on_exit
      # callback runs the repo is stopped, and the raise is reported as a
      # setup_all failure that invalidates every test in the module.
      Ecto.Adapters.SQL.query!(Repo, TestSchema.drop_sql(), [])
      Enum.each(TestSchema.create_sql(:uuid), &Ecto.Adapters.SQL.query!(Repo, &1, []))

      store = Module.concat(__MODULE__, Store)
      start_supervised!({Store.ETS, name: store})

      pid =
        start_supervised!(
          {Bandit,
           plug: Fixtures.ASRouter,
           port: 0,
           ip: :loopback,
           startup_log: false,
           thousand_island_options: [shutdown_timeout: 10]}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      base = "http://127.0.0.1:#{port}"

      Fixtures.AS.setup(base, store)
      Noizu.MCP.Test.ensure_server_started(Fixtures.Server)

      %{base: base}
    end

    setup do
      Ecto.Adapters.SQL.query!(Repo, TestSchema.truncate_sql(), [])

      # Every request in this module is served by Store.Ecto, not the ETS store
      # the fixture defaults to. `track_access_tokens: true` because the table
      # exists here and the tracked path is the one the host apps run.
      Fixtures.AS.put(
        :store,
        {Store.Ecto, repo: Repo, subject_type: :uuid, track_access_tokens: true}
      )

      Fixtures.AS.put(:subject, @subject)
      Fixtures.AS.put(:cimd_document, nil)
      Fixtures.AS.track_upstream(nil)

      on_exit(fn -> Fixtures.AS.put(:store, nil) end)
      :ok
    end

    describe "discovery → DCR → authorize → token → tools/call → refresh, on Postgres" do
      test "the whole flow, with a uuid subject", %{base: base} do
        # Discovery.
        metadata = get_json(base <> "/.well-known/oauth-authorization-server")
        assert metadata["issuer"] == base
        assert "S256" in metadata["code_challenge_methods_supported"]
        assert metadata["registration_endpoint"] == base <> "/oauth/register"

        # Dynamic registration — the first write to Postgres.
        client = register(base)
        assert is_binary(client["client_id"])

        # It is really in the database, not in a process somewhere.
        assert {:ok, stored} = Store.Ecto.get_client(client["client_id"], store_opts())
        assert stored.client_id == client["client_id"]

        # Authorize → consent → code, then exchange.
        verifier = PKCE.generate_verifier()
        resource = base <> "/mcp/learning"
        {code, state} = authorize(base, client["client_id"], verifier, resource)
        assert state == "client-state-123"

        tokens = exchange(base, client["client_id"], code, verifier, resource)
        assert is_binary(tokens["access_token"])
        assert is_binary(tokens["refresh_token"])

        # The uuid subject survived the round trip through a uuid column.
        {:ok, session} = mcp_initialize(base, "/mcp/learning", tokens["access_token"])
        result = mcp_call(base, "/mcp/learning", tokens["access_token"], session)
        assert result["result"]["content"] |> hd() |> Map.get("text") == "sub=#{@subject}"

        # Refresh, which reads and rotates a persisted row.
        refreshed = refresh(base, client["client_id"], tokens["refresh_token"])
        assert is_binary(refreshed["access_token"])
        assert refreshed["refresh_token"] != tokens["refresh_token"]

        {:ok, session2} = mcp_initialize(base, "/mcp/learning", refreshed["access_token"])
        result2 = mcp_call(base, "/mcp/learning", refreshed["access_token"], session2)
        assert result2["result"]["content"] |> hd() |> Map.get("text") == "sub=#{@subject}"
      end

      test "a token minted for /mcp is REJECTED at /mcp/learning, and vice versa", %{base: base} do
        # The assertion that makes two mounts on one host safe. Audience binding
        # is enforced by the verifier, but the token it checks was persisted and
        # re-read by the SQL adapter, so this is the adapter's resource column
        # doing its job as much as the verifier's.
        client = register(base)

        root = full_flow(base, client["client_id"], base <> "/mcp")
        learning = full_flow(base, client["client_id"], base <> "/mcp/learning")

        # Each works on its own mount...
        assert {:ok, _} = mcp_initialize(base, "/mcp", root)
        assert {:ok, _} = mcp_initialize(base, "/mcp/learning", learning)

        # ...and neither works on the other's.
        assert {:error, 401} = mcp_initialize(base, "/mcp/learning", root)
        assert {:error, 401} = mcp_initialize(base, "/mcp", learning)
      end

      test "a replayed authorization code is refused and takes the family with it", %{base: base} do
        client = register(base)
        verifier = PKCE.generate_verifier()
        resource = base <> "/mcp/learning"
        {code, _state} = authorize(base, client["client_id"], verifier, resource)

        tokens = exchange(base, client["client_id"], code, verifier, resource)

        # Replaying the code must fail...
        replay =
          Req.post!(base <> "/oauth/token",
            form: %{
              "grant_type" => "authorization_code",
              "client_id" => client["client_id"],
              "code" => code,
              "code_verifier" => verifier,
              "redirect_uri" => "https://claude.ai/api/mcp/auth_callback",
              "resource" => resource
            },
            retry: false
          )

        assert replay.status == 400

        # ...and the refresh token issued from that code must be dead, because a
        # replayed code means the first redemption may not have been the client.
        assert raw_refresh(base, client["client_id"], tokens["refresh_token"]).status == 400
      end

      test "a replayed refresh token kills the family", %{base: base} do
        client = register(base)
        tokens = exchange_flow(base, client["client_id"], base <> "/mcp/learning")

        rotated = refresh(base, client["client_id"], tokens["refresh_token"])

        # The retired token is refused...
        assert raw_refresh(base, client["client_id"], tokens["refresh_token"]).status == 400
        # ...and its successor dies with it.
        assert raw_refresh(base, client["client_id"], rotated["refresh_token"]).status == 400
      end
    end

    describe "CIMD variant, on Postgres" do
      test "a URL client_id runs the same flow with no registration step", %{base: base} do
        Fixtures.AS.put_cimd_document(%{
          "client_id" => "https://public.example.com/mcp-client",
          "client_name" => "Ecto CIMD client",
          "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
          "token_endpoint_auth_method" => "none"
        })

        with_cimd_fetcher(fn ->
          client_id = "https://public.example.com/mcp-client"
          token = full_flow(base, client_id, base <> "/mcp/learning")

          {:ok, session} = mcp_initialize(base, "/mcp/learning", token)
          result = mcp_call(base, "/mcp/learning", token, session)
          assert result["result"]["content"] |> hd() |> Map.get("text") == "sub=#{@subject}"

          # The CIMD client was persisted as a cimd-kind client, in Postgres.
          assert {:ok, stored} = Store.Ecto.get_client(client_id, store_opts())
          assert stored.client_id_kind == :cimd
        end)
      end
    end

    # ── helpers ────────────────────────────────────────────────────────────

    defp store_opts, do: [repo: Repo, subject_type: :uuid, track_access_tokens: true]

    defp with_cimd_fetcher(fun) do
      previous = Application.get_env(:noizu_mcp, :test_cimd_fetcher)
      Application.put_env(:noizu_mcp, :test_cimd_fetcher, &Fixtures.AS.fetch_cimd/2)

      try do
        fun.()
      after
        Application.put_env(:noizu_mcp, :test_cimd_fetcher, previous)
      end
    end

    defp register(base) do
      response =
        Req.post!(base <> "/oauth/register",
          json: %{
            "client_name" => "E2E Ecto agent",
            "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
            "grant_types" => ["authorization_code", "refresh_token"],
            "response_types" => ["code"],
            "token_endpoint_auth_method" => "none",
            "scope" => "mcp"
          },
          retry: false
        )

      assert response.status == 201, inspect(response.body)
      decoded(response)
    end

    defp authorize(base, client_id, verifier, resource) do
      {:ok, challenge} = PKCE.challenge(verifier)

      query =
        URI.encode_query(%{
          "response_type" => "code",
          "client_id" => client_id,
          "redirect_uri" => "https://claude.ai/api/mcp/auth_callback",
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "scope" => "mcp",
          "state" => "client-state-123",
          "resource" => resource
        })

      page = Req.get!(base <> "/oauth/authorize?" <> query, redirect: false, retry: false)

      location =
        case page.status do
          302 ->
            page |> Req.Response.get_header("location") |> List.first()

          200 ->
            form =
              ~r/name="(?<name>[^"]+)" value="(?<value>[^"]*)"/
              |> Regex.scan(page.body, capture: :all_names)
              |> Map.new(fn [name, value] -> {name, value} end)

            approved =
              Req.post!(base <> "/oauth/consent",
                form: %{
                  "login_state" => form["login_state"],
                  "csrf_token" => form["csrf_token"],
                  "decision" => "approve"
                },
                redirect: false,
                retry: false
              )

            assert approved.status == 302, "consent should redirect, got #{approved.status}"
            approved |> Req.Response.get_header("location") |> List.first()
        end

      decoded_query = URI.decode_query(URI.parse(location).query)
      assert is_binary(decoded_query["code"]), "expected a code, got #{location}"
      {decoded_query["code"], decoded_query["state"]}
    end

    defp exchange(base, client_id, code, verifier, resource) do
      response =
        Req.post!(base <> "/oauth/token",
          form: %{
            "grant_type" => "authorization_code",
            "client_id" => client_id,
            "code" => code,
            "code_verifier" => verifier,
            "redirect_uri" => "https://claude.ai/api/mcp/auth_callback",
            "resource" => resource
          },
          retry: false
        )

      assert response.status == 200, "token exchange failed: #{inspect(response.body)}"
      decoded(response)
    end

    defp exchange_flow(base, client_id, resource) do
      verifier = PKCE.generate_verifier()
      {code, _state} = authorize(base, client_id, verifier, resource)
      exchange(base, client_id, code, verifier, resource)
    end

    defp full_flow(base, client_id, resource),
      do: exchange_flow(base, client_id, resource)["access_token"]

    defp raw_refresh(base, client_id, refresh_token) do
      Req.post!(base <> "/oauth/token",
        form: %{
          "grant_type" => "refresh_token",
          "client_id" => client_id,
          "refresh_token" => refresh_token
        },
        retry: false
      )
    end

    defp refresh(base, client_id, refresh_token) do
      response = raw_refresh(base, client_id, refresh_token)
      assert response.status == 200, "refresh failed: #{inspect(response.body)}"
      decoded(response)
    end

    defp mcp_initialize(base, path, token) do
      response =
        Req.post!(base <> path,
          json: %{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "initialize",
            "params" => %{
              "protocolVersion" => "2025-11-25",
              "capabilities" => %{},
              "clientInfo" => %{"name" => "e2e-ecto", "version" => "1.0.0"}
            }
          },
          headers: [{"authorization", "Bearer " <> token}],
          retry: false
        )

      case response.status do
        200 -> {:ok, response |> Req.Response.get_header("mcp-session-id") |> List.first()}
        status -> {:error, status}
      end
    end

    defp mcp_call(base, path, token, session) do
      Req.post!(base <> path,
        json: %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
        headers: [{"authorization", "Bearer " <> token}, {"mcp-session-id", session}],
        retry: false
      )

      response =
        Req.post!(base <> path,
          json: %{
            "jsonrpc" => "2.0",
            "id" => 2,
            "method" => "tools/call",
            "params" => %{"name" => "whoami", "arguments" => %{}}
          },
          headers: [{"authorization", "Bearer " <> token}, {"mcp-session-id", session}],
          retry: false
        )

      decoded(response)
    end

    defp get_json(url) do
      response = Req.get!(url, retry: false)
      assert response.status == 200
      decoded(response)
    end

    defp decoded(%Req.Response{body: body}) when is_map(body), do: body
    defp decoded(%Req.Response{body: body}), do: Jason.decode!(body)
  end
end
