defmodule Noizu.MCP.Auth.Server.SecretTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.Auth.Server.Secret

  # PBKDF2 at production iterations is deliberately slow; these tests only care
  # about the algebra, so they turn it down.
  @fast [iterations: 1_000]

  describe "hash/2 and verify/3" do
    test "a secret verifies against its own hash" do
      hash = Secret.hash("s3cret", @fast)
      assert Secret.verify("s3cret", hash, @fast)
    end

    test "a wrong secret does not verify" do
      hash = Secret.hash("s3cret", @fast)
      refute Secret.verify("s3cre", hash, @fast)
      refute Secret.verify("s3crets", hash, @fast)
      refute Secret.verify("", hash, @fast)
    end

    test "the plaintext never appears in the stored hash" do
      hash = Secret.hash("a-very-distinctive-secret", @fast)
      refute hash =~ "distinctive"
    end

    test "the same secret hashes differently every time (random salt)" do
      assert Secret.hash("same", @fast) != Secret.hash("same", @fast)
    end

    test "the hash is self-describing, so iterations can be raised later" do
      assert "pbkdf2-sha256$1000$" <> _ = Secret.hash("s", @fast)

      # A row written at a lower cost still verifies after the default rises.
      old = Secret.hash("s", iterations: 1_000)
      assert Secret.verify("s", old, iterations: 50_000)
    end

    test "a missing or malformed stored hash is false, not a crash" do
      refute Secret.verify("s", nil, @fast)
      refute Secret.verify("s", "", @fast)
      refute Secret.verify("s", "garbage", @fast)
      refute Secret.verify("s", "pbkdf2-sha256$notanumber$AAAA$AAAA", @fast)
      refute Secret.verify("s", "argon2$x$y$z", @fast)
      refute Secret.verify(nil, Secret.hash("s", @fast), @fast)
    end
  end

  describe ":secret_hasher override" do
    def sha_hasher(secret), do: :crypto.hash(:sha256, "pepper" <> secret) |> Base.encode16()

    test "hashing and verification both route through the override" do
      opts = [secret_hasher: {__MODULE__, :sha_hasher}]

      hash = Secret.hash("s3cret", opts)
      assert hash == sha_hasher("s3cret")
      assert Secret.verify("s3cret", hash, opts)
      refute Secret.verify("other", hash, opts)
    end

    test "a 1-arity fun is accepted" do
      opts = [secret_hasher: &__MODULE__.sha_hasher/1]
      assert Secret.verify("s3cret", Secret.hash("s3cret", opts), opts)
    end

    test "an override does not verify against a pbkdf2 hash, and vice versa" do
      opts = [secret_hasher: {__MODULE__, :sha_hasher}]
      refute Secret.verify("s3cret", Secret.hash("s3cret", @fast), opts)
      refute Secret.verify("s3cret", Secret.hash("s3cret", opts), @fast)
    end
  end

  describe "token_hash/1" do
    test "is SHA-256 in lowercase hex" do
      assert Secret.token_hash("abc") ==
               "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    end

    test "is deterministic — a store can look a token up by its hash" do
      assert Secret.token_hash("tok") == Secret.token_hash("tok")
      assert Secret.token_hash("tok") != Secret.token_hash("tok2")
    end

    test "reveals nothing of the token" do
      refute Secret.token_hash("mcp_live_distinctive") =~ "distinctive"
    end
  end

  describe "equal?/2" do
    test "compares equal binaries" do
      assert Secret.equal?("abc", "abc")
      assert Secret.equal?("", "")
    end

    test "rejects differing binaries, including differing lengths" do
      refute Secret.equal?("abc", "abd")
      refute Secret.equal?("abc", "abcd")
      refute Secret.equal?("abc", "")
    end

    test "nil is never equal to anything (and does not raise)" do
      refute Secret.equal?(nil, "abc")
      refute Secret.equal?("abc", nil)
      refute Secret.equal?(nil, nil)
    end
  end

  describe "generate/1" do
    test "is URL-safe, unpadded and unique" do
      secrets = for _ <- 1..50, do: Secret.generate()
      assert length(Enum.uniq(secrets)) == 50
      assert Enum.all?(secrets, &(&1 =~ ~r/\A[A-Za-z0-9_-]+\z/))
      assert Enum.all?(secrets, &(byte_size(&1) == 43))
    end

    test "entropy is configurable" do
      assert byte_size(Secret.generate(16)) == 22
    end
  end
end
