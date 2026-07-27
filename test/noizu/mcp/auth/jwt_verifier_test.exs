defmodule Noizu.MCP.Auth.JWTVerifierTest do
  @moduledoc """
  Audience binding is the headline: a token minted for one mount must be
  refused at its neighbour, in both directions.
  """
  use ExUnit.Case, async: true

  alias Noizu.MCP.Auth.JWTVerifier
  alias Noizu.MCP.Fixtures.OAuth

  @parent "https://app.example.com/mcp"
  @child "https://app.example.com/mcp/learning"

  defp verify(token, opts \\ []),
    do: JWTVerifier.verify(token, OAuth.conn_info(), OAuth.jwt_opts(opts))

  describe "audience binding" do
    test "a token for the parent mount is REJECTED at the child mount" do
      token = OAuth.token(%{"aud" => @parent})
      assert {:ok, _} = verify(token, resource: @parent)
      assert {:error, :invalid_token} = verify(token, resource: @child)
    end

    test "a token for the child mount is REJECTED at the parent mount" do
      token = OAuth.token(%{"aud" => @child})
      assert {:ok, _} = verify(token, resource: @child)
      assert {:error, :invalid_token} = verify(token, resource: @parent)
    end

    test "a sibling mount's token is rejected" do
      token = OAuth.token(%{"aud" => "https://app.example.com/mcp/workspace"})
      assert {:error, :invalid_token} = verify(token, resource: @child)
    end

    test "audience comparison is byte-exact past normalization" do
      # Scheme/host case and the default port normalize; nothing else does.
      assert {:ok, _} = verify(OAuth.token(%{"aud" => "https://APP.example.com:443/mcp"}))
      assert {:error, :invalid_token} = verify(OAuth.token(%{"aud" => @parent <> "/"}))

      assert {:error, :invalid_token} =
               verify(OAuth.token(%{"aud" => "https://app.example.com/MCP"}))
    end

    test "a single-element aud array is accepted" do
      assert {:ok, _} = verify(OAuth.token(%{"aud" => [@parent]}))
    end

    test "a multi-audience token is rejected even when this resource is in it" do
      # Valid at two resources is exactly the property audience binding removes.
      assert {:error, :invalid_token} = verify(OAuth.token(%{"aud" => [@parent, @child]}))

      assert {:error, :invalid_token} =
               verify(OAuth.token(%{"aud" => [@parent, "https://other/mcp"]}))
    end

    test "a token with no aud is rejected" do
      assert {:error, :invalid_token} = verify(OAuth.token(%{"aud" => nil}))
    end

    test "a mount configured with an unusable resource fails closed" do
      assert {:error, :invalid_token} = verify(OAuth.token(), resource: "not-a-uri")
      assert {:error, :invalid_token} = JWTVerifier.verify(OAuth.token(), OAuth.conn_info(), [])
    end
  end

  describe "signature and algorithm" do
    test "a valid HS256 token verifies and returns its claims" do
      assert {:ok, claims} = verify(OAuth.token())
      assert claims["sub"] == "user-1"
      assert claims["scope"] == "mcp"
    end

    test "a token signed with a different secret is rejected" do
      token = OAuth.token(%{}, jwk: JOSE.JWK.from_oct("some-other-secret-entirely-here"))
      assert {:error, :invalid_token} = verify(token)
    end

    test "alg: none is rejected" do
      claims = %{
        "iss" => "https://app.example.com",
        "sub" => "user-1",
        "aud" => @parent,
        "exp" => System.system_time(:second) + 900
      }

      unsecured =
        [Jason.encode!(%{"alg" => "none", "typ" => "JWT"}), Jason.encode!(claims)]
        |> Enum.map_join(".", &Base.url_encode64(&1, padding: false))
        |> Kernel.<>(".")

      assert {:error, :invalid_token} = verify(unsecured)
    end

    test "an RS256 token is rejected by an HS256-only mount" do
      # The allowlist comes from config, never from the token header, so the
      # classic HS/RS confusion has nowhere to land.
      token = OAuth.token(%{}, jwk: OAuth.rsa_jwk(), alg: "RS256")
      assert {:error, :invalid_token} = verify(token)
    end

    test "an RS256 token verifies when the mount is configured for it" do
      jwk = OAuth.rsa_jwk()
      token = OAuth.token(%{}, jwk: jwk, alg: "RS256")
      public = JOSE.JWK.to_public(jwk)

      assert {:ok, _} =
               JWTVerifier.verify(
                 token,
                 OAuth.conn_info(),
                 resource: @parent,
                 issuer: "https://app.example.com",
                 jwk: public,
                 algorithms: ["RS256"]
               )
    end

    test "garbage is rejected without raising" do
      for token <- ["", "not.a.jwt", "a.b.c.d.e", "Bearer x", String.duplicate("x", 5_000)] do
        assert {:error, :invalid_token} = verify(token)
      end

      assert {:error, :invalid_token} = verify(nil)
    end
  end

  describe "claims" do
    test "an expired token is rejected" do
      assert {:error, :invalid_token} =
               verify(OAuth.token(%{"exp" => System.system_time(:second) - 1}))
    end

    test "a token with no exp is rejected" do
      assert {:error, :invalid_token} = verify(OAuth.token(%{"exp" => nil}))
    end

    test "leeway forgives a small clock skew" do
      token = OAuth.token(%{"exp" => System.system_time(:second) - 5})
      assert {:error, :invalid_token} = verify(token)
      assert {:ok, _} = verify(token, leeway: 30)
    end

    test "a not-yet-valid token is rejected" do
      assert {:error, :invalid_token} =
               verify(OAuth.token(%{"nbf" => System.system_time(:second) + 300}))
    end

    test "a wrong or missing issuer is rejected when one is configured" do
      assert {:error, :invalid_token} = verify(OAuth.token(%{"iss" => "https://evil.example"}))
      assert {:error, :invalid_token} = verify(OAuth.token(%{"iss" => nil}))
      assert {:ok, _} = verify(OAuth.token(%{"iss" => "https://evil.example"}), issuer: nil)
    end

    test "a subject-less token is rejected by default" do
      assert {:error, :invalid_token} = verify(OAuth.token(%{"sub" => nil}))
      assert {:error, :invalid_token} = verify(OAuth.token(%{"sub" => ""}))
      assert {:ok, _} = verify(OAuth.token(%{"sub" => nil}), subject_required: false)
    end
  end

  describe "scopes" do
    test "a missing scope is a 403 step-up, not a 401" do
      assert {:error, :insufficient_scope, %{"scope" => "mcp:admin"}} =
               verify(OAuth.token(), scopes: ["mcp:admin"])
    end

    test "all required scopes must be present" do
      token = OAuth.token(%{"scope" => "mcp mcp:read"})
      assert {:ok, _} = verify(token, scopes: ["mcp", "mcp:read"])
      assert {:error, :insufficient_scope, _} = verify(token, scopes: ["mcp", "mcp:write"])
    end

    test "an invalid token loses to the scope check" do
      # Order matters: an expired token must not be told which scope to ask for.
      assert {:error, :invalid_token} =
               verify(OAuth.token(%{"exp" => System.system_time(:second) - 1}),
                 scopes: ["mcp:admin"]
               )
    end

    test "scopes/1 reads every spelling of the claim" do
      assert JWTVerifier.scopes(%{"scope" => "a b"}) == ["a", "b"]
      assert JWTVerifier.scopes(%{"scopes" => ["a", "b"]}) == ["a", "b"]
      assert JWTVerifier.scopes(%{"scp" => ["a"]}) == ["a"]
      assert JWTVerifier.scopes(%{"scp" => "a b"}) == ["a", "b"]
      assert JWTVerifier.scopes(%{}) == []
    end
  end

  describe "secret resolution" do
    def runtime_secret, do: OAuth.secret()

    test "a {module, function} secret is resolved per request" do
      assert {:ok, _} = verify(OAuth.token(), secret: {__MODULE__, :runtime_secret})
    end

    test "a 0-arity fun secret is resolved per request" do
      assert {:ok, _} = verify(OAuth.token(), secret: &__MODULE__.runtime_secret/0)
    end

    test "a missing or empty secret fails closed" do
      assert {:error, :invalid_token} = verify(OAuth.token(), secret: nil)
      assert {:error, :invalid_token} = verify(OAuth.token(), secret: "")
    end
  end
end
