defmodule Noizu.MCP.Auth.Server do
  @moduledoc """
  OAuth 2.1 authorization-server facade for MCP hosts.

  MCP clients need an authorization server that speaks RFC 7591 dynamic client
  registration or client-id metadata documents. Most enterprise IdPs — Authentik
  among them — do not. This facade sits in front of the IdP you already have: it
  owns the OAuth client registry, consent, authorization codes, and token
  issuance, and delegates *authenticating the human* to the host's existing
  login. The IdP never sees an MCP client, and no upstream token is ever passed
  through to a downstream caller.

  ## Wiring it up

      # lib/my_app_web/mcp_config.ex
      def as_opts do
        Noizu.MCP.Auth.Server.config(
          issuer: issuer(),                        # origin, NO path
          store: {Noizu.MCP.Auth.Server.Store.Ecto, repo: MyApp.Repo},
          signing: {:hs256, {MyApp.MCPAuth, :secret}},
          scopes_supported: ["mcp"],
          resources: [
            [resource: issuer() <> "/mcp", name: "MyApp"],
            [resource: issuer() <> "/mcp/learning", name: "MyApp Learning"]
          ],
          dcr: [enabled: true, allowed_redirect_hosts: ["claude.ai"]],
          cimd: [enabled: true],
          upstream: {Noizu.MCP.Auth.Server.Upstream.HostSession,
                     current_subject: {MyApp.Auth.MCPBridge, :current_subject},
                     login_url: {MyApp.Auth.MCPBridge, :login_url}},
          api_keys: [validator: {MyApp.MCPKeys, :verify}]
        )
      end

      # router.ex
      scope "/" do
        forward "/.well-known/oauth-authorization-server",
                Noizu.MCP.Auth.Server.MetadataPlug, MCPConfig.as_opts()
        forward "/.well-known/openid-configuration",
                Noizu.MCP.Auth.Server.MetadataPlug, MCPConfig.as_opts()
      end

      scope "/oauth" do
        pipe_through :browser_session          # NOT require_authenticated
        forward "/", Noizu.MCP.Auth.Server.Router, MCPConfig.as_opts()
      end

      scope "/api/mcp" do
        pipe_through :api                      # must skip protect_from_forgery
        forward "/token", Noizu.MCP.Auth.Server.ApiKeyTokenPlug, MCPConfig.as_opts()
      end

  `/oauth/authorize` needs the session pipeline (it redirects a browser through
  your login and renders a consent form) but must **not** require an authenticated
  user — resolving that is the flow's job. `/oauth/token`, `/register` and
  `/revoke` are called by a machine with no cookie and must skip CSRF protection.

  ## Options

    * `:issuer` (required) — an origin with **no path**. Collapses the RFC 8414
      path-insertion/suffix ambiguity to one URL.
    * `:store` (required) — `{module, opts}`, see `Noizu.MCP.Auth.Server.Store`.
    * `:signing` (required) — `{:hs256, secret}` where secret is a binary,
      `{mod, fun}` or 0-arity fun; or `{:rs256, jwk: ..., kid: ...}`, which also
      publishes a JWKS document.
    * `:resources` — the mounts this server may mint tokens for, each
      `[resource: uri, name: ..., scopes: [...]]`. An RFC 8707 `resource` outside
      this list is `invalid_target`. With one entry it is the default audience.
    * `:resource_required` — require the `resource` parameter rather than
      defaulting to the single configured mount. Default `false`.
    * `:scopes_supported` / `:default_scope`.
    * `:access_token_ttl` — seconds, default and **maximum** 900. A longer value
      is clamped: with no access-token table there is no way to revoke early.
    * `:refresh_token_ttl` (default 30 days), `:refresh_family_ttl` (default 90
      days, `nil` for none) — the ceiling rotation cannot extend.
    * `:authorization_code_ttl` (default 60), `:login_state_ttl` (default 600).
    * `:dcr` — `[enabled: false, allowed_redirect_hosts: [...],
      initial_access_token: {mod, fun}]`.
    * `:cimd` — `[enabled: false, fetcher: {mod, opts}, ttl: 3600]`.
    * `:upstream` — `{module, opts}`, see `Noizu.MCP.Auth.Server.Upstream`.
      Defaults to `Upstream.HostSession`, which reuses the host's own login.
    * `:consent` — `[enabled: true, renderer: {mod, fun}, skip_for: [...]]`.
      Consent is **required** for DCR and CIMD clients; `enabled: false` only
      affects preconfigured ones.
    * `:api_keys` — options for `ApiKeyTokenPlug`, which trades a host API key
      for an access token. Omit to disable that endpoint.
    * `:rate_limit` — `{mod, fun}` or 3-arity fun called as
      `(endpoint, conn, config)` returning `:ok | {:error, retry_after_seconds}`.
      The limiter itself is host-owned.
    * `:track_access_tokens` — persist a row per access token, enabling immediate
      revocation. Default `false`.
    * `:paths` — override any endpoint path.
    * `:extra_metadata` — merged into the metadata document.
  """

  alias Noizu.MCP.Auth.Resource
  alias Noizu.MCP.Auth.Server.Config

  # RFC 9700 / MCP guidance: a bearer that cannot be revoked must not live long.
  @max_access_token_ttl 900

  @default_paths %{
    authorize: "/oauth/authorize",
    token: "/oauth/token",
    register: "/oauth/register",
    revoke: "/oauth/revoke",
    jwks: "/oauth/jwks",
    consent: "/oauth/consent",
    callback: "/oauth/callback",
    api_token: "/api/mcp/token"
  }

  @doc """
  Build and validate a `Noizu.MCP.Auth.Server.Config`.

  Raises `ArgumentError` on a misconfiguration. That is deliberate: every failure
  mode here (a path in the issuer, an unknown resource, a missing signing key)
  presents in production as *every client refusing to authenticate*, with nothing
  in the logs. Better to fail at boot.
  """
  @spec config(keyword() | Config.t()) :: Config.t()
  def config(%Config{} = config), do: config

  def config(opts) when is_list(opts) do
    issuer = issuer!(opts)

    %Config{
      issuer: issuer,
      store: store!(opts),
      signing: signing!(opts),
      access_token_ttl: ttl(opts, :access_token_ttl, 900, @max_access_token_ttl),
      refresh_token_ttl: ttl(opts, :refresh_token_ttl, 2_592_000, nil),
      refresh_family_ttl: optional_ttl(opts, :refresh_family_ttl, 7_776_000),
      authorization_code_ttl: ttl(opts, :authorization_code_ttl, 60, 600),
      login_state_ttl: ttl(opts, :login_state_ttl, 600, 3_600),
      scopes_supported: scopes(opts, :scopes_supported, ["mcp"]),
      default_scope: scopes(opts, :default_scope, scopes(opts, :scopes_supported, ["mcp"])),
      resources: resources!(opts, issuer),
      resource_required: Keyword.get(opts, :resource_required, false),
      dcr: Keyword.get(opts, :dcr, []),
      cimd: Keyword.get(opts, :cimd, []),
      upstream: upstream(opts),
      consent: Keyword.get(opts, :consent, []),
      api_keys: Keyword.get(opts, :api_keys),
      rate_limit: Keyword.get(opts, :rate_limit),
      track_access_tokens: Keyword.get(opts, :track_access_tokens, false),
      leeway: Keyword.get(opts, :leeway, 0),
      paths: Map.merge(@default_paths, Map.new(Keyword.get(opts, :paths, []))),
      extra_metadata: Keyword.get(opts, :extra_metadata, %{})
    }
  end

  @doc "Whether dynamic client registration is enabled."
  @spec dcr_enabled?(Config.t()) :: boolean()
  def dcr_enabled?(%Config{dcr: dcr}), do: Keyword.get(dcr, :enabled, false)

  @doc "Whether client-id metadata documents are accepted."
  @spec cimd_enabled?(Config.t()) :: boolean()
  def cimd_enabled?(%Config{cimd: cimd}), do: Keyword.get(cimd, :enabled, false)

  @doc """
  Resolve the RFC 8707 `resource` a request asked for.

  An absent `resource` falls back to the single configured mount, which is how a
  client that predates resource indicators still works. An absent `resource` with
  several mounts configured is an error rather than a guess — guessing hands out a
  token for the wrong audience.

  A `resource` may **narrow** to a configured mount. It can never widen: the list
  is the ceiling.
  """
  @spec resolve_resource(Config.t(), String.t() | nil) ::
          {:ok, String.t() | nil} | {:error, :invalid_target}
  def resolve_resource(%Config{resources: []} = config, requested) do
    cond do
      is_nil(requested) and not config.resource_required -> {:ok, nil}
      # Nothing configured means nothing to validate against; refusing is the
      # only safe answer, since we cannot tell whether this is one of ours.
      true -> {:error, :invalid_target}
    end
  end

  def resolve_resource(%Config{} = config, nil) do
    case {config.resource_required, config.resources} do
      {false, [only]} -> {:ok, only.resource}
      _ -> {:error, :invalid_target}
    end
  end

  def resolve_resource(%Config{} = config, requested) when is_binary(requested) do
    case Config.resource(config, requested) do
      {:ok, resource} -> {:ok, resource.resource}
      :error -> {:error, :invalid_target}
    end
  end

  def resolve_resource(%Config{}, _requested), do: {:error, :invalid_target}

  @doc """
  Resolve a `client_id` to a client: a stored one, or a CIMD document fetched and
  cached on the spot.

  `{:error, %Errors{}}` for anything unresolvable — and the caller must **render**
  that error rather than redirect, since without a resolved client there is no
  `redirect_uri` it is safe to send anything to.
  """
  @spec resolve_client(Config.t(), String.t() | nil) ::
          {:ok, Noizu.MCP.Auth.Server.Client.t()} | {:error, Noizu.MCP.Auth.Server.Errors.t()}
  def resolve_client(%Config{} = config, client_id) when is_binary(client_id) do
    {adapter, store_opts} = Config.store(config)
    alias Noizu.MCP.Auth.Server.{CIMD, Client, Errors}

    stored =
      case adapter.get_client(client_id, store_opts) do
        {:ok, %Client{} = client} -> client
        _ -> nil
      end

    cond do
      not is_nil(stored) and not Client.active?(stored) ->
        {:error, Errors.new(:invalid_client, reason: :client_disabled)}

      not is_nil(stored) and stored.client_id_kind != :cimd ->
        {:ok, stored}

      CIMD.cimd_client_id?(client_id) ->
        resolve_cimd(config, client_id, stored)

      true ->
        {:error, Errors.new(:invalid_client, reason: :unknown_client)}
    end
  end

  def resolve_client(%Config{}, _client_id),
    do: {:error, Noizu.MCP.Auth.Server.Errors.new(:invalid_client, reason: :missing_client_id)}

  defp resolve_cimd(config, client_id, stored) do
    alias Noizu.MCP.Auth.Server.CIMD

    with {:ok, client, source} <- CIMD.resolve(client_id, stored, config) do
      if source == :fetched do
        # Cache the document so the next authorization request does not refetch.
        {adapter, store_opts} = Config.store(config)
        _ = adapter.put_client(client, store_opts)
      end

      {:ok, client}
    end
  end

  @doc """
  Invoke the host's rate-limit hook for an endpoint. `:ok` when no hook is set —
  the library ships the seam, the host ships the limiter (both apps have Hammer).
  """
  @spec rate_limit(Config.t(), atom(), term()) :: :ok | {:error, non_neg_integer()}
  def rate_limit(%Config{rate_limit: nil}, _endpoint, _conn), do: :ok

  def rate_limit(%Config{rate_limit: hook} = config, endpoint, conn) do
    case hook do
      {module, fun} -> apply(module, fun, [endpoint, conn, config])
      fun when is_function(fun, 3) -> fun.(endpoint, conn, config)
    end
  end

  # ── validation ───────────────────────────────────────────────────────────

  defp issuer!(opts) do
    issuer = Keyword.get(opts, :issuer) || raise ArgumentError, "Auth.Server: :issuer is required"

    case Resource.normalize(issuer) do
      {:ok, normalized} ->
        if URI.parse(normalized).path in [nil, ""] do
          normalized
        else
          raise ArgumentError,
                "Auth.Server: :issuer must be an origin with no path, got #{inspect(issuer)}. " <>
                  "A path here makes RFC 8414 discovery ambiguous — mount paths belong in :resources."
        end

      {:error, :invalid_resource} ->
        raise ArgumentError,
              "Auth.Server: :issuer is not a usable https origin: #{inspect(issuer)}"
    end
  end

  defp store!(opts) do
    case Keyword.get(opts, :store) do
      {module, store_opts} when is_atom(module) and is_list(store_opts) -> {module, store_opts}
      module when is_atom(module) and not is_nil(module) -> {module, []}
      _ -> raise ArgumentError, "Auth.Server: :store is required, as {module, opts}"
    end
  end

  defp signing!(opts) do
    case Keyword.get(opts, :signing) do
      {:hs256, secret} when not is_nil(secret) ->
        {:hs256, secret}

      {:rs256, rs_opts} when is_list(rs_opts) ->
        unless Keyword.has_key?(rs_opts, :jwk) do
          raise ArgumentError, "Auth.Server: signing: {:rs256, ...} requires :jwk"
        end

        {:rs256, rs_opts}

      _ ->
        raise ArgumentError,
              "Auth.Server: :signing is required — {:hs256, secret | {mod, fun}} or " <>
                "{:rs256, jwk: ..., kid: ...}"
    end
  end

  defp resources!(opts, issuer) do
    opts
    |> Keyword.get(:resources, [])
    |> Enum.map(fn entry ->
      entry = if is_map(entry), do: Enum.into(entry, []), else: entry

      uri =
        Keyword.get(entry, :resource) ||
          raise ArgumentError, "Auth.Server: resource entry needs :resource"

      resource = Resource.normalize!(uri)

      unless String.starts_with?(resource, issuer) do
        raise ArgumentError,
              "Auth.Server: resource #{inspect(resource)} is not under issuer #{inspect(issuer)}"
      end

      %{
        resource: resource,
        name: Keyword.get(entry, :name),
        scopes: Keyword.get(entry, :scopes)
      }
    end)
  end

  defp upstream(opts) do
    case Keyword.get(opts, :upstream) do
      {module, upstream_opts} when is_atom(module) -> {module, upstream_opts}
      module when is_atom(module) and not is_nil(module) -> {module, []}
      nil -> raise ArgumentError, "Auth.Server: :upstream is required, as {module, opts}"
    end
  end

  defp scopes(opts, key, default) do
    case Keyword.get(opts, key, default) do
      scopes when is_list(scopes) -> Enum.map(scopes, &to_string/1)
      scopes when is_binary(scopes) -> String.split(scopes, " ", trim: true)
      _ -> default
    end
  end

  defp ttl(opts, key, default, max) do
    value = Keyword.get(opts, key, default)

    unless is_integer(value) and value > 0 do
      raise ArgumentError, "Auth.Server: #{key} must be a positive integer of seconds"
    end

    if max && value > max, do: max, else: value
  end

  defp optional_ttl(opts, key, default) do
    case Keyword.get(opts, key, default) do
      nil -> nil
      value when is_integer(value) and value > 0 -> value
      _ -> raise ArgumentError, "Auth.Server: #{key} must be a positive integer of seconds or nil"
    end
  end
end
