defmodule Noizu.MCP.Auth.Server.RedirectURITest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.Auth.Server.RedirectURI

  doctest Noizu.MCP.Auth.Server.RedirectURI

  describe "loopback port-agnosticism" do
    @registered [
      "http://localhost/callback",
      "http://127.0.0.1/callback"
    ]

    test "matches an ephemeral port on either loopback spelling" do
      # Claude Code binds whatever port the OS hands it, so the registered
      # port can never be the one that comes back.
      assert RedirectURI.matches?("http://127.0.0.1:53821/callback", @registered)
      assert RedirectURI.matches?("http://localhost:8912/callback", @registered)
      assert RedirectURI.matches?("http://127.0.0.1/callback", @registered)
    end

    test "matches when the registration carries a port and the request does not" do
      assert RedirectURI.matches?("http://127.0.0.1/callback", ["http://127.0.0.1:1410/callback"])
      assert RedirectURI.matches?("http://127.0.0.1:9999/callback", ["http://127.0.0.1:1410/callback"])
    end

    test "only the port is loose — path still has to match" do
      refute RedirectURI.matches?("http://127.0.0.1:53821/other", @registered)
      refute RedirectURI.matches?("http://127.0.0.1:53821/callback/sub", @registered)
      refute RedirectURI.matches?("http://127.0.0.1:53821/CALLBACK", @registered)
    end

    test "only the port is loose — scheme, host and query still have to match" do
      refute RedirectURI.matches?("https://127.0.0.1:53821/callback", @registered)
      refute RedirectURI.matches?("http://127.0.0.2:53821/callback", @registered)
      refute RedirectURI.matches?("http://127.0.0.1:53821/callback?next=/admin", @registered)
    end

    test "localhost and 127.0.0.1 are not interchangeable" do
      refute RedirectURI.matches?("http://localhost:1/callback", ["http://127.0.0.1/callback"])
      refute RedirectURI.matches?("http://127.0.0.1:1/callback", ["http://localhost/callback"])
    end

    test "an empty path and / compare equal for loopback" do
      assert RedirectURI.matches?("http://127.0.0.1:5000", ["http://127.0.0.1/"])
      assert RedirectURI.matches?("http://127.0.0.1:5000/", ["http://127.0.0.1"])
    end

    test "loopback?/1" do
      assert RedirectURI.loopback?("http://127.0.0.1:1/cb")
      assert RedirectURI.loopback?("http://localhost/cb")
      assert RedirectURI.loopback?("http://[::1]:9/cb")
      refute RedirectURI.loopback?("https://claude.ai/cb")
      refute RedirectURI.loopback?(nil)
    end
  end

  describe "exact matching for everything else" do
    @registered ["https://claude.ai/api/mcp/auth_callback"]

    test "exact match passes" do
      assert RedirectURI.matches?("https://claude.ai/api/mcp/auth_callback", @registered)
    end

    test "a non-loopback port is not loose" do
      refute RedirectURI.matches?("https://claude.ai:8443/api/mcp/auth_callback", @registered)
    end

    test "trailing slash is a different URI" do
      refute RedirectURI.matches?("https://claude.ai/api/mcp/auth_callback/", @registered)
    end

    test "appended query or path is a different URI" do
      refute RedirectURI.matches?("https://claude.ai/api/mcp/auth_callback?x=1", @registered)
      refute RedirectURI.matches?("https://claude.ai/api/mcp/auth_callback/../evil", @registered)
    end

    test "a string registration is accepted as a single-entry list" do
      assert RedirectURI.matches?("https://claude.ai/cb", "https://claude.ai/cb")
    end

    test "non-binary input never matches" do
      refute RedirectURI.matches?(nil, @registered)
      refute RedirectURI.matches?(["https://claude.ai/cb"], @registered)
    end
  end

  describe "host_allowed?/2 — suffix attacks" do
    @allowed ["claude.ai", "openai.com"]

    test "rejects a host that merely ends with the allowed host" do
      refute RedirectURI.host_allowed?("evil-claude.ai", @allowed)
      refute RedirectURI.host_allowed?("notclaude.ai", @allowed)
      refute RedirectURI.host_allowed?("xclaude.ai", @allowed)
      refute RedirectURI.host_allowed?("evilopenai.com", @allowed)
    end

    test "accepts the host itself and label-boundary subdomains" do
      assert RedirectURI.host_allowed?("claude.ai", @allowed)
      assert RedirectURI.host_allowed?("api.claude.ai", @allowed)
      assert RedirectURI.host_allowed?("a.b.claude.ai", @allowed)
    end

    test "rejects a host that only contains the allowed host" do
      refute RedirectURI.host_allowed?("claude.ai.evil.example", @allowed)
      refute RedirectURI.host_allowed?("claude.ai.co", @allowed)
    end

    test "is case-insensitive and tolerates a wildcard-style entry" do
      assert RedirectURI.host_allowed?("API.Claude.AI", @allowed)
      assert RedirectURI.host_allowed?("api.claude.ai", ["*.claude.ai"])
      refute RedirectURI.host_allowed?("evil-claude.ai", ["*.claude.ai"])
    end

    test "an empty allowlist allows nothing" do
      refute RedirectURI.host_allowed?("claude.ai", [])
      refute RedirectURI.host_allowed?(nil, @allowed)
    end
  end

  describe "validate/2" do
    test "https passes" do
      assert {:ok, _} = RedirectURI.validate("https://claude.ai/cb")
    end

    test "http passes only for loopback" do
      assert {:ok, _} = RedirectURI.validate("http://127.0.0.1:1410/cb")
      assert {:ok, _} = RedirectURI.validate("http://localhost/cb")
      assert {:error, :insecure_scheme} = RedirectURI.validate("http://claude.ai/cb")
    end

    test "a fragment is refused" do
      assert {:error, :fragment_not_allowed} = RedirectURI.validate("https://claude.ai/cb#x")
      # Even an empty fragment: RFC 6749 §3.1.2 forbids one outright.
      assert {:error, :fragment_not_allowed} = RedirectURI.validate("https://claude.ai/cb#")
    end

    test "userinfo is refused" do
      assert {:error, :userinfo_not_allowed} =
               RedirectURI.validate("https://claude.ai@evil.example/cb")
    end

    test "wildcards are refused" do
      assert {:error, :invalid_redirect_uri} = RedirectURI.validate("https://*.claude.ai/cb")
    end

    test "a relative or empty URI is refused" do
      assert {:error, :invalid_redirect_uri} = RedirectURI.validate("/cb")
      assert {:error, :invalid_redirect_uri} = RedirectURI.validate("")
      assert {:error, :invalid_redirect_uri} = RedirectURI.validate(nil)
    end

    test "a non-http scheme is refused unless custom schemes are enabled" do
      assert {:error, :invalid_redirect_uri} = RedirectURI.validate("com.example.app:/cb")
      assert {:ok, _} = RedirectURI.validate("com.example.app:/cb", allow_custom_scheme: true)
      # No dot means no reverse-DNS ownership claim (RFC 8252 §7.1).
      assert {:error, :invalid_redirect_uri} =
               RedirectURI.validate("myapp:/cb", allow_custom_scheme: true)
    end

    test "allowed_hosts constrains a dynamic registration but exempts loopback" do
      opts = [allowed_hosts: ["claude.ai"]]
      assert {:ok, _} = RedirectURI.validate("https://claude.ai/cb", opts)
      assert {:ok, _} = RedirectURI.validate("https://api.claude.ai/cb", opts)
      assert {:error, :host_not_allowed} = RedirectURI.validate("https://evil-claude.ai/cb", opts)
      assert {:ok, _} = RedirectURI.validate("http://127.0.0.1:1/cb", opts)
    end

    test "valid?/2 mirrors validate/2" do
      assert RedirectURI.valid?("https://claude.ai/cb")
      refute RedirectURI.valid?("http://claude.ai/cb")
    end
  end

  describe "resolve/2" do
    test "an omitted redirect_uri resolves only when the client registered exactly one" do
      assert {:ok, "https://claude.ai/cb"} = RedirectURI.resolve(nil, ["https://claude.ai/cb"])

      assert {:error, :invalid_redirect_uri} =
               RedirectURI.resolve(nil, ["https://claude.ai/cb", "http://127.0.0.1/cb"])

      assert {:error, :invalid_redirect_uri} = RedirectURI.resolve(nil, [])
    end

    test "resolves to the request's own URI when it matches" do
      assert {:ok, "http://127.0.0.1:5555/cb"} =
               RedirectURI.resolve("http://127.0.0.1:5555/cb", ["http://127.0.0.1/cb"])
    end

    test "an unmatched URI is an error, never a redirect target" do
      assert {:error, :invalid_redirect_uri} =
               RedirectURI.resolve("https://evil.example/cb", ["https://claude.ai/cb"])
    end
  end
end
