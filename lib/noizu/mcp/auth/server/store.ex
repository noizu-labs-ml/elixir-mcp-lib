defmodule Noizu.MCP.Auth.Server.Store do
  @moduledoc """
  Persistence contract for the authorization-server facade.

  Two adapters ship: `Noizu.MCP.Auth.Server.Store.ETS` (in-memory, single node,
  fine for development and for a single-replica deployment that can afford to
  lose sessions on restart) and `Noizu.MCP.Auth.Server.Store.Ecto` (raw SQL, no
  Ecto schemas). A host may implement its own; `Noizu.MCP.Auth.Server.StoreConformance`
  in the test support tree is the test battery that says whether it works.

  ## The hashing rule

  **Every callback receives raw secrets and MUST hash them before persisting or
  comparing.** Authorization codes, refresh tokens, login-state keys and access
  token identifiers arrive in the clear; `Noizu.MCP.Auth.Server.Secret.token_hash/1`
  (SHA-256, lowercase hex) is what goes in the column. Hashing never lives in the
  caller — if it did, a caller that forgot would write plaintext and no adapter
  could tell.

  Client secrets are the exception in the other direction: they arrive
  **already** hashed on `%Client{secret_hash: …}`, because they are hashed with
  PBKDF2 and a salt at registration time and the adapter must not re-hash them.

  ## Argument order

  Every callback takes the adapter's own options as its **last** argument — the
  `store: {Module, opts}` pair from `Noizu.MCP.Auth.Server.config/1`. For
  `Store.Ecto` that carries `repo:`; for `Store.ETS` it carries `name:`.

  ## Optional callbacks

  `delete_client/2`, `revoke_subject_tokens/3`, `put_access_token/2`,
  `access_token_revoked?/2`, `revoke_access_token/2` and `purge_expired/2` are
  optional. `Noizu.MCP.Auth.Server.Store` provides `supports?/2` so callers can
  degrade rather than crash: with no access-token table an access token is valid
  until it expires, which is why the TTL is capped at 15 minutes.

  ## Atomicity

  `take_authorization_code/2` and `rotate_refresh_token/3` are the two
  callbacks where a race is a security bug rather than a glitch — two concurrent
  redemptions of one code, or of one refresh token, must not both succeed. Each
  must be a single atomic operation (one `UPDATE … WHERE used_at IS NULL
  RETURNING *`, or a serialized write), and each must distinguish "never existed"
  from **"already used"** — the latter is a replay, and a replay revokes the whole
  refresh family (RFC 6819 §5.2.2.3). An adapter that returns `:not_found` for a
  replay silently disables reuse detection.
  """

  alias Noizu.MCP.Auth.Server.Client

  @typedoc "Adapter options — the second element of `store: {Module, opts}`."
  @type opts :: keyword()

  @typedoc "Raw, unhashed credential as presented by a client."
  @type raw :: String.t()

  @typedoc """
  Opaque per-adapter reason. Never rendered to a client: the endpoints map every
  store failure onto a fixed OAuth error.
  """
  @type reason :: atom() | {atom(), term()}

  defmodule AuthorizationCode do
    @moduledoc """
    A pending authorization code. `code` is raw on the way in and is **never**
    stored; the adapter persists `Secret.token_hash(code)`.

    `refresh_family_id` is allocated at code issuance so that the refresh token
    minted from this code, and every rotation after it, share one family — which
    is what makes family revocation on replay possible.
    """
    @type t :: %__MODULE__{
            code: String.t() | nil,
            client_id: String.t(),
            subject: String.t(),
            redirect_uri: String.t(),
            scope: [String.t()],
            resource: String.t() | nil,
            code_challenge: String.t(),
            code_challenge_method: String.t(),
            nonce: String.t() | nil,
            refresh_family_id: String.t() | nil,
            upstream_ref: map() | nil,
            expires_at: DateTime.t(),
            used_at: DateTime.t() | nil,
            inserted_at: DateTime.t() | nil
          }

    defstruct code: nil,
              client_id: nil,
              subject: nil,
              redirect_uri: nil,
              scope: [],
              resource: nil,
              code_challenge: nil,
              code_challenge_method: "S256",
              nonce: nil,
              refresh_family_id: nil,
              upstream_ref: nil,
              expires_at: nil,
              used_at: nil,
              inserted_at: nil
  end

  defmodule RefreshToken do
    @moduledoc """
    A refresh token. `token` is raw on the way in and never stored.

    `family_id` groups a token with every token it has been rotated into.
    `family_expires_at` is an absolute ceiling: rotation extends a token's own
    life but never the family's, so a stolen-and-rotated chain cannot live
    forever.
    """
    @type t :: %__MODULE__{
            id: String.t() | nil,
            token: String.t() | nil,
            client_id: String.t(),
            subject: String.t(),
            scope: [String.t()],
            resource: String.t() | nil,
            family_id: String.t(),
            rotated_to: String.t() | nil,
            rotated_at: DateTime.t() | nil,
            revoked_at: DateTime.t() | nil,
            expires_at: DateTime.t(),
            family_expires_at: DateTime.t() | nil,
            inserted_at: DateTime.t() | nil
          }

    defstruct id: nil,
              token: nil,
              client_id: nil,
              subject: nil,
              scope: [],
              resource: nil,
              family_id: nil,
              rotated_to: nil,
              rotated_at: nil,
              revoked_at: nil,
              expires_at: nil,
              family_expires_at: nil,
              inserted_at: nil
  end

  defmodule Consent do
    @moduledoc """
    A recorded grant of scope by a subject to a client. Unique on
    `{subject, client_id}`; `scope` is the union granted so far, so a request for
    a scope outside it re-prompts (the spec's confused-deputy requirement).
    """
    @type t :: %__MODULE__{
            subject: String.t(),
            client_id: String.t(),
            scope: [String.t()],
            resource: String.t() | nil,
            granted_at: DateTime.t() | nil,
            expires_at: DateTime.t() | nil
          }

    defstruct subject: nil,
              client_id: nil,
              scope: [],
              resource: nil,
              granted_at: nil,
              expires_at: nil
  end

  defmodule AccessToken do
    @moduledoc """
    An issued access token, tracked **only** when `track_access_tokens: true`.
    `jti` is raw on the way in; the adapter stores its hash. Tracking buys
    immediate revocation; not tracking means a token is good until it expires,
    which is why the TTL ceiling is 15 minutes.
    """
    @type t :: %__MODULE__{
            jti: String.t(),
            client_id: String.t(),
            subject: String.t(),
            scope: [String.t()],
            resource: String.t() | nil,
            family_id: String.t() | nil,
            expires_at: DateTime.t(),
            revoked_at: DateTime.t() | nil
          }

    defstruct jti: nil,
              client_id: nil,
              subject: nil,
              scope: [],
              resource: nil,
              family_id: nil,
              expires_at: nil,
              revoked_at: nil
  end

  # ── clients ──────────────────────────────────────────────────────────────

  @doc """
  Fetch a client by its `client_id`.

  For a CIMD client the `client_id` is an https URL; the adapter does not care.
  Returning `{:error, :not_found}` for an unresolvable client is what keeps the
  authorization endpoint from redirecting anywhere.
  """
  @callback get_client(client_id :: String.t(), opts()) ::
              {:ok, Client.t()} | {:error, :not_found} | {:error, reason()}

  @doc "Insert or replace a client. `secret_hash` arrives already hashed."
  @callback put_client(Client.t(), opts()) :: {:ok, Client.t()} | {:error, reason()}

  @doc "Delete a client. Optional."
  @callback delete_client(client_id :: String.t(), opts()) :: :ok | {:error, reason()}

  # ── login state (the upstream round trip) ────────────────────────────────

  @doc """
  Store the state carried across the upstream IdP round trip, keyed by a raw
  `state` value the adapter hashes. `ttl` is in seconds — login state is
  short-lived by construction, so an adapter may expire it eagerly.

  The payload holds the pending authorization request (client_id, redirect_uri,
  scope, resource, PKCE challenge, the client's own `state`) plus CSRF material.
  """
  @callback put_login_state(state :: raw(), payload :: map(), ttl :: pos_integer(), opts()) ::
              :ok | {:error, reason()}

  @doc "Read login state without consuming it (the consent screen re-renders)."
  @callback get_login_state(state :: raw(), opts()) ::
              {:ok, map()} | {:error, :not_found} | {:error, reason()}

  @doc """
  Merge changes into stored login state — how a consent decision or a resolved
  upstream subject is recorded without a second round trip.
  """
  @callback update_login_state(state :: raw(), changes :: map(), opts()) ::
              {:ok, map()} | {:error, :not_found} | {:error, reason()}

  @doc """
  Consume login state: read and delete atomically, so one callback cannot be
  replayed into two authorization codes.
  """
  @callback take_login_state(state :: raw(), opts()) ::
              {:ok, map()} | {:error, :not_found} | {:error, reason()}

  # ── authorization codes ──────────────────────────────────────────────────

  @doc "Persist a pending authorization code. `code` is raw; store its hash."
  @callback put_authorization_code(AuthorizationCode.t(), opts()) :: :ok | {:error, reason()}

  @doc """
  Redeem a code **atomically and exactly once**.

    * `{:ok, code}` — redeemed now, by this call, for the first time
    * `{:error, :not_found}` — no such code, or it expired
    * `{:error, {:replayed, code}}` — it existed and had already been redeemed.
      The caller revokes `code.refresh_family_id` and answers `invalid_grant`.

  Collapsing the third case into the second disables replay detection, so it is
  part of the contract, not a nicety.
  """
  @callback take_authorization_code(code :: raw(), opts()) ::
              {:ok, AuthorizationCode.t()}
              | {:error, :not_found}
              | {:error, {:replayed, AuthorizationCode.t()}}
              | {:error, reason()}

  @doc """
  Attach a refresh family to an already-stored code.

  Used when the family is allocated after the code row is written (an upstream
  flow that resolves the subject late). Idempotent.
  """
  @callback bind_authorization_code_family(code :: raw(), family_id :: String.t(), opts()) ::
              :ok | {:error, :not_found} | {:error, reason()}

  # ── refresh tokens ───────────────────────────────────────────────────────

  @doc "Persist a refresh token. `token` is raw; store its hash."
  @callback put_refresh_token(RefreshToken.t(), opts()) :: :ok | {:error, reason()}

  @doc "Look a refresh token up by its raw value, without consuming it."
  @callback get_refresh_token(token :: raw(), opts()) ::
              {:ok, RefreshToken.t()} | {:error, :not_found} | {:error, reason()}

  @doc """
  Rotate `old_token` into `new_token` **atomically**, returning the old record.

    * `{:ok, old}` — rotated now, by this call
    * `{:error, :not_found}` — unknown, expired, or revoked
    * `{:error, {:replayed, old}}` — already rotated. This is the reuse-detection
      signal: the caller revokes `old.family_id` in full and answers
      `invalid_grant`, on the assumption that either the client or an attacker
      holds a copy, and there is no way to tell which.

  `new_token.token` is raw; store its hash. The new row must carry the old row's
  `family_id` and `family_expires_at`.
  """
  @callback rotate_refresh_token(old_token :: raw(), new_token :: RefreshToken.t(), opts()) ::
              {:ok, RefreshToken.t()}
              | {:error, :not_found}
              | {:error, {:replayed, RefreshToken.t()}}
              | {:error, reason()}

  @doc "Revoke a single refresh token (RFC 7009). Revoking an unknown token is `:ok`."
  @callback revoke_refresh_token(token :: raw(), opts()) :: :ok | {:error, reason()}

  @doc "Revoke every refresh token in a family. Called on replay detection and on logout."
  @callback revoke_refresh_family(family_id :: String.t(), opts()) :: :ok | {:error, reason()}

  @doc """
  Revoke every refresh token a subject holds, optionally narrowed to one client.
  Optional; `client_id` may be `nil` for "all clients".
  """
  @callback revoke_subject_tokens(subject :: String.t(), client_id :: String.t() | nil, opts()) ::
              :ok | {:error, reason()}

  # ── consent ──────────────────────────────────────────────────────────────

  @doc "Fetch a subject's recorded consent for a client."
  @callback get_consent(subject :: String.t(), client_id :: String.t(), opts()) ::
              {:ok, Consent.t()} | {:error, :not_found} | {:error, reason()}

  @doc "Record consent, replacing any prior row for the same `{subject, client_id}`."
  @callback put_consent(Consent.t(), opts()) :: :ok | {:error, reason()}

  @doc "Withdraw consent. Withdrawing consent that was never given is `:ok`."
  @callback revoke_consent(subject :: String.t(), client_id :: String.t(), opts()) ::
              :ok | {:error, reason()}

  # ── access tokens (optional: `track_access_tokens: true`) ────────────────

  @doc "Record an issued access token. Optional. `jti` is raw; store its hash."
  @callback put_access_token(AccessToken.t(), opts()) :: :ok | {:error, reason()}

  @doc """
  Whether an access token has been revoked. Optional.

  **Fails closed for the caller**: a verifier that cannot reach the store treats
  the token as revoked rather than as valid.
  """
  @callback access_token_revoked?(jti :: raw(), opts()) :: boolean() | {:error, reason()}

  @doc "Revoke a single access token by `jti`. Optional."
  @callback revoke_access_token(jti :: raw(), opts()) :: :ok | {:error, reason()}

  @doc """
  Delete everything that expired before `now`. Optional.

  The host owns the schedule (a 15-minute Oban job); the library never starts a
  sweeper of its own. Returns per-table counts for logging.
  """
  @callback purge_expired(now :: DateTime.t(), opts()) ::
              {:ok, %{optional(atom()) => non_neg_integer()}} | {:error, reason()}

  @optional_callbacks delete_client: 2,
                      revoke_subject_tokens: 3,
                      put_access_token: 2,
                      access_token_revoked?: 2,
                      revoke_access_token: 2,
                      purge_expired: 2

  @doc """
  Whether an adapter implements an optional callback.

      Store.supports?(Store.ETS, {:purge_expired, 2})
  """
  @spec supports?(module(), {atom(), arity()}) :: boolean()
  def supports?(adapter, {fun, arity}) do
    Code.ensure_loaded?(adapter) and function_exported?(adapter, fun, arity)
  end

  @doc "A random opaque credential — authorization codes, refresh tokens, state keys."
  @spec generate_token() :: String.t()
  def generate_token, do: Noizu.MCP.Auth.Server.Secret.generate(32)

  @doc """
  A random family/row identifier, formatted as a UUIDv4 string so it fits a
  Postgres `uuid` column without the library depending on a UUID package.
  """
  @spec generate_id() :: String.t()
  def generate_id do
    <<a::binary-4, b::binary-2, _::4, c::12, _::2, d::14, e::binary-6>> =
      :crypto.strong_rand_bytes(16)

    # `4::4` is the version nibble, `2::2` the RFC 4122 variant bits.
    [a, b, <<4::4, c::12>>, <<2::2, d::14>>, e]
    |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
  end
end
