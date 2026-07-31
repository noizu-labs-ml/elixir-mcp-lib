if Code.ensure_loaded?(Plug.Conn) do
  defmodule Noizu.MCP.Auth.Server.TokenPlug do
    @moduledoc """
    The token endpoint — `POST /oauth/token`. Two grants:
    `authorization_code` and `refresh_token`.

    Called by a machine with no cookie, so the route must **skip CSRF protection**;
    every response carries `cache-control: no-store`.

    ## What is checked on a code redemption

    All of it, every time — a code is only as good as its bindings:

      * redemption is **atomic and single-use**; a second attempt is a replay, and a
        replay revokes the whole refresh family rather than merely failing
      * the code was issued to *this* authenticated client
      * `redirect_uri` byte-matches the one the code was issued for
      * the PKCE verifier hashes to the stored challenge (S256, constant-time)
      * a `resource` in the request must equal the one the code was issued for — it
        may narrow nothing and widen nothing, because the audience was fixed at
        authorization time

    ## Refresh rotation

    Every refresh returns a **new** refresh token and retires the old one. Reusing a
    retired token is the signal that someone has a copy — and since there is no way
    to tell whether it is the client or an attacker, the entire family is revoked
    and both must re-authorize (RFC 6819 §5.2.2.3). A refresh may narrow scope; it
    can never broaden it.

    Every failure answers `invalid_grant` with a fixed description. A caller cannot
    tell an unknown code from an expired one from a stolen one.
    """

    @behaviour Plug

    require Logger

    alias Noizu.MCP.Auth.Server
    alias Noizu.MCP.Auth.Server.Client
    alias Noizu.MCP.Auth.Server.Config
    alias Noizu.MCP.Auth.Server.Errors
    alias Noizu.MCP.Auth.Server.Params
    alias Noizu.MCP.Auth.Server.PKCE
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

      with :ok <- PlugSupport.rate_limit(conn, config, :token),
           {:ok, conn, params} <- PlugSupport.read_params(conn),
           {:ok, client} <- authenticate_client(conn, params, config),
           {:ok, grant_type} <- Params.fetch(params, "grant_type"),
           :ok <- check_grant(client, grant_type),
           {:ok, body} <- grant(grant_type, client, params, config) do
        PlugSupport.json(conn, 200, body)
      else
        {:error, %Errors{} = error} -> PlugSupport.error_json(conn, error)
        {:error, %Plug.Conn{} = rate_limited} -> rate_limited
      end
    end

    defp serve(conn, _config), do: PlugSupport.method_not_allowed(conn, "POST, OPTIONS")

    # ── client authentication ──────────────────────────────────────────────

    defp authenticate_client(conn, params, config) do
      with {:ok, {client_id, secret}} <- PlugSupport.client_credentials(conn, params),
           {:ok, client} <- Server.resolve_client(config, client_id),
           :ok <- Client.authenticate(client, secret, Keyword.get(config.dcr, :secret_opts, [])) do
        {:ok, client}
      end
    end

    defp check_grant(client, grant_type) do
      cond do
        grant_type not in Client.grant_types() ->
          {:error, Errors.new(:unsupported_grant_type, reason: {:grant, grant_type})}

        not Client.supports_grant?(client, grant_type) ->
          {:error, Errors.new(:unauthorized_client, reason: {:grant, grant_type})}

        true ->
          :ok
      end
    end

    # ── authorization_code ─────────────────────────────────────────────────

    defp grant("authorization_code", client, params, config) do
      with {:ok, code} <- Params.fetch(params, "code", code: :invalid_grant),
           {:ok, verifier} <- Params.fetch(params, "code_verifier", code: :invalid_grant),
           {:ok, record} <- redeem(code, config),
           :ok <- check_code_client(record, client, config),
           :ok <- check_code_redirect_uri(record, params, config),
           :ok <- check_pkce(record, verifier, config),
           {:ok, resource} <- check_code_resource(record, params) do
        issue(config, client, %{
          subject: record.subject,
          scope: record.scope,
          resource: resource,
          family_id: record.refresh_family_id
        })
      end
    end

    # ── refresh_token ──────────────────────────────────────────────────────

    defp grant("refresh_token", client, params, config) do
      {adapter, store_opts} = Config.store(config)

      with {:ok, presented} <- Params.fetch(params, "refresh_token", code: :invalid_grant),
           {:ok, existing} <- fetch_refresh(adapter, store_opts, presented, client, config),
           :ok <- check_refresh_client(existing, client),
           {:ok, scope} <- narrowed_scope(params, existing),
           {:ok, resource} <- check_refresh_resource(existing, params),
           {:ok, token, record} <-
             mint_rotation(config, client, existing, scope, resource),
           {:ok, _old} <- rotate(adapter, store_opts, presented, record, config) do
        {:ok, access, claims} =
          Tokens.mint_access_token(config, %{
            subject: existing.subject,
            client_id: client.client_id,
            scope: scope,
            resource: resource,
            family_id: existing.family_id
          })

        :ok =
          Tokens.track_access_token(config, claims, %{
            subject: existing.subject,
            client_id: client.client_id,
            scope: scope,
            resource: resource,
            family_id: existing.family_id
          })

        {:ok, Tokens.token_response(config, access, scope, token)}
      end
    end

    defp grant(grant_type, _client, _params, _config),
      do: {:error, Errors.new(:unsupported_grant_type, reason: {:grant, grant_type})}

    # ── issuance ───────────────────────────────────────────────────────────

    defp issue(config, client, grant) do
      grant = Map.put(grant, :client_id, client.client_id)
      {:ok, access, claims} = Tokens.mint_access_token(config, grant)
      :ok = Tokens.track_access_token(config, claims, grant)

      refresh =
        if Client.supports_grant?(client, "refresh_token") do
          {:ok, token, record} = Tokens.mint_refresh_token(config, grant)
          {adapter, store_opts} = Config.store(config)

          case adapter.put_refresh_token(record, store_opts) do
            :ok ->
              token

            # A refresh token we could not store must not be handed out; the
            # access token still is, so the client is not stuck.
            {:error, reason} ->
              Logger.warning("Auth.Server: refresh token not stored (#{inspect(reason)})")
              nil
          end
        end

      {:ok, Tokens.token_response(config, access, grant[:scope] || [], refresh)}
    end

    defp mint_rotation(config, client, existing, scope, resource) do
      {:ok, token, record} =
        Tokens.mint_refresh_token(config, %{
          subject: existing.subject,
          client_id: client.client_id,
          scope: scope,
          resource: resource,
          family_id: existing.family_id,
          family_expires_at: existing.family_expires_at
        })

      {:ok, token, record}
    end

    # ── checks ─────────────────────────────────────────────────────────────

    defp redeem(code, config) do
      {adapter, store_opts} = Config.store(config)

      case adapter.take_authorization_code(code, store_opts) do
        {:ok, record} ->
          {:ok, record}

        {:error, {:replayed, record}} ->
          # Someone redeemed this code twice. Either the client is broken or a
          # copy leaked; revoke everything that came from it either way.
          revoke_family(config, record.refresh_family_id)
          {:error, Errors.new(:invalid_grant, reason: :code_replayed)}

        {:error, reason} ->
          {:error, Errors.new(:invalid_grant, reason: {:code, reason})}
      end
    end

    defp check_code_client(record, client, config) do
      if record.client_id == client.client_id do
        :ok
      else
        # The code was issued to somebody else. Treat it as compromised.
        revoke_family(config, record.refresh_family_id)
        {:error, Errors.new(:invalid_grant, reason: :code_client_mismatch)}
      end
    end

    defp check_code_redirect_uri(record, params, config) do
      case Params.optional(params, "redirect_uri") do
        {:ok, nil} ->
          # RFC 6749 §4.1.3 requires it whenever it was in the authorization
          # request, and it always is here.
          {:error, Errors.new(:invalid_grant, reason: :missing_redirect_uri)}

        {:ok, presented} ->
          if presented == record.redirect_uri do
            :ok
          else
            revoke_family(config, record.refresh_family_id)
            {:error, Errors.new(:invalid_grant, reason: :redirect_uri_mismatch)}
          end

        {:error, error} ->
          {:error, error}
      end
    end

    defp check_pkce(record, verifier, config) do
      case PKCE.verify(verifier, record.code_challenge, record.code_challenge_method) do
        :ok ->
          :ok

        {:error, :invalid_grant} ->
          # Whoever holds this code does not hold the verifier — which is the
          # definition of a stolen code.
          revoke_family(config, record.refresh_family_id)
          {:error, Errors.new(:invalid_grant, reason: :pkce_mismatch)}
      end
    end

    defp check_code_resource(record, params) do
      case Params.optional(params, "resource") do
        {:ok, nil} ->
          {:ok, record.resource}

        {:ok, requested} ->
          if Noizu.MCP.Auth.Resource.equal?(requested, record.resource) do
            {:ok, record.resource}
          else
            # The audience was fixed when the code was issued. A different one
            # here is a widening attempt, whichever direction it points.
            {:error, Errors.new(:invalid_target, reason: :resource_mismatch)}
          end

        {:error, error} ->
          {:error, error}
      end
    end

    defp fetch_refresh(adapter, store_opts, presented, client, config) do
      case adapter.get_refresh_token(presented, store_opts) do
        {:ok, record} ->
          {:ok, record}

        _ ->
          # `get_refresh_token/2` only returns *usable* tokens, so a rotated one
          # reads as missing here. That is where reuse detection would be lost:
          # probe the atomic rotation, which is the only operation that can tell
          # "already rotated" from "never existed". The probe record is never
          # stored — the guarded update finds no row to claim.
          detect_reuse(adapter, store_opts, presented, client, config)
      end
    end

    defp detect_reuse(adapter, store_opts, presented, client, config) do
      probe = %Noizu.MCP.Auth.Server.Store.RefreshToken{
        token: Noizu.MCP.Auth.Server.Store.generate_token(),
        client_id: client.client_id,
        subject: "reuse-probe",
        family_id: Noizu.MCP.Auth.Server.Store.generate_id(),
        expires_at: DateTime.utc_now()
      }

      case adapter.rotate_refresh_token(presented, probe, store_opts) do
        {:error, {:replayed, old}} ->
          revoke_family(config, old.family_id)
          {:error, Errors.new(:invalid_grant, reason: :refresh_replayed)}

        _ ->
          {:error, Errors.new(:invalid_grant, reason: :unknown_refresh_token)}
      end
    end

    defp check_refresh_client(existing, client) do
      if existing.client_id == client.client_id do
        :ok
      else
        {:error, Errors.new(:invalid_grant, reason: :refresh_client_mismatch)}
      end
    end

    defp narrowed_scope(params, existing) do
      with {:ok, requested} <- Params.space_list(params, "scope") do
        cond do
          requested == [] -> {:ok, existing.scope}
          Enum.all?(requested, &(&1 in existing.scope)) -> {:ok, requested}
          # A refresh may narrow. Broadening would let a token outgrow the consent
          # it was granted under.
          true -> {:error, Errors.new(:invalid_scope, reason: :scope_broadened_on_refresh)}
        end
      end
    end

    defp check_refresh_resource(existing, params) do
      case Params.optional(params, "resource") do
        {:ok, nil} ->
          {:ok, existing.resource}

        {:ok, requested} ->
          if Noizu.MCP.Auth.Resource.equal?(requested, existing.resource) do
            {:ok, existing.resource}
          else
            {:error, Errors.new(:invalid_target, reason: :resource_mismatch)}
          end

        {:error, error} ->
          {:error, error}
      end
    end

    defp rotate(adapter, store_opts, presented, record, config) do
      case adapter.rotate_refresh_token(presented, record, store_opts) do
        {:ok, old} ->
          {:ok, old}

        {:error, {:replayed, old}} ->
          revoke_family(config, old.family_id)
          {:error, Errors.new(:invalid_grant, reason: :refresh_replayed)}

        {:error, reason} ->
          {:error, Errors.new(:invalid_grant, reason: {:rotate, reason})}
      end
    end

    defp revoke_family(_config, nil), do: :ok

    defp revoke_family(config, family_id) do
      {adapter, store_opts} = Config.store(config)
      _ = adapter.revoke_refresh_family(family_id, store_opts)

      Logger.warning(
        "Auth.Server: revoked refresh family #{inspect(family_id)} after a replay or binding mismatch"
      )

      :ok
    end
  end
end
