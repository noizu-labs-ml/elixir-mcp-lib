if Code.ensure_loaded?(Plug.Conn) do
  defmodule Noizu.MCP.Auth.Server.ApiKeyTokenPlug do
    @moduledoc """
    Trade a host API key for a short-lived, audience-bound access token —
    `POST /api/mcp/token`.

        scope "/api/mcp" do
          pipe_through [:api, :rate_limited_auth]     # must skip protect_from_forgery
          forward "/token", Noizu.MCP.Auth.Server.ApiKeyTokenPlug, MCPConfig.as_opts()
        end

    A headless caller — a cron job, a CI step — cannot open a browser, and OAuth
    without a browser is not OAuth. This endpoint gives it the same kind of token
    every other client gets: same `aud`, same 15-minute ceiling, same scope rules.

    ## Why not just accept the API key at the MCP mount?

    You can — `Noizu.MCP.Auth.ApiKeyVerifier` in a `ChainVerifier` does exactly
    that, and for a single-mount host it is simpler. This endpoint is better when
    there are several mounts: the key is presented **once**, to one endpoint, and
    what travels to each mount afterwards is a token bound to that mount alone. A
    long-lived key presented on every request is a long-lived key in every log.

    No refresh token is issued: the API key *is* the long-lived credential, and a
    caller that holds it can always ask again.

    ## Options (`api_keys:` on the server config)

      * `:validator` (required) — `{mod, fun}` over the presented key, exactly as
        `Noizu.MCP.Auth.ApiKeyVerifier` uses it
      * `:prefix`, `:keys`, `:default_claims`, `:scopes` — passed straight through
      * `:client_id` — the `client_id` recorded on issued tokens, default
        `"api-key"`

    The rate-limit hook fires as `:api_key_token`. Rate limiting here is the point:
    without it this endpoint is an offline-free API-key oracle.
    """

    @behaviour Plug

    alias Noizu.MCP.Auth.ApiKeyVerifier
    alias Noizu.MCP.Auth.Server
    alias Noizu.MCP.Auth.Server.Config
    alias Noizu.MCP.Auth.Server.Errors
    alias Noizu.MCP.Auth.Server.Params
    alias Noizu.MCP.Auth.Server.PlugSupport
    alias Noizu.MCP.Auth.Server.Tokens

    @impl Plug
    def init(opts), do: PlugSupport.config(opts)

    @impl Plug
    def call(conn, %Config{} = config) do
      case PlugSupport.preflight(conn, "POST, OPTIONS") do
        nil -> serve(conn, config)
        answered -> answered
      end
    end

    defp serve(%{method: "POST"} = conn, config) do
      conn = PlugSupport.cors(conn)

      with :ok <- enabled(config),
           :ok <- PlugSupport.rate_limit(conn, config, :api_key_token),
           {:ok, conn, params} <- PlugSupport.read_params(conn),
           {:ok, key} <- presented_key(conn, params),
           {:ok, resource} <- resource(params, config),
           {:ok, claims} <- validate(conn, key, resource, config),
           {:ok, scope} <- scope(params, claims, config) do
        grant = %{
          subject: claims["sub"],
          client_id: Keyword.get(config.api_keys, :client_id, "api-key"),
          scope: scope,
          resource: resource
        }

        {:ok, access, token_claims} = Tokens.mint_access_token(config, grant)
        :ok = Tokens.track_access_token(config, token_claims, grant)

        PlugSupport.json(conn, 200, Tokens.token_response(config, access, scope, nil))
      else
        {:error, %Errors{} = error} -> PlugSupport.error_json(conn, error)
        {:error, %Plug.Conn{} = rate_limited} -> rate_limited
      end
    end

    defp serve(conn, _config), do: PlugSupport.method_not_allowed(conn, "POST, OPTIONS")

    defp enabled(%Config{api_keys: nil}),
      do: {:error, Errors.new(:invalid_request, reason: :api_keys_disabled, status: 404)}

    defp enabled(%Config{}), do: :ok

    # The key may arrive as a bearer header (what a CLI does naturally) or as an
    # `api_key` form field (what a curl one-liner does).
    defp presented_key(conn, params) do
      header =
        case conn |> Plug.Conn.get_req_header("authorization") |> List.first() do
          "Bearer " <> token -> token
          "bearer " <> token -> token
          _ -> nil
        end

      case header || Map.get(params, "api_key") do
        key when is_binary(key) and key != "" -> {:ok, key}
        _ -> {:error, Errors.new(:invalid_client, reason: :missing_api_key)}
      end
    end

    defp resource(params, config) do
      with {:ok, requested} <- Params.optional(params, "resource") do
        case Server.resolve_resource(config, requested) do
          {:ok, resource} ->
            {:ok, resource}

          {:error, :invalid_target} ->
            {:error, Errors.new(:invalid_target, reason: :unknown_resource)}
        end
      end
    end

    defp validate(conn, key, resource, config) do
      opts =
        config.api_keys
        |> Keyword.drop([:client_id])
        |> Keyword.put(:resource, resource)

      conn_info = %{method: conn.method, peer: conn.remote_ip, headers: conn.req_headers}

      case ApiKeyVerifier.verify(key, conn_info, opts) do
        {:ok, %{"sub" => sub} = claims} when is_binary(sub) ->
          {:ok, claims}

        {:ok, _claims} ->
          # Without a subject there is nothing for a tool handler to authorize
          # against, and `sub` is what every one of them reads.
          {:error, Errors.new(:invalid_client, reason: :api_key_without_subject)}

        {:error, :insufficient_scope, _meta} ->
          {:error, Errors.new(:invalid_scope, reason: :api_key_scope)}

        {:error, :invalid_token} ->
          {:error, Errors.new(:invalid_client, reason: :api_key_rejected)}
      end
    end

    defp scope(params, claims, config) do
      held = Noizu.MCP.Auth.JWTVerifier.scopes(claims)
      held = if held == [], do: config.default_scope, else: held

      with {:ok, requested} <- Params.space_list(params, "scope") do
        cond do
          requested == [] -> {:ok, held}
          Enum.all?(requested, &(&1 in held)) -> {:ok, requested}
          # A key may ask for less than it holds, never more.
          true -> {:error, Errors.new(:invalid_scope, reason: :scope_exceeds_key)}
        end
      end
    end
  end
end
