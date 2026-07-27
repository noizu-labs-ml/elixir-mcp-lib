if Code.ensure_loaded?(Plug.Conn) do
  defmodule Noizu.MCP.Auth.Server.JWKSPlug do
    @moduledoc """
    The JWKS document — `GET /oauth/jwks`. **RS256 mode only.**

    In HS256 mode there is no public key: publishing an empty `keys` array would
    invite a client to try verifying tokens it cannot verify, so this answers
    `404` and the metadata document omits `jwks_uri` entirely. Nothing about an
    HMAC deployment needs this endpoint — the resource server holds the same
    shared secret.

    Public, cacheable, CORS-open. Only the public half of the key is ever rendered:
    `Tokens.jwks/1` runs `JOSE.JWK.to_public/1`, so a private key cannot leak here
    even if one is misconfigured into `:jwk`.
    """

    @behaviour Plug

    alias Noizu.MCP.Auth.Server.Config
    alias Noizu.MCP.Auth.Server.Errors
    alias Noizu.MCP.Auth.Server.PlugSupport
    alias Noizu.MCP.Auth.Server.Tokens

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
      conn = PlugSupport.cors(conn)

      if Config.asymmetric?(config) do
        PlugSupport.cacheable_json(conn, 200, Tokens.jwks(config), 3_600)
      else
        PlugSupport.json(
          conn,
          404,
          Errors.to_map(Errors.new(:invalid_request, reason: :hs256_mode))
        )
      end
    end

    defp serve(conn, _config), do: PlugSupport.method_not_allowed(conn, "GET, OPTIONS")
  end
end
