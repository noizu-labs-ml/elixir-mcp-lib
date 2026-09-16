defmodule Noizu.MCP.Auth.Server.Config do
  @moduledoc """
  Validated configuration for the authorization-server facade — the struct every
  plug in `Noizu.MCP.Auth.Server` receives.

  Built by `Noizu.MCP.Auth.Server.config/1`. See that function for the option
  list; this module is the shape and the derived endpoint URLs.
  """

  @type signing :: {:hs256, term()} | {:rs256, keyword()}

  @type t :: %__MODULE__{
          issuer: String.t(),
          store: {module(), keyword()},
          signing: signing(),
          access_token_ttl: pos_integer(),
          refresh_token_ttl: pos_integer(),
          refresh_family_ttl: pos_integer() | nil,
          authorization_code_ttl: pos_integer(),
          login_state_ttl: pos_integer(),
          scopes_supported: [String.t()],
          default_scope: [String.t()],
          resources: [map()],
          resource_required: boolean(),
          dcr: keyword(),
          cimd: keyword(),
          upstream: {module(), keyword()},
          consent: keyword(),
          api_keys: keyword() | nil,
          agent_auth: keyword(),
          rate_limit: term() | nil,
          track_access_tokens: boolean(),
          leeway: non_neg_integer(),
          paths: map(),
          extra_metadata: map()
        }

  defstruct issuer: nil,
            store: nil,
            signing: nil,
            access_token_ttl: 900,
            refresh_token_ttl: 2_592_000,
            refresh_family_ttl: 7_776_000,
            authorization_code_ttl: 60,
            login_state_ttl: 600,
            scopes_supported: ["mcp"],
            default_scope: ["mcp"],
            resources: [],
            resource_required: false,
            dcr: [],
            cimd: [],
            upstream: nil,
            consent: [],
            api_keys: nil,
            agent_auth: [],
            rate_limit: nil,
            track_access_tokens: false,
            leeway: 0,
            paths: %{},
            extra_metadata: %{}

  @doc "Absolute URL for a named endpoint: `url(config, :token)`."
  @spec url(t(), atom()) :: String.t()
  def url(%__MODULE__{issuer: issuer, paths: paths}, name), do: issuer <> Map.fetch!(paths, name)

  @doc "The canonical resource URIs this server may mint tokens for."
  @spec resource_uris(t()) :: [String.t()]
  def resource_uris(%__MODULE__{resources: resources}),
    do: Enum.map(resources, & &1.resource)

  @doc "Look a configured mount up by its canonical resource URI."
  @spec resource(t(), String.t()) :: {:ok, map()} | :error
  def resource(%__MODULE__{resources: resources}, uri) do
    case Enum.find(resources, &Noizu.MCP.Auth.Resource.equal?(&1.resource, uri)) do
      nil -> :error
      found -> {:ok, found}
    end
  end

  @doc "Whether RS256 mode is in use — the only mode with a JWKS document."
  @spec asymmetric?(t()) :: boolean()
  def asymmetric?(%__MODULE__{signing: {:rs256, _}}), do: true
  def asymmetric?(%__MODULE__{}), do: false

  @doc """
  Whether anonymous keypair (agent) authentication is turned on.

  Off by default. A host that has not implemented the agent block of
  `Noizu.MCP.Auth.Server.Store` and turns this on gets an `ArgumentError` at boot
  rather than a 500 on the first agent that tries to register.
  """
  @spec agent_auth?(t()) :: boolean()
  def agent_auth?(%__MODULE__{agent_auth: opts}), do: Keyword.get(opts, :enabled, false)

  @doc "One `:agent_auth` option, with the library default."
  @spec agent_auth(t(), atom()) :: term()
  def agent_auth(%__MODULE__{agent_auth: opts}, key) do
    Keyword.get(opts, key, Map.fetch!(agent_auth_defaults(), key))
  end

  @doc """
  Defaults for every `:agent_auth` option.

  Exposed so a host can render its own "how to connect an agent" page from the
  same numbers the server enforces, rather than from a copy that drifts.
  """
  @spec agent_auth_defaults() :: map()
  def agent_auth_defaults do
    %{
      enabled: false,
      session_ttl: 600,
      assertion_max_age: 300,
      clock_skew: 60,
      max_keys: 10,
      require_approval: true,
      ip_salt: nil,
      pending_scope: ["agent:profile", "agent:keys"],
      approved_scope: ["agent:profile", "agent:keys", "mcp"]
    }
  end

  @doc "Adapter module and opts, for a `Store` call."
  @spec store(t()) :: {module(), keyword()}
  def store(%__MODULE__{store: store}), do: store
end
