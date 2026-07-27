defmodule Noizu.MCP.Auth.ChainVerifier do
  @moduledoc """
  Tries several verifiers in order and takes the first success.

  This is what lets one mount serve both an interactive agent holding an OAuth
  access token and a headless script holding an API key, without the mount
  needing to know which is which:

      auth: [
        verifier: {Noizu.MCP.Auth.ChainVerifier, [
          verifiers: [
            {Noizu.MCP.Auth.JWTVerifier, [resource: resource, secret: {MyApp, :secret}]},
            {Noizu.MCP.Auth.ApiKeyVerifier, [resource: resource, validator: {MyApp.Keys, :verify}]}
          ]
        ]}
      ]

  A bare list is also accepted (`{Noizu.MCP.Auth.ChainVerifier, [{Mod, opts}, ...]}`).

  Order by cost, cheapest first — a JWT verifies with no database round trip,
  an API key usually needs one.

  ## Failure is uniform

  When every verifier rejects, the answer is a single `{:error, :invalid_token}`
  with no indication of which link rejected it or how far the token got. A
  chain is otherwise an oracle: "this failed at the API-key step" tells an
  attacker their string was accepted as a JWT.

  The one exception is `{:error, :insufficient_scope, meta}` — the first
  verifier to report it wins, and it propagates so the client gets the 403
  step-up hint it needs. That is not an oracle: the caller already holds a
  token the server accepted, and is only being told which scope is missing.

  A verifier that raises is treated as a rejection and logged (without the
  token), so one misconfigured link cannot 500 the mount or fail it open.
  """

  @behaviour Noizu.MCP.Auth.TokenVerifier

  require Logger

  @impl true
  def verify(token, conn_info, opts) do
    opts
    |> verifiers()
    |> Enum.reduce_while({:error, :invalid_token}, fn verifier, acc ->
      case attempt(verifier, token, conn_info) do
        {:ok, claims} -> {:halt, {:ok, claims}}
        {:error, :insufficient_scope, meta} -> {:cont, first_scope_error(acc, meta)}
        _ -> {:cont, acc}
      end
    end)
  end

  defp verifiers(opts) when is_list(opts) do
    case Keyword.fetch(opts, :verifiers) do
      {:ok, verifiers} -> verifiers
      # A bare `[{Mod, opts}, ...]` list is itself a keyword list, so this
      # fallback has to come second.
      :error -> opts
    end
  end

  defp verifiers(_opts), do: []

  defp attempt({module, verifier_opts}, token, conn_info) do
    module.verify(token, conn_info, verifier_opts)
  rescue
    error ->
      Logger.warning(
        "Noizu.MCP.Auth.ChainVerifier: #{inspect(module)} raised " <>
          "#{inspect(error.__struct__)}; treating as invalid_token"
      )

      {:error, :invalid_token}
  end

  defp attempt(module, token, conn_info) when is_atom(module),
    do: attempt({module, []}, token, conn_info)

  defp first_scope_error({:error, :insufficient_scope, _} = existing, _meta), do: existing
  defp first_scope_error(_acc, meta), do: {:error, :insufficient_scope, meta}
end
