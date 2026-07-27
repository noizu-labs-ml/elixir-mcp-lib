defmodule Noizu.MCP.Auth.JWTVerifier do
  @moduledoc """
  Audience-checking JWT verifier for an MCP mount.

  The one thing `Noizu.MCP.Auth.CompoundJWTVerifier` does not do is bind the
  token to *this* resource. This verifier does, and that binding is the point:
  a token minted for `https://host/mcp` is rejected at `https://host/mcp/learning`
  and vice versa, so a mount cannot be used as a confused deputy for its
  neighbour.

      forward "/mcp/learning", Noizu.MCP.Transport.StreamableHTTP.Plug,
        server: MyApp.Learning.MCP,
        auth: [
          verifier: {Noizu.MCP.Auth.JWTVerifier, [
            resource: "https://app.example.com/mcp/learning",
            issuer: "https://app.example.com",
            secret: {MyApp.MCPAuth, :secret},
            algorithms: ["HS256"],
            scopes: ["mcp"]
          ]},
          resource_metadata: :derive
        ]

  ## Options

    * `:resource` (required) — the canonical resource URI of this mount. The
      token's `aud` must match it exactly (see below).
    * `:secret` — HMAC secret: a binary, `{module, function}`, or a 0-arity fun
      resolved per request (so a release reads it from runtime config, not from
      a compile-time literal).
    * `:jwk` — an asymmetric key, as a `JOSE.JWK` or a JWK map. Use instead of
      `:secret` for RS256/ES256.
    * `:algorithms` — allowed JWS algorithms, default `["HS256"]`. **Always
      read from config, never from the token header** — that is what makes
      `alg: "none"` and HS/RS confusion non-issues here.
    * `:issuer` — required `iss` claim, when set.
    * `:scopes` — scopes every token must carry, else
      `{:error, :insufficient_scope, %{"scope" => ...}}` (→ 403 step-up).
    * `:leeway` — clock skew allowance in seconds for `exp`/`nbf`, default `0`.
    * `:subject_required` — reject a token with no `sub`, default `true`. An
      MCP tool handler that authorizes on `ctx.assigns.auth_claims["sub"]`
      silently authorizes nobody when `sub` is missing.

  ## Audience matching

  `aud` must be either the configured resource as a string, or a **single**
  element list holding it. A multi-audience token is rejected: it is valid at
  more than one resource, which is exactly the property audience binding exists
  to remove. Our own authorization server mints single-audience tokens, so this
  costs nothing and closes the case where an upstream IdP is talked into adding
  an audience.
  """

  @behaviour Noizu.MCP.Auth.TokenVerifier

  alias Noizu.MCP.Auth.Resource

  @impl true
  def verify(token, _conn_info, opts) when is_binary(token) and is_list(opts) do
    with {:ok, resource} <- resource(opts),
         {:ok, jwk} <- key(opts),
         algorithms <- Keyword.get(opts, :algorithms, ["HS256"]),
         {true, %JOSE.JWT{fields: claims}, _jws} <-
           JOSE.JWT.verify_strict(jwk, algorithms, token),
         :ok <- check_time(claims, Keyword.get(opts, :leeway, 0)),
         :ok <- check_issuer(claims, Keyword.get(opts, :issuer)),
         :ok <- check_audience(claims, resource),
         :ok <- check_subject(claims, Keyword.get(opts, :subject_required, true)),
         :ok <- check_scopes(claims, Keyword.get(opts, :scopes, [])) do
      {:ok, claims}
    else
      {:error, :insufficient_scope, meta} -> {:error, :insufficient_scope, meta}
      # Every other rejection collapses to one answer — a caller learns that
      # the token was refused, never why.
      _ -> {:error, :invalid_token}
    end
  rescue
    # JOSE raises on structurally broken tokens.
    _ -> {:error, :invalid_token}
  end

  def verify(_token, _conn_info, _opts), do: {:error, :invalid_token}

  @doc """
  The scopes a token carries, as a list. Handy in tool handlers reading
  `ctx.assigns.auth_claims`.
  """
  @spec scopes(map()) :: [String.t()]
  def scopes(claims) do
    case claims do
      %{"scope" => scope} when is_binary(scope) -> String.split(scope, " ", trim: true)
      %{"scopes" => scopes} when is_list(scopes) -> Enum.map(scopes, &to_string/1)
      %{"scp" => scopes} when is_list(scopes) -> Enum.map(scopes, &to_string/1)
      %{"scp" => scope} when is_binary(scope) -> String.split(scope, " ", trim: true)
      _ -> []
    end
  end

  defp resource(opts) do
    case Keyword.fetch(opts, :resource) do
      {:ok, resource} -> Resource.normalize(resource)
      :error -> {:error, :missing_resource}
    end
  end

  defp key(opts) do
    case {Keyword.fetch(opts, :secret), Keyword.fetch(opts, :jwk)} do
      {{:ok, secret}, _} -> hmac_key(secret)
      {_, {:ok, %JOSE.JWK{} = jwk}} -> {:ok, jwk}
      {_, {:ok, jwk}} when is_map(jwk) -> {:ok, JOSE.JWK.from_map(stringify(jwk))}
      _ -> {:error, :missing_key}
    end
  end

  defp hmac_key(secret) when is_binary(secret) and byte_size(secret) > 0,
    do: {:ok, JOSE.JWK.from_oct(secret)}

  defp hmac_key({module, fun}), do: hmac_key(apply(module, fun, []))
  defp hmac_key(fun) when is_function(fun, 0), do: hmac_key(fun.())
  defp hmac_key(_), do: {:error, :missing_key}

  defp stringify(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp check_time(claims, leeway) do
    now = System.system_time(:second)

    expired? =
      case claims["exp"] do
        exp when is_number(exp) -> now >= exp + leeway
        # An access token with no expiry is not an access token.
        _ -> true
      end

    too_early? =
      case claims["nbf"] do
        nbf when is_number(nbf) -> now + leeway < nbf
        _ -> false
      end

    if expired? or too_early?, do: {:error, :invalid_token}, else: :ok
  end

  defp check_issuer(_claims, nil), do: :ok
  defp check_issuer(%{"iss" => iss}, expected) when iss == expected, do: :ok
  defp check_issuer(_claims, _expected), do: {:error, :invalid_token}

  defp check_audience(%{"aud" => aud}, resource) when is_binary(aud) do
    if Resource.equal?(aud, resource), do: :ok, else: {:error, :invalid_token}
  end

  defp check_audience(%{"aud" => [aud]}, resource) when is_binary(aud),
    do: check_audience(%{"aud" => aud}, resource)

  # Multi-audience or missing audience: not bound to this resource.
  defp check_audience(_claims, _resource), do: {:error, :invalid_token}

  defp check_subject(_claims, false), do: :ok
  defp check_subject(%{"sub" => sub}, true) when is_binary(sub) and sub != "", do: :ok
  defp check_subject(_claims, true), do: {:error, :invalid_token}

  defp check_scopes(_claims, []), do: :ok

  defp check_scopes(claims, required) do
    held = scopes(claims)

    if Enum.all?(required, &(&1 in held)) do
      :ok
    else
      {:error, :insufficient_scope, %{"scope" => Enum.join(required, " ")}}
    end
  end
end
