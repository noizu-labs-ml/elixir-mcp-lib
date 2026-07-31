defmodule Noizu.MCP.Auth.ResourceTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.Auth.Resource

  doctest Noizu.MCP.Auth.Resource

  describe "normalize/1 — what it does change" do
    test "lowercases the scheme and host" do
      assert {:ok, "https://app.example.com/mcp"} =
               Resource.normalize("HTTPS://App.Example.COM/mcp")
    end

    test "drops the default port for the scheme" do
      assert {:ok, "https://app.example.com/mcp"} =
               Resource.normalize("https://app.example.com:443/mcp")

      assert {:ok, "http://app.example.com/mcp"} =
               Resource.normalize("http://app.example.com:80/mcp")
    end

    test "keeps a non-default port" do
      assert {:ok, "https://app.example.com:8443/mcp"} =
               Resource.normalize("https://app.example.com:8443/mcp")
    end
  end

  describe "normalize/1 — what it deliberately leaves alone" do
    test "does not case-fold the path" do
      assert {:ok, "https://x/MCP/Learning"} = Resource.normalize("https://x/MCP/Learning")
      refute Resource.equal?("https://x/mcp", "https://x/MCP")
    end

    test "does not coerce a trailing slash" do
      assert {:ok, "https://x/mcp/"} = Resource.normalize("https://x/mcp/")
      refute Resource.equal?("https://x/mcp", "https://x/mcp/")
    end

    test "does not add a path to an origin" do
      assert {:ok, "https://x"} = Resource.normalize("https://x")
      refute Resource.equal?("https://x", "https://x/")
    end

    test "keeps the query" do
      assert {:ok, "https://x/mcp?v=1"} = Resource.normalize("https://x/mcp?v=1")
    end
  end

  describe "normalize/1 rejections" do
    test "a fragment is refused — two spellings must not name one resource" do
      assert {:error, :invalid_resource} = Resource.normalize("https://x/mcp#frag")
    end

    test "userinfo is refused" do
      assert {:error, :invalid_resource} = Resource.normalize("https://u:p@x/mcp")
    end

    test "a non-http scheme is refused" do
      assert {:error, :invalid_resource} = Resource.normalize("urn:example:mcp")
      assert {:error, :invalid_resource} = Resource.normalize("file:///mcp")
    end

    test "a relative or empty reference is refused" do
      assert {:error, :invalid_resource} = Resource.normalize("/mcp")
      assert {:error, :invalid_resource} = Resource.normalize("")
      assert {:error, :invalid_resource} = Resource.normalize(nil)
      assert {:error, :invalid_resource} = Resource.normalize(:mcp)
    end

    test "normalize!/1 raises with the offending value for a boot-time failure" do
      assert Resource.normalize!("https://X/mcp") == "https://x/mcp"
      assert_raise ArgumentError, fn -> Resource.normalize!("/mcp") end
    end
  end

  describe "equal?/2 and matches?/2" do
    test "the headline pair: a parent mount is not its child" do
      refute Resource.equal?("https://x/mcp", "https://x/mcp/learning")
      refute Resource.equal?("https://x/mcp/learning", "https://x/mcp")
    end

    test "sibling mounts do not match" do
      refute Resource.equal?("https://x/mcp/learning", "https://x/mcp/workspace")
    end

    test "different hosts do not match, however similar" do
      refute Resource.equal?("https://x/mcp", "https://y/mcp")
      refute Resource.equal?("https://app.example.com/mcp", "https://app.example.com.evil/mcp")
    end

    test "an invalid resource never equals anything" do
      refute Resource.equal?("https://x/mcp", "/mcp")
      refute Resource.equal?(nil, nil)
    end

    test "matches?/2 accepts a list for a migration window without widening" do
      allowed = ["https://x/mcp", "https://legacy.x/mcp"]
      assert Resource.matches?("https://X:443/mcp", allowed)
      assert Resource.matches?("https://legacy.x/mcp", allowed)
      refute Resource.matches?("https://x/mcp/learning", allowed)
      refute Resource.matches?("https://x/mcp", [])
    end

    test "matches?/2 accepts a single resource" do
      assert Resource.matches?("https://x/mcp", "https://x/mcp")
      refute Resource.matches?("https://x/mcp", "https://x/mcp/learning")
    end
  end

  describe "build/2" do
    test "concatenates an issuer origin and a mount path" do
      assert {:ok, "https://app.example.com/mcp/learning"} =
               Resource.build("https://app.example.com", "/mcp/learning")
    end

    test "a nil or empty path yields the origin itself" do
      assert {:ok, "https://app.example.com"} = Resource.build("https://app.example.com", nil)
      assert {:ok, "https://app.example.com"} = Resource.build("https://app.example.com", "")
    end

    test "a relative path is refused rather than guessed at" do
      assert {:error, :invalid_resource} = Resource.build("https://app.example.com", "mcp")
    end

    test "an invalid issuer propagates" do
      assert {:error, :invalid_resource} = Resource.build("app.example.com", "/mcp")
    end
  end
end
