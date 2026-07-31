if Code.ensure_loaded?(Plug.Conn) do
  defmodule Noizu.MCP.Auth.Server.MetadataPlug do
    @moduledoc """
    RFC 8414 authorization-server metadata, aliased at
    `/.well-known/openid-configuration`.

        forward "/.well-known/oauth-authorization-server",
                Noizu.MCP.Auth.Server.MetadataPlug, MCPConfig.as_opts()
        forward "/.well-known/openid-configuration",
                Noizu.MCP.Auth.Server.MetadataPlug, MCPConfig.as_opts()

    ## The fields clients actually gate on

    This document is not decoration — Claude reads it and decides what it is
    willing to do:

      * `code_challenge_methods_supported: ["S256"]` — only S256, never `plain`
      * `token_endpoint_auth_methods_supported` **containing `"none"`** — together
        with the next flag, this is what makes Claude offer CIMD. Drop `"none"` and
        it silently falls back to dynamic registration
      * `client_id_metadata_document_supported: true` — the other half of that pair
      * `registration_endpoint` — present only with `dcr: [enabled: true]`; its
        absence is how a client learns not to try
      * `authorization_response_iss_parameter_supported: true` — and the
        authorization endpoint really does emit `iss` (RFC 9207)
      * `resource_indicators_supported: true` — RFC 8707, which is how a client
        knows to ask for a token bound to one mount
      * `jwks_uri` — **only** in RS256 mode. Advertising it with an HMAC key would
        point clients at an empty key set.

    The document is public, unauthenticated and cacheable, and is served with
    `Access-Control-Allow-Origin: *` because claude.ai reads it from a browser
    context.
    """

    @behaviour Plug

    alias Noizu.MCP.Auth.Server
    alias Noizu.MCP.Auth.Server.Config
    alias Noizu.MCP.Auth.Server.PlugSupport

    @impl Plug
    def init(opts), do: PlugSupport.config(opts)

    @impl Plug
    def call(conn, %Config{} = config) do
      case PlugSupport.preflight(conn, "GET, OPTIONS") do
        nil -> serve(conn, config)
        answered -> answered
      end
    end

    defp serve(%{method: "GET"} = conn, config) do
      conn
      |> PlugSupport.cors()
      |> PlugSupport.cacheable_json(200, document(config))
    end

    defp serve(conn, _config), do: PlugSupport.method_not_allowed(conn, "GET, OPTIONS")

    @doc """
    The metadata document as a map — exposed so a host can assert on it in its own
    tests, and so a frontend "connect an agent" page can render from it.
    """
    @spec document(Config.t()) :: map()
    def document(%Config{} = config) do
      %{
        "issuer" => config.issuer,
        "authorization_endpoint" => Config.url(config, :authorize),
        "token_endpoint" => Config.url(config, :token),
        "revocation_endpoint" => Config.url(config, :revoke),
        "scopes_supported" => config.scopes_supported,
        "response_types_supported" => ["code"],
        "response_modes_supported" => ["query"],
        "grant_types_supported" => ["authorization_code", "refresh_token"],
        "code_challenge_methods_supported" => ["S256"],
        "token_endpoint_auth_methods_supported" => auth_methods(config),
        "revocation_endpoint_auth_methods_supported" => auth_methods(config),
        "authorization_response_iss_parameter_supported" => true,
        "resource_indicators_supported" => true,
        "client_id_metadata_document_supported" => Server.cimd_enabled?(config),
        "service_documentation" => Keyword.get(config.dcr, :documentation_uri)
      }
      |> maybe_put("registration_endpoint", registration_endpoint(config))
      |> maybe_put("jwks_uri", jwks_uri(config))
      |> maybe_put("resources_supported", resources(config))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
      |> Map.merge(config.extra_metadata)
    end

    # `"none"` first, and always present: a public client with PKCE is the normal
    # case for an MCP client, and its presence is half of what turns CIMD on.
    defp auth_methods(_config), do: ["none", "client_secret_post", "client_secret_basic"]

    defp registration_endpoint(config) do
      if Server.dcr_enabled?(config), do: Config.url(config, :register)
    end

    defp jwks_uri(config) do
      if Config.asymmetric?(config), do: Config.url(config, :jwks)
    end

    defp resources(%Config{resources: []}), do: nil
    defp resources(%Config{resources: resources}), do: Enum.map(resources, & &1.resource)

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, value), do: Map.put(map, key, value)
  end
end
