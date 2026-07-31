defmodule Noizu.MCP.Auth.Server.Upstream.HostSession do
  @moduledoc """
  The default `Noizu.MCP.Auth.Server.Upstream`: reuse the host application's
  **existing** login.

  The host already knows how to authenticate a person — session cookie, Authentik
  OIDC, MFA, the lot. Two callbacks are all this needs:

      upstream: {Noizu.MCP.Auth.Server.Upstream.HostSession,
                 current_subject: {MyApp.Auth.MCPBridge, :current_subject},
                 login_url:       {MyApp.Auth.MCPBridge, :login_url}}

      defmodule MyApp.Auth.MCPBridge do
        # (conn) -> {:ok, subject} | {:ok, %{subject: ...}} | :none
        def current_subject(conn) do
          case conn.assigns[:current_user] do
            %{id: id} -> {:ok, to_string(id)}
            _ -> :none
          end
        end

        # (conn, return_to) -> url the browser should be sent to
        def login_url(_conn, return_to),
          do: "/sso/oidc?return_to=" <> URI.encode_www_form(return_to)
      end

  `return_to` is the authorization endpoint with the login state attached, so the
  user lands back mid-flow. **Validate it same-origin** in the host's SSO
  controller: a `return_to` an attacker chose is an open redirect, and the login
  screen is exactly where someone will try one. The URL this module builds is
  always same-origin with the configured issuer, so a same-origin check never
  rejects a legitimate one.

  ## Options

    * `:current_subject` (required) — `{mod, fun}` or 1-arity fun over the conn
    * `:login_url` (required) — `{mod, fun}` or 2-arity fun `(conn, return_to)`
    * `:return_to` — override how the return URL is built, `(conn, state, config)`

  The upstream session is used to answer one question — *who is this?* — and
  nothing else. No upstream token is read, stored, or passed on.
  """

  @behaviour Noizu.MCP.Auth.Server.Upstream

  alias Noizu.MCP.Auth.Server.Config
  alias Noizu.MCP.Auth.Server.Upstream

  @impl Upstream
  def authenticate(conn, state, %Config{} = config, opts) do
    case resolve_subject(conn, opts) do
      {:ok, identity} ->
        {:ok, identity}

      :none ->
        {:redirect, login_url(conn, state, config, opts)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_subject(conn, opts) do
    callback =
      Keyword.get(opts, :current_subject) ||
        raise ArgumentError, "Upstream.HostSession requires :current_subject"

    result =
      case callback do
        {module, fun} -> apply(module, fun, [conn])
        fun when is_function(fun, 1) -> fun.(conn)
      end

    case result do
      :none ->
        :none

      nil ->
        :none

      {:error, reason} ->
        {:error, reason}

      {:ok, value} ->
        with :error <- Upstream.normalize_identity(value), do: {:error, :bad_subject}

      value ->
        with :error <- Upstream.normalize_identity(value), do: {:error, :bad_subject}
    end
  end

  defp login_url(conn, state, config, opts) do
    return_to = return_to(conn, state, config, opts)

    case Keyword.get(opts, :login_url) ||
           raise(ArgumentError, "Upstream.HostSession requires :login_url") do
      {module, fun} -> apply(module, fun, [conn, return_to])
      fun when is_function(fun, 2) -> fun.(conn, return_to)
    end
  end

  defp return_to(conn, state, config, opts) do
    case Keyword.get(opts, :return_to) do
      nil ->
        # Resume at the authorization endpoint carrying only the login-state key.
        # The full authorization request lives in the store, so nothing sensitive
        # rides in a URL that will end up in the host's logs.
        Config.url(config, :authorize) <> "?login_state=" <> URI.encode_www_form(state)

      {module, fun} ->
        apply(module, fun, [conn, state, config])

      fun when is_function(fun, 3) ->
        fun.(conn, state, config)
    end
  end
end
