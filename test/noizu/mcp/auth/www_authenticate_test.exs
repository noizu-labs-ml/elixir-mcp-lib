defmodule Noizu.MCP.Auth.WWWAuthenticateTest do
  @moduledoc """
  Header-injection safety for the 401 challenge. The values interpolated here
  are the most attacker-adjacent strings in the transport: a derived
  `resource_metadata` URL can carry whatever the Host header said.
  """
  use ExUnit.Case, async: true

  alias Noizu.MCP.Auth.WWWAuthenticate

  doctest Noizu.MCP.Auth.WWWAuthenticate

  describe "escape_quoted/1" do
    test "escapes backslash and double quote" do
      assert WWWAuthenticate.escape_quoted(~s(plain)) == "plain"
      assert WWWAuthenticate.escape_quoted(~s(say "hi")) == ~S(say \"hi\")
      assert WWWAuthenticate.escape_quoted(~S(a\b)) == ~S(a\\b)
      # Escape the backslash first, or `\"` becomes `\\"` and the quote escapes.
      assert WWWAuthenticate.escape_quoted(~S(a\"b)) == ~S(a\\\"b)
    end

    test "accepts tab, space and high-bit bytes" do
      assert WWWAuthenticate.escape_quoted("a\tb c") == "a\tb c"
      assert WWWAuthenticate.escape_quoted("café") == "café"
    end

    for {name, value} <- [
          {"CR", "a\rb"},
          {"LF", "a\nb"},
          {"CRLF", "a\r\nb"},
          {"NUL", "a\0b"},
          {"DEL", "a\x7Fb"},
          {"vertical tab", "a\vb"},
          {"bare CR at end", "a\r"}
        ] do
      test "rejects #{name}" do
        assert_raise ArgumentError, fn ->
          WWWAuthenticate.escape_quoted(unquote(value))
        end
      end
    end

    test "the raised message does not echo the offending value" do
      error =
        assert_raise ArgumentError, fn ->
          WWWAuthenticate.escape_quoted("https://evil\r\nX-Injected: 1")
        end

      refute error.message =~ "X-Injected"
    end

    test "accepts atoms and numbers" do
      assert WWWAuthenticate.escape_quoted(:invalid_token) == "invalid_token"
      assert WWWAuthenticate.escape_quoted(42) == "42"
    end
  end

  describe "format/2" do
    test "escapes values it interpolates" do
      header = WWWAuthenticate.format([{"error_description", ~s(the "quoted" bit)}])
      assert header == ~S(Bearer error_description="the \"quoted\" bit")

      # Round-trips: the parser sees one parameter, not two.
      assert map_size(WWWAuthenticate.parse(header).params) == 1
    end

    test "a CRLF value raises rather than splitting the header" do
      assert_raise ArgumentError, fn ->
        WWWAuthenticate.format([
          {"resource_metadata", "https://x/\r\nSet-Cookie: session=stolen"}
        ])
      end
    end

    test "rejects a parameter name that is not an HTTP token" do
      assert_raise ArgumentError, fn ->
        WWWAuthenticate.format([{~s(bad name), "value"}])
      end

      assert_raise ArgumentError, fn ->
        WWWAuthenticate.format([{"error\r\nX-Injected: 1", "value"}])
      end
    end

    test "bare scheme when there are no params" do
      assert WWWAuthenticate.format([]) == "Bearer"
      assert WWWAuthenticate.format("DPoP", %{}) == "DPoP"
    end
  end

  describe "bearer_challenge/1" do
    test "drops nil values and preserves order" do
      assert WWWAuthenticate.bearer_challenge(
               resource_metadata: "https://x/.well-known/oauth-protected-resource",
               scope: nil,
               error: nil
             ) == ~s(Bearer resource_metadata="https://x/.well-known/oauth-protected-resource")
    end

    test "an all-nil challenge is still a valid challenge" do
      assert WWWAuthenticate.bearer_challenge(resource_metadata: nil, error: nil) == "Bearer"
    end

    test "round-trips through parse" do
      parsed =
        WWWAuthenticate.bearer_challenge(
          resource_metadata: "https://x/.well-known/oauth-protected-resource/mcp",
          scope: "mcp:write",
          error: "insufficient_scope"
        )
        |> WWWAuthenticate.parse()

      assert parsed.params["scope"] == "mcp:write"
      assert parsed.params["error"] == "insufficient_scope"
      assert parsed.params["resource_metadata"] =~ "/mcp"
    end
  end
end
