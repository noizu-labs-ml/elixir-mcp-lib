defmodule Noizu.MCP.Auth.Server.Agent do
  @moduledoc """
  Anonymous-but-tracked authentication for MCP agents.

  An autonomous agent has no email, no operator to click a confirmation link, and
  nothing a password-based flow can hang identity on. What it does have is a
  keypair. This module lets it bootstrap an account from that keypair alone, and
  lets a host keep a kill switch over what those accounts may do.

  ## The flow

      1. POST /oauth/session   {public_key}                → L0 token + session id + nonce
      2. POST /oauth/agents    {handle, …}       [L0]      → account, status: pending
      3. POST /oauth/token     grant=jwt-bearer, assertion → L1 token, amr: ["sig"]
      4. POST /oauth/keys      {public_key, two proofs}    [L1, amr must contain "sig"]

  Step 1 requires no credentials at all — that is the "OAuth flow with no auth
  required". Step 2 is skipped by an agent that has run before: step 1 already
  told it whether its key is known. Step 3 is an ordinary RFC 7523
  `private_key_jwt` exchange, so a client that speaks OAuth needs no bespoke code.

  ## What `amr: ["sig"]` buys

  Key management is gated on the token having been obtained by *signature*, not
  merely on the token being valid. A password-authenticated human token cannot add
  a key to an agent account, and neither can an admin token — an admin may revoke
  a key as a moderation action, but granting one would let an operator mint an
  identity that signs as somebody else. Everything an account is rests on its
  keys, so only a current key may nominate the next one.

  ## Pending accounts still get tokens

  `:pending` authenticates. An agent that cannot obtain a token cannot read why it
  was refused, cannot rotate a key while it waits, and has no way to poll for
  approval except by retrying registration — which is precisely the traffic an
  approval queue least wants. It gets a real token whose `st` claim says
  `pending`, and the host's contribution scopes are withheld until an admin acts.

  ## What is deliberately not here

  No I/O policy, no rate limiting, no admin UI. Rate limiting is the host's
  (`:rate_limit` on the config), because only the host knows what its edge already
  does. Approval is a host decision surfaced through `set_status/4`.
  """

  alias Noizu.MCP.Auth.Server.Agent.Account
  alias Noizu.MCP.Auth.Server.Agent.Assertion
  alias Noizu.MCP.Auth.Server.Agent.Key
  alias Noizu.MCP.Auth.Server.Agent.Session
  alias Noizu.MCP.Auth.Server.Config
  alias Noizu.MCP.Auth.Server.Store
  alias Noizu.MCP.Auth.Server.Tokens
  alias Noizu.MCP.Auth.JWTVerifier

  @required_callbacks [
    put_agent_account: 2,
    get_agent_account: 2,
    get_agent_account_by_handle: 2,
    put_agent_key: 2,
    get_agent_key: 2,
    list_agent_keys: 2,
    put_agent_session: 2,
    get_agent_session: 2,
    consume_agent_session: 3,
    claim_assertion_jti: 3
  ]

  @typedoc """
  A fixed, machine-readable failure code.

  Agents branch on these, so they are part of the contract and must not be
  reworded into prose. `account_pending` in particular is what tells a well-behaved
  agent to back off rather than retry registration in a loop.
  """
  @type error_code ::
          :agent_auth_disabled
          | :invalid_public_key
          | :invalid_session
          | :session_replayed
          | :handle_taken
          | :handle_invalid
          | :already_registered
          | :invalid_assertion
          | :assertion_replayed
          | :unknown_key
          | :key_revoked
          | :account_pending
          | :account_rejected
          | :account_suspended
          | :signature_required
          | :key_limit_reached
          | :key_already_known
          | :last_key
          | :not_found
          | :store_error

  @doc """
  Which agent callbacks an adapter is missing.

  `[]` means the adapter can serve anonymous keypair auth. A non-empty list is a
  boot-time error rather than a runtime one — see `Noizu.MCP.Auth.Server.config/1`.
  Partial implementation is always a mistake: the flow needs every one of these to
  complete a single registration.
  """
  @spec missing_callbacks(module()) :: [{atom(), arity()}]
  def missing_callbacks(adapter) do
    Enum.reject(@required_callbacks, &Store.supports?(adapter, &1))
  end

  @doc "Whether this config can serve anonymous keypair auth."
  @spec supported?(Config.t()) :: boolean()
  def supported?(%Config{} = config) do
    {adapter, _} = Config.store(config)
    Config.agent_auth?(config) and missing_callbacks(adapter) == []
  end

  # ── step 1: open an anonymous session ────────────────────────────────────

  @doc """
  Open an anonymous session bound to a public key.

  No credentials required. Returns the L0 token, the session id, the nonce to sign,
  and — crucially — whether this key already has an account, so a returning agent
  skips registration instead of colliding on its own handle.

  `opts` accepts `:remote_ip` (hashed, never stored raw) and `:now`.
  """
  @spec start_session(Config.t(), map(), keyword()) ::
          {:ok, map()} | {:error, error_code()}
  def start_session(%Config{} = config, params, opts \\ []) do
    with :ok <- ensure_enabled(config),
         {:ok, key} <- build_key(params) do
      now = Keyword.get(opts, :now) || DateTime.utc_now()

      session =
        Session.new(
          ttl: Config.agent_auth(config, :session_ttl),
          key_fingerprint: key.fingerprint,
          public_key: key.public_key,
          client: sanitize_client(Map.get(params, "client")),
          ip_hash: Session.hash_ip(Keyword.get(opts, :remote_ip), ip_salt(config)),
          now: now
        )

      # Look the account up *before* persisting, so a store failure cannot leave a
      # usable session pointing at an account we never confirmed exists.
      account = existing_account(config, key)
      session = %{session | account_id: account && account.id}

      case call_store(config, :put_agent_session, [session]) do
        :ok ->
          {:ok,
           %{
             "session_token" => session_token(config, session, key),
             "session_id" => session.id,
             "nonce" => session.nonce,
             "expires_in" => DateTime.diff(session.expires_at, now),
             "key_fingerprint" => key.fingerprint,
             "token_endpoint" => Config.url(config, :token),
             "account" => account && Account.to_map(account),
             "registration_required" => is_nil(account)
           }}

        _ ->
          {:error, :store_error}
      end
    end
  end

  # ── step 2: register ─────────────────────────────────────────────────────

  @doc """
  Create a `:pending` account and bind the session's key to it.

  Requires a live L0 token. The key comes from the *session*, never from the
  request body: binding it at session creation and reading it back here removes
  the window in which a session opened for one key could acquire an account for
  another.
  """
  @spec register(Config.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, error_code()}
  def register(%Config{} = config, session_token, params, opts \\ []) do
    with :ok <- ensure_enabled(config),
         {:ok, session} <- live_session(config, session_token, opts),
         {:ok, key} <- session_key(config, session),
         {:ok, account} <- build_account(params),
         :ok <- ensure_handle_free(config, account.handle) do
      now = Keyword.get(opts, :now) || DateTime.utc_now()
      key = %{key | account_id: account.id, added_via: "registration", added_at: now}

      with :ok <- call_store(config, :put_agent_account, [account]),
           :ok <- call_store(config, :put_agent_key, [key]) do
        audit(config, account.id, "account.registered", %{
          "handle" => account.handle,
          "fingerprint" => key.fingerprint,
          "ip_hash" => session.ip_hash
        })

        {:ok, %{"account" => Account.to_map(account), "key" => Key.to_map(key)}}
      else
        _ -> {:error, :store_error}
      end
    end
  end

  # ── step 3: authenticate ─────────────────────────────────────────────────

  @doc """
  Trade a signed assertion for an access token.

  This is the RFC 7523 `jwt-bearer` grant. Verification order matters and is not
  arbitrary: cheap structural checks run before any store lookup, the signature is
  checked before the session is spent, and the session is spent before the token
  is minted. A failure after the session is consumed must never be recoverable by
  retrying the same assertion — that is the whole point of consuming it.

  Returns a standard OAuth token response.
  """
  @spec authenticate(Config.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, error_code()}
  def authenticate(%Config{} = config, assertion, params \\ %{}, opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    with :ok <- ensure_enabled(config),
         {:ok, parsed} <- parse_assertion(assertion),
         {:ok, key} <- active_key(config, parsed.kid),
         {:ok, account} <- fetch_account(config, key.account_id),
         :ok <- ensure_authenticatable(account),
         {:ok, claims} <- verify_assertion(config, parsed, key, account, now),
         :ok <- claim_jti(config, claims),
         {:ok, _session} <- spend_session(config, claims) do
      audit(config, account.id, "account.authenticated", %{"fingerprint" => key.fingerprint})

      {:ok, access_token(config, account, key, params, now)}
    end
  end

  # ── step 4: key management (requires amr: ["sig"]) ───────────────────────

  @doc "Every key on the caller's account, revoked ones included."
  @spec list_keys(Config.t(), map()) :: {:ok, map()} | {:error, error_code()}
  def list_keys(%Config{} = config, claims) do
    with {:ok, account} <- caller_account(config, claims),
         {:ok, keys} <- fetch_keys(config, account.id) do
      {:ok, %{"keys" => Enum.map(keys, &Key.to_map/1)}}
    end
  end

  @doc """
  Add a key, given proof of possession of both the old and the new one.

  Two signatures are required and neither is redundant:

    * `proof_existing` — a JWS signed by a key **already** on the account, over the
      new key's thumbprint. Without it, a stolen bearer token is enough to graft a
      permanent identity onto the account, which would make token theft
      unrecoverable rather than merely bad.
    * `proof_new` — a self-signature by the key being added. Without it, an agent
      can register a public key it does not hold the private half of, which sounds
      harmless until you notice it lets one account park another party's key and
      make that party's future signatures ambiguous.

  Both are bound to `op: "add_key"` and to the new key's thumbprint, so a signature
  gathered for any other purpose cannot be presented here.
  """
  @spec add_key(Config.t(), map(), map()) :: {:ok, map()} | {:error, error_code()}
  def add_key(%Config{} = config, claims, params) do
    with :ok <- ensure_signature_auth(claims),
         {:ok, account} <- caller_account(config, claims),
         {:ok, new_key} <- build_key(params),
         {:ok, keys} <- fetch_keys(config, account.id),
         :ok <- ensure_key_budget(config, keys),
         :ok <- ensure_key_unknown(config, account, new_key, keys),
         :ok <- verify_proof(config, params, "proof_new", new_key, account, new_key.fingerprint),
         {:ok, signer} <- resolve_signer(config, params, account, new_key.fingerprint) do
      now = DateTime.utc_now()

      key = %{
        new_key
        | account_id: account.id,
          label: string_or_nil(Map.get(params, "label")),
          added_via: signer.fingerprint,
          added_at: now
      }

      case call_store(config, :put_agent_key, [key]) do
        :ok ->
          audit(config, account.id, "key.added", %{
            "fingerprint" => key.fingerprint,
            "added_via" => signer.fingerprint
          })

          {:ok, Key.to_map(key)}

        _ ->
          {:error, :store_error}
      end
    end
  end

  @doc """
  Revoke a key.

  Refuses to remove the account's last active key unless a password credential
  exists, because the result would be an account nobody — not even an admin — can
  authenticate as. Two concurrent revocations could still race past that check; the
  window is small, the consequence is a lockout rather than a compromise, and an
  admin can restore access by approving a fresh registration. Closing it properly
  needs an atomic store callback, which is not worth the contract for the risk.
  """
  @spec revoke_key(Config.t(), map(), String.t()) :: {:ok, map()} | {:error, error_code()}
  def revoke_key(%Config{} = config, claims, fingerprint) do
    with :ok <- ensure_signature_auth(claims),
         {:ok, account} <- caller_account(config, claims),
         {:ok, keys} <- fetch_keys(config, account.id),
         {:ok, key} <- find_key(keys, fingerprint),
         :ok <- ensure_not_last_key(config, account, keys, key) do
      revoked = Key.revoke(key, account.id, DateTime.utc_now())

      case call_store(config, :put_agent_key, [revoked]) do
        :ok ->
          audit(config, account.id, "key.revoked", %{"fingerprint" => fingerprint})
          {:ok, Key.to_map(revoked)}

        _ ->
          {:error, :store_error}
      end
    end
  end

  @doc "The caller's own account and keys — what an agent calls to find out who it is."
  @spec whoami(Config.t(), map()) :: {:ok, map()} | {:error, error_code()}
  def whoami(%Config{} = config, claims) do
    with {:ok, account} <- caller_account(config, claims),
         {:ok, keys} <- fetch_keys(config, account.id) do
      {:ok,
       Map.merge(Account.to_map(account), %{
         "keys" => keys |> Enum.filter(&Key.active?/1) |> Enum.map(&Key.to_map/1),
         "scope" => scopes_for(config, account),
         "authenticated_by" => Map.get(claims, "amr", [])
       })}
    end
  end

  # ── admin ────────────────────────────────────────────────────────────────

  @doc """
  Apply an admin decision to an account.

  `:rejected` and `:suspended` bump the account's revocation epoch, which
  invalidates tokens already in flight. Without that, a suspension would not take
  effect until the offending token expired — up to fifteen minutes of continued
  writes after a human decided to stop them.
  """
  @spec set_status(Config.t(), String.t(), Account.status(), keyword()) ::
          {:ok, map()} | {:error, error_code()}
  def set_status(%Config{} = config, account_id, status, opts \\ []) do
    with {:ok, account} <- fetch_account(config, account_id),
         {:ok, updated} <- apply_status(account, status, opts),
         :ok <- call_store(config, :put_agent_account, [updated]) do
      audit(config, account_id, "account.#{status}", %{
        "actor" => Keyword.get(opts, :actor),
        "reason" => Keyword.get(opts, :reason)
      })

      {:ok, Account.to_map(updated)}
    else
      {:error, code} when is_atom(code) -> {:error, code}
      _ -> {:error, :store_error}
    end
  end

  @doc "Accounts for an admin queue. Requires the optional `list_agent_accounts/2`."
  @spec list_accounts(Config.t(), keyword()) :: {:ok, [map()]} | {:error, error_code()}
  def list_accounts(%Config{} = config, filter \\ []) do
    {adapter, _} = Config.store(config)

    if Store.supports?(adapter, {:list_agent_accounts, 2}) do
      case call_store(config, :list_agent_accounts, [filter]) do
        {:ok, accounts} -> {:ok, Enum.map(accounts, &Account.to_map/1)}
        _ -> {:error, :store_error}
      end
    else
      {:error, :store_error}
    end
  end

  # ── tokens ───────────────────────────────────────────────────────────────

  @doc """
  Verify an agent token minted by this server.

  Tries the issuer audience first, then each configured resource, because an agent
  may hold either an AS-scoped token (what the key endpoints want) or a
  resource-bound one (what an MCP mount wants), and both are legitimately "this
  agent". Returns the claims, with the account's current revocation epoch already
  checked — a token whose epoch is stale is refused even though its signature and
  expiry are fine.
  """
  @spec verify_token(Config.t(), String.t()) :: {:ok, map()} | {:error, error_code()}
  def verify_token(%Config{} = config, token) do
    audiences = [config.issuer | Config.resource_uris(config)]

    result =
      Enum.find_value(audiences, fn audience ->
        case JWTVerifier.verify(token, nil, Tokens.verifier_opts(config, audience)) do
          {:ok, claims} -> {:ok, claims}
          _ -> nil
        end
      end)

    with {:ok, claims} <- result || {:error, :invalid_session},
         {:ok, account} <- fetch_account(config, Map.get(claims, "act")),
         :ok <- ensure_epoch(claims, account) do
      {:ok, claims}
    end
  end

  @doc "Scopes an account is entitled to right now."
  @spec scopes_for(Config.t(), Account.t()) :: [String.t()]
  def scopes_for(%Config{} = config, %Account{} = account) do
    if Account.approved?(account) or not Config.agent_auth(config, :require_approval),
      do: Config.agent_auth(config, :approved_scope),
      else: Config.agent_auth(config, :pending_scope)
  end

  @doc """
  HTTP status and body for a failure code.

  One table, so an endpoint cannot invent a status that contradicts what another
  endpoint returns for the same condition.
  """
  @spec error(error_code()) :: {pos_integer(), map()}
  def error(code) do
    {status, description} = Map.get(error_table(), code, {400, "The request was refused."})
    {status, %{"error" => Atom.to_string(code), "error_description" => description}}
  end

  defp error_table do
    %{
      agent_auth_disabled: {404, "Anonymous agent authentication is not enabled here."},
      invalid_public_key: {400, "public_key must be a base64 or base64url Ed25519 key."},
      invalid_session: {401, "The session token is missing, invalid or expired."},
      session_replayed: {401, "That session has already been used. Open a new one."},
      handle_taken: {409, "That handle is already registered."},
      handle_invalid: {400, "Handle must be 3-32 characters of a-z, 0-9, - or _."},
      already_registered: {409, "This key already belongs to an account."},
      invalid_assertion: {400, "The assertion is malformed or its signature did not verify."},
      assertion_replayed: {401, "That assertion has already been used."},
      unknown_key: {401, "That key is not registered."},
      key_revoked: {401, "That key has been revoked."},
      account_pending: {403, "This account is awaiting approval."},
      account_rejected: {403, "This account was rejected."},
      account_suspended: {403, "This account is suspended."},
      signature_required: {403, "This operation requires a token obtained by key signature."},
      key_limit_reached: {409, "This account has reached its key limit."},
      key_already_known: {409, "That key is already on this account."},
      last_key: {409, "An account must keep at least one active key."},
      not_found: {404, "Not found."},
      store_error: {500, "The request could not be completed."}
    }
  end

  # ── internals ────────────────────────────────────────────────────────────

  defp ensure_enabled(config) do
    if supported?(config), do: :ok, else: {:error, :agent_auth_disabled}
  end

  defp build_key(params) do
    case Key.new(Map.get(params, "public_key") || "", alg: Map.get(params, "alg", "ed25519")) do
      {:ok, key} -> {:ok, key}
      {:error, _} -> {:error, :invalid_public_key}
    end
  end

  defp build_account(params) do
    opts = [
      handle: Map.get(params, "handle"),
      kind: Map.get(params, "kind", :agent),
      display_name: string_or_nil(Map.get(params, "display_name")),
      profile: sanitize_client(Map.get(params, "profile"))
    ]

    case Account.new(opts) do
      {:ok, account} -> {:ok, account}
      {:error, _} -> {:error, :handle_invalid}
    end
  end

  defp existing_account(config, %Key{fingerprint: fingerprint}) do
    with {:ok, key} <- call_store(config, :get_agent_key, [fingerprint]),
         true <- Key.active?(key),
         {:ok, account} <- call_store(config, :get_agent_account, [key.account_id]) do
      account
    else
      _ -> nil
    end
  end

  defp ensure_handle_free(config, handle) do
    case call_store(config, :get_agent_account_by_handle, [handle]) do
      {:error, :not_found} -> :ok
      {:ok, _} -> {:error, :handle_taken}
      _ -> {:error, :store_error}
    end
  end

  defp live_session(config, token, opts) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    with {:ok, claims} <-
           (case JWTVerifier.verify(token || "", nil, Tokens.verifier_opts(config, config.issuer)) do
              {:ok, claims} -> {:ok, claims}
              _ -> {:error, :invalid_session}
            end),
         sid when is_binary(sid) <- Map.get(claims, "sid") || {:error, :invalid_session},
         {:ok, session} <- session_by_id(config, sid),
         true <- Session.usable?(session, now) || {:error, :invalid_session} do
      {:ok, session}
    else
      {:error, code} -> {:error, code}
      _ -> {:error, :invalid_session}
    end
  end

  defp session_by_id(config, sid) do
    case call_store(config, :get_agent_session, [sid]) do
      {:ok, session} -> {:ok, session}
      {:error, :not_found} -> {:error, :invalid_session}
      _ -> {:error, :store_error}
    end
  end

  # The session is the only thing spanning steps 1 and 2, so it carries the raw
  # key. A fingerprint alone could not be reversed into one, and taking the key
  # from the request body instead would reopen exactly the substitution window
  # that binding it at session creation closes.
  defp session_key(_config, %Session{public_key: nil}), do: {:error, :invalid_session}

  defp session_key(config, %Session{public_key: raw, key_fingerprint: fingerprint}) do
    case call_store(config, :get_agent_key, [fingerprint]) do
      {:ok, _existing} ->
        {:error, :already_registered}

      {:error, :not_found} ->
        {:ok,
         %Key{
           fingerprint: fingerprint,
           public_key: raw,
           alg: :ed25519,
           added_at: DateTime.utc_now()
         }}

      _ ->
        {:error, :store_error}
    end
  end

  defp parse_assertion(assertion) do
    case Assertion.parse(assertion || "") do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> {:error, :invalid_assertion}
    end
  end

  defp active_key(config, fingerprint) do
    case call_store(config, :get_agent_key, [fingerprint]) do
      {:ok, key} -> if Key.active?(key), do: {:ok, key}, else: {:error, :key_revoked}
      {:error, :not_found} -> {:error, :unknown_key}
      _ -> {:error, :store_error}
    end
  end

  defp fetch_account(_config, nil), do: {:error, :not_found}

  defp fetch_account(config, id) do
    case call_store(config, :get_agent_account, [id]) do
      {:ok, account} -> {:ok, account}
      {:error, :not_found} -> {:error, :not_found}
      _ -> {:error, :store_error}
    end
  end

  defp fetch_keys(config, account_id) do
    case call_store(config, :list_agent_keys, [account_id]) do
      {:ok, keys} -> {:ok, keys}
      _ -> {:error, :store_error}
    end
  end

  defp ensure_authenticatable(%Account{status: :pending}), do: :ok
  defp ensure_authenticatable(%Account{status: :approved}), do: :ok
  defp ensure_authenticatable(%Account{status: :rejected}), do: {:error, :account_rejected}
  defp ensure_authenticatable(%Account{status: :suspended}), do: {:error, :account_suspended}

  defp verify_assertion(config, parsed, key, account, now) do
    opts = [
      public_key: key.public_key,
      audience: Config.url(config, :token),
      account_id: account.id,
      handle: account.handle,
      now: now,
      skew: Config.agent_auth(config, :clock_skew),
      max_age: Config.agent_auth(config, :assertion_max_age),
      require: ["sid", "nonce"]
    ]

    case Assertion.verify(parsed, opts) do
      {:ok, claims} -> {:ok, claims}
      {:error, _} -> {:error, :invalid_assertion}
    end
  end

  defp claim_jti(config, claims) do
    expires_at = claims |> Map.get("exp") |> DateTime.from_unix!()

    case call_store(config, :claim_assertion_jti, [Map.get(claims, "jti"), expires_at]) do
      :ok -> :ok
      {:error, :replayed} -> {:error, :assertion_replayed}
      _ -> {:error, :store_error}
    end
  end

  defp spend_session(config, claims) do
    case call_store(config, :consume_agent_session, [
           Map.get(claims, "sid"),
           Map.get(claims, "nonce")
         ]) do
      {:ok, session} -> {:ok, session}
      {:error, :replayed} -> {:error, :session_replayed}
      {:error, :not_found} -> {:error, :invalid_session}
      _ -> {:error, :store_error}
    end
  end

  defp ensure_signature_auth(claims) do
    if "sig" in List.wrap(Map.get(claims, "amr")),
      do: :ok,
      else: {:error, :signature_required}
  end

  defp caller_account(config, claims) do
    with {:ok, account} <- fetch_account(config, Map.get(claims, "act")),
         :ok <- ensure_epoch(claims, account) do
      {:ok, account}
    end
  end

  defp ensure_epoch(claims, %Account{revocation_epoch: epoch}) do
    if Map.get(claims, "epoch", 0) == epoch, do: :ok, else: {:error, :invalid_session}
  end

  defp ensure_key_budget(config, keys) do
    active = Enum.count(keys, &Key.active?/1)
    if active < Config.agent_auth(config, :max_keys), do: :ok, else: {:error, :key_limit_reached}
  end

  # A fingerprint already on the account is refused whether or not it is revoked:
  # silently reviving a revoked key would undo a revocation decision.
  defp ensure_key_unknown(config, _account, %Key{fingerprint: fingerprint}, keys) do
    cond do
      Enum.any?(keys, &(&1.fingerprint == fingerprint)) ->
        {:error, :key_already_known}

      match?({:ok, _}, call_store(config, :get_agent_key, [fingerprint])) ->
        {:error, :already_registered}

      true ->
        :ok
    end
  end

  defp resolve_signer(config, params, account, subject_fingerprint) do
    with {:ok, parsed} <- parse_proof(Map.get(params, "proof_existing")),
         {:ok, key} <- active_key(config, parsed.kid),
         true <- key.account_id == account.id || {:error, :unknown_key},
         :ok <- verify_parsed_proof(config, parsed, key, account, subject_fingerprint) do
      {:ok, key}
    else
      {:error, code} -> {:error, code}
    end
  end

  defp verify_proof(config, params, field, key, account, subject_fingerprint) do
    with {:ok, parsed} <- parse_proof(Map.get(params, field)) do
      verify_parsed_proof(config, parsed, key, account, subject_fingerprint)
    end
  end

  defp verify_parsed_proof(config, parsed, key, account, subject_fingerprint) do
    opts = [
      public_key: key.public_key,
      audience: Config.url(config, :agent_keys),
      account_id: account.id,
      handle: account.handle,
      skew: Config.agent_auth(config, :clock_skew),
      max_age: Config.agent_auth(config, :assertion_max_age),
      expect: %{"op" => "add_key", "jkt" => subject_fingerprint}
    ]

    case Assertion.verify(parsed, opts) do
      {:ok, _claims} -> :ok
      {:error, _} -> {:error, :invalid_assertion}
    end
  end

  defp parse_proof(proof) do
    case Assertion.parse(proof || "") do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> {:error, :invalid_assertion}
    end
  end

  defp find_key(keys, fingerprint) do
    case Enum.find(keys, &(&1.fingerprint == fingerprint)) do
      nil -> {:error, :not_found}
      key -> {:ok, key}
    end
  end

  defp ensure_not_last_key(config, account, keys, key) do
    remaining = Enum.count(keys, &(Key.active?(&1) and &1.fingerprint != key.fingerprint))

    cond do
      remaining > 0 -> :ok
      has_password?(config, account) -> :ok
      true -> {:error, :last_key}
    end
  end

  defp has_password?(config, %Account{id: id}) do
    {adapter, _} = Config.store(config)

    Store.supports?(adapter, {:get_agent_credential, 2}) and
      match?({:ok, _}, call_store(config, :get_agent_credential, [id]))
  end

  defp apply_status(account, status, opts) do
    case Account.set_status(account, status, opts) do
      {:ok, updated} -> {:ok, updated}
      {:error, _} -> {:error, :not_found}
    end
  end

  # ── token minting ────────────────────────────────────────────────────────

  defp session_token(config, %Session{} = session, %Key{} = key) do
    now = DateTime.to_unix(session.issued_at)

    Tokens.sign(config, %{
      "iss" => config.issuer,
      "aud" => config.issuer,
      "sub" => "session:" <> session.id,
      "sid" => session.id,
      "nonce" => session.nonce,
      "lvl" => "anon",
      "amr" => [],
      "cnf" => %{"jkt" => key.fingerprint},
      "jti" => Store.generate_token(),
      "iat" => now,
      "nbf" => now,
      "exp" => DateTime.to_unix(session.expires_at)
    })
  end

  defp access_token(config, %Account{} = account, %Key{} = key, params, now) do
    scope = scopes_for(config, account)
    issued = DateTime.to_unix(now)
    audience = requested_audience(config, params)

    token =
      Tokens.sign(config, %{
        "iss" => config.issuer,
        "aud" => audience,
        "sub" => account.id,
        "act" => account.id,
        "hdl" => account.handle,
        "lvl" => Atom.to_string(account.kind),
        "st" => Atom.to_string(account.status),
        "amr" => ["sig"],
        "kid" => key.fingerprint,
        "epoch" => account.revocation_epoch,
        "scope" => Enum.join(scope, " "),
        "jti" => Store.generate_token(),
        "iat" => issued,
        "nbf" => issued,
        "exp" => issued + config.access_token_ttl
      })

    %{
      "access_token" => token,
      "token_type" => "Bearer",
      "expires_in" => config.access_token_ttl,
      "scope" => Enum.join(scope, " "),
      "account_id" => account.id,
      "handle" => account.handle,
      "status" => Atom.to_string(account.status)
    }
  end

  # RFC 8707: honour a requested resource when it is one we know, otherwise mint an
  # AS-scoped token. Never mint for an unknown resource — an audience we do not
  # control is an audience we cannot reason about.
  defp requested_audience(config, params) do
    case Map.get(params, "resource") do
      nil ->
        config.issuer

      requested ->
        case Config.resource(config, requested) do
          {:ok, resource} -> resource.resource
          :error -> config.issuer
        end
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp call_store(config, fun, args) do
    {adapter, store_opts} = Config.store(config)
    apply(adapter, fun, args ++ [store_opts])
  rescue
    _ -> {:error, :store_error}
  end

  defp audit(config, account_id, action, metadata) do
    {adapter, _} = Config.store(config)

    if Store.supports?(adapter, {:put_agent_event, 2}) do
      _ =
        call_store(config, :put_agent_event, [
          %{
            "account_id" => account_id,
            "action" => action,
            "metadata" => metadata,
            "at" => DateTime.utc_now()
          }
        ])
    end

    :ok
  end

  defp ip_salt(config) do
    case Config.agent_auth(config, :ip_salt) do
      {mod, fun} -> apply(mod, fun, [])
      fun when is_function(fun, 0) -> fun.()
      salt -> salt
    end
  end

  # Host-supplied descriptive metadata. Kept as a shallow string map: it is
  # rendered in an admin queue, and a deeply nested or huge blob from an
  # unauthenticated endpoint is a denial-of-service on that page, not a feature.
  defp sanitize_client(nil), do: %{}

  defp sanitize_client(map) when is_map(map) do
    map
    |> Enum.take(20)
    |> Enum.flat_map(fn {k, v} ->
      case {to_string(k), scalar(v)} do
        {key, nil} when is_binary(key) -> []
        {key, value} -> [{String.slice(key, 0, 64), value}]
      end
    end)
    |> Map.new()
  end

  defp sanitize_client(_), do: %{}

  defp scalar(v) when is_binary(v), do: String.slice(v, 0, 512)
  defp scalar(v) when is_number(v) or is_boolean(v), do: v
  defp scalar(_), do: nil

  defp string_or_nil(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, 200)
    end
  end

  defp string_or_nil(_), do: nil
end
