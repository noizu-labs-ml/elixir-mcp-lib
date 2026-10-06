if Code.ensure_loaded?(Plug.Conn) do
  defmodule Noizu.MCP.Auth.Server.Upstream.Password do
    @moduledoc """
    A self-contained username/password login for the built-in authorization
    server — the upstream for a host with no session and no IdP.

    Like `Noizu.MCP.Auth.Server.Upstream.OIDC` this runs its own round trip, but
    it is one page instead of a federation: `authenticate/4` renders a login
    form that POSTs to the authorization server's own callback path, and
    `callback/4` checks the credentials and resumes the flow at consent.

        upstream: {Noizu.MCP.Auth.Server.Upstream.Password,
                   users: %{
                     "alice" => Noizu.MCP.Auth.Server.Secret.token_hash("…"),
                     "svc"   => Noizu.MCP.Auth.Server.Secret.token_hash("…")
                   }}

    …or with a host validator, which is what a real user store wants (hash the
    password there with bcrypt/Argon2 — this module never sees a plaintext at
    rest):

        upstream: {Noizu.MCP.Auth.Server.Upstream.Password,
                   validator: {MyApp.Accounts, :mcp_login}}

    `MyApp.Accounts.mcp_login/2` receives `(username, password)` and answers
    `{:ok, %{scopes: [...], claims: %{...}}}` or `:error` — the same shape
    `Noizu.MCP.Auth.BasicVerifier` validates, and the same call that verifier
    makes, so one validator can serve both.

    On a failed attempt the form is re-rendered with a single generic message:
    "Invalid username or password" is all a wrong credential ever earns, so the
    endpoint cannot be used to enumerate users.

    ## Options

      * `:validator` — `{module, function}`, `{module, function, extra_args}`,
        or a 2-arity fun over `(username, password)`.
      * `:users` — a static `%{username => Secret.token_hash(password)}` map
        (used when `:validator` is absent). For tests and single-operator
        deployments.
      * `:scopes`, `:default_claims` — what a validator that named no scopes
        grants, and claims merged under the identity's claims.
      * `:title` — the form's heading. Default `"Sign in"`.

    The credential **stops here**: the identity is `%{subject: username, claims:
    ...}`, and what reaches the MCP client is a token this server minted.
    """

    @behaviour Noizu.MCP.Auth.Server.Upstream

    import Plug.Conn

    alias Noizu.MCP.Auth.BasicVerifier, as: Basic
    alias Noizu.MCP.Auth.Server.Config
    alias Noizu.MCP.Auth.Server.PlugSupport
    alias Noizu.MCP.Auth.Server.Upstream

    @impl Upstream
    def authenticate(conn, state, %Config{} = config, opts) do
      {:sent, send_form(conn, Config.url(config, :callback), state, nil, opts)}
    end

    @impl Upstream
    def callback(conn, params, %Config{} = config, opts) do
      with {:ok, state} <- fetch_state(params),
           {:ok, username} <- fetch_field(params, "username"),
           {:ok, password} <- fetch_field(params, "password"),
           {:ok, granted} <- Basic.validate_credentials(username, password, opts) do
        claims =
          Map.merge(Keyword.get(opts, :default_claims, %{}), granted.claims)
          |> put_scope(granted.scopes)

        {:ok, %{subject: username, claims: claims}, state}
      else
        # A wrong credential leaves the login state live, so the form is
        # re-rendered mid-flow with a generic message — the response goes on
        # the conn here, and `{:sent, conn}` tells the router the response is
        # already owned. A missing/expired state key cannot re-render a form
        # for a dead flow; that surfaces as the flow's own error page instead.
        {:error, :invalid_credentials} ->
          case fetch_state(params) do
            {:ok, state} ->
              conn = send_form(conn, Config.url(config, :callback), state,
                "Invalid username or password.", opts
              )

              {:sent, conn}

            :error ->
              {:error, :invalid_callback}
          end

        _ ->
          {:error, :invalid_callback}
      end
    end

    defp send_form(conn, action, state, error, opts) do
      body = render_form(action, state, error, opts)

      conn
      |> PlugSupport.no_store()
      |> put_resp_content_type("text/html")
      |> send_resp(200, body)
    end

    @doc false
    def render_form(action, state, error, opts) do
      title = Keyword.get(opts, :title, "Sign in")
      error_html = if error, do: ~s(<p class="error">#{escape(error)}</p>), else: ""

      """
      <!DOCTYPE html>
      <html lang="en"><head>
      <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
      <title>#{escape(title)}</title>
      <style>
        :root { color-scheme: light dark; }
        body { font: 16px/1.5 system-ui, sans-serif; max-width: 24rem; margin: 4rem auto; padding: 0 1rem; }
        h1 { font-size: 1.3rem; }
        label { display: block; margin-top: 1rem; }
        input { width: 100%; box-sizing: border-box; font: inherit; padding: .5rem; border-radius: 6px; border: 1px solid rgba(127,127,127,.5); }
        button { font: inherit; margin-top: 1.25rem; padding: .6rem 1.2rem; border-radius: 6px; border: 1px solid transparent; background: #2563eb; color: #fff; cursor: pointer; }
        .error { background: rgba(200,40,40,.12); padding: .75rem; border-radius: 6px; }
      </style>
      </head><body>
      <h1>#{escape(title)}</h1>
      #{error_html}
      <form method="post" action="#{escape(action)}">
        <input type="hidden" name="login_state" value="#{escape(state)}">
        <label>Username <input type="text" name="username" autocomplete="username" required></label>
        <label>Password <input type="password" name="password" autocomplete="current-password" required></label>
        <button type="submit">Sign in</button>
      </form>
      </body></html>
      """
    end

    defp fetch_state(params) do
      case Map.get(params, "login_state") do
        state when is_binary(state) and state != "" -> {:ok, state}
        _ -> :error
      end
    end

    defp fetch_field(params, key) do
      case Map.get(params, key) do
        value when is_binary(value) and value != "" -> {:ok, value}
        _ -> :error
      end
    end

    defp put_scope(claims, []), do: claims

    defp put_scope(claims, scopes) do
      if Map.has_key?(claims, "scope") or Map.has_key?(claims, "scopes") do
        claims
      else
        Map.put(claims, "scope", Enum.join(scopes, " "))
      end
    end

    defp escape(value) do
      value
      |> to_string()
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
      |> String.replace("\"", "&quot;")
      |> String.replace("'", "&#39;")
    end
  end
end
