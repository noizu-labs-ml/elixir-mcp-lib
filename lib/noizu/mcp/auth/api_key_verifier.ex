defmodule Noizu.MCP.Auth.ApiKeyVerifier do
  @moduledoc """
  Accepts a raw API key presented as a bearer token.

  Headless callers (a cron job, a CI step, a CLI that cannot open a browser)
  have no way to run the OAuth dance. This verifier lets them present a
  long-lived key in the same `Authorization: Bearer` header, so a mount can
  serve both audiences — pair it with `Noizu.MCP.Auth.ChainVerifier`.

      auth: [
        verifier: {Noizu.MCP.Auth.ChainVerifier, [
          verifiers: [
            {Noizu.MCP.Auth.JWTVerifier, [resource: resource, secret: {MyApp, :secret}]},
            {Noizu.MCP.Auth.ApiKeyVerifier, [
              resource: resource,
              prefix: "mcp_live_",
              validator: {MyApp.MCPKeys, :verify}
            ]}
          ]
        ]}
      ]

  The key store belongs to the host — only it knows the table. `:validator` is
  called with the presented key and must answer
  `{:ok, claims}` | `{:error, reason}` | `false` | `nil`. It **must** compare
  against a hash, not a plaintext column; `Noizu.MCP.Auth.Server.Secret`
  provides `token_hash/1` and a constant-time `equal?/2` for that.

  ## Options

    * `:validator` (required unless `:keys` is given) — `{module, function}`,
      `{module, function, extra_args}` (the key is prepended), or a 1-arity fun.
    * `:keys` — a static `[{key, claims}]` list, compared in constant time.
      For tests and single-operator deployments; a real key list belongs in a
      database, behind `:validator`.
    * `:resource` — canonical resource URI of the mount. Stamped onto the
      claims as `aud` when the validator did not set one: an API key is bound
      to a resource by *where it was configured*, and downstream code that
      reads `aud` should see the same shape either way.
    * `:prefix` — required key prefix. A cheap non-secret shape check that
      keeps obviously-wrong credentials (an OAuth JWT, say) from reaching the
      database on every request.
    * `:scopes` — scopes the resulting claims must carry, checked exactly as
      `Noizu.MCP.Auth.JWTVerifier` does.
    * `:default_claims` — merged under whatever the validator returns (e.g.
      `%{"scope" => "mcp"}`).

  Failure is always `{:error, :invalid_token}` — a caller cannot distinguish
  "no such key" from "revoked key" from "wrong prefix".
  """

  @behaviour Noizu.MCP.Auth.TokenVerifier

  alias Noizu.MCP.Auth.JWTVerifier
  alias Noizu.MCP.Auth.Resource
  alias Noizu.MCP.Auth.Server.Secret

  @impl true
  def verify(token, _conn_info, opts) when is_binary(token) and is_list(opts) do
    with :ok <- check_prefix(token, Keyword.get(opts, :prefix)),
         {:ok, claims} <- validate(token, opts),
         claims <- stamp(claims, opts),
         :ok <- check_scopes(claims, Keyword.get(opts, :scopes, [])) do
      {:ok, claims}
    else
      {:error, :insufficient_scope, meta} -> {:error, :insufficient_scope, meta}
      _ -> {:error, :invalid_token}
    end
  end

  def verify(_token, _conn_info, _opts), do: {:error, :invalid_token}

  defp check_prefix(_token, nil), do: :ok

  defp check_prefix(token, prefix) when is_binary(prefix) do
    if String.starts_with?(token, prefix), do: :ok, else: {:error, :invalid_token}
  end

  defp validate(token, opts) do
    case {Keyword.fetch(opts, :validator), Keyword.fetch(opts, :keys)} do
      {{:ok, validator}, _} -> normalize_result(apply_validator(validator, token))
      {_, {:ok, keys}} -> static_lookup(token, keys)
      _ -> {:error, :not_configured}
    end
  end

  defp apply_validator({module, fun}, token), do: apply(module, fun, [token])
  defp apply_validator({module, fun, args}, token), do: apply(module, fun, [token | args])
  defp apply_validator(fun, token) when is_function(fun, 1), do: fun.(token)
  defp apply_validator(_validator, _token), do: {:error, :not_configured}

  defp normalize_result({:ok, claims}) when is_map(claims), do: {:ok, claims}
  defp normalize_result(claims) when is_map(claims), do: {:ok, claims}
  defp normalize_result(_other), do: {:error, :invalid_token}

  # Constant-time over the whole list: every candidate is compared, and the
  # comparison itself is length-independent, so neither the match position nor
  # a shared prefix is observable in the timing.
  defp static_lookup(token, keys) do
    Enum.reduce(keys, {:error, :invalid_token}, fn {key, claims}, acc ->
      if Secret.equal?(token, key), do: {:ok, claims}, else: acc
    end)
  end

  defp stamp(claims, opts) do
    claims = Map.merge(Keyword.get(opts, :default_claims, %{}), claims)

    case Keyword.fetch(opts, :resource) do
      {:ok, resource} ->
        case Resource.normalize(resource) do
          {:ok, resource} -> Map.put_new(claims, "aud", resource)
          {:error, :invalid_resource} -> claims
        end

      :error ->
        claims
    end
  end

  defp check_scopes(_claims, []), do: :ok

  defp check_scopes(claims, required) do
    held = JWTVerifier.scopes(claims)

    if Enum.all?(required, &(&1 in held)) do
      :ok
    else
      {:error, :insufficient_scope, %{"scope" => Enum.join(required, " ")}}
    end
  end
end
