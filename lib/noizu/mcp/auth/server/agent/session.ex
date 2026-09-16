defmodule Noizu.MCP.Auth.Server.Agent.Session do
  @moduledoc """
  The anonymous session an agent opens before it can do anything else.

  This is the "OAuth flow with no auth required" leg: a client `POST`s a public
  key and gets back a short-lived token, a session id and a **nonce**. It has
  proved nothing at this point — the session is `:anonymous` — but it now has:

    * a server-issued challenge to sign, which is what makes the next step
      replay-resistant (see `Noizu.MCP.Auth.Server.Agent.Assertion`);
    * a stable handle on "this client, this key" that registration can attach an
      account to;
    * an answer to *"do I already have an account?"*, so an agent that has run
      before skips registration instead of colliding on its own handle.

  ## Why the key is bound at session creation rather than at registration

  Binding here means the account created in the next step is provably tied to the
  key that opened the session, in one hop, with no window where a session exists
  for one key and gets an account for another. The thumbprint is carried on the
  issued token as `cnf.jkt` (RFC 7638 / RFC 8705 confirmation), so a session token
  lifted from a log cannot be used to register against a *different* key.

  ## Why the raw public key is carried, not just its thumbprint

  A thumbprint is a hash, so registration could not recover the key from it. The
  32 raw bytes ride along on the session and are what gets written to
  `agent_account_keys` in the next step. They are public material — there is
  nothing here to protect — but they must survive between the two requests, and
  the session is the only thing that spans them.

  ## `ip_hash`

  HMAC-SHA256 of the peer address under a server-held, rotatable salt. Enough to
  rate-limit and to let an admin reject a burst of registrations from one source;
  not enough to recover the address, and worthless once the salt rotates. That is
  the whole of "anonymous but tracked" — correlation within a window, no identity,
  ever.
  """

  @type level :: :anonymous | :agent | :human

  @type t :: %__MODULE__{
          id: String.t(),
          nonce: String.t(),
          level: level(),
          account_id: String.t() | nil,
          key_fingerprint: String.t() | nil,
          public_key: binary() | nil,
          client: map(),
          ip_hash: String.t() | nil,
          issued_at: DateTime.t(),
          expires_at: DateTime.t(),
          consumed_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil
        }

  defstruct id: nil,
            nonce: nil,
            level: :anonymous,
            account_id: nil,
            key_fingerprint: nil,
            public_key: nil,
            client: %{},
            ip_hash: nil,
            issued_at: nil,
            expires_at: nil,
            consumed_at: nil,
            revoked_at: nil

  @doc """
  Open a session.

  `:ttl` is seconds and should stay small — the session exists only to be signed
  against, and a long-lived challenge is a long-lived replay target.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    ttl = Keyword.get(opts, :ttl, 600)

    %__MODULE__{
      id: Keyword.get(opts, :id) || random(16),
      nonce: Keyword.get(opts, :nonce) || random(24),
      level: Keyword.get(opts, :level, :anonymous),
      account_id: Keyword.get(opts, :account_id),
      key_fingerprint: Keyword.get(opts, :key_fingerprint),
      public_key: Keyword.get(opts, :public_key),
      client: Keyword.get(opts, :client, %{}),
      ip_hash: Keyword.get(opts, :ip_hash),
      issued_at: now,
      expires_at: DateTime.add(now, ttl, :second)
    }
  end

  @doc """
  Whether this session can still be used to authenticate.

  Consumed counts as unusable: a session's nonce is good for exactly one
  successful assertion. Re-authenticating means opening a new session, which costs
  the agent one request and costs an attacker the entire replay strategy.
  """
  @spec usable?(t(), DateTime.t()) :: boolean()
  def usable?(%__MODULE__{} = session, now \\ DateTime.utc_now()) do
    is_nil(session.consumed_at) and is_nil(session.revoked_at) and
      DateTime.compare(now, session.expires_at) == :lt
  end

  @doc "Mark the session spent. Idempotent."
  @spec consume(t(), DateTime.t()) :: t()
  def consume(%__MODULE__{consumed_at: nil} = session, now), do: %{session | consumed_at: now}
  def consume(%__MODULE__{} = session, _now), do: session

  @doc """
  HMAC a peer address for correlation without identification.

  Takes the salt rather than reading it from config so that rotating the salt is
  a host decision and a test can pin it. `nil` in, `nil` out — a host that has no
  address (unix socket, stdio transport) records nothing rather than a hash of the
  empty string, which would collide every such client into one bucket.
  """
  @spec hash_ip(:inet.ip_address() | String.t() | nil, binary() | nil) :: String.t() | nil
  def hash_ip(nil, _salt), do: nil
  def hash_ip(_address, nil), do: nil

  def hash_ip(address, salt) do
    :hmac
    |> :crypto.mac(:sha256, salt, to_string_address(address))
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 22)
  end

  defp to_string_address(address) when is_binary(address), do: address

  defp to_string_address(address) when is_tuple(address) do
    case :inet.ntoa(address) do
      {:error, _} -> inspect(address)
      charlist -> List.to_string(charlist)
    end
  end

  defp to_string_address(other), do: inspect(other)

  defp random(bytes), do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
