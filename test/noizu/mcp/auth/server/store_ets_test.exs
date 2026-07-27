defmodule Noizu.MCP.Auth.Server.Store.ETSTest do
  @moduledoc """
  The shipped in-memory adapter against the shared conformance battery, plus the
  hashing checks that can only be made by looking inside the tables.
  """
  use ExUnit.Case, async: false

  alias Noizu.MCP.Auth.Server.Secret
  alias Noizu.MCP.Auth.Server.Store
  alias Noizu.MCP.Auth.Server.Store.AuthorizationCode

  setup do
    name = Module.concat(__MODULE__, :"Store#{System.unique_integer([:positive])}")
    start_supervised!({Store.ETS, name: name})
    %{adapter: Store.ETS, store_opts: [name: name]}
  end

  describe "nothing is stored in the clear" do
    test "an authorization code is keyed by its hash, and the raw code is dropped", ctx do
      raw = Store.generate_token()

      :ok =
        Store.ETS.put_authorization_code(
          %AuthorizationCode{
            code: raw,
            client_id: "c1",
            subject: "user-1",
            redirect_uri: "https://claude.ai/cb",
            code_challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
          },
          ctx.store_opts
        )

      dumped = :ets.tab2list(Module.concat([ctx.store_opts[:name], Table, Codes]))

      assert [{key, record}] = dumped
      assert key == Secret.token_hash(raw)
      refute key == raw
      # The struct keeps no copy of the plaintext either.
      assert record.code == nil
      refute inspect(dumped) =~ raw
    end

    test "a refresh token is keyed by its hash, and the raw token is dropped", ctx do
      raw = Store.generate_token()

      :ok =
        Store.ETS.put_refresh_token(
          %Store.RefreshToken{
            token: raw,
            client_id: "c1",
            subject: "user-1",
            family_id: Store.generate_id(),
            expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
          },
          ctx.store_opts
        )

      dumped = :ets.tab2list(Module.concat([ctx.store_opts[:name], Table, RefreshTokens]))

      assert [{key, record}] = dumped
      assert key == Secret.token_hash(raw)
      assert record.token == nil
      refute inspect(dumped) =~ raw
    end

    test "login state is keyed by the hash of the state value", ctx do
      state = Store.generate_token()
      :ok = Store.ETS.put_login_state(state, %{"client_id" => "c1"}, 600, ctx.store_opts)

      dumped = :ets.tab2list(Module.concat([ctx.store_opts[:name], Table, LoginStates]))
      assert [{key, _record}] = dumped
      assert key == Secret.token_hash(state)
      refute inspect(dumped) =~ state
    end
  end

  describe "adapter specifics" do
    test "reset/1 empties every table", ctx do
      _ = Store.ETS.put_client(%Noizu.MCP.Auth.Server.Client{client_id: "c1"}, ctx.store_opts)
      assert {:ok, _} = Store.ETS.get_client("c1", ctx.store_opts)

      assert :ok = Store.ETS.reset(ctx.store_opts)
      assert {:error, :not_found} = Store.ETS.get_client("c1", ctx.store_opts)
    end

    test "several named stores coexist without seeing each other", ctx do
      other = Module.concat(__MODULE__, :SecondStore)
      start_supervised!({Store.ETS, name: other}, id: :second)

      _ = Store.ETS.put_client(%Noizu.MCP.Auth.Server.Client{client_id: "c1"}, ctx.store_opts)

      assert {:ok, _} = Store.ETS.get_client("c1", ctx.store_opts)
      assert {:error, :not_found} = Store.ETS.get_client("c1", name: other)
    end

    test "a store that was never started reports :store_unavailable rather than raising" do
      assert {:error, :store_unavailable} = Store.ETS.get_client("c1", name: :never_started_store)
    end
  end

  use Noizu.MCP.Auth.Server.StoreConformanceCase
end
