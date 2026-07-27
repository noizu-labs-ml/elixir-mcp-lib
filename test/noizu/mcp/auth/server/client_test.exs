defmodule Noizu.MCP.Auth.Server.ClientTest do
  @moduledoc """
  Registration validation is the gate on an endpoint anyone may POST to, so most
  of what matters here is what it *refuses*.
  """
  use ExUnit.Case, async: true

  alias Noizu.MCP.Auth.Server
  alias Noizu.MCP.Auth.Server.Client
  alias Noizu.MCP.Auth.Server.Errors
  alias Noizu.MCP.Auth.Server.Secret
  alias Noizu.MCP.Auth.Server.Store

  @fast [iterations: 1_000]

  defp config(overrides \\ []) do
    Server.config(
      Keyword.merge(
        [
          issuer: "https://app.example.com",
          store: {Store.ETS, name: :unused},
          signing: {:hs256, "a-secret-long-enough-for-hs256-use"},
          upstream: {Noizu.MCP.Auth.Server.Upstream.HostSession, []},
          scopes_supported: ["mcp", "mcp:admin"],
          dcr: [enabled: true, secret_opts: @fast]
        ],
        overrides
      )
    )
  end

  defp registration(overrides \\ %{}) do
    Map.merge(
      %{
        "client_name" => "Agent",
        "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
        "token_endpoint_auth_method" => "none",
        "scope" => "mcp"
      },
      overrides
    )
  end

  describe "from_registration/2 — accepting" do
    test "a public client with PKCE is the normal case" do
      assert {:ok, client, nil} = Client.from_registration(registration(), config())

      assert String.starts_with?(client.client_id, "mcp_")
      assert client.client_id_kind == :registered
      assert client.token_endpoint_auth_method == "none"
      assert client.secret_hash == nil
      assert client.grant_types == ["authorization_code", "refresh_token"]
      assert client.response_types == ["code"]
      assert client.scope == ["mcp"]
    end

    test "a confidential client gets a secret exactly once" do
      assert {:ok, client, secret} =
               Client.from_registration(
                 registration(%{"token_endpoint_auth_method" => "client_secret_post"}),
                 config()
               )

      assert is_binary(secret)
      assert byte_size(secret) >= 32
      # Stored hashed, and the plaintext is not recoverable from the struct.
      refute client.secret_hash == secret
      assert Secret.verify(secret, client.secret_hash, @fast)
      refute inspect(client) =~ secret
    end

    test "loopback redirect URIs are accepted for native clients" do
      assert {:ok, client, _} =
               Client.from_registration(
                 registration(%{
                   "redirect_uris" => ["http://127.0.0.1/callback", "http://localhost/callback"]
                 }),
                 config()
               )

      assert length(client.redirect_uris) == 2
    end

    test "an omitted scope falls back to the server default" do
      assert {:ok, %{scope: ["mcp", "mcp:admin"]}, _} =
               Client.from_registration(
                 registration() |> Map.delete("scope"),
                 config(default_scope: ["mcp", "mcp:admin"])
               )
    end

    test "metadata fields are carried and bounded" do
      assert {:ok, client, _} =
               Client.from_registration(
                 registration(%{
                   "client_uri" => "https://claude.ai",
                   "logo_uri" => "https://claude.ai/logo.png",
                   "software_id" => String.duplicate("x", 5_000)
                 }),
                 config()
               )

      assert client.client_uri == "https://claude.ai"
      assert byte_size(client.software_id) == 2_048
    end
  end

  describe "from_registration/2 — refusing" do
    test "no redirect_uris at all" do
      assert {:error, %Errors{code: :invalid_redirect_uri}} =
               Client.from_registration(registration(%{"redirect_uris" => []}), config())

      assert {:error, %Errors{code: :invalid_redirect_uri}} =
               Client.from_registration(registration() |> Map.delete("redirect_uris"), config())

      assert {:error, %Errors{code: :invalid_redirect_uri}} =
               Client.from_registration(
                 registration(%{"redirect_uris" => "not-a-list"}),
                 config()
               )
    end

    test "an unusable redirect URI" do
      for uri <- [
            "http://claude.ai/cb",
            "https://claude.ai/cb#fragment",
            "https://claude.ai@evil.example/cb",
            "https://*.claude.ai/cb",
            "/relative",
            "javascript:alert(1)"
          ] do
        assert {:error, %Errors{code: :invalid_redirect_uri}} =
                 Client.from_registration(registration(%{"redirect_uris" => [uri]}), config()),
               "#{uri} should not be registrable"
      end
    end

    test "a host outside allowed_redirect_hosts — including a suffix look-alike" do
      config =
        config(dcr: [enabled: true, allowed_redirect_hosts: ["claude.ai"], secret_opts: @fast])

      assert {:ok, _, _} = Client.from_registration(registration(), config)

      assert {:error, %Errors{code: :invalid_redirect_uri}} =
               Client.from_registration(
                 registration(%{"redirect_uris" => ["https://evil-claude.ai/cb"]}),
                 config
               )

      # Loopback is exempt: a native client's callback is not a host anyone claims.
      assert {:ok, _, _} =
               Client.from_registration(
                 registration(%{"redirect_uris" => ["http://127.0.0.1/cb"]}),
                 config
               )
    end

    test "too many redirect URIs" do
      uris = for n <- 1..11, do: "https://claude.ai/cb#{n}"

      assert {:error, %Errors{}} =
               Client.from_registration(registration(%{"redirect_uris" => uris}), config())
    end

    test "an unsupported auth method, grant or response type" do
      assert {:error, %Errors{code: :invalid_client_metadata}} =
               Client.from_registration(
                 registration(%{"token_endpoint_auth_method" => "private_key_jwt"}),
                 config()
               )

      assert {:error, %Errors{code: :invalid_client_metadata}} =
               Client.from_registration(registration(%{"grant_types" => ["password"]}), config())

      assert {:error, %Errors{code: :invalid_client_metadata}} =
               Client.from_registration(registration(%{"response_types" => ["token"]}), config())
    end

    test "refresh_token without authorization_code has nothing to refresh" do
      assert {:error, %Errors{code: :invalid_client_metadata}} =
               Client.from_registration(
                 registration(%{"grant_types" => ["refresh_token"]}),
                 config()
               )
    end

    test "a scope the server does not support" do
      assert {:error, %Errors{code: :invalid_scope}} =
               Client.from_registration(registration(%{"scope" => "mcp root"}), config())
    end
  end

  describe "from_cimd/3" do
    @document %{
      "client_id" => "https://claude.ai/.well-known/mcp-client",
      "client_name" => "Claude",
      "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"]
    }

    test "builds a public client from a self-consistent document" do
      assert {:ok, client} =
               Client.from_cimd("https://claude.ai/.well-known/mcp-client", @document, config())

      assert client.client_id_kind == :cimd
      assert client.token_endpoint_auth_method == "none"
      assert client.secret_hash == nil
      assert client.client_name == "Claude"
      refute is_nil(client.cimd_expires_at)
    end

    test "refuses a document claiming a different client_id" do
      # Without this check one URL could serve a document impersonating another
      # client and inherit its consent.
      assert {:error, %Errors{code: :invalid_client_metadata}} =
               Client.from_cimd("https://claude.ai/other", @document, config())

      assert {:error, %Errors{code: :invalid_client_metadata}} =
               Client.from_cimd(
                 "https://claude.ai/.well-known/mcp-client",
                 Map.delete(@document, "client_id"),
                 config()
               )
    end

    test "accepts the singular redirect_uri spelling" do
      document =
        @document
        |> Map.delete("redirect_uris")
        |> Map.put("redirect_uri", "https://claude.ai/api/mcp/auth_callback")

      assert {:ok, client} =
               Client.from_cimd("https://claude.ai/.well-known/mcp-client", document, config())

      assert client.redirect_uris == ["https://claude.ai/api/mcp/auth_callback"]
    end

    test "still validates redirect URIs" do
      document = Map.put(@document, "redirect_uris", ["http://claude.ai/cb"])

      assert {:error, %Errors{}} =
               Client.from_cimd("https://claude.ai/.well-known/mcp-client", document, config())
    end

    test "cimd_stale?/2 drives re-fetching" do
      {:ok, client} =
        Client.from_cimd("https://claude.ai/.well-known/mcp-client", @document, config())

      refute Client.cimd_stale?(client, DateTime.utc_now())
      assert Client.cimd_stale?(client, DateTime.add(DateTime.utc_now(), 7_200, :second))
      assert Client.cimd_stale?(%{client | cimd_expires_at: nil}, DateTime.utc_now())
      # A registered client never goes stale — there is no document behind it.
      refute Client.cimd_stale?(%Client{client_id_kind: :registered}, DateTime.utc_now())
    end
  end

  describe "authenticate/3" do
    test "a public client authenticates by presenting nothing" do
      client = %Client{token_endpoint_auth_method: "none"}
      assert :ok = Client.authenticate(client, nil)
    end

    test "presenting a secret for a public client is an error, not something to ignore" do
      client = %Client{token_endpoint_auth_method: "none"}
      assert {:error, %Errors{code: :invalid_client}} = Client.authenticate(client, "anything")
    end

    test "a confidential client needs its secret" do
      client = %Client{
        token_endpoint_auth_method: "client_secret_post",
        secret_hash: Secret.hash("s3cret", @fast)
      }

      assert :ok = Client.authenticate(client, "s3cret", @fast)

      assert {:error, %Errors{code: :invalid_client}} =
               Client.authenticate(client, "wrong", @fast)

      assert {:error, %Errors{code: :invalid_client}} = Client.authenticate(client, nil, @fast)
    end

    test "a confidential client with no stored hash always fails" do
      client = %Client{token_endpoint_auth_method: "client_secret_post", secret_hash: nil}

      assert {:error, %Errors{code: :invalid_client}} =
               Client.authenticate(client, "anything", @fast)
    end
  end

  describe "policy" do
    test "registered and CIMD clients always require consent" do
      # `consent: [enabled: false]` must not disable it for a client that
      # registered itself — that is the confused-deputy hole.
      config = config(consent: [enabled: false])

      assert Client.requires_consent?(%Client{client_id_kind: :registered}, config)
      assert Client.requires_consent?(%Client{client_id_kind: :cimd}, config)
      refute Client.requires_consent?(%Client{client_id_kind: :preconfigured}, config)

      assert Client.requires_consent?(%Client{client_id_kind: :preconfigured}, config())
    end

    test "active?/1 and supports_grant?/2" do
      assert Client.active?(%Client{})
      refute Client.active?(%Client{disabled_at: DateTime.utc_now()})

      assert Client.supports_grant?(
               %Client{grant_types: ["authorization_code"]},
               "authorization_code"
             )

      refute Client.supports_grant?(%Client{grant_types: ["authorization_code"]}, "refresh_token")
    end

    test "public?/1" do
      assert Client.public?(%Client{token_endpoint_auth_method: "none"})
      refute Client.public?(%Client{token_endpoint_auth_method: "client_secret_basic"})
    end
  end

  describe "to_registration_response/2" do
    test "includes the secret and its non-expiry only for a confidential client" do
      {:ok, client, secret} =
        Client.from_registration(
          registration(%{"token_endpoint_auth_method" => "client_secret_basic"}),
          config()
        )

      body = Client.to_registration_response(client, secret)
      assert body["client_secret"] == secret
      assert body["client_secret_expires_at"] == 0
      assert body["client_id"] == client.client_id
      assert is_integer(body["client_id_issued_at"])

      {:ok, public, nil} = Client.from_registration(registration(), config())
      public_body = Client.to_registration_response(public, nil)
      refute Map.has_key?(public_body, "client_secret")
      refute Map.has_key?(public_body, "client_secret_expires_at")
    end
  end
end
