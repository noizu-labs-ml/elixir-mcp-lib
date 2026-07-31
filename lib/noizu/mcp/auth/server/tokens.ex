defmodule Noizu.MCP.Auth.Server.Tokens do
  @moduledoc """
  Minting: access tokens (signed JWTs), refresh tokens and authorization codes
  (opaque random, hashed at rest).

  ## No token passthrough

  Everything here is minted from a subject this server resolved locally — from
  the host's own session, or from an upstream authorization code this server
  itself exchanged. An inbound bearer is **never** re-emitted, wrapped, or
  forwarded upstream. That is the MCP spec's token-passthrough prohibition, and
  it is a property of this module: no function takes an inbound token as input.

  ## Audience

  Every access token carries exactly one `aud`: the canonical resource URI of the
  mount it is for. Not a list — a single string, so
  `Noizu.MCP.Auth.JWTVerifier` can insist on an exact match and a token for
  `/mcp` cannot open `/mcp/learning`.
  """

  alias Noizu.MCP.Auth.Server.Config
  alias Noizu.MCP.Auth.Server.Store
  alias Noizu.MCP.Auth.Server.Store.AccessToken
  alias Noizu.MCP.Auth.Server.Store.AuthorizationCode
  alias Noizu.MCP.Auth.Server.Store.RefreshToken

  @type grant :: %{
          required(:subject) => String.t(),
          required(:client_id) => String.t(),
          optional(:scope) => [String.t()],
          optional(:resource) => String.t() | nil,
          optional(:family_id) => String.t() | nil
        }

  @doc """
  Mint a signed access token. Returns `{:ok, jwt, claims}`.

  `jti` is random per token so a tracked token can be revoked individually.
  """
  @spec mint_access_token(Config.t(), grant()) :: {:ok, String.t(), map()}
  def mint_access_token(%Config{} = config, grant) do
    now = System.system_time(:second)
    jti = Store.generate_token()

    claims =
      %{
        "iss" => config.issuer,
        "sub" => grant.subject,
        "aud" => grant[:resource],
        "client_id" => grant.client_id,
        "scope" => Enum.join(grant[:scope] || [], " "),
        "jti" => jti,
        "iat" => now,
        "nbf" => now,
        "exp" => now + config.access_token_ttl
      }
      |> maybe_put("family_id", grant[:family_id])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    {:ok, sign(config, claims), claims}
  end

  @doc """
  Record an issued access token, when `track_access_tokens: true` and the adapter
  supports it. A no-op otherwise: the 15-minute TTL is what bounds an untracked
  token.
  """
  @spec track_access_token(Config.t(), map(), grant()) :: :ok
  def track_access_token(%Config{track_access_tokens: false}, _claims, _grant), do: :ok

  def track_access_token(%Config{} = config, claims, grant) do
    {adapter, store_opts} = Config.store(config)

    if Store.supports?(adapter, {:put_access_token, 2}) do
      record = %AccessToken{
        jti: claims["jti"],
        client_id: grant.client_id,
        subject: grant.subject,
        scope: grant[:scope] || [],
        resource: grant[:resource],
        family_id: grant[:family_id],
        expires_at: DateTime.from_unix!(claims["exp"])
      }

      _ = adapter.put_access_token(record, store_opts)
    end

    :ok
  end

  @doc """
  Mint a refresh token. Returns `{:ok, raw_token, %RefreshToken{}}`; the raw value
  goes to the client, the struct to the store (which hashes it).

  `family_id` is inherited from the authorization code, so a whole rotation chain
  can be revoked at once when one link is replayed.
  """
  @spec mint_refresh_token(Config.t(), grant()) :: {:ok, String.t(), RefreshToken.t()}
  def mint_refresh_token(%Config{} = config, grant) do
    token = Store.generate_token()
    now = DateTime.utc_now()

    record = %RefreshToken{
      id: Store.generate_id(),
      token: token,
      client_id: grant.client_id,
      subject: grant.subject,
      scope: grant[:scope] || [],
      resource: grant[:resource],
      family_id: grant[:family_id] || Store.generate_id(),
      expires_at: DateTime.add(now, config.refresh_token_ttl, :second),
      family_expires_at: family_deadline(config, grant, now)
    }

    {:ok, token, record}
  end

  @doc """
  Mint an authorization code bound to the PKCE challenge, the redirect URI and the
  resource the request asked for.

  All three are checked again at redemption. The `refresh_family_id` allocated
  here is what the refresh token inherits.
  """
  @spec mint_authorization_code(Config.t(), map()) :: {:ok, String.t(), AuthorizationCode.t()}
  def mint_authorization_code(%Config{} = config, request) do
    code = Store.generate_token()

    record = %AuthorizationCode{
      code: code,
      client_id: request.client_id,
      subject: request.subject,
      redirect_uri: request.redirect_uri,
      scope: request[:scope] || [],
      resource: request[:resource],
      code_challenge: request.code_challenge,
      code_challenge_method: "S256",
      nonce: request[:nonce],
      refresh_family_id: request[:family_id] || Store.generate_id(),
      upstream_ref: request[:upstream_ref],
      expires_at: DateTime.add(DateTime.utc_now(), config.authorization_code_ttl, :second),
      inserted_at: DateTime.utc_now()
    }

    {:ok, code, record}
  end

  @doc """
  The RFC 6749 §5.1 token response body.

  `scope` is echoed **always**, not only when it differs from the request: a client
  that asked for more than it got has to be able to see that without diffing.
  """
  @spec token_response(Config.t(), String.t(), [String.t()], String.t() | nil) :: map()
  def token_response(%Config{} = config, access_token, scope, refresh_token) do
    %{
      "access_token" => access_token,
      "token_type" => "Bearer",
      "expires_in" => config.access_token_ttl,
      "scope" => Enum.join(scope, " ")
    }
    |> maybe_put("refresh_token", refresh_token)
  end

  @doc """
  Verifier options for a mount, derived from the same config that mints the
  tokens.

  Using this in `MCPConfig.plug_opts/2` is what keeps the issuer, the algorithm
  and the audience from drifting between the two halves — the failure mode being
  tokens that verify nowhere, with nothing in the logs to say why.

      auth: [verifier: {Noizu.MCP.Auth.JWTVerifier,
                        Noizu.MCP.Auth.Server.Tokens.verifier_opts(as_opts(), resource)}]
  """
  @spec verifier_opts(Config.t(), String.t()) :: keyword()
  def verifier_opts(%Config{} = config, resource) do
    base = [resource: resource, issuer: config.issuer, leeway: config.leeway]

    case config.signing do
      {:hs256, secret} -> base ++ [secret: secret, algorithms: ["HS256"]]
      {:rs256, rs_opts} -> base ++ [jwk: public_jwk(rs_opts), algorithms: ["RS256"]]
    end
  end

  @doc """
  The JWKS document — RS256 mode only. In HS256 mode there is no public key to
  publish, and the metadata document omits `jwks_uri` accordingly.
  """
  @spec jwks(Config.t()) :: %{required(String.t()) => list()}
  def jwks(%Config{signing: {:rs256, rs_opts}}) do
    key =
      rs_opts
      |> public_jwk()
      |> JOSE.JWK.to_map()
      |> elem(1)
      |> Map.merge(%{"use" => "sig", "alg" => "RS256"})
      |> then(fn map ->
        case Keyword.get(rs_opts, :kid) do
          nil -> map
          kid -> Map.put(map, "kid", kid)
        end
      end)

    %{"keys" => [key]}
  end

  def jwks(%Config{}), do: %{"keys" => []}

  @doc "Sign a claim set with the configured key."
  @spec sign(Config.t(), map()) :: String.t()
  def sign(%Config{signing: {:hs256, secret}}, claims) do
    secret
    |> resolve_secret()
    |> JOSE.JWK.from_oct()
    |> JOSE.JWT.sign(%{"alg" => "HS256", "typ" => "at+jwt"}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  def sign(%Config{signing: {:rs256, rs_opts}}, claims) do
    header =
      %{"alg" => "RS256", "typ" => "at+jwt"}
      |> then(fn header ->
        case Keyword.get(rs_opts, :kid) do
          nil -> header
          kid -> Map.put(header, "kid", kid)
        end
      end)

    rs_opts
    |> private_jwk()
    |> JOSE.JWT.sign(header, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  @doc """
  Resolve the HS256 secret. Accepts a binary, `{mod, fun}` or a 0-arity fun, so a
  release reads it from runtime config rather than baking it into the build.
  """
  @spec resolve_secret(term()) :: String.t()
  def resolve_secret(secret) when is_binary(secret), do: secret
  def resolve_secret({module, fun}), do: resolve_secret(apply(module, fun, []))
  def resolve_secret(fun) when is_function(fun, 0), do: resolve_secret(fun.())

  defp family_deadline(%Config{refresh_family_ttl: nil}, _grant, _now), do: nil

  defp family_deadline(%Config{} = config, grant, now) do
    # A rotation inherits the family's existing deadline (the store copies it
    # over); this only applies to the first token in a family.
    grant[:family_expires_at] || DateTime.add(now, config.refresh_family_ttl, :second)
  end

  defp private_jwk(rs_opts) do
    case Keyword.fetch!(rs_opts, :jwk) do
      %JOSE.JWK{} = jwk -> jwk
      map when is_map(map) -> JOSE.JWK.from_map(stringify(map))
      pem when is_binary(pem) -> JOSE.JWK.from_pem(pem)
    end
  end

  defp public_jwk(rs_opts), do: rs_opts |> private_jwk() |> JOSE.JWK.to_public()

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
