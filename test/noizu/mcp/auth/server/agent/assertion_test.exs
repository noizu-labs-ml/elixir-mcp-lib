defmodule Noizu.MCP.Auth.Server.Agent.AssertionTest do
  @moduledoc """
  This is the module that decides whether a signature counts. `alg`
  confusion and key injection are the headline attacks — both must fail
  even when the rest of the token is otherwise well-formed.
  """
  use ExUnit.Case, async: true

  alias Noizu.MCP.Auth.Server.Agent.Assertion

  @audience "https://mcp.example.com/token"
  @account_id "acc_1"
  @handle "agentsmith"

  setup do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    {other_public, other_private} = :crypto.generate_key(:eddsa, :ed25519)

    %{
      public_key: public_key,
      private_key: private_key,
      other_public: other_public,
      other_private: other_private
    }
  end

  defp claims(overrides \\ %{}) do
    now = DateTime.utc_now() |> DateTime.to_unix()

    Map.merge(
      %{
        "iss" => @account_id,
        "sub" => @account_id,
        "aud" => @audience,
        "hdl" => @handle,
        "iat" => now,
        "exp" => now + 60,
        "jti" => "jti-1",
        "sid" => "sid-1",
        "nonce" => "nonce-1"
      },
      overrides
    )
  end

  defp verify_opts(overrides) do
    Keyword.merge(
      [audience: @audience, account_id: @account_id, handle: @handle],
      overrides
    )
  end

  defp verify(token, public_key, opts \\ []) do
    with {:ok, assertion} <- Assertion.parse(token) do
      Assertion.verify(assertion, Keyword.put(verify_opts(opts), :public_key, public_key))
    end
  end

  describe "happy path" do
    test "a well-formed assertion verifies", %{public_key: pub, private_key: priv} do
      token = Assertion.sign(claims(), priv, "kid-1")
      assert {:ok, claims} = verify(token, pub)
      assert claims["sub"] == @account_id
    end
  end

  describe "signature checks" do
    test "a signature made by a different key is rejected", %{
      public_key: pub,
      other_private: other_priv
    } do
      token = Assertion.sign(claims(), other_priv, "kid-1")
      assert {:error, :bad_signature} = verify(token, pub)
    end

    test "a tampered byte in the header segment is rejected", %{public_key: pub, private_key: priv} do
      token = Assertion.sign(claims(), priv, "kid-1")
      assert {:error, _} = verify(tamper_segment(token, 0), pub)
    end

    test "a tampered byte in the payload segment is rejected", %{
      public_key: pub,
      private_key: priv
    } do
      token = Assertion.sign(claims(), priv, "kid-1")
      assert {:error, _} = verify(tamper_segment(token, 1), pub)
    end
  end

  describe "alg confusion" do
    test "alg: none is rejected", %{public_key: pub} do
      header = %{"alg" => "none", "typ" => "JWT", "kid" => "kid-1"}
      token = unsigned_token(header, claims())
      assert {:error, :unsupported_alg} = verify(token, pub)
    end

    test "alg: HS256 signed with the victim's own public key as the HMAC secret is rejected", %{
      public_key: pub
    } do
      header = %{"alg" => "HS256", "typ" => "JWT", "kid" => "kid-1"}
      h = header |> Jason.encode!() |> Base.url_encode64(padding: false)
      p = claims() |> Jason.encode!() |> Base.url_encode64(padding: false)
      input = h <> "." <> p
      sig = :crypto.mac(:hmac, :sha256, pub, input)
      token = input <> "." <> Base.url_encode64(sig, padding: false)

      assert {:error, :unsupported_alg} = verify(token, pub)
    end
  end

  describe "key injection" do
    for header_key <- ["jwk", "jku", "x5u", "x5c"] do
      test "a header carrying #{header_key} is rejected even with an otherwise valid signature",
           %{private_key: priv} do
        header_key = unquote(header_key)
        header = %{"alg" => "EdDSA", "typ" => "JWT", "kid" => "kid-1", header_key => "injected"}
        token = signed_token(header, claims(), priv)

        # The rejection happens at parse time, before any key is loaded — a
        # valid signature must not save a token carrying a key-injection header.
        assert Assertion.parse(token) == {:error, :key_injection}
      end
    end
  end

  describe "kid" do
    test "missing kid is rejected", %{public_key: pub, private_key: priv} do
      header = %{"alg" => "EdDSA", "typ" => "JWT"}
      token = signed_token(header, claims(), priv)
      assert {:error, :missing_kid} = verify(token, pub)
    end

    test "empty kid is rejected", %{public_key: pub, private_key: priv} do
      header = %{"alg" => "EdDSA", "typ" => "JWT", "kid" => ""}
      token = signed_token(header, claims(), priv)
      assert {:error, :missing_kid} = verify(token, pub)
    end
  end

  describe "oversized input" do
    test "input over 8KB is rejected with :too_large before decoding" do
      huge = String.duplicate("a", 8_193)
      assert Assertion.parse(huge) == {:error, :too_large}
    end
  end

  describe "claim checks" do
    test "wrong audience is rejected", %{public_key: pub, private_key: priv} do
      token = Assertion.sign(claims(%{"aud" => "https://other.example.com/token"}), priv, "kid-1")
      assert {:error, :bad_audience} = verify(token, pub)
    end

    test "aud as a list containing the expected value is accepted", %{
      public_key: pub,
      private_key: priv
    } do
      # BUG (see report): check_required/2's present?/1 has no clause for a
      # list value, so an array `aud` (explicitly allowed per RFC 7519 §4.1.3
      # and the moduledoc) is rejected as :missing_claim before
      # check_audience/2 ever runs. Expected behavior asserted here.
      token = Assertion.sign(claims(%{"aud" => [@audience, "https://other"]}), priv, "kid-1")
      assert {:ok, _} = verify(token, pub)
    end

    test "aud as a list NOT containing the expected value is rejected", %{
      public_key: pub,
      private_key: priv
    } do
      # BUG (see report): same present?/1 gap — this currently fails closed
      # with :missing_claim rather than :bad_audience, which happens to be
      # safe here but masks the real reason and breaks the "aud as a list
      # containing the expected value" case above.
      token = Assertion.sign(claims(%{"aud" => ["https://other-a", "https://other-b"]}), priv, "kid-1")
      assert {:error, :bad_audience} = verify(token, pub)
    end

    test "wrong iss is rejected", %{public_key: pub, private_key: priv} do
      token = Assertion.sign(claims(%{"iss" => "someone-else"}), priv, "kid-1")
      assert {:error, :bad_subject} = verify(token, pub)
    end

    test "iss != sub is rejected", %{public_key: pub, private_key: priv} do
      token = Assertion.sign(claims(%{"sub" => "someone-else"}), priv, "kid-1")
      assert {:error, :bad_subject} = verify(token, pub)
    end

    test "wrong hdl is rejected", %{public_key: pub, private_key: priv} do
      token = Assertion.sign(claims(%{"hdl" => "impostor"}), priv, "kid-1")
      assert {:error, :bad_handle} = verify(token, pub)
    end

    test "missing sid/nonce is rejected when required", %{public_key: pub, private_key: priv} do
      base = claims() |> Map.drop(["sid", "nonce"])
      token = Assertion.sign(base, priv, "kid-1")
      assert {:error, :missing_claim} = verify(token, pub, require: ["sid", "nonce"])
    end

    test "missing sid/nonce is accepted when not required (key-management proof)", %{
      public_key: pub,
      private_key: priv
    } do
      base = claims() |> Map.drop(["sid", "nonce"])
      token = Assertion.sign(base, priv, "kid-1")
      assert {:ok, _} = verify(token, pub, require: [])
    end
  end

  describe "time checks" do
    test "an expired assertion is rejected", %{public_key: pub, private_key: priv} do
      now = DateTime.utc_now() |> DateTime.to_unix()
      token = Assertion.sign(claims(%{"iat" => now - 120, "exp" => now - 61}), priv, "kid-1")
      assert {:error, :expired} = verify(token, pub, skew: 60)
    end

    test "a not-yet-valid assertion beyond skew is rejected", %{
      public_key: pub,
      private_key: priv
    } do
      now = DateTime.utc_now() |> DateTime.to_unix()
      token = Assertion.sign(claims(%{"iat" => now + 120, "exp" => now + 180}), priv, "kid-1")
      assert {:error, :not_yet_valid} = verify(token, pub, skew: 60)
    end

    test "accepted at the not-yet-valid edge of skew", %{public_key: pub, private_key: priv} do
      now = DateTime.utc_now() |> DateTime.to_unix()
      token = Assertion.sign(claims(%{"iat" => now + 60, "exp" => now + 90}), priv, "kid-1")
      assert {:ok, _} = verify(token, pub, skew: 60)
    end

    test "accepted at the expiry edge of skew", %{public_key: pub, private_key: priv} do
      now = DateTime.utc_now() |> DateTime.to_unix()
      token = Assertion.sign(claims(%{"iat" => now - 90, "exp" => now - 60}), priv, "kid-1")
      assert {:ok, _} = verify(token, pub, skew: 60)
    end

    test "exp <= iat is rejected", %{public_key: pub, private_key: priv} do
      now = DateTime.utc_now() |> DateTime.to_unix()
      token = Assertion.sign(claims(%{"iat" => now, "exp" => now}), priv, "kid-1")
      assert {:error, :lifetime_too_long} = verify(token, pub)
    end

    test "exp - iat greater than max_age is rejected", %{public_key: pub, private_key: priv} do
      now = DateTime.utc_now() |> DateTime.to_unix()
      token = Assertion.sign(claims(%{"iat" => now, "exp" => now + 600}), priv, "kid-1")
      assert {:error, :lifetime_too_long} = verify(token, pub, max_age: 300)
    end
  end

  describe "expect binding" do
    test "a proof binds to op and jkt and is accepted against the matching expect map", %{
      public_key: pub,
      private_key: priv
    } do
      jkt = "some-thumbprint"
      base = claims() |> Map.put("op", "add_key") |> Map.put("jkt", jkt)
      token = Assertion.sign(base, priv, "kid-1")

      assert {:ok, _} =
               verify(token, pub, expect: %{"op" => "add_key", "jkt" => jkt})
    end

    test "the same proof is rejected against a different jkt", %{
      public_key: pub,
      private_key: priv
    } do
      base = claims() |> Map.put("op", "add_key") |> Map.put("jkt", "thumbprint-a")
      token = Assertion.sign(base, priv, "kid-1")

      assert {:error, :bad_claim} =
               verify(token, pub, expect: %{"op" => "add_key", "jkt" => "thumbprint-b"})
    end
  end

  describe "malformed input" do
    test "not a string is rejected" do
      assert Assertion.parse(nil) == {:error, :malformed}
      assert Assertion.parse(123) == {:error, :malformed}
      assert Assertion.parse(%{}) == {:error, :malformed}
    end

    test "wrong number of dot-separated segments is rejected" do
      assert Assertion.parse("a.b") == {:error, :malformed}
      assert Assertion.parse("a.b.c.d") == {:error, :malformed}
      assert Assertion.parse("noD ots here") == {:error, :malformed}
    end

    test "non-base64 segments are rejected" do
      assert Assertion.parse("!!!.!!!.!!!") == {:error, :malformed}
    end

    test "valid base64 that is not JSON is rejected" do
      not_json = Base.url_encode64("not json", padding: false)
      sig = Base.url_encode64(:binary.copy(<<0>>, 64), padding: false)
      assert Assertion.parse("#{not_json}.#{not_json}.#{sig}") == {:error, :malformed}
    end

    test "JSON that is not an object is rejected" do
      arr = Jason.encode!([1, 2, 3]) |> Base.url_encode64(padding: false)
      good_payload = claims() |> Jason.encode!() |> Base.url_encode64(padding: false)
      sig = Base.url_encode64(:binary.copy(<<0>>, 64), padding: false)
      assert Assertion.parse("#{arr}.#{good_payload}.#{sig}") == {:error, :malformed}
    end
  end

  # --- helpers --------------------------------------------------------------

  defp signed_token(header, claims, private_key) do
    h = header |> Jason.encode!() |> Base.url_encode64(padding: false)
    p = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    input = h <> "." <> p
    sig = :crypto.sign(:eddsa, :none, input, [private_key, :ed25519])
    input <> "." <> Base.url_encode64(sig, padding: false)
  end

  defp unsigned_token(header, claims) do
    h = header |> Jason.encode!() |> Base.url_encode64(padding: false)
    p = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    sig = Base.url_encode64(:binary.copy(<<0>>, 64), padding: false)
    h <> "." <> p <> "." <> sig
  end

  # Flip one byte inside the header (segment 0) or payload (segment 1) of a
  # compact JWS while keeping it valid base64url, so the change is caught by
  # signature verification rather than by the decoder.
  defp tamper_segment(token, index) do
    segments = String.split(token, ".", parts: 3)
    segment = Enum.at(segments, index)
    {:ok, raw} = Base.url_decode64(segment, padding: false)
    <<byte, rest::binary>> = raw
    tampered_raw = <<:erlang.bxor(byte, 0xFF), rest::binary>>
    tampered_segment = Base.url_encode64(tampered_raw, padding: false)

    segments
    |> List.replace_at(index, tampered_segment)
    |> Enum.join(".")
  end
end
