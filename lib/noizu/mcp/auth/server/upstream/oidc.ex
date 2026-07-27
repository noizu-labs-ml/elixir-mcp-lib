defmodule Noizu.MCP.Auth.Server.Upstream.OIDC do
  @moduledoc """
  Optional fallback `Noizu.MCP.Auth.Server.Upstream`: run an OIDC
  authorization-code round trip against the IdP ourselves.

  Only for a host with no browser session to reuse. Prefer
  `Noizu.MCP.Auth.Server.Upstream.HostSession` — a host that already logs people
  in should not grow a second login with its own session, its own callback, and
  its own bugs.

      upstream: {Noizu.MCP.Auth.Server.Upstream.OIDC,
                 issuer: "https://auth.derobot.is/application/o/myapp",
                 client_id: System.fetch_env!("OIDC_CLIENT_ID"),
                 client_secret: {MyApp.Secrets, :oidc_secret},
                 redirect_uri: "https://app.example.com/oauth/callback",
                 authorization_endpoint: "...", token_endpoint: "...",
                 scope: "openid profile email"}

  ## What is deliberately *not* sent upstream

  No RFC 8707 `resource` parameter. Authentik's support for it is unconfirmed, and
  it would not matter if it were: the upstream token is exchanged here, read for
  its `sub`, and discarded. It is never presented to an MCP client and never
  reaches a resource server, so there is no audience to narrow. Sending an
  unsupported parameter to an IdP that rejects unknown parameters would break the
  login for no benefit.

  Also not sent: anything the MCP client supplied. The downstream request's PKCE
  verifier, scope and `resource` belong to *our* grant, not to the upstream one;
  this leg runs its own PKCE.

  ## Options

    * `:client_id` (required), `:client_secret` (binary, `{mod, fun}`, or fun/0)
    * `:redirect_uri` (required) — must be registered with the IdP
    * `:authorization_endpoint` / `:token_endpoint` (required — discovery is the
      host's job, so a release does no network I/O at boot)
    * `:scope` — default `"openid profile email"`
    * `:subject_claim` — which ID-token claim becomes the subject, default `"sub"`
    * `:fetcher` — `{mod, fun}` for the token exchange, so this is testable and
      `:req` stays optional. Defaults to `Noizu.MCP.Auth.Server.CIMD.ReqFetcher`'s
      transport when `:req` is available.
  """

  @behaviour Noizu.MCP.Auth.Server.Upstream

  require Logger

  alias Noizu.MCP.Auth.Server.PKCE
  alias Noizu.MCP.Auth.Server.Store
  alias Noizu.MCP.Auth.Server.Upstream

  @impl Upstream
  def authenticate(_conn, state, config, opts) do
    verifier = PKCE.generate_verifier()
    {:ok, challenge} = PKCE.challenge(verifier)

    # The upstream leg gets its own PKCE verifier, stashed under the same login
    # state. The client's verifier is for our grant and never leaves the store.
    {adapter, store_opts} = config.store

    case adapter.update_login_state(state, %{"upstream_verifier" => verifier}, store_opts) do
      {:ok, _payload} ->
        {:redirect, authorization_url(state, challenge, opts)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Upstream
  def callback(_conn, params, config, opts) do
    with {:ok, code} <- fetch(params, "code"),
         {:ok, state} <- fetch(params, "state"),
         {adapter, store_opts} = config.store,
         {:ok, payload} <- adapter.get_login_state(state, store_opts),
         {:ok, verifier} <- Map.fetch(payload, "upstream_verifier"),
         {:ok, tokens} <- exchange(code, verifier, opts),
         {:ok, identity} <- identity(tokens, opts) do
      {:ok, identity, state}
    else
      :error -> {:error, :invalid_callback}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorization_url(state, challenge, opts) do
    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => fetch!(opts, :client_id),
        "redirect_uri" => fetch!(opts, :redirect_uri),
        "scope" => Keyword.get(opts, :scope, "openid profile email"),
        "state" => state,
        "nonce" => Store.generate_token(),
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      })

    fetch!(opts, :authorization_endpoint) <> "?" <> query
  end

  defp exchange(code, verifier, opts) do
    body =
      %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => fetch!(opts, :redirect_uri),
        "client_id" => fetch!(opts, :client_id),
        "code_verifier" => verifier
      }
      |> then(fn body ->
        case secret(opts) do
          nil -> body
          secret -> Map.put(body, "client_secret", secret)
        end
      end)

    case post(fetch!(opts, :token_endpoint), body, opts) do
      {:ok, %{"id_token" => _} = tokens} -> {:ok, tokens}
      {:ok, %{"access_token" => _} = tokens} -> {:ok, tokens}
      {:ok, _other} -> {:error, :upstream_token_error}
      {:error, reason} -> {:error, reason}
    end
  end

  defp identity(tokens, opts) do
    claim = Keyword.get(opts, :subject_claim, "sub")

    with {:ok, id_token} <- Map.fetch(tokens, "id_token"),
         {:ok, claims} <- peek(id_token),
         subject when is_binary(subject) <- Map.get(claims, claim) do
      {:ok, %{subject: subject, email: claims["email"], name: claims["name"], claims: claims}}
    else
      _ -> {:error, :no_subject}
    end
  end

  # The ID token arrives over a TLS-authenticated back channel from the token
  # endpoint we chose, so its signature adds nothing here (OIDC Core §3.1.3.7
  # allows skipping validation in exactly this case). Nothing from it is passed
  # on — only `sub` is read.
  defp peek(id_token) do
    case String.split(id_token, ".") do
      [_header, payload, _signature | _] ->
        with {:ok, json} <- Base.url_decode64(payload, padding: false),
             {:ok, claims} <- Jason.decode(json) do
          {:ok, claims}
        end

      _ ->
        :error
    end
  end

  defp post(url, body, opts) do
    case Keyword.get(opts, :fetcher) || default_fetcher() do
      nil ->
        Logger.error("Upstream.OIDC needs :fetcher, or :req in your deps")
        {:error, :no_fetcher}

      {module, fun} ->
        apply(module, fun, [url, body])

      fun when is_function(fun, 2) ->
        fun.(url, body)
    end
  end

  defp default_fetcher do
    if Code.ensure_loaded?(Req), do: {Noizu.MCP.Auth.Server.CIMD.ReqFetcher, :post_form}
  end

  defp secret(opts) do
    case Keyword.get(opts, :client_secret) do
      nil -> nil
      secret when is_binary(secret) -> secret
      {module, fun} -> apply(module, fun, [])
      fun when is_function(fun, 0) -> fun.()
    end
  end

  defp fetch(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end

  defp fetch!(opts, key) do
    Keyword.get(opts, key) || raise ArgumentError, "Upstream.OIDC requires #{inspect(key)}"
  end
end
