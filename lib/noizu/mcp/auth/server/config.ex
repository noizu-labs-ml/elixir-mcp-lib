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

  @doc "Adapter module and opts, for a `Store` call."
  @spec store(t()) :: {module(), keyword()}
  def store(%__MODULE__{store: store}), do: store
end
