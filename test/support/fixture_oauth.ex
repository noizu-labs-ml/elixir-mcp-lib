defmodule Noizu.MCP.Fixtures.OAuth do
  @moduledoc false
  # Shared fixtures for the resource-server verifiers and the authorization
  # server's pure logic. Kept apart from `fixture_auth.ex`, which serves the
  # older client-side OAuth tests.

  @secret "test-hmac-secret-at-least-32-bytes-long"

  def secret, do: @secret
  def secret_fun, do: @secret

  @doc """
  Mint an HS256 JWT. `claims` overrides the defaults, so a test names only the
  claim it is about.
  """
  def token(claims \\ %{}, opts \\ []) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "iss" => "https://app.example.com",
          "sub" => "user-1",
          "aud" => "https://app.example.com/mcp",
          "scope" => "mcp",
          "iat" => now,
          "exp" => now + 900
        },
        stringify(claims)
      )

    jwk = Keyword.get_lazy(opts, :jwk, fn -> JOSE.JWK.from_oct(@secret) end)
    alg = Keyword.get(opts, :alg, "HS256")

    {_meta, compact} =
      jwk
      |> JOSE.JWT.sign(%{"alg" => alg}, claims)
      |> JOSE.JWS.compact()

    compact
  end

  @doc "An RSA key pair for algorithm-confusion tests."
  def rsa_jwk, do: JOSE.JWK.generate_key({:rsa, 2048})

  @doc "Verifier opts for a mount, overridable per test."
  def jwt_opts(overrides \\ []) do
    Keyword.merge(
      [
        resource: "https://app.example.com/mcp",
        issuer: "https://app.example.com",
        secret: @secret,
        algorithms: ["HS256"]
      ],
      overrides
    )
  end

  def conn_info, do: %{method: "POST", peer: {127, 0, 0, 1}, headers: []}

  # ── API keys ─────────────────────────────────────────────────────────────

  @api_key "mcp_live_2WPKhV4dpaKcqFJq7cVKcJnqTsVvXqUx"

  def api_key, do: @api_key

  @doc "A host-side validator: recognizes exactly one key, rejects the rest."
  def validate_api_key(presented) do
    if Noizu.MCP.Auth.Server.Secret.equal?(presented, @api_key) do
      {:ok, %{"sub" => "service-account-1", "scope" => "mcp", "api_key_id" => "key-1"}}
    else
      {:error, :unknown_key}
    end
  end

  def validate_api_key_revoked(_presented), do: false

  def raise_validator(_presented), do: raise("boom")

  # ── DNS ──────────────────────────────────────────────────────────────────

  @hosts %{
    "public.example.com" => [{93, 184, 216, 34}],
    "metadata.example.com" => [{169, 254, 169, 254}],
    "internal.example.com" => [{10, 1, 2, 3}],
    "mapped.example.com" => [{0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE}],
    "split.example.com" => [{93, 184, 216, 34}, {127, 0, 0, 1}],
    "v6.example.com" => [{0x2606, 0x2800, 0x220, 1, 0x248, 0x1893, 0x25C8, 0x1946}]
  }

  @doc """
  A resolver with no DNS behind it, so the SSRF table is deterministic.
  Unknown hosts do not resolve.
  """
  def resolver(host) do
    case Map.fetch(@hosts, host) do
      {:ok, addresses} -> {:ok, addresses}
      :error -> {:error, :nxdomain}
    end
  end

  def ssrf_opts(overrides \\ []),
    do: Keyword.merge([resolver: &__MODULE__.resolver/1], overrides)

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
