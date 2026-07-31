defmodule Noizu.MCP.Auth.Server.Secret do
  @moduledoc """
  Secret generation, hashing and constant-time comparison for the
  authorization-server facade.

  Nothing secret is ever stored in plaintext. Two shapes are used, for two
  different reasons:

    * **Client secrets** — `hash/2` / `verify/3`, PBKDF2-HMAC-SHA256 with a
      per-secret random salt. A client secret is chosen once and checked
      often; the salt and the iteration count are what make a stolen table
      useless.
    * **Codes and tokens** — `token_hash/1`, plain SHA-256. Authorization codes
      and refresh tokens are 256 bits of `:crypto.strong_rand_bytes/1` with a
      few minutes' or days' life, so there is nothing to brute-force and no
      dictionary to salt against; PBKDF2 on the token path would only add
      latency to every refresh.

  Every comparison goes through `:crypto.hash_equals/2` on equal-length
  digests, so neither the length of a candidate nor the position of its first
  wrong byte is observable.

  ## Overriding the hasher

  A host with an existing password-hashing dependency (Argon2, bcrypt) can pass
  `secret_hasher: {MyApp.Hash, :hash}` — a 1-arity function returning a
  *deterministic* digest for a given secret. `verify/3` then re-hashes the
  candidate and compares. Deterministic is a real constraint: a randomly-salted
  hasher like `Argon2.hash_pwd_salt/1` will never compare equal here. Wrap such
  a library's own `verify_pass/2` instead of using this module.
  """

  @iterations 100_000
  @salt_bytes 16
  @dk_bytes 32
  @prefix "pbkdf2-sha256"

  @doc """
  A URL-safe random secret. `bytes` is entropy, not output length (32 bytes →
  43 characters).
  """
  @spec generate(pos_integer()) :: String.t()
  def generate(bytes \\ 32) do
    bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  @doc """
  Hash a client secret for storage.

  Returns `pbkdf2-sha256$<iterations>$<salt>$<derived-key>` — self-describing,
  so the iteration count can be raised later without invalidating old rows.

  Options: `:iterations` (default `#{@iterations}`), `:secret_hasher`.
  """
  @spec hash(String.t(), keyword()) :: String.t()
  def hash(secret, opts \\ []) when is_binary(secret) do
    case Keyword.get(opts, :secret_hasher) do
      nil ->
        iterations = Keyword.get(opts, :iterations, @iterations)
        salt = :crypto.strong_rand_bytes(@salt_bytes)
        encode(iterations, salt, derive(secret, salt, iterations))

      hasher ->
        apply_hasher(hasher, secret)
    end
  end

  @doc """
  Verify a candidate secret against a stored hash, in constant time.

  A malformed or `nil` stored hash answers `false` — after doing the same work,
  so an unknown `client_id` and a wrong secret take the same time.
  """
  @spec verify(String.t() | nil, String.t() | nil, keyword()) :: boolean()
  def verify(candidate, stored, opts \\ [])

  def verify(candidate, stored, opts) when is_binary(candidate) and is_binary(stored) do
    case Keyword.get(opts, :secret_hasher) do
      nil -> verify_pbkdf2(candidate, stored)
      hasher -> equal?(apply_hasher(hasher, candidate), stored)
    end
  end

  def verify(candidate, _stored, opts) do
    # No stored hash (unknown client) — burn the same work so the miss is not
    # measurably faster than a wrong secret.
    _ = hash(if(is_binary(candidate), do: candidate, else: ""), opts)
    false
  end

  @doc """
  SHA-256 of a code or token, lowercase hex — what an authorization code or
  refresh token is stored as.
  """
  @spec token_hash(String.t()) :: String.t()
  def token_hash(token) when is_binary(token),
    do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  @doc """
  Constant-time equality for two binaries of any length.

  `:crypto.hash_equals/2` requires equal sizes (and raises otherwise), so both
  sides are digested first — which also removes length from the comparison.
  """
  @spec equal?(binary() | nil, binary() | nil) :: boolean()
  def equal?(a, b) when is_binary(a) and is_binary(b) do
    :crypto.hash_equals(:crypto.hash(:sha256, a), :crypto.hash(:sha256, b))
  end

  def equal?(_a, _b), do: false

  defp verify_pbkdf2(candidate, stored) do
    with [@prefix, iterations, salt, dk] <- String.split(stored, "$"),
         {iterations, ""} <- Integer.parse(iterations),
         {:ok, salt} <- Base.decode64(salt),
         {:ok, dk} <- Base.decode64(dk) do
      :crypto.hash_equals(derive(candidate, salt, iterations), dk)
    else
      _ -> false
    end
  end

  defp derive(secret, salt, iterations),
    do: :crypto.pbkdf2_hmac(:sha256, secret, salt, iterations, @dk_bytes)

  defp encode(iterations, salt, dk),
    do: "#{@prefix}$#{iterations}$#{Base.encode64(salt)}$#{Base.encode64(dk)}"

  defp apply_hasher({module, fun}, secret), do: apply(module, fun, [secret])
  defp apply_hasher({module, fun, args}, secret), do: apply(module, fun, [secret | args])
  defp apply_hasher(fun, secret) when is_function(fun, 1), do: fun.(secret)
end
