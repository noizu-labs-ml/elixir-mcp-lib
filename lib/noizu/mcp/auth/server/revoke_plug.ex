if Code.ensure_loaded?(Plug.Conn) do
  defmodule Noizu.MCP.Auth.Server.RevokePlug do
    @moduledoc """
    Token revocation (RFC 7009) — `POST /oauth/revoke`.

    Accepts a refresh token or an access token, with an optional
    `token_type_hint`. Must skip CSRF protection; answers `no-store`.

    ## Always 200

    RFC 7009 §2.2 is explicit: an unknown token is a **success**. The client asked
    for the token to stop working, and it does not work — that is the outcome it
    wanted. Answering 400 would turn this endpoint into a free oracle for testing
    whether a token exists.

    Revoking a refresh token revokes **its whole family**. A caller asking to
    invalidate a token wants the session gone, not to be handed the token it was
    already rotated into.

    An access token is revoked only with `track_access_tokens: true`; otherwise its
    ≤15-minute expiry is the bound. Its `jti` is read only after verifying the
    signature with our own key — an unverified JWT's `jti` is attacker-chosen, and
    acting on one would let anyone revoke anyone's tokens.
    """

    @behaviour Plug

    alias Noizu.MCP.Auth.Server
    alias Noizu.MCP.Auth.Server.Client
    alias Noizu.MCP.Auth.Server.Config
    alias Noizu.MCP.Auth.Server.Errors
    alias Noizu.MCP.Auth.Server.Params
    alias Noizu.MCP.Auth.Server.PlugSupport
    alias Noizu.MCP.Auth.Server.Store
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

      with {:ok, conn, params} <- PlugSupport.read_params(conn),
           {:ok, client} <- authenticate_client(conn, params, config),
           {:ok, token} <- Params.fetch(params, "token") do
        revoke(config, client, token, Map.get(params, "token_type_hint"))
        PlugSupport.json(conn, 200, %{})
      else
        # A bad client credential is the one case that is *not* a success: it is
        # not this caller's token to revoke.
        {:error, %Errors{code: :invalid_client} = error} -> PlugSupport.error_json(conn, error)
        {:error, %Errors{}} -> PlugSupport.json(conn, 200, %{})
      end
    end

    defp serve(conn, _config), do: PlugSupport.method_not_allowed(conn, "POST, OPTIONS")

    defp authenticate_client(conn, params, config) do
      with {:ok, {client_id, secret}} <- PlugSupport.client_credentials(conn, params),
           {:ok, client} <- Server.resolve_client(config, client_id),
           :ok <- Client.authenticate(client, secret, Keyword.get(config.dcr, :secret_opts, [])) do
        {:ok, client}
      end
    end

    defp revoke(config, client, token, hint) do
      {adapter, store_opts} = Config.store(config)

      case hint do
        "access_token" ->
          revoke_access_token(config, client, token)

        _ ->
          # Try the refresh table first (the common case), then the access-token
          # path. Neither branch reports which one matched.
          case adapter.get_refresh_token(token, store_opts) do
            {:ok, record} ->
              if record.client_id == client.client_id do
                _ = adapter.revoke_refresh_family(record.family_id, store_opts)
              end

              :ok

            _ ->
              revoke_access_token(config, client, token)
          end
      end
    end

    defp revoke_access_token(config, client, token) do
      {adapter, store_opts} = Config.store(config)

      with true <- config.track_access_tokens,
           true <- Store.supports?(adapter, {:revoke_access_token, 2}),
           {:ok, claims} <- verify_own_token(config, token),
           true <- claims["client_id"] == client.client_id,
           jti when is_binary(jti) <- claims["jti"] do
        _ = adapter.revoke_access_token(jti, store_opts)
        :ok
      else
        _ -> :ok
      end
    end

    # Verify with our own signing key before trusting anything in the token.
    defp verify_own_token(config, token) do
      jwk =
        case config.signing do
          {:hs256, secret} -> secret |> Tokens.resolve_secret() |> JOSE.JWK.from_oct()
          {:rs256, _} -> nil
        end

      algorithms =
        case config.signing do
          {:hs256, _} -> ["HS256"]
          {:rs256, _} -> ["RS256"]
        end

      jwk =
        jwk ||
          config
          |> Tokens.verifier_opts(config.issuer)
          |> Keyword.get(:jwk)

      case JOSE.JWT.verify_strict(jwk, algorithms, token) do
        {true, %JOSE.JWT{fields: claims}, _jws} -> {:ok, claims}
        _ -> :error
      end
    rescue
      _ -> :error
    end
  end
end
