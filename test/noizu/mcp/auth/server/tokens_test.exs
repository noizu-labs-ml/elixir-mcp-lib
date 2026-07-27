defmodule Noizu.MCP.Auth.Server.TokensTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.Auth.JWTVerifier
  alias Noizu.MCP.Auth.Server
  alias Noizu.MCP.Auth.Server.Store
  alias Noizu.MCP.Auth.Server.Tokens
  alias Noizu.MCP.Fixtures.OAuth

  @secret "a-secret-long-enough-for-hs256-use-here"
  @resource "https://app.example.com/mcp/learning"

  defp config(overrides \\ []) do
    Server.config(
      Keyword.merge(
        [
          issuer: "https://app.example.com",
          store: {Store.ETS, name: :unused},
          signing: {:hs256, @secret},
          upstream: {Noizu.MCP.Auth.Server.Upstream.HostSession, []},
          resources: [
            [resource: "https://app.example.com/mcp"],
            [resource: @resource]
          ]
        ],
        overrides
      )
    )
  end

  # `JOSE.JWT.peek_protected/1` lifts `alg` into the struct rather than the field
  # map, so read the header straight off the wire.
  defp protected_header(token) do
    [header, _payload, _signature] = String.split(token, ".")
    header |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  defp grant(overrides \\ %{}) do
    Map.merge(
      %{subject: "user-1", client_id: "mcp_abc", scope: ["mcp"], resource: @resource},
      overrides
    )
  end

  describe "mint_access_token/2" do
    test "carries a single string audience, the issuer, and a jti" do
      {:ok, token, claims} = Tokens.mint_access_token(config(), grant())

      assert claims["iss"] == "https://app.example.com"
      assert claims["sub"] == "user-1"
      assert claims["client_id"] == "mcp_abc"
      assert claims["scope"] == "mcp"
      # A string, not a list: `JWTVerifier` refuses a multi-audience token, and
      # this is the shape that makes that possible.
      assert claims["aud"] == @resource
      assert is_binary(claims["aud"])
      assert is_binary(claims["jti"])
      assert claims["exp"] - claims["iat"] == 900
      assert is_binary(token)
    end

    test "the minted token verifies through the mount's own verifier" do
      config = config()
      {:ok, token, _claims} = Tokens.mint_access_token(config, grant())

      assert {:ok, claims} =
               JWTVerifier.verify(
                 token,
                 OAuth.conn_info(),
                 Tokens.verifier_opts(config, @resource)
               )

      assert claims["sub"] == "user-1"
    end

    test "and is REJECTED by a sibling mount's verifier" do
      config = config()
      {:ok, token, _claims} = Tokens.mint_access_token(config, grant())

      assert {:error, :invalid_token} =
               JWTVerifier.verify(
                 token,
                 OAuth.conn_info(),
                 Tokens.verifier_opts(config, "https://app.example.com/mcp")
               )
    end

    test "the header declares at+jwt, so a client cannot mistake it for an id token" do
      {:ok, token, _} = Tokens.mint_access_token(config(), grant())
      header = protected_header(token)

      assert header["alg"] == "HS256"
      assert header["typ"] == "at+jwt"
    end

    test "a nil resource is omitted rather than serialized as null" do
      {:ok, _token, claims} = Tokens.mint_access_token(config(), grant(%{resource: nil}))
      refute Map.has_key?(claims, "aud")
    end

    test "the family id rides along when there is one" do
      {:ok, _token, claims} = Tokens.mint_access_token(config(), grant(%{family_id: "fam-1"}))
      assert claims["family_id"] == "fam-1"
    end

    test "RS256 mode signs with the private key and publishes only the public one" do
      jwk = JOSE.JWK.generate_key({:rsa, 2048})
      config = config(signing: {:rs256, jwk: jwk, kid: "key-1"})

      {:ok, token, _claims} = Tokens.mint_access_token(config, grant())
      header = protected_header(token)
      assert header["alg"] == "RS256"
      assert header["kid"] == "key-1"

      assert {:ok, _} =
               JWTVerifier.verify(
                 token,
                 OAuth.conn_info(),
                 Tokens.verifier_opts(config, @resource)
               )

      %{"keys" => [published]} = Tokens.jwks(config)
      assert published["kty"] == "RSA"
      assert published["use"] == "sig"
      assert published["alg"] == "RS256"
      assert published["kid"] == "key-1"
      # The private exponent must never appear in a published key set.
      refute Map.has_key?(published, "d")
      refute Map.has_key?(published, "p")
      refute Map.has_key?(published, "q")
    end

    test "HS256 mode publishes no keys at all" do
      assert Tokens.jwks(config()) == %{"keys" => []}
    end
  end

  describe "secret resolution" do
    def runtime_secret, do: @secret

    test "accepts a binary, a {mod, fun} and a fun/0 — so a release reads runtime config" do
      for signing <- [
            {:hs256, @secret},
            {:hs256, {__MODULE__, :runtime_secret}},
            {:hs256, &__MODULE__.runtime_secret/0}
          ] do
        {:ok, token, _} = Tokens.mint_access_token(config(signing: signing), grant())

        assert {true, _, _} =
                 JOSE.JWT.verify_strict(JOSE.JWK.from_oct(@secret), ["HS256"], token)
      end
    end
  end

  describe "mint_refresh_token/2" do
    test "is opaque, random, and carries the grant's family" do
      {:ok, token, record} = Tokens.mint_refresh_token(config(), grant(%{family_id: "fam-1"}))

      assert is_binary(token)
      # Opaque: not a JWT, nothing to read out of it.
      refute token =~ "."
      assert record.token == token
      assert record.family_id == "fam-1"
      assert record.subject == "user-1"
      assert record.resource == @resource
      assert DateTime.diff(record.expires_at, DateTime.utc_now()) > 2_591_000
      # The family deadline is a ceiling rotation cannot extend.
      assert DateTime.diff(record.family_expires_at, DateTime.utc_now()) > 7_775_000
    end

    test "allocates a family when the grant has none" do
      {:ok, _token, record} = Tokens.mint_refresh_token(config(), grant())
      assert is_binary(record.family_id)
    end

    test "an inherited family deadline is not extended" do
      deadline = DateTime.add(DateTime.utc_now(), 60, :second)

      {:ok, _token, record} =
        Tokens.mint_refresh_token(config(), grant(%{family_expires_at: deadline}))

      assert record.family_expires_at == deadline
    end

    test "refresh_family_ttl: nil means no ceiling" do
      {:ok, _token, record} = Tokens.mint_refresh_token(config(refresh_family_ttl: nil), grant())
      assert record.family_expires_at == nil
    end

    test "two tokens are never the same" do
      tokens = for _ <- 1..50, do: elem(Tokens.mint_refresh_token(config(), grant()), 1)
      assert length(Enum.uniq(tokens)) == 50
    end
  end

  describe "mint_authorization_code/2" do
    test "binds the PKCE challenge, the redirect URI and the resource" do
      request = %{
        client_id: "mcp_abc",
        subject: "user-1",
        redirect_uri: "https://claude.ai/cb",
        scope: ["mcp"],
        resource: @resource,
        code_challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
      }

      {:ok, code, record} = Tokens.mint_authorization_code(config(), request)

      assert is_binary(code)
      assert record.code == code
      assert record.code_challenge_method == "S256"
      assert record.redirect_uri == "https://claude.ai/cb"
      assert record.resource == @resource
      # Short-lived by construction.
      assert DateTime.diff(record.expires_at, DateTime.utc_now()) <= 60
      # A family is allocated here so the refresh token can inherit it.
      assert is_binary(record.refresh_family_id)
    end
  end

  describe "token_response/4" do
    test "always echoes scope, and omits refresh_token when there is none" do
      config = config()

      assert Tokens.token_response(config, "at", ["mcp"], "rt") == %{
               "access_token" => "at",
               "token_type" => "Bearer",
               "expires_in" => 900,
               "scope" => "mcp",
               "refresh_token" => "rt"
             }

      response = Tokens.token_response(config, "at", ["mcp"], nil)
      refute Map.has_key?(response, "refresh_token")
    end
  end

  describe "verifier_opts/2" do
    test "derives the mount verifier from the same config that mints" do
      # Drift between these two is the failure where tokens verify nowhere.
      opts = Tokens.verifier_opts(config(), @resource)

      assert Keyword.get(opts, :resource) == @resource
      assert Keyword.get(opts, :issuer) == "https://app.example.com"
      assert Keyword.get(opts, :algorithms) == ["HS256"]
      assert Keyword.get(opts, :secret) == @secret
    end

    test "RS256 hands over the public key only" do
      jwk = JOSE.JWK.generate_key({:rsa, 2048})
      opts = Tokens.verifier_opts(config(signing: {:rs256, jwk: jwk}), @resource)

      assert Keyword.get(opts, :algorithms) == ["RS256"]
      {_, published} = opts |> Keyword.fetch!(:jwk) |> JOSE.JWK.to_map()
      refute Map.has_key?(published, "d")
    end
  end

  describe "track_access_token/3" do
    setup do
      name = Module.concat(__MODULE__, :"Store#{System.unique_integer([:positive])}")
      start_supervised!({Store.ETS, name: name})
      %{store: [name: name]}
    end

    test "does nothing unless tracking is on", %{store: store} do
      config = config(store: {Store.ETS, store})
      {:ok, _token, claims} = Tokens.mint_access_token(config, grant())

      assert :ok = Tokens.track_access_token(config, claims, grant())
      refute Store.ETS.access_token_revoked?(claims["jti"], store)
      # Nothing was written, so there is nothing to revoke either.
      assert :ok = Store.ETS.revoke_access_token(claims["jti"], store)
      refute Store.ETS.access_token_revoked?(claims["jti"], store)
    end

    test "records a row when tracking is on, making revocation possible", %{store: store} do
      config = config(store: {Store.ETS, store}, track_access_tokens: true)
      {:ok, _token, claims} = Tokens.mint_access_token(config, grant())

      assert :ok = Tokens.track_access_token(config, claims, grant())
      refute Store.ETS.access_token_revoked?(claims["jti"], store)

      assert :ok = Store.ETS.revoke_access_token(claims["jti"], store)
      assert Store.ETS.access_token_revoked?(claims["jti"], store)
    end
  end
end
