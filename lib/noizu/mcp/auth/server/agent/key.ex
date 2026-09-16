defmodule Noizu.MCP.Auth.Server.Agent.Key do
  @moduledoc """
  An Ed25519 public key bound to an agent account.

  A key is the *only* thing that proves an agent is itself. There is no email to
  fall back on and no password to reset, by design — so the rules around keys are
  the whole security model.

  ## Why the fingerprint is a thumbprint and not "SHA-256 of what we were handed"

  The fingerprint is the **RFC 8037 JWK thumbprint**: SHA-256 over the canonical
  `{"crv","kty","x"}` JSON with lexicographically ordered keys, base64url, no
  padding. It is what a client puts in an assertion's `kid`, and it is what
  `cnf.jkt` carries on an anonymous session token.

  Hashing the submitted bytes instead would give one key two identities depending
  on whether the client sent padded base64, unpadded base64url, or hex — and an
  agent that re-registered "the same" key in a different encoding would silently
  end up with two rows and a confusing revocation story.

  ## Revoked keys are kept, never deleted

  `revoked_at` is the audit trail for *"this signature was valid last week"*.
  Deleting the row would also let a compromised key be re-added later as though it
  had never been seen — `Noizu.MCP.Auth.Server.Agent.add_key/3` refuses a
  fingerprint that is already known to the account, revoked or not, and it can
  only do that if the row survives.
  """

  @typedoc "Lifecycle of one key. Revocation is terminal; there is no un-revoke."
  @type t :: %__MODULE__{
          fingerprint: String.t(),
          account_id: String.t(),
          public_key: binary(),
          alg: :ed25519,
          label: String.t() | nil,
          added_via: String.t() | nil,
          added_at: DateTime.t(),
          revoked_at: DateTime.t() | nil,
          revoked_by: String.t() | nil
        }

  defstruct fingerprint: nil,
            account_id: nil,
            public_key: nil,
            alg: :ed25519,
            label: nil,
            added_via: nil,
            added_at: nil,
            revoked_at: nil,
            revoked_by: nil

  @key_bytes 32

  @doc """
  Build a key from a client-supplied encoded public key.

  Accepts base64url (padded or not) and standard base64, because clients in
  different languages disagree about which one "base64" means and the failure is
  otherwise an opaque `invalid_request` at registration time. Hex is deliberately
  *not* accepted: a 64-character hex string is also valid base64, so accepting
  both makes some inputs ambiguous.
  """
  @spec new(String.t(), keyword()) ::
          {:ok, t()} | {:error, :malformed_key | :unsupported_alg}
  def new(encoded, opts \\ []) do
    with :ok <- check_alg(Keyword.get(opts, :alg, "ed25519")),
         {:ok, raw} <- decode(encoded) do
      {:ok,
       %__MODULE__{
         fingerprint: thumbprint(raw),
         account_id: Keyword.get(opts, :account_id),
         public_key: raw,
         alg: :ed25519,
         label: Keyword.get(opts, :label),
         added_via: Keyword.get(opts, :added_via),
         added_at: Keyword.get(opts, :added_at) || DateTime.utc_now()
       }}
    end
  end

  @doc """
  Decode an encoded Ed25519 public key to its 32 raw bytes.

  The length check is not cosmetic: `:crypto.verify/5` with a wrong-sized key
  raises rather than returning `false`, which would turn a malformed registration
  into a 500 at *verification* time — long after the bad row was accepted.
  """
  @spec decode(String.t()) :: {:ok, binary()} | {:error, :malformed_key}
  def decode(encoded) when is_binary(encoded) do
    candidates = [
      Base.url_decode64(encoded, padding: false),
      Base.url_decode64(encoded),
      Base.decode64(encoded, padding: false),
      Base.decode64(encoded)
    ]

    case Enum.find_value(candidates, fn
           {:ok, raw} when byte_size(raw) == @key_bytes -> raw
           _ -> nil
         end) do
      nil -> {:error, :malformed_key}
      raw -> {:ok, raw}
    end
  end

  def decode(_), do: {:error, :malformed_key}

  @doc "The canonical base64url (unpadded) encoding — what goes back over the wire."
  @spec encode(t() | binary()) :: String.t()
  def encode(%__MODULE__{public_key: raw}), do: encode(raw)
  def encode(raw) when is_binary(raw), do: Base.url_encode64(raw, padding: false)

  @doc """
  RFC 8037 JWK thumbprint of an Ed25519 public key, base64url unpadded.

  The JSON is built by hand rather than encoded from a map because RFC 7638
  requires exact lexicographic member order with no whitespace, and no JSON
  encoder guarantees that for a map.
  """
  @spec thumbprint(binary()) :: String.t()
  def thumbprint(raw) when byte_size(raw) == @key_bytes do
    x = Base.url_encode64(raw, padding: false)

    :sha256
    |> :crypto.hash(~s({"crv":"Ed25519","kty":"OKP","x":"#{x}"}))
    |> Base.url_encode64(padding: false)
  end

  @doc "Whether this key may still authenticate."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{revoked_at: nil}), do: true
  def active?(%__MODULE__{}), do: false

  @doc "Mark a key revoked. Idempotent — re-revoking keeps the original timestamp."
  @spec revoke(t(), String.t() | nil, DateTime.t()) :: t()
  def revoke(%__MODULE__{revoked_at: nil} = key, actor, at),
    do: %{key | revoked_at: at, revoked_by: actor}

  def revoke(%__MODULE__{} = key, _actor, _at), do: key

  @doc "Public view — never includes anything secret, because nothing here is."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = key) do
    %{
      "fingerprint" => key.fingerprint,
      "public_key" => encode(key),
      "alg" => "ed25519",
      "label" => key.label,
      "added_at" => key.added_at && DateTime.to_iso8601(key.added_at),
      "added_via" => key.added_via,
      "revoked_at" => key.revoked_at && DateTime.to_iso8601(key.revoked_at)
    }
  end

  defp check_alg(alg) when alg in ["ed25519", "Ed25519", "EdDSA", :ed25519], do: :ok
  defp check_alg(_), do: {:error, :unsupported_alg}
end
