if Code.ensure_loaded?(Plug.Conn) do
  defmodule Noizu.MCP.Auth.Server.AgentKeysPlug do
    @moduledoc """
    `/oauth/keys` — an agent manages its own signing keys.

        GET    /oauth/keys                        → list
        POST   /oauth/keys                        → add (two proofs required)
        DELETE /oauth/keys?fingerprint=<thumbprint> → revoke

    Every method requires an access token that was obtained **by signature** —
    `amr` must contain `"sig"`. A password-authenticated token is refused, and so
    is an admin token. Enforcement lives in
    `Noizu.MCP.Auth.Server.Agent.add_key/3` and `revoke_key/3`; this plug does not
    re-check it, so there is exactly one place that decides.

    ## Why the fingerprint is a query parameter and not a path segment

    `Noizu.MCP.Auth.Server.Router` dispatches on the **last** path segment. A
    `DELETE /oauth/keys/<fingerprint>` would arrive with the fingerprint as that
    segment and match no route — a 404 that looks like the endpoint is missing. A
    host mounting this plug directly, outside the router, may of course route it
    however it likes.

    ## Adding a key needs two signatures

        POST /oauth/keys
        Authorization: Bearer <token with amr: ["sig"]>
        {"public_key": "<new key>",
         "label": "laptop",
         "proof_existing": "<JWS by a key already on the account>",
         "proof_new":      "<JWS by the new key, self-signed>"}

    Both proofs are ordinary compact JWS with claims
    `{iss, sub, aud: "<issuer>/oauth/keys", hdl, iat, exp, jti,
    "op": "add_key", "jkt": "<new key thumbprint>"}`.

    `proof_existing` is what stops a stolen bearer token from grafting a permanent
    identity onto the account. `proof_new` is what stops an account parking a
    public key it does not hold the private half of. Neither is redundant, and the
    reasoning for each is in `Agent.add_key/3`.
    """

    @behaviour Plug

    alias Noizu.MCP.Auth.Server.Agent
    alias Noizu.MCP.Auth.Server.Config
    alias Noizu.MCP.Auth.Server.PlugSupport

    @impl Plug
    def init(opts), do: PlugSupport.config(opts)

    @impl Plug
    def call(conn, %Config{} = config) do
      case PlugSupport.preflight(conn, "GET, POST, DELETE, OPTIONS") do
        nil -> serve(conn, config)
        answered -> answered
      end
    end

    defp serve(%{method: method} = conn, config) when method in ~w(GET POST DELETE) do
      conn = conn |> PlugSupport.cors() |> PlugSupport.no_store()

      with :ok <- PlugSupport.rate_limit(conn, config, :agent_keys),
           {:ok, conn, params} <- PlugSupport.read_params(conn),
           {:ok, claims} <- authenticate(conn, config),
           {:ok, status, body} <- dispatch(method, config, claims, params) do
        PlugSupport.json(conn, status, body)
      else
        {:error, %Plug.Conn{} = rate_limited} -> rate_limited
        {:error, code} when is_atom(code) -> agent_error(conn, code)
      end
    end

    defp serve(conn, _config),
      do: PlugSupport.method_not_allowed(conn, "GET, POST, DELETE, OPTIONS")

    defp authenticate(conn, config) do
      case PlugSupport.bearer(conn) do
        nil -> {:error, :invalid_session}
        token -> Agent.verify_token(config, token)
      end
    end

    defp dispatch("GET", config, claims, _params) do
      with {:ok, body} <- Agent.list_keys(config, claims), do: {:ok, 200, body}
    end

    defp dispatch("POST", config, claims, params) do
      with {:ok, body} <- Agent.add_key(config, claims, params), do: {:ok, 201, body}
    end

    defp dispatch("DELETE", config, claims, params) do
      case Map.get(params, "fingerprint") do
        fingerprint when is_binary(fingerprint) and fingerprint != "" ->
          with {:ok, body} <- Agent.revoke_key(config, claims, fingerprint),
               do: {:ok, 200, body}

        _ ->
          {:error, :not_found}
      end
    end

    defp agent_error(conn, code) do
      {status, body} = Agent.error(code)
      PlugSupport.json(conn, status, body)
    end
  end
end
