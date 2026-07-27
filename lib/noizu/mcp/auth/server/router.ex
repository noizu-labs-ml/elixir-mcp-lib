if Code.ensure_loaded?(Plug.Conn) do
  defmodule Noizu.MCP.Auth.Server.Router do
    @moduledoc """
    One forward for the whole authorization server.

        scope "/oauth" do
          pipe_through :browser_session      # session YES, require_authenticated NO
          forward "/", Noizu.MCP.Auth.Server.Router, MCPConfig.as_opts()
        end

    Dispatches on the path remaining after the forward:

    | Path | Plug | Notes |
    |---|---|---|
    | `authorize` | `AuthorizePlug` | GET; needs the session pipeline |
    | `consent` | `AuthorizePlug` | POST; the approve/deny decision |
    | `callback` | `AuthorizePlug` / `Upstream` | only used by `Upstream.OIDC` |
    | `token` | `TokenPlug` | POST; **must skip CSRF** |
    | `register` | `RegistrationPlug` | POST; **must skip CSRF** |
    | `revoke` | `RevokePlug` | POST; **must skip CSRF** |
    | `jwks` | `JWKSPlug` | GET; RS256 only |

    The paths come from `paths:` on the config, so overriding one moves it here and
    in the metadata document together — which is the only way they cannot drift.

    ## Two pipeline requirements, and what happens if you miss them

    `/oauth/authorize` and `/oauth/consent` need a **session** (they redirect a
    browser through your login and render a form) but must not require an
    authenticated user, or the flow can never reach the login redirect that would
    authenticate one — the user sees a 401 loop.

    `/oauth/token`, `/register` and `/revoke` are called by machines with no cookie.
    If `protect_from_forgery` is in their pipeline, every token exchange fails with
    an `InvalidCSRFTokenError` — after the browser leg has already succeeded, which
    makes it look like a token bug rather than a routing one.

    A host that would rather mount the endpoints individually can: each plug stands
    alone and takes the same options.
    """

    @behaviour Plug

    alias Noizu.MCP.Auth.Server.AuthorizePlug
    alias Noizu.MCP.Auth.Server.Config
    alias Noizu.MCP.Auth.Server.Errors
    alias Noizu.MCP.Auth.Server.JWKSPlug
    alias Noizu.MCP.Auth.Server.PlugSupport
    alias Noizu.MCP.Auth.Server.RegistrationPlug
    alias Noizu.MCP.Auth.Server.RevokePlug
    alias Noizu.MCP.Auth.Server.TokenPlug
    alias Noizu.MCP.Auth.Server.Upstream

    @impl Plug
    def init(opts) do
      config = PlugSupport.config(opts)

      # Only the endpoints this router serves. `:api_token` is mounted separately
      # and its last path segment ("token") would otherwise collide with the
      # token endpoint's and shadow it — a 404 on every token exchange.
      %{
        config: config,
        routes:
          config.paths
          |> Map.take([:authorize, :consent, :callback, :token, :register, :revoke, :jwks])
          |> Map.new(fn {name, path} ->
            {path |> String.split("/", trim: true) |> List.last(), name}
          end)
      }
    end

    @impl Plug
    def call(conn, %{config: config, routes: routes}) do
      segment = conn.path_info |> List.last()

      case Map.get(routes, segment) do
        :authorize -> AuthorizePlug.call(conn, config)
        :consent -> AuthorizePlug.consent(conn, config)
        :callback -> callback(conn, config)
        :token -> TokenPlug.call(conn, config)
        :register -> RegistrationPlug.call(conn, config)
        :revoke -> RevokePlug.call(conn, config)
        :jwks -> JWKSPlug.call(conn, config)
        _ -> not_found(conn)
      end
    end

    # Only `Upstream.OIDC` runs its own callback leg; `Upstream.HostSession` has
    # the host's own SSO controller land the user back on `/oauth/authorize`.
    defp callback(conn, %Config{} = config) do
      if Upstream.handles_callback?(config) do
        {:ok, conn, params} = PlugSupport.read_params(conn)

        case Upstream.callback(conn, params, config) do
          {:ok, identity, state} ->
            {adapter, store_opts} = Config.store(config)
            _ = adapter.update_login_state(state, %{"subject" => identity.subject}, store_opts)

            PlugSupport.redirect(
              conn,
              Config.url(config, :authorize) <> "?login_state=" <> URI.encode_www_form(state)
            )

          {:error, reason} ->
            PlugSupport.error_page(conn, Errors.new(:server_error, reason: {:upstream, reason}))
        end
      else
        not_found(conn)
      end
    end

    defp not_found(conn) do
      PlugSupport.json(
        conn,
        404,
        Errors.to_map(Errors.new(:invalid_request, reason: :no_such_endpoint))
      )
    end
  end
end
