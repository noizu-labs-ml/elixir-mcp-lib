defmodule Noizu.MCP.Auth.Server.Agent.KeyTest do
  @moduledoc """
  The fingerprint is the whole identity story for a key: it must be stable
  across every encoding a client might send, and it must be the RFC 8037
  thumbprint, not merely "some hash of the bytes".
  """
  use ExUnit.Case, async: true

  alias Noizu.MCP.Auth.Server.Agent.Key

  # 32 raw bytes, fixed so the thumbprint can be checked against a value
  # computed independently from the RFC 8037 definition rather than from
  # this module's own implementation.
  @raw :binary.copy(<<1>>, 32)
  # sha256(#{"crv":"Ed25519","kty":"OKP","x":"<url_encode64 no padding of @raw>"}),
  # base64url no padding — computed by hand against RFC 7638 / RFC 8037, not by
  # calling Key.thumbprint/1.
  @known_x Base.url_encode64(@raw, padding: false)
  @known_json ~s({"crv":"Ed25519","kty":"OKP","x":"#{@known_x}"})
  @known_thumbprint :sha256 |> :crypto.hash(@known_json) |> Base.url_encode64(padding: false)

  describe "thumbprint/1" do
    test "matches a known-answer vector computed from the RFC 8037 definition" do
      assert Key.thumbprint(@raw) == @known_thumbprint
    end

    test "the same key in padded base64, unpadded base64url, and standard base64 all fingerprint the same" do
      padded_std = Base.encode64(@raw)
      unpadded_url = Base.url_encode64(@raw, padding: false)
      padded_url = Base.url_encode64(@raw)
      unpadded_std = Base.encode64(@raw, padding: false)

      {:ok, k1} = Key.new(padded_std)
      {:ok, k2} = Key.new(unpadded_url)
      {:ok, k3} = Key.new(padded_url)
      {:ok, k4} = Key.new(unpadded_std)

      assert k1.fingerprint == k2.fingerprint
      assert k2.fingerprint == k3.fingerprint
      assert k3.fingerprint == k4.fingerprint
      assert k1.fingerprint == @known_thumbprint
    end
  end

  describe "decode/1" do
    test "round-trips through encode/1" do
      {:ok, raw} = Key.decode(Key.encode(@raw))
      assert raw == @raw
    end

    test "rejects wrong-length input" do
      assert Key.decode(Base.url_encode64(:binary.copy(<<1>>, 31), padding: false)) ==
               {:error, :malformed_key}

      assert Key.decode(Base.url_encode64(:binary.copy(<<1>>, 33), padding: false)) ==
               {:error, :malformed_key}
    end

    test "rejects non-base64 input" do
      assert Key.decode("not base64!! @@@ ///") == {:error, :malformed_key}
    end

    test "rejects a 64-char hex string rather than silently reading it as base64" do
      hex = @raw |> Base.encode16(case: :lower) |> binary_part(0, 64)
      assert byte_size(hex) == 64
      assert Key.decode(hex) == {:error, :malformed_key}
    end

    test "rejects non-binary input" do
      assert Key.decode(nil) == {:error, :malformed_key}
      assert Key.decode(123) == {:error, :malformed_key}
    end
  end

  describe "new/2" do
    test "accepts ed25519 alg spellings" do
      encoded = Key.encode(@raw)
      assert {:ok, _} = Key.new(encoded, alg: "ed25519")
      assert {:ok, _} = Key.new(encoded, alg: "Ed25519")
      assert {:ok, _} = Key.new(encoded, alg: "EdDSA")
      assert {:ok, _} = Key.new(encoded, alg: :ed25519)
    end

    test "rejects an unsupported alg" do
      assert Key.new(Key.encode(@raw), alg: "RS256") == {:error, :unsupported_alg}
    end

    test "rejects a malformed key before the alg check would matter" do
      assert Key.new("garbage") == {:error, :malformed_key}
    end

    test "carries through the optional metadata" do
      now = DateTime.utc_now()

      {:ok, key} =
        Key.new(Key.encode(@raw), account_id: "acc1", label: "laptop", added_via: "registration", added_at: now)

      assert key.account_id == "acc1"
      assert key.label == "laptop"
      assert key.added_via == "registration"
      assert key.added_at == now
    end
  end

  describe "active?/1 and revoke/3" do
    test "a fresh key is active" do
      {:ok, key} = Key.new(Key.encode(@raw))
      assert Key.active?(key)
    end

    test "a revoked key is not active" do
      {:ok, key} = Key.new(Key.encode(@raw))
      revoked = Key.revoke(key, "admin", DateTime.utc_now())
      refute Key.active?(revoked)
    end

    test "revoke is idempotent — the original timestamp and actor are kept" do
      {:ok, key} = Key.new(Key.encode(@raw))
      t1 = DateTime.utc_now()
      once = Key.revoke(key, "admin", t1)

      t2 = DateTime.add(t1, 60, :second)
      twice = Key.revoke(once, "someone-else", t2)

      assert twice.revoked_at == t1
      assert twice.revoked_by == "admin"
    end
  end

  describe "to_map/1" do
    test "only exposes the documented public view" do
      {:ok, key} = Key.new(Key.encode(@raw), label: "laptop", added_via: "registration")
      map = Key.to_map(key)

      assert Map.keys(map) |> Enum.sort() ==
               Enum.sort(["fingerprint", "public_key", "alg", "label", "added_at", "added_via", "revoked_at"])

      refute Map.has_key?(map, "account_id")
      assert map["public_key"] == Key.encode(@raw)
      assert map["alg"] == "ed25519"
    end
  end
end
