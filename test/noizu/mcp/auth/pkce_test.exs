defmodule Noizu.MCP.Auth.Server.PKCETest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.Auth.Server.PKCE

  doctest Noizu.MCP.Auth.Server.PKCE

  # RFC 7636 Appendix B.
  @verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
  @challenge "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

  describe "RFC 7636 test vector" do
    test "challenge/1 reproduces the published S256 challenge" do
      assert {:ok, @challenge} = PKCE.challenge(@verifier)
    end

    test "verify/3 accepts the vector's pair" do
      assert :ok = PKCE.verify(@verifier, @challenge)
    end

    test "the published challenge is a valid challenge and 43 bytes" do
      assert PKCE.valid_challenge?(@challenge)
      assert byte_size(@challenge) == 43
    end
  end

  describe "verify/3" do
    test "rejects a wrong verifier" do
      assert {:error, :invalid_grant} = PKCE.verify(PKCE.generate_verifier(), @challenge)
    end

    test "rejects a verifier that differs in one byte" do
      tampered = String.replace_prefix(@verifier, "d", "e")
      assert {:error, :invalid_grant} = PKCE.verify(tampered, @challenge)
    end

    test "rejects plain, even when the verifier equals the challenge" do
      # The downgrade this module exists to refuse: under `plain` a stolen
      # authorization request is replayable, since the challenge *is* the secret.
      assert {:error, :invalid_grant} = PKCE.verify("same-verifier", "same-verifier", "plain")
      assert {:error, :invalid_grant} = PKCE.verify(@verifier, @challenge, "plain")
    end

    test "rejects a missing method" do
      assert {:error, :invalid_grant} = PKCE.verify(@verifier, @challenge, nil)
    end

    test "rejects a non-binary verifier or challenge" do
      assert {:error, :invalid_grant} = PKCE.verify(nil, @challenge)
      assert {:error, :invalid_grant} = PKCE.verify(@verifier, nil)
    end
  end

  describe "grammar" do
    test "verifier length bounds are 43..128" do
      refute PKCE.valid_verifier?(String.duplicate("a", 42))
      assert PKCE.valid_verifier?(String.duplicate("a", 43))
      assert PKCE.valid_verifier?(String.duplicate("a", 128))
      refute PKCE.valid_verifier?(String.duplicate("a", 129))
    end

    test "verifier is limited to the unreserved set" do
      refute PKCE.valid_verifier?(String.duplicate("a", 42) <> "+")
      refute PKCE.valid_verifier?(String.duplicate("a", 42) <> "/")
      refute PKCE.valid_verifier?(String.duplicate("a", 42) <> "=")
      assert PKCE.valid_verifier?(String.duplicate("a", 39) <> "-._~")
    end

    test "generate_verifier/0 is in the grammar" do
      for _ <- 1..25, do: assert(PKCE.valid_verifier?(PKCE.generate_verifier()))
    end

    test "a short or non-base64url challenge is refused" do
      refute PKCE.valid_challenge?(String.duplicate("a", 42))
      refute PKCE.valid_challenge?(String.duplicate("a", 44))
      refute PKCE.valid_challenge?(String.duplicate("a", 42) <> "=")
      refute PKCE.valid_challenge?(String.duplicate("a", 42) <> "+")
      refute PKCE.valid_challenge?(nil)
    end

    test "only S256 is a valid method" do
      assert PKCE.valid_method?("S256")
      refute PKCE.valid_method?("plain")
      refute PKCE.valid_method?("s256")
      refute PKCE.valid_method?(nil)
      assert PKCE.method() == "S256"
    end

    test "challenge/1 refuses a verifier outside the grammar" do
      assert {:error, :invalid_verifier} = PKCE.challenge("too-short")
      assert {:error, :invalid_verifier} = PKCE.challenge(String.duplicate("a", 43) <> "+")
    end
  end
end
