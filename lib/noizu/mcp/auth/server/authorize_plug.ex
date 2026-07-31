if Code.ensure_loaded?(Plug.Conn) do
  defmodule Noizu.MCP.Auth.Server.AuthorizePlug do
    @moduledoc """
    The authorization endpoint (RFC 6749 §4.1.1, OAuth 2.1) and the consent
    decision that goes with it.

    Mounted by `Noizu.MCP.Auth.Server.Router` at `GET /oauth/authorize` and
    `POST /oauth/consent`. Needs a session pipeline (it redirects a browser through
    your login and renders a form) but must **not** require an authenticated user —
    resolving that is this endpoint's job.

    ## The flow

    1. **Validate the request.** `client_id` resolves to a client (a stored one, or
       a CIMD document fetched under the SSRF guard); `redirect_uri` matches one the
       client registered. Until *both* hold, every error is a **rendered page** —
       never a redirect. Afterwards, errors go back to the validated URI as
       `?error=`, which is what a client needs to fail cleanly.
    2. **PKCE, mandatory.** `code_challenge` with `code_challenge_method=S256`.
       Absent or `plain` is `invalid_request`, for confidential clients too.
    3. **Park the request.** Everything is written to login state under a random
       key; only that key travels in URLs, so no scope, challenge or `state` ends
       up in the host's access logs.
    4. **Authenticate the human** through `Noizu.MCP.Auth.Server.Upstream` —
       normally the host's own session. Not logged in ⇒ redirect to the host's
       login with a `return_to` that lands back here.
    5. **Consent**, mandatory for registered and CIMD clients, CSRF-protected, and
       re-prompted when the requested scope broadens.
    6. **Issue the code** and redirect with `code`, the client's `state`, and `iss`
       (RFC 9207).

    An inbound `Authorization` header is never consulted for identity: an access
    token this server issued must not be usable to mint another.
    """

    @behaviour Plug

    alias Noizu.MCP.Auth.Server
    alias Noizu.MCP.Auth.Server.Config
    alias Noizu.MCP.Auth.Server.Consent
    alias Noizu.MCP.Auth.Server.Errors
    alias Noizu.MCP.Auth.Server.Params
    alias Noizu.MCP.Auth.Server.PKCE
    alias Noizu.MCP.Auth.Server.PlugSupport
    alias Noizu.MCP.Auth.Server.RedirectURI
    alias Noizu.MCP.Auth.Server.Store
    alias Noizu.MCP.Auth.Server.Tokens
    alias Noizu.MCP.Auth.Server.Upstream

    @impl Plug
    def init(opts), do: PlugSupport.config(opts)

    @impl Plug
    def call(conn, %Config{} = config) do
      case conn.method do
        "GET" -> authorize(conn, config)
        "POST" -> consent(conn, config)
        _ -> PlugSupport.method_not_allowed(conn, "GET, POST")
      end
    end

    @doc """
    `GET /oauth/authorize`. Also the landing point after the host's login, which
    comes back carrying `login_state`.
    """
    @spec authorize(Plug.Conn.t(), Config.t() | keyword()) :: Plug.Conn.t()
    def authorize(conn, opts) do
      config = PlugSupport.config(opts)
      {:ok, conn, params} = PlugSupport.read_params(conn)

      case Map.get(params, "login_state") do
        state when is_binary(state) and state != "" -> resume(conn, config, state)
        _ -> start(conn, config, params)
      end
    end

    @doc """
    `POST /oauth/consent` — the approve/deny decision from the consent form.
    """
    @spec consent(Plug.Conn.t(), Config.t() | keyword()) :: Plug.Conn.t()
    def consent(conn, opts) do
      config = PlugSupport.config(opts)
      {:ok, conn, params} = PlugSupport.read_params(conn)

      with {:ok, state} <- Params.fetch(params, "login_state"),
           {:ok, payload} <- load_state(config, state),
           :ok <- check_csrf(payload, params),
           {:ok, client} <- Server.resolve_client(config, payload["client_id"]),
           {:ok, subject} <- stated_subject(payload) do
        request = to_request(payload)

        case Map.get(params, "decision") do
          "approve" ->
            :ok = Consent.record(client, subject, request.scope, request.resource, config)
            issue_code(conn, config, client, subject, request, state)

          _ ->
            # A denial is a normal outcome, and the client is told so at the
            # redirect URI it registered — not on a page the user has to read.
            _ = take_state(config, state)

            PlugSupport.error_redirect(
              conn,
              request.redirect_uri,
              Errors.new(:access_denied, reason: :user_denied)
              |> Errors.with_state(request.state),
              config
            )
        end
      else
        {:error, %Errors{} = error} -> PlugSupport.error_page(conn, error)
      end
    end

    # ── step 1: a fresh authorization request ──────────────────────────────

    defp start(conn, config, params) do
      # Phase one: nothing may redirect. An unresolved client or an unregistered
      # redirect_uri means we have no URI we are allowed to send anything to.
      with {:ok, client_id} <- Params.fetch(params, "client_id", code: :invalid_client),
           {:ok, client} <- Server.resolve_client(config, client_id),
           {:ok, requested_uri} <- Params.optional(params, "redirect_uri"),
           {:ok, redirect_uri} <- resolve_redirect_uri(requested_uri, client) do
        # Phase two: the redirect URI is validated, so errors may go back to it.
        state = Params.optional(params, "state") |> unwrap()

        with {:ok, _} <- check_response_type(params),
             {:ok, challenge} <- check_pkce(params),
             {:ok, scope} <- check_scope(params, client, config),
             {:ok, resource} <- check_resource(params, config) do
          request = %{
            client_id: client.client_id,
            redirect_uri: redirect_uri,
            scope: scope,
            resource: resource,
            code_challenge: challenge,
            state: state,
            nonce: Params.optional(params, "nonce") |> unwrap()
          }

          park_and_continue(conn, config, client, request)
        else
          {:error, %Errors{} = error} ->
            PlugSupport.error_redirect(
              conn,
              redirect_uri,
              Errors.with_state(error, state),
              config
            )
        end
      else
        {:error, %Errors{} = error} -> PlugSupport.error_page(conn, error)
      end
    end

    defp park_and_continue(conn, config, client, request) do
      state_key = Store.generate_token()

      payload =
        request
        |> Map.new(fn {key, value} -> {to_string(key), value} end)
        |> Map.put("csrf_token", Consent.csrf_token())

      {adapter, store_opts} = Config.store(config)

      case adapter.put_login_state(state_key, payload, config.login_state_ttl, store_opts) do
        :ok ->
          authenticate(conn, config, client, state_key, payload)

        {:error, reason} ->
          PlugSupport.error_page(conn, Errors.new(:server_error, reason: reason))
      end
    end

    # ── step 4: resume after login, or after the IdP callback ──────────────

    defp resume(conn, config, state_key) do
      with {:ok, payload} <- load_state(config, state_key),
           {:ok, client} <- Server.resolve_client(config, payload["client_id"]) do
        authenticate(conn, config, client, state_key, payload)
      else
        {:error, %Errors{} = error} -> PlugSupport.error_page(conn, error)
      end
    end

    defp authenticate(conn, config, client, state_key, payload) do
      case Upstream.authenticate(conn, state_key, config) do
        {:ok, identity} ->
          record_subject(config, state_key, identity)
          gate_consent(conn, config, client, identity.subject, state_key, payload)

        {:redirect, url} ->
          PlugSupport.redirect(conn, url)

        {:error, reason} ->
          PlugSupport.error_page(conn, Errors.new(:server_error, reason: {:upstream, reason}))
      end
    end

    defp record_subject(config, state_key, identity) do
      {adapter, store_opts} = Config.store(config)
      _ = adapter.update_login_state(state_key, %{"subject" => identity.subject}, store_opts)
      :ok
    end

    # ── step 5: consent ────────────────────────────────────────────────────

    defp gate_consent(conn, config, client, subject, state_key, payload) do
      request = to_request(payload)

      case Consent.required?(client, subject, request.scope, config) do
        :skip ->
          issue_code(conn, config, client, subject, request, state_key)

        {:prompt, _reason} ->
          render_consent(conn, config, client, subject, request, state_key, payload)
      end
    end

    defp render_consent(conn, config, client, subject, request, state_key, payload) do
      assigns = %{
        client: client,
        subject: subject,
        scope: request.scope,
        resource: request.resource,
        csrf_token: payload["csrf_token"],
        login_state: state_key,
        action: Config.url(config, :consent)
      }

      case Keyword.get(config.consent, :renderer) do
        nil ->
          conn
          |> PlugSupport.no_store()
          |> Plug.Conn.put_resp_content_type("text/html")
          |> Plug.Conn.send_resp(200, Consent.render_html(assigns))

        {module, fun} ->
          apply(module, fun, [conn, assigns])

        fun when is_function(fun, 2) ->
          fun.(conn, assigns)
      end
    end

    # ── step 6: issue the code ─────────────────────────────────────────────

    defp issue_code(conn, config, client, subject, request, state_key) do
      # Consume the login state: one authenticated, consented flow yields exactly
      # one code, and a replayed callback URL yields nothing.
      _ = take_state(config, state_key)

      {:ok, code, record} =
        Tokens.mint_authorization_code(config, %{
          client_id: client.client_id,
          subject: subject,
          redirect_uri: request.redirect_uri,
          scope: request.scope,
          resource: request.resource,
          code_challenge: request.code_challenge,
          nonce: request.nonce
        })

      {adapter, store_opts} = Config.store(config)

      case adapter.put_authorization_code(record, store_opts) do
        :ok ->
          query =
            %{"code" => code, "iss" => config.issuer}
            |> then(fn query ->
              if request.state, do: Map.put(query, "state", request.state), else: query
            end)

          PlugSupport.redirect(conn, PlugSupport.append_query(request.redirect_uri, query))

        {:error, reason} ->
          PlugSupport.error_redirect(
            conn,
            request.redirect_uri,
            Errors.new(:server_error, reason: reason) |> Errors.with_state(request.state),
            config
          )
      end
    end

    # ── validation ─────────────────────────────────────────────────────────

    defp resolve_redirect_uri(requested, client) do
      case RedirectURI.resolve(requested, client.redirect_uris) do
        {:ok, uri} -> {:ok, uri}
        {:error, reason} -> {:error, Errors.new(:invalid_redirect_uri, reason: reason)}
      end
    end

    defp check_response_type(params) do
      case Map.get(params, "response_type") do
        "code" ->
          {:ok, "code"}

        _ ->
          # Implicit and hybrid flows are gone in OAuth 2.1; there is nothing to
          # fall back to.
          {:error, Errors.new(:unsupported_response_type, reason: :not_code)}
      end
    end

    defp check_pkce(params) do
      challenge = Map.get(params, "code_challenge")
      method = Map.get(params, "code_challenge_method")

      cond do
        not PKCE.valid_method?(method) ->
          {:error, Errors.new(:invalid_request, reason: :pkce_method)}

        not PKCE.valid_challenge?(challenge) ->
          {:error, Errors.new(:invalid_request, reason: :pkce_challenge)}

        true ->
          {:ok, challenge}
      end
    end

    defp check_scope(params, client, config) do
      with {:ok, requested} <- Params.space_list(params, "scope") do
        requested = if requested == [], do: default_scope(client, config), else: requested
        permitted = permitted_scope(client, config)

        case Params.within_scope(requested, permitted) do
          {:ok, scope} -> {:ok, scope}
          {:error, error} -> {:error, error}
        end
      end
    end

    defp default_scope(client, config) do
      case client.scope do
        [] -> config.default_scope
        scope -> scope
      end
    end

    # A client can never be granted more than it registered for, and never more
    # than the server supports — the intersection, not the union.
    defp permitted_scope(client, config) do
      case client.scope do
        [] -> config.scopes_supported
        scope -> Enum.filter(scope, &(&1 in config.scopes_supported))
      end
    end

    defp check_resource(params, config) do
      with {:ok, requested} <- Params.optional(params, "resource") do
        case Server.resolve_resource(config, requested) do
          {:ok, resource} ->
            {:ok, resource}

          {:error, :invalid_target} ->
            {:error, Errors.new(:invalid_target, reason: :unknown_resource)}
        end
      end
    end

    defp check_csrf(payload, params) do
      if Consent.valid_csrf?(payload, Map.get(params, "csrf_token")) do
        :ok
      else
        {:error, Errors.new(:invalid_request, reason: :bad_csrf_token)}
      end
    end

    defp stated_subject(payload) do
      case Map.get(payload, "subject") do
        subject when is_binary(subject) and subject != "" -> {:ok, subject}
        # The consent form is only rendered after the subject is recorded, so a
        # POST without one is a forged or stale submission.
        _ -> {:error, Errors.new(:invalid_request, reason: :no_subject_in_state)}
      end
    end

    defp load_state(config, state_key) do
      {adapter, store_opts} = Config.store(config)

      case adapter.get_login_state(state_key, store_opts) do
        {:ok, payload} -> {:ok, payload}
        _ -> {:error, Errors.new(:invalid_request, reason: :unknown_login_state)}
      end
    end

    defp take_state(config, state_key) do
      {adapter, store_opts} = Config.store(config)
      adapter.take_login_state(state_key, store_opts)
    end

    defp to_request(payload) do
      %{
        client_id: payload["client_id"],
        redirect_uri: payload["redirect_uri"],
        scope: List.wrap(payload["scope"]),
        resource: payload["resource"],
        code_challenge: payload["code_challenge"],
        state: payload["state"],
        nonce: payload["nonce"]
      }
    end

    defp unwrap({:ok, value}), do: value
    defp unwrap(_other), do: nil
  end
end
