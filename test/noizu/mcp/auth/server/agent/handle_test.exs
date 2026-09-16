defmodule Noizu.MCP.Auth.Server.Agent.HandleTest do
  @moduledoc """
  Handles are the only human-readable attribution an account has, so the
  squash rule matters as much as the shape rule — and it must not be so
  aggressive that it eats legitimate handles that merely contain a digit.
  """
  use ExUnit.Case, async: true

  alias Noizu.MCP.Auth.Server.Agent.Handle

  describe "validate/1 — length bounds" do
    test "2 characters is too short" do
      assert Handle.validate("ab") == {:error, :handle_too_short}
    end

    test "3 characters is accepted" do
      assert Handle.validate("abc") == {:ok, "abc"}
    end

    test "32 characters is accepted" do
      handle = String.duplicate("a", 32)
      assert Handle.validate(handle) == {:ok, handle}
    end

    test "33 characters is too long" do
      handle = String.duplicate("a", 33)
      assert Handle.validate(handle) == {:error, :handle_too_long}
    end
  end

  describe "validate/1 — case and shape" do
    test "uppercase input is downcased and accepted" do
      assert Handle.validate("AgentSmith") == {:ok, "agentsmith"}
    end

    test "leading or trailing hyphen is rejected" do
      assert Handle.validate("-agent") == {:error, :handle_malformed}
      assert Handle.validate("agent-") == {:error, :handle_malformed}
    end

    test "leading or trailing underscore is rejected" do
      assert Handle.validate("_agent") == {:error, :handle_malformed}
      assert Handle.validate("agent_") == {:error, :handle_malformed}
    end

    test "internal hyphens and underscores are accepted" do
      assert Handle.validate("agent-smith_42") == {:ok, "agent-smith_42"}
    end

    test "empty or whitespace-only is required, not malformed" do
      assert Handle.validate("") == {:error, :handle_required}
      assert Handle.validate("   ") == {:error, :handle_required}
    end

    test "non-binary input is required" do
      assert Handle.validate(nil) == {:error, :handle_required}
      assert Handle.validate(123) == {:error, :handle_required}
    end
  end

  describe "validate/1 — reserved words and squash attacks" do
    test "a reserved word is rejected outright" do
      assert Handle.validate("admin") == {:error, :handle_reserved}
      assert Handle.validate("root") == {:error, :handle_reserved}
      assert Handle.validate("noizu") == {:error, :handle_reserved}
    end

    test "leetspeak/homoglyph squashes of reserved words are rejected" do
      # BUG (see report): squash/1 maps "1" -> "l", not "1" -> "i", so
      # "adm1n" squashes to "admln" rather than "admin" and slips past the
      # reserved check. Asserting the intended behavior here, not the
      # observed one.
      assert Handle.validate("adm1n") == {:error, :handle_reserved}
      assert Handle.validate("r00t") == {:error, :handle_reserved}
      assert Handle.validate("a-d-m-i-n") == {:error, :handle_reserved}
      assert Handle.validate("n0izu") == {:error, :handle_reserved}
      assert Handle.validate("t0b0r") == {:error, :handle_reserved}
    end

    test "a legitimate handle with a non-confusable digit is accepted" do
      assert Handle.validate("agent42") == {:ok, "agent42"}
    end
  end

  describe "reserved?/1" do
    test "agrees with validate/1 on squashed collisions" do
      # BUG (see report): "1" squashes to "l", not "i" — "adm1n" does not
      # currently collide with "admin". Expected behavior asserted here.
      assert Handle.reserved?("adm1n")
      refute Handle.reserved?("agent42")
    end
  end

  describe "squash/1" do
    test "folds separators and digit homoglyphs" do
      assert Handle.squash("a-d-m-i-n") == "admin"
      assert Handle.squash("r00t") == "root"
      assert Handle.squash("n0izu") == "noizu"
      assert Handle.squash("t0b0r") == "tobor"
    end

    test "does not fold digits that have no homoglyph mapping" do
      # "4" does map (to "a"); only the mapping-less digit ("2") survives.
      assert Handle.squash("agent42") == "agenta2"
    end
  end

  describe "reserved/0" do
    test "exposes the raw reserved word list" do
      assert "admin" in Handle.reserved()
      assert "noizu" in Handle.reserved()
    end
  end
end
