defmodule Noizu.MCP.Auth.ApiKeyVerifierTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.Auth.ApiKeyVerifier
  alias Noizu.MCP.Fixtures.OAuth

  @resource "https://app.example.com/mcp"

  defp opts(overrides) do
    Keyword.merge(
      [resource: @resource, validator: {OAuth, :validate_api_key}],
      overrides
    )
  end

  defp verify(key, overrides \\ []),
    do: ApiKeyVerifier.verify(key, OAuth.conn_info(), opts(overrides))

  describe "validator" do
    test "a known key yields the host's claims" do
      assert {:ok, claims} = verify(OAuth.api_key())
      assert claims["sub"] == "service-account-1"
      assert claims["api_key_id"] == "key-1"
    end

    test "an unknown key is invalid_token" do
      assert {:error, :invalid_token} = verify("mcp_live_wrong")
      assert {:error, :invalid_token} = verify("")
      assert {:error, :invalid_token} = verify(nil)
    end

    test "a revoked key is indistinguishable from an unknown one" do
      assert {:error, :invalid_token} =
               verify(OAuth.api_key(), validator: {OAuth, :validate_api_key_revoked})
    end

    test "a bare claims map is accepted as success" do
      assert {:ok, %{"sub" => "svc"}} = verify("any", validator: fn _ -> %{"sub" => "svc"} end)
    end

    test "no validator and no keys fails closed" do
      assert {:error, :invalid_token} =
               ApiKeyVerifier.verify(OAuth.api_key(), OAuth.conn_info(), resource: @resource)
    end
  end

  describe "prefix" do
    test "a matching prefix passes through" do
      assert {:ok, _} = verify(OAuth.api_key(), prefix: "mcp_live_")
    end

    test "a non-matching prefix is rejected before the validator runs" do
      # Also proves the validator is not consulted: it would raise.
      assert {:error, :invalid_token} =
               verify("eyJhbGciOiJIUzI1NiJ9.x.y",
                 prefix: "mcp_live_",
                 validator: {OAuth, :raise_validator}
               )
    end
  end

  describe "resource stamping" do
    test "aud is stamped from the mount's configured resource" do
      assert {:ok, %{"aud" => "https://app.example.com/mcp"}} = verify(OAuth.api_key())
    end

    test "the resource is normalized when stamped" do
      assert {:ok, %{"aud" => "https://app.example.com/mcp"}} =
               verify(OAuth.api_key(), resource: "HTTPS://App.Example.com:443/mcp")
    end

    test "a validator that set its own aud wins" do
      assert {:ok, %{"aud" => "https://elsewhere/mcp"}} =
               verify("k", validator: fn _ -> {:ok, %{"aud" => "https://elsewhere/mcp"}} end)
    end

    test "default_claims fill in behind the validator" do
      assert {:ok, claims} =
               verify("k",
                 validator: fn _ -> {:ok, %{"sub" => "svc"}} end,
                 default_claims: %{"scope" => "mcp", "sub" => "ignored"}
               )

      assert claims["scope"] == "mcp"
      assert claims["sub"] == "svc"
    end

    test "an unusable configured resource does not stamp a bad audience" do
      assert {:ok, claims} = verify(OAuth.api_key(), resource: "not-a-uri")
      refute Map.has_key?(claims, "aud")
    end
  end

  describe "static :keys list" do
    @keys [{"key-one", %{"sub" => "one"}}, {"key-two", %{"sub" => "two"}}]

    test "matches any entry" do
      assert {:ok, %{"sub" => "one"}} =
               ApiKeyVerifier.verify("key-one", OAuth.conn_info(), keys: @keys)

      assert {:ok, %{"sub" => "two"}} =
               ApiKeyVerifier.verify("key-two", OAuth.conn_info(), keys: @keys)
    end

    test "rejects a near-miss and a prefix" do
      for candidate <- ["key-thre", "key-on", "key-onex", "", "KEY-ONE"] do
        assert {:error, :invalid_token} =
                 ApiKeyVerifier.verify(candidate, OAuth.conn_info(), keys: @keys)
      end
    end
  end

  describe "scopes" do
    test "a key without the required scope gets a step-up, not a rejection" do
      assert {:error, :insufficient_scope, %{"scope" => "mcp:admin"}} =
               verify(OAuth.api_key(), scopes: ["mcp:admin"])
    end

    test "a key with the scope passes" do
      assert {:ok, _} = verify(OAuth.api_key(), scopes: ["mcp"])
    end
  end
end
