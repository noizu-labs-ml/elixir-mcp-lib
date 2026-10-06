defmodule Noizu.MCP.Auth.BasicVerifierTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.Auth.BasicVerifier
  alias Noizu.MCP.Auth.ChainVerifier
  alias Noizu.MCP.Auth.JWTVerifier
  alias Noizu.MCP.Auth.Server.Secret
  alias Noizu.MCP.Fixtures.OAuth

  @resource "https://app.example.com/mcp"

  @users %{
    "alice" => Secret.token_hash("wonderland"),
    "bob" => Secret.token_hash("builder")
  }

  defp opts(overrides \\ []),
    do: Keyword.merge([resource: @resource, users: @users], overrides)

  defp basic(user, pass), do: "Basic " <> Base.encode64("#{user}:#{pass}")

  defp verify(header, overrides \\ []),
    do: BasicVerifier.verify(header, OAuth.conn_info(), opts(overrides))

  describe "static :users" do
    test "a known user with the right password yields claims" do
      assert {:ok, claims} = verify(basic("alice", "wonderland"))
      assert claims["sub"] == "alice"
      assert claims["aud"] == @resource
    end

    test "a wrong password is invalid_token" do
      assert {:error, :invalid_token} = verify(basic("alice", "builder"))
    end

    test "an unknown user is indistinguishable from a wrong password" do
      assert {:error, :invalid_token} = verify(basic("eve", "wonderland"))
      assert {:error, :invalid_token} = verify(basic("eve", "anything"))
    end

    test "usernames are case-sensitive" do
      assert {:error, :invalid_token} = verify(basic("Alice", "wonderland"))
    end

    test "a user with an empty password matches only an empty stored hash" do
      assert {:error, :invalid_token} = verify(basic("alice", ""))
    end
  end

  describe "validator" do
    test "a validator's scopes and claims land in the result" do
      validator = fn "alice", "wonderland" ->
        {:ok, %{scopes: ["mcp", "mcp:admin"], claims: %{"email" => "alice@example.com"}}}
      end

      assert {:ok, claims} = verify(basic("alice", "wonderland"), users: nil, validator: validator)
      assert claims["sub"] == "alice"
      assert claims["scope"] == "mcp mcp:admin"
      assert claims["email"] == "alice@example.com"
    end

    test "an mfa validator receives username and password" do
      validator = {__MODULE__.Validator, :check}

      assert {:ok, %{"sub" => "svc"}} =
               verify(basic("svc", "tok"), users: nil, validator: validator)
    end

    test "a validator rejection is invalid_token, not an error tuple leak" do
      validator = fn _u, _p -> {:error, :rate_limited} end
      assert {:error, :invalid_token} = verify(basic("alice", "x"), users: nil, validator: validator)
    end

    test "a validator that raises lets the raise propagate" do
      # Trapping misbehaving links is ChainVerifier's job, not each link's.
      assert_raise RuntimeError, fn ->
        verify(basic("a", "b"), users: nil, validator: fn _, _ -> raise "boom" end)
      end
    end

    test "the validator wins over :users when both are set" do
      validator = fn "alice", "wonderland" -> {:ok, %{scopes: ["v"], claims: %{}}} end

      assert {:ok, %{"scope" => "v"}} =
               verify(basic("alice", "wonderland"), validator: validator)
    end

    test "no validator and no users fails closed" do
      assert {:error, :invalid_token} =
               BasicVerifier.verify(basic("alice", "wonderland"), OAuth.conn_info(), resource: @resource)
    end
  end

  describe "parsing (RFC 7617)" do
    test "the lowercase scheme is accepted" do
      assert {:ok, _} = verify("basic " <> Base.encode64("alice:wonderland"))
    end

    test "a bare base64 payload (scheme already stripped) is accepted" do
      assert {:ok, _} = verify(Base.encode64("alice:wonderland"))
    end

    test "a password containing a colon survives" do
      # Static :users cannot match a coloned password here; the point is that
      # the split happens at the FIRST colon and the rest stays the password.
      validator = fn "alice", "pass:word:extra" -> {:ok, %{scopes: [], claims: %{}}} end

      assert {:ok, %{"sub" => "alice"}} =
               verify(basic("alice", "pass:word:extra"), users: nil, validator: validator)
    end

    test "malformed inputs are invalid_token" do
      for header <- [
            "Bearer not-basic",
            "Basic",
            "Basic ",
            "Basic !!!not-base64!!!",
            "Basic " <> Base.encode64("no-colon"),
            "Basic " <> Base.encode64(":password"),
            ""
          ] do
        assert {:error, :invalid_token} = verify(header)
      end
    end

    test "a non-binary token is invalid_token" do
      assert {:error, :invalid_token} = BasicVerifier.verify(nil, OAuth.conn_info(), opts())
      assert {:error, :invalid_token} = verify(:basic)
    end
  end

  describe "claims shaping" do
    test "aud is stamped from the mount's configured resource" do
      assert {:ok, %{"aud" => @resource}} = verify(basic("alice", "wonderland"))
    end

    test "the resource is normalized when stamped" do
      assert {:ok, %{"aud" => @resource}} =
               verify(basic("alice", "wonderland"), resource: "HTTPS://App.Example.com:443/mcp")
    end

    test "default_claims fill in behind the credential source" do
      assert {:ok, claims} =
               verify(basic("alice", "wonderland"),
                 default_claims: %{"scope" => "mcp", "iss" => "https://app.example.com"}
               )

      assert claims["iss"] == "https://app.example.com"
      refute Map.has_key?(claims, "scope")
    end

    test ":scopes grants a default when the source names none" do
      assert {:ok, %{"scope" => "mcp"}} = verify(basic("alice", "wonderland"), scopes: ["mcp"])
    end

    test "a validator's scopes win over the :scopes default" do
      validator = fn _u, _p -> {:ok, %{scopes: ["theirs"], claims: %{}}} end

      assert {:ok, %{"scope" => "theirs"}} =
               verify(basic("a", "b"), users: nil, validator: validator, scopes: ["mine"])
    end

    test "claims that already carry a scope are not clobbered" do
      validator = fn _u, _p -> {:ok, %{scopes: [], claims: %{"scope" => "held"}}} end

      assert {:ok, %{"scope" => "held"}} =
               verify(basic("a", "b"), users: nil, validator: validator, scopes: ["mcp"])
    end
  end

  describe "challenge" do
    test "the default realm" do
      assert BasicVerifier.challenge() == ~s(Basic realm="mcp")
    end

    test "a custom realm" do
      assert BasicVerifier.challenge(realm: "ops") == ~s(Basic realm="ops")
    end
  end

  describe "chain composition" do
    defp chain do
      [
        {JWTVerifier, OAuth.jwt_opts()},
        {BasicVerifier, resource: @resource, users: @users}
      ]
    end

    test "a Basic credential falls through the JWT link to the Basic one" do
      assert {:ok, claims} = ChainVerifier.verify(basic("alice", "wonderland"), OAuth.conn_info(), chain())
      assert claims["sub"] == "alice"
    end

    test "a JWT is answered by the first link, never by Basic" do
      assert {:ok, claims} = ChainVerifier.verify(OAuth.token(), OAuth.conn_info(), chain())
      assert claims["sub"] == "user-1"

      assert {:error, :invalid_token} =
               BasicVerifier.verify(OAuth.token(), OAuth.conn_info(), opts())
    end

    test "nothing matches when neither link accepts" do
      assert {:error, :invalid_token} =
               ChainVerifier.verify("Basic " <> Base.encode64("eve:x"), OAuth.conn_info(), chain())
    end
  end
end

defmodule Noizu.MCP.Auth.BasicVerifierTest.Validator do
  @moduledoc false
  def check("svc", "tok"), do: {:ok, %{scopes: [], claims: %{"sub" => "svc"}}}
  def check(_u, _p), do: :error
end
