defmodule Noizu.MCP.Auth.Server.Client do
  @moduledoc """
  An OAuth client of this authorization server, and the validation that admits
  one.

  Three kinds, because MCP hosts meet clients three ways:

    * `:registered` — arrived through RFC 7591 dynamic registration. What Claude
      Desktop and Claude Code do by default.
    * `:cimd` — its `client_id` *is* an https URL serving a client-id metadata
      document. Nothing is stored until the document is fetched, and the fetch is
      SSRF-guarded (`Noizu.MCP.Auth.Server.CIMD`).
    * `:preconfigured` — created by the operator out of band. The only kind that
      may skip the consent screen, because a human already approved it.

  ## Secrets

  `secret_hash` is a PBKDF2 string from `Noizu.MCP.Auth.Server.Secret`. The
  plaintext exists exactly once, in the registration response; it is never stored
  and cannot be recovered. A client whose `token_endpoint_auth_method` is `"none"`
  has no secret at all — which is the common case, since a desktop app cannot keep
  one, and PKCE rather than a secret is what binds the code to the caller.
  """

  alias Noizu.MCP.Auth.Server.Config
  alias Noizu.MCP.Auth.Server.Errors
  alias Noizu.MCP.Auth.Server.RedirectURI
  alias Noizu.MCP.Auth.Server.Secret

  @kinds [:registered, :cimd, :preconfigured]
  @auth_methods ["none", "client_secret_post", "client_secret_basic"]
  @grant_types ["authorization_code", "refresh_token"]
  @response_types ["code"]
  # A registration document is metadata, not a payload; these bounds keep an
  # oversized field out of the database and out of the log.
  @max_uris 10
  @max_field 2_048

  @type kind :: :registered | :cimd | :preconfigured

  @type t :: %__MODULE__{
          client_id: String.t(),
          client_id_kind: kind(),
          client_name: String.t() | nil,
          secret_hash: String.t() | nil,
          token_endpoint_auth_method: String.t(),
          redirect_uris: [String.t()],
          grant_types: [String.t()],
          response_types: [String.t()],
          scope: [String.t()],
          upstream_client_ref: String.t() | nil,
          logo_uri: String.t() | nil,
          client_uri: String.t() | nil,
          policy_uri: String.t() | nil,
          tos_uri: String.t() | nil,
          software_id: String.t() | nil,
          software_version: String.t() | nil,
          cimd_fetched_at: DateTime.t() | nil,
          cimd_etag: String.t() | nil,
          cimd_expires_at: DateTime.t() | nil,
          metadata: map(),
          disabled_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  defstruct client_id: nil,
            client_id_kind: :registered,
            client_name: nil,
            secret_hash: nil,
            token_endpoint_auth_method: "none",
            redirect_uris: [],
            grant_types: @grant_types,
            response_types: @response_types,
            scope: [],
            upstream_client_ref: nil,
            logo_uri: nil,
            client_uri: nil,
            policy_uri: nil,
            tos_uri: nil,
            software_id: nil,
            software_version: nil,
            cimd_fetched_at: nil,
            cimd_etag: nil,
            cimd_expires_at: nil,
            metadata: %{},
            disabled_at: nil,
            inserted_at: nil,
            updated_at: nil

  @doc "Client kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Token-endpoint authentication methods this server supports."
  @spec auth_methods() :: [String.t()]
  def auth_methods, do: @auth_methods

  @doc "Grant types this server supports."
  @spec grant_types() :: [String.t()]
  def grant_types, do: @grant_types

  @doc "Response types this server supports."
  @spec response_types() :: [String.t()]
  def response_types, do: @response_types

  @doc """
  Build a client from an RFC 7591 registration request.

  Returns `{:ok, client, plaintext_secret | nil}` — the plaintext is returned
  *only* here, for the response body, and is never persisted.

  Validation is deliberately strict: `redirect_uris` is required and each entry
  must pass `RedirectURI.validate/2` (https, or loopback http; no fragment, no
  userinfo, no wildcard), and with `dcr: [allowed_redirect_hosts: [...]]` the host
  must match on a label boundary — otherwise anyone can register
  `https://evil-claude.ai/cb` and be handed codes meant for `claude.ai`.
  """
  @spec from_registration(map(), Config.t()) ::
          {:ok, t(), String.t() | nil} | {:error, Errors.t()}
  def from_registration(params, %Config{} = config) do
    with {:ok, redirect_uris} <- registration_redirect_uris(params, config),
         {:ok, auth_method} <- auth_method(params),
         {:ok, grants} <- subset(params, "grant_types", @grant_types, @grant_types),
         {:ok, responses} <- subset(params, "response_types", @response_types, @response_types),
         {:ok, scope} <- registration_scope(params, config),
         :ok <- check_grant_response_pairing(grants, responses) do
      {secret, secret_hash} = mint_secret(auth_method, config)

      client = %__MODULE__{
        client_id: "mcp_" <> Secret.generate(24),
        client_id_kind: :registered,
        client_name: string_field(params, "client_name"),
        secret_hash: secret_hash,
        token_endpoint_auth_method: auth_method,
        redirect_uris: redirect_uris,
        grant_types: grants,
        response_types: responses,
        scope: scope,
        logo_uri: string_field(params, "logo_uri"),
        client_uri: string_field(params, "client_uri"),
        policy_uri: string_field(params, "policy_uri"),
        tos_uri: string_field(params, "tos_uri"),
        software_id: string_field(params, "software_id"),
        software_version: string_field(params, "software_version")
      }

      {:ok, client, secret}
    end
  end

  @doc """
  Build a client from a fetched client-id metadata document.

  `client_id` is the URL the document was fetched from. The document must assert
  the **same** `client_id` (RFC-draft CIMD §client_id self-assertion): without
  that check, one URL could serve a document claiming to be another client and
  inherit its consent.

  A CIMD client is always public — there is no registration step in which a secret
  could be exchanged.
  """
  @spec from_cimd(String.t(), map(), Config.t()) :: {:ok, t()} | {:error, Errors.t()}
  def from_cimd(client_id, document, %Config{} = config) do
    with :ok <- check_self_assertion(client_id, document),
         {:ok, redirect_uris} <- cimd_redirect_uris(document, config),
         {:ok, grants} <- subset(document, "grant_types", @grant_types, @grant_types),
         {:ok, responses} <- subset(document, "response_types", @response_types, @response_types),
         {:ok, scope} <- registration_scope(document, config) do
      ttl = Keyword.get(config.cimd, :ttl, 3_600)
      now = DateTime.utc_now()

      {:ok,
       %__MODULE__{
         client_id: client_id,
         client_id_kind: :cimd,
         client_name: string_field(document, "client_name"),
         secret_hash: nil,
         token_endpoint_auth_method: "none",
         redirect_uris: redirect_uris,
         grant_types: grants,
         response_types: responses,
         scope: scope,
         logo_uri: string_field(document, "logo_uri"),
         client_uri: string_field(document, "client_uri"),
         policy_uri: string_field(document, "policy_uri"),
         tos_uri: string_field(document, "tos_uri"),
         software_id: string_field(document, "software_id"),
         cimd_fetched_at: now,
         cimd_expires_at: DateTime.add(now, ttl, :second)
       }}
    end
  end

  @doc """
  The RFC 7591 §3.2.1 registration response body. `secret` is the plaintext from
  `from_registration/2`, or `nil` for a public client.
  """
  @spec to_registration_response(t(), String.t() | nil) :: map()
  def to_registration_response(%__MODULE__{} = client, secret) do
    %{
      "client_id" => client.client_id,
      "client_id_issued_at" => DateTime.to_unix(client.inserted_at || DateTime.utc_now()),
      "token_endpoint_auth_method" => client.token_endpoint_auth_method,
      "redirect_uris" => client.redirect_uris,
      "grant_types" => client.grant_types,
      "response_types" => client.response_types,
      "scope" => Enum.join(client.scope, " ")
    }
    |> maybe_put("client_name", client.client_name)
    |> maybe_put("client_secret", secret)
    # RFC 7591: a secret with no expiry must say so explicitly.
    |> then(fn body ->
      if secret, do: Map.put(body, "client_secret_expires_at", 0), else: body
    end)
  end

  @doc """
  Authenticate a client at the token endpoint.

  The comparison is constant-time, and a client with no stored secret still burns
  the same work, so "no such client" is not measurably faster than "wrong secret".

  A `"none"` client authenticates by presenting no secret at all — and by PKCE,
  which every client must satisfy. Presenting a secret for a `"none"` client is an
  error rather than something to ignore: it means the caller has the wrong idea
  about who it is.
  """
  @spec authenticate(t(), String.t() | nil, keyword()) :: :ok | {:error, Errors.t()}
  def authenticate(client, presented, opts \\ [])

  def authenticate(%__MODULE__{token_endpoint_auth_method: "none"}, nil, _opts), do: :ok

  def authenticate(%__MODULE__{token_endpoint_auth_method: "none"}, _presented, _opts),
    do: {:error, Errors.new(:invalid_client, reason: :secret_for_public_client)}

  def authenticate(%__MODULE__{secret_hash: hash}, presented, opts)
      when is_binary(hash) and is_binary(presented) do
    if Secret.verify(presented, hash, opts) do
      :ok
    else
      {:error, Errors.new(:invalid_client, reason: :bad_secret)}
    end
  end

  def authenticate(%__MODULE__{}, presented, opts) do
    # No stored hash, or nothing presented: do the work anyway, then refuse.
    _ = Secret.verify(presented || "", nil, opts)
    {:error, Errors.new(:invalid_client, reason: :missing_secret)}
  end

  @doc "True for a client that keeps no secret."
  @spec public?(t()) :: boolean()
  def public?(%__MODULE__{token_endpoint_auth_method: "none"}), do: true
  def public?(%__MODULE__{}), do: false

  @doc """
  True when this client must be consented to before any IdP redirect or code
  issuance.

  Registered and CIMD clients always must: nobody vetted them, and skipping
  consent for a self-registered client is exactly the confused-deputy hole the
  MCP spec calls out. A preconfigured client may skip it, since an operator
  created it deliberately — and only then does `consent: [enabled: false]` apply.
  """
  @spec requires_consent?(t(), Config.t()) :: boolean()
  def requires_consent?(%__MODULE__{client_id_kind: kind}, %Config{consent: consent}) do
    cond do
      kind in [:registered, :cimd] -> true
      true -> Keyword.get(consent, :enabled, true)
    end
  end

  @doc "True when the client is not disabled."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{disabled_at: nil}), do: true
  def active?(%__MODULE__{}), do: false

  @doc "True when the client registered for a grant type."
  @spec supports_grant?(t(), String.t()) :: boolean()
  def supports_grant?(%__MODULE__{grant_types: grants}, grant), do: grant in grants

  @doc "True when a cached CIMD document has gone stale and should be re-fetched."
  @spec cimd_stale?(t(), DateTime.t()) :: boolean()
  def cimd_stale?(%__MODULE__{client_id_kind: :cimd, cimd_expires_at: nil}, _now), do: true

  def cimd_stale?(%__MODULE__{client_id_kind: :cimd, cimd_expires_at: expires}, now),
    do: DateTime.compare(now, expires) != :lt

  def cimd_stale?(%__MODULE__{}, _now), do: false

  # ── validation helpers ───────────────────────────────────────────────────

  defp registration_redirect_uris(params, config) do
    opts = [allowed_hosts: Keyword.get(config.dcr, :allowed_redirect_hosts)]

    case Map.get(params, "redirect_uris") do
      uris when is_list(uris) and uris != [] and length(uris) <= @max_uris ->
        validate_uris(uris, opts)

      _ ->
        {:error, Errors.new(:invalid_redirect_uri, reason: :missing_redirect_uris)}
    end
  end

  # A CIMD document may spell the field either way; the draft uses
  # `redirect_uris`, some clients emit the singular.
  defp cimd_redirect_uris(document, config) do
    opts = [allowed_hosts: Keyword.get(config.cimd, :allowed_redirect_hosts)]

    case {Map.get(document, "redirect_uris"), Map.get(document, "redirect_uri")} do
      {uris, _} when is_list(uris) and uris != [] and length(uris) <= @max_uris ->
        validate_uris(uris, opts)

      {_, uri} when is_binary(uri) ->
        validate_uris([uri], opts)

      _ ->
        {:error, Errors.new(:invalid_client_metadata, reason: :missing_redirect_uris)}
    end
  end

  defp validate_uris(uris, opts) do
    Enum.reduce_while(uris, {:ok, []}, fn uri, {:ok, acc} ->
      case RedirectURI.validate(uri, opts) do
        {:ok, valid} ->
          {:cont, {:ok, acc ++ [valid]}}

        {:error, reason} ->
          {:halt, {:error, Errors.new(:invalid_redirect_uri, reason: reason)}}
      end
    end)
  end

  defp auth_method(params) do
    case Map.get(params, "token_endpoint_auth_method", "none") do
      method when method in @auth_methods -> {:ok, method}
      _ -> {:error, Errors.new(:invalid_client_metadata, reason: :bad_auth_method)}
    end
  end

  defp subset(params, key, allowed, default) do
    case Map.get(params, key) do
      nil ->
        {:ok, default}

      values when is_list(values) ->
        case Enum.reject(values, &(&1 in allowed)) do
          [] -> {:ok, if(values == [], do: default, else: values)}
          _ -> {:error, Errors.new(:invalid_client_metadata, reason: {:unsupported, key})}
        end

      _ ->
        {:error, Errors.new(:invalid_client_metadata, reason: {:malformed, key})}
    end
  end

  # A client asking for `refresh_token` without `authorization_code` has nothing
  # to refresh — reject the combination rather than silently issuing a dead client.
  defp check_grant_response_pairing(grants, responses) do
    cond do
      "authorization_code" in grants and "code" not in responses ->
        {:error, Errors.new(:invalid_client_metadata, reason: :grant_response_mismatch)}

      "refresh_token" in grants and "authorization_code" not in grants ->
        {:error, Errors.new(:invalid_client_metadata, reason: :refresh_without_code)}

      true ->
        :ok
    end
  end

  defp registration_scope(params, config) do
    requested =
      case Map.get(params, "scope") do
        scope when is_binary(scope) -> String.split(scope, " ", trim: true)
        _ -> config.default_scope
      end

    case Enum.reject(requested, &(&1 in config.scopes_supported)) do
      [] -> {:ok, requested}
      _ -> {:error, Errors.new(:invalid_scope, reason: :scope_not_supported)}
    end
  end

  defp check_self_assertion(client_id, document) do
    case Map.get(document, "client_id") do
      ^client_id -> :ok
      _ -> {:error, Errors.new(:invalid_client_metadata, reason: :cimd_self_assertion)}
    end
  end

  defp mint_secret("none", _config), do: {nil, nil}

  defp mint_secret(_method, config) do
    secret = Secret.generate(32)
    {secret, Secret.hash(secret, Keyword.get(config.dcr, :secret_opts, []))}
  end

  defp string_field(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" ->
        binary_part(value, 0, min(byte_size(value), @max_field))

      _ ->
        nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
