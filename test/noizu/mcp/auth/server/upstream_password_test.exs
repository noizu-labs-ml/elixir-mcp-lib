defmodule Noizu.MCP.Auth.Server.Upstream.PasswordTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Noizu.MCP.Auth.Server
  alias Noizu.MCP.Auth.Server.Config
  alias Noizu.MCP.Auth.Server.Secret
  alias Noizu.MCP.Auth.Server.Store
  alias Noizu.MCP.Auth.Server.Upstream.Password

  @issuer "https://app.example.com"
  @users %{
    "alice" => Secret.token_hash("wonderland"),
    "bob" => Secret.token_hash("builder")
  }

  setup do
    name = String.to_atom("mcp_password_store_#{System.unique_integer([:positive])}")

    start_supervised!({Store.ETS, name: name})

    config =
      Server.config(
        issuer: @issuer,
        store: {Store.ETS, name: name},
        signing: {:hs256, "a-secret-long-enough-for-hs256-use"},
        upstream: {Password, users: @users}
      )

    %{config: config}
  end

  defp opts(overrides), do: Keyword.merge([users: @users], overrides)

  # ── authenticate/4: the form ─────────────────────────────────────────────

  describe "authenticate" do
    test "renders the login form posting to the callback path with the state hidden", %{config: config} do
      conn = conn(:get, "/oauth/authorize")

      assert {:sent, conn} = Password.authenticate(conn, "state-1", config, opts([]))

      assert conn.state == :sent
      assert conn.status == 200

      body = conn.resp_body
      assert body =~ ~s(method="post")
      assert body =~ ~s(action="#{@issuer}/oauth/callback")
      assert body =~ ~s(name="login_state" value="state-1")
      assert body =~ ~s(name="username")
      assert body =~ ~s(type="password" name="password")
    end

    test "the response is not cacheable", %{config: config} do
      conn = conn(:get, "/oauth/authorize")
      assert {:sent, conn} = Password.authenticate(conn, "state-1", config, opts([]))

      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "the title option is escaped, not interpolated raw", %{config: config} do
      conn = conn(:get, "/oauth/authorize")
      assert {:sent, conn} = Password.authenticate(conn, "state-1", config, title: "Sign <b>in</b>")

      refute conn.resp_body =~ "<b>"
      assert conn.resp_body =~ "&lt;b&gt;"
    end
  end

  # ── callback/4: the credentials ──────────────────────────────────────────

  describe "callback success" do
    test "valid static credentials mint an identity and echo the state", %{config: config} do
      conn = conn(:post, "/oauth/callback", %{})
      params = %{"login_state" => "state-1", "username" => "alice", "password" => "wonderland"}

      assert {:ok, identity, "state-1"} = Password.callback(conn, params, config, opts([]))
      assert identity.subject == "alice"
      assert is_map(identity.claims)
      assert identity.claims == %{}
    end

    test "a validator's scopes and claims land in the identity" do
      validator = fn "alice", "pw" ->
        {:ok, %{scopes: ["mcp"], claims: %{"email" => "alice@example.com"}}}
      end

      config = config_with(validator: validator)

      assert {:ok, identity, _} =
               Password.callback(
                 conn(:post, "/oauth/callback", %{}),
                 %{"login_state" => "s", "username" => "alice", "password" => "pw"},
                 config,
                 validator: validator
               )

      assert identity.subject == "alice"
      assert identity.claims["scope"] == "mcp"
      assert identity.claims["email"] == "alice@example.com"
    end

    test "default_claims fill in behind the validator" do
      validator = fn _u, _p -> {:ok, %{scopes: [], claims: %{}}} end
      config = config_with(validator: validator)

      assert {:ok, identity, _} =
               Password.callback(
                 conn(:post, "/oauth/callback", %{}),
                 %{"login_state" => "s", "username" => "alice", "password" => "pw"},
                 config,
                 validator: validator,
                 default_claims: %{"iss" => @issuer}
               )

      assert identity.claims["iss"] == @issuer
    end
  end

  describe "callback failure" do
    test "a wrong password re-renders the form with a generic message", %{config: config} do
      conn = conn(:post, "/oauth/callback", %{})
      params = %{"login_state" => "state-1", "username" => "alice", "password" => "wrong"}

      assert {:sent, conn} = Password.callback(conn, params, config, opts([]))

      assert conn.state == :sent
      assert conn.resp_body =~ "Invalid username or password."
      assert conn.resp_body =~ ~s(value="state-1")
    end

    test "an unknown user gets the same message a wrong password gets", %{config: config} do
      wrong_password = fn username ->
        conn = conn(:post, "/oauth/callback", %{})
        params = %{"login_state" => "state-1", "username" => username, "password" => "nope"}
        assert {:sent, conn} = Password.callback(conn, params, config, opts([]))
        conn.resp_body
      end

      assert wrong_password.("alice") == wrong_password.("no-such-user")
    end

    test "a validator rejection earns the generic message, not the reason", %{config: config} do
      validator = fn _u, _p -> {:error, :account_locked} end

      conn = conn(:post, "/oauth/callback", %{})
      params = %{"login_state" => "state-1", "username" => "alice", "password" => "wonderland"}

      assert {:sent, conn} =
               Password.callback(conn, params, config, validator: validator)

      assert conn.resp_body =~ "Invalid username or password."
      refute conn.resp_body =~ "locked"
    end

    test "a missing state key cannot re-render a form", %{config: config} do
      conn = conn(:post, "/oauth/callback", %{})
      params = %{"username" => "alice", "password" => "wonderland"}

      assert {:error, :invalid_callback} = Password.callback(conn, params, config, opts([]))
      assert conn.state == :unset
    end

    test "missing or blank fields are invalid_callback with no response sent", %{config: config} do
      conn = conn(:post, "/oauth/callback", %{})

      assert {:error, :invalid_callback} =
               Password.callback(
                 conn,
                 %{"login_state" => "s", "username" => "", "password" => "x"},
                 config,
                 opts([])
               )

      assert conn.state == :unset
    end
  end

  defp config_with(upstream_opts) do
    name = String.to_atom("mcp_password_store_#{System.unique_integer([:positive])}")
    start_supervised!({Store.ETS, name: name})

    Server.config(
      issuer: @issuer,
      store: {Store.ETS, name: name},
      signing: {:hs256, "a-secret-long-enough-for-hs256-use"},
      upstream: {Password, upstream_opts}
    )
  end
end
