defmodule Noizu.MCP.Auth.Server.PKCE do
  @moduledoc """
  PKCE (RFC 7636), **S256 only**.

  `plain` is not implemented and `code_challenge_method` values other than
  `"S256"` are rejected rather than defaulted — OAuth 2.1 requires S256 for
  every client, and a "default to plain when the method is absent" branch is
  precisely how a downgrade gets in. The authorization-server metadata
  advertises `code_challenge_methods_supported: ["S256"]` to match.

      iex> Noizu.MCP.Auth.Server.PKCE.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
      {:ok, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"}
  """

  alias Noizu.MCP.Auth.Server.Secret

  @method "S256"
  @min_verifier 43
  @max_verifier 128

  @doc "The one supported method."
  @spec method() :: String.t()
  def method, do: @method

  @doc """
  Derive the `code_challenge` for a verifier: base64url(SHA-256(verifier)),
  unpadded.
  """
  @spec challenge(String.t()) :: {:ok, String.t()} | {:error, :invalid_verifier}
  def challenge(verifier) do
    if valid_verifier?(verifier) do
      {:ok, :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)}
    else
      {:error, :invalid_verifier}
    end
  end

  @doc """
  Check a presented verifier against the stored challenge.

  `method` must be `"S256"`; anything else — including `nil`, which is how a
  client that skipped PKCE presents — is a rejection.
  """
  @spec verify(term(), term(), term()) :: :ok | {:error, :invalid_grant}
  def verify(verifier, stored_challenge, method \\ @method)

  def verify(verifier, stored_challenge, @method)
      when is_binary(verifier) and is_binary(stored_challenge) do
    case challenge(verifier) do
      {:ok, derived} ->
        # Constant-time: the challenge is not itself a secret, but the verifier
        # is, and a byte-wise `==` on the derived value leaks its prefix.
        if Secret.equal?(derived, stored_challenge), do: :ok, else: {:error, :invalid_grant}

      {:error, :invalid_verifier} ->
        {:error, :invalid_grant}
    end
  end

  def verify(_verifier, _stored_challenge, _method), do: {:error, :invalid_grant}

  @doc """
  Validate a `code_challenge` as received at the authorization endpoint.

  An S256 challenge is exactly 43 unpadded base64url characters — a shorter
  one is a `plain` verifier being smuggled through.
  """
  @spec valid_challenge?(term()) :: boolean()
  def valid_challenge?(challenge) when is_binary(challenge) do
    byte_size(challenge) == 43 and base64url?(challenge)
  end

  def valid_challenge?(_challenge), do: false

  @doc "Validate a `code_verifier` against the RFC 7636 §4.1 grammar."
  @spec valid_verifier?(term()) :: boolean()
  def valid_verifier?(verifier) when is_binary(verifier) do
    byte_size(verifier) in @min_verifier..@max_verifier and unreserved?(verifier)
  end

  def valid_verifier?(_verifier), do: false

  @doc "Validate a `code_challenge_method`. Only `\"S256\"` passes."
  @spec valid_method?(term()) :: boolean()
  def valid_method?(@method), do: true
  def valid_method?(_method), do: false

  @doc "A fresh 32-byte verifier, for tests and for the library's own client."
  @spec generate_verifier() :: String.t()
  def generate_verifier, do: Secret.generate(32)

  # RFC 7636: unreserved = ALPHA / DIGIT / "-" / "." / "_" / "~"
  defp unreserved?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(fn c ->
      c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?-, ?., ?_, ?~]
    end)
  end

  defp base64url?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(fn c ->
      c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?-, ?_]
    end)
  end
end
