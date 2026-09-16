defmodule Noizu.MCP.Auth.Server.Agent.SessionTest do
  @moduledoc """
  A session's nonce is good for exactly one successful assertion, so
  `usable?/2` and `consume/2` carry the entire replay-resistance guarantee.
  """
  use ExUnit.Case, async: true

  alias Noizu.MCP.Auth.Server.Agent.Session

  describe "usable?/2" do
    test "false when expired" do
      now = DateTime.utc_now()
      session = Session.new(now: now, ttl: 60)
      later = DateTime.add(now, 61, :second)
      refute Session.usable?(session, later)
    end

    test "true within ttl" do
      now = DateTime.utc_now()
      session = Session.new(now: now, ttl: 60)
      soon = DateTime.add(now, 30, :second)
      assert Session.usable?(session, soon)
    end

    test "false when consumed" do
      now = DateTime.utc_now()
      session = Session.new(now: now, ttl: 60) |> Session.consume(now)
      refute Session.usable?(session, now)
    end

    test "false when revoked" do
      now = DateTime.utc_now()
      session = %{Session.new(now: now, ttl: 60) | revoked_at: now}
      refute Session.usable?(session, now)
    end
  end

  describe "consume/2" do
    test "is idempotent and keeps the first timestamp" do
      now = DateTime.utc_now()
      session = Session.new(now: now)

      t1 = DateTime.add(now, 5, :second)
      once = Session.consume(session, t1)

      t2 = DateTime.add(now, 10, :second)
      twice = Session.consume(once, t2)

      assert twice.consumed_at == t1
    end
  end

  describe "hash_ip/2" do
    test "returns nil for a nil address" do
      assert Session.hash_ip(nil, "salt") == nil
    end

    test "returns nil for a nil salt" do
      assert Session.hash_ip("127.0.0.1", nil) == nil
    end

    test "the same address under two different salts gives different hashes" do
      h1 = Session.hash_ip("127.0.0.1", "salt-a")
      h2 = Session.hash_ip("127.0.0.1", "salt-b")
      assert h1 != h2
      assert is_binary(h1)
      assert is_binary(h2)
    end

    test "hashes a tuple IPv4 address without raising" do
      assert Session.hash_ip({127, 0, 0, 1}, "salt") =~ ~r/\A[A-Za-z0-9_-]+\z/
    end

    test "hashes a tuple IPv6 address without raising" do
      assert Session.hash_ip({0, 0, 0, 0, 0, 0, 0, 1}, "salt") =~ ~r/\A[A-Za-z0-9_-]+\z/
    end

    test "is deterministic for the same address and salt" do
      assert Session.hash_ip({127, 0, 0, 1}, "salt") == Session.hash_ip({127, 0, 0, 1}, "salt")
    end
  end
end
