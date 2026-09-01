defmodule Noizu.MCP.Auth.PrincipalTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.Auth.Principal

  defp principal(scopes) do
    %Principal{
      subject: "user-1",
      authenticator: :api_key,
      token_id: "tok-77",
      granted_scopes: MapSet.new(scopes)
    }
  end

  describe "struct defaults (FR-2.1)" do
    test "subject and authenticator are enforced" do
      # Elixir 1.20's struct!/2 raises ArgumentError for missing enforced keys.
      assert_raise ArgumentError, fn -> struct!(Principal, %{}) end
    end

    test "claims/granted_scopes/metadata default empty" do
      p = %Principal{subject: "user-1", authenticator: :api_key}
      assert p.claims == %{}
      assert p.granted_scopes == MapSet.new()
      assert p.metadata == %{}
      assert p.token_id == nil
    end
  end

  describe "anonymous?/1" do
    test "nil is anonymous — the only anonymous identity" do
      assert Principal.anonymous?(nil)
      refute Principal.anonymous?(principal([]))
    end
  end

  describe "has_scope?/2 glob matrix" do
    test "exact match" do
      p = principal(["mcp", "pm:read"])
      assert Principal.has_scope?(p, "mcp")
      assert Principal.has_scope?(p, "pm:read")
      refute Principal.has_scope?(p, "pm:write")
    end

    test "trailing-* glob matches by prefix" do
      p = principal(["pm:read", "pm:write", "mcp"])
      assert Principal.has_scope?(p, "pm:*")
      assert Principal.has_scope?(p, "pm:r*")
      refute Principal.has_scope?(p, "mcp:*")
      # "pm" itself is not under the "pm:" prefix
      refute Principal.has_scope?(principal(["pm"]), "pm:*")
    end

    test "bare * matches every granted scope" do
      assert Principal.has_scope?(principal(["anything"]), "*")
      assert Principal.has_scope?(principal(["a", "b"]), "*")
    end

    test "no scopes matches nothing" do
      p = principal([])
      refute Principal.has_scope?(p, "mcp")
      refute Principal.has_scope?(p, "pm:*")
      refute Principal.has_scope?(p, "*")
    end
  end

  describe "scope_list/1" do
    test "returns the granted scopes as a list" do
      scopes = Principal.scope_list(principal(["a", "b"]))
      assert Enum.sort(scopes) == ["a", "b"]
    end
  end

  describe "no trusted fallback identity (FR-2.1, AP-4)" do
    test "the module exports no system/0 constructor — the lib cannot mint identity" do
      exports = Principal.module_info(:exports) |> MapSet.new(&elem(&1, 0))
      refute MapSet.member?(exports, :system)
      refute function_exported?(Principal, :system, 0)
      refute function_exported?(Principal, :system, 1)
    end
  end
end
