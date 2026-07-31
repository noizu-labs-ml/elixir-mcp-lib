defmodule Noizu.MCP.Auth.ChainVerifierTest do
  @moduledoc """
  One mount, two credential kinds: an OAuth access token for an interactive
  agent, an API key for a headless one.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Noizu.MCP.Auth.ApiKeyVerifier
  alias Noizu.MCP.Auth.ChainVerifier
  alias Noizu.MCP.Auth.JWTVerifier
  alias Noizu.MCP.Fixtures.OAuth

  @resource "https://app.example.com/mcp"

  @jwt {JWTVerifier,
        [resource: @resource, issuer: "https://app.example.com", secret: OAuth.secret()]}
  @api_key {ApiKeyVerifier, [resource: @resource, validator: {OAuth, :validate_api_key}]}

  defp verify(token, verifiers \\ [@jwt, @api_key]),
    do: ChainVerifier.verify(token, OAuth.conn_info(), verifiers: verifiers)

  describe "first success wins" do
    test "an OAuth token verifies through the first link" do
      assert {:ok, %{"sub" => "user-1"}} = verify(OAuth.token())
    end

    test "an API key verifies through the second link" do
      assert {:ok, %{"sub" => "service-account-1"}} = verify(OAuth.api_key())
    end

    test "order does not change the outcome, only the cost" do
      assert {:ok, %{"sub" => "user-1"}} = verify(OAuth.token(), [@api_key, @jwt])
      assert {:ok, %{"sub" => "service-account-1"}} = verify(OAuth.api_key(), [@api_key, @jwt])
    end

    test "a bare list of verifiers is accepted" do
      assert {:ok, _} = ChainVerifier.verify(OAuth.token(), OAuth.conn_info(), [@jwt, @api_key])
    end

    test "a bare module with no opts is accepted" do
      assert {:error, :invalid_token} =
               ChainVerifier.verify("x", OAuth.conn_info(), verifiers: [JWTVerifier])
    end
  end

  describe "uniform failure" do
    test "every rejection is the same answer" do
      for token <- ["", "garbage", "mcp_live_wrong", OAuth.token(%{"aud" => "https://other/mcp"})] do
        assert {:error, :invalid_token} = verify(token)
      end
    end

    test "an empty chain rejects rather than failing open" do
      assert {:error, :invalid_token} = verify(OAuth.token(), [])
      assert {:error, :invalid_token} = ChainVerifier.verify(OAuth.token(), OAuth.conn_info(), [])

      assert {:error, :invalid_token} =
               ChainVerifier.verify(OAuth.token(), OAuth.conn_info(), nil)
    end

    test "a token valid for a sibling mount is rejected by the whole chain" do
      sibling = OAuth.token(%{"aud" => "https://app.example.com/mcp/learning"})
      assert {:error, :invalid_token} = verify(sibling)
    end
  end

  describe "insufficient_scope propagation" do
    test "the first step-up report survives, so the client learns what to ask for" do
      scoped = {JWTVerifier, Keyword.put(elem(@jwt, 1), :scopes, ["mcp:admin"])}

      assert {:error, :insufficient_scope, %{"scope" => "mcp:admin"}} =
               verify(OAuth.token(), [scoped, @api_key])
    end

    test "a later success still beats an earlier step-up" do
      scoped = {JWTVerifier, Keyword.put(elem(@jwt, 1), :scopes, ["mcp:admin"])}
      # The API key link recognizes this credential outright.
      assert {:ok, %{"sub" => "service-account-1"}} = verify(OAuth.api_key(), [scoped, @api_key])
    end

    test "the first step-up wins over a later one" do
      first = {JWTVerifier, Keyword.put(elem(@jwt, 1), :scopes, ["scope:one"])}
      second = {JWTVerifier, Keyword.put(elem(@jwt, 1), :scopes, ["scope:two"])}

      assert {:error, :insufficient_scope, %{"scope" => "scope:one"}} =
               verify(OAuth.token(), [first, second])
    end
  end

  describe "a raising verifier" do
    test "is treated as a rejection, not a 500, and does not stop the chain" do
      raising = {ApiKeyVerifier, [validator: {OAuth, :raise_validator}]}

      log =
        capture_log(fn ->
          assert {:ok, %{"sub" => "user-1"}} = verify(OAuth.token(), [raising, @jwt])
        end)

      assert log =~ "ChainVerifier"
    end

    test "does not leak the presented token into the log" do
      raising = {ApiKeyVerifier, [validator: {OAuth, :raise_validator}]}

      log = capture_log(fn -> verify("super-secret-key-value", [raising]) end)

      refute log =~ "super-secret-key-value"
    end
  end
end
