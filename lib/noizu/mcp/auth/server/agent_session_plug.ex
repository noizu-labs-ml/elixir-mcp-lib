if Code.ensure_loaded?(Plug.Conn) do
  defmodule Noizu.MCP.Auth.Server.AgentSessionPlug do
    @moduledoc """
    `POST /oauth/session` — open an anonymous session. **No credentials required.**

    This is the entry point for an autonomous agent that has never been here
    before. It hands up a public key and receives a short-lived token, a session
    id, a nonce to sign, and the answer to *"do I already have an account?"*.

        POST /oauth/session
        {"public_key": "<base64url Ed25519>",
         "client": {"name": "my-agent", "version": "1.2.0", "model": "..."}}

        200 {"session_token": "...", "session_id": "...", "nonce": "...",
             "expires_in": 600, "key_fingerprint": "...",
             "token_endpoint": "https://…/oauth/token",
             "account": null, "registration_required": true}

    ## Why an unauthenticated write endpoint is acceptable here

    It creates a row, so it is a spam target, and it is protected the same way the
    rest of the server is: `:rate_limit` on the config, keyed by the host's own
    limiter. What it deliberately does *not* do is anything expensive or anything
    an attacker can read back — no key generation, no account, no email, no
    lookup that leaks whether a handle exists. The worst outcome of a flood is a
    table of expired sessions that `purge_expired/2` sweeps.

    `registration_required` is the field that keeps a returning agent from
    hammering registration: an agent whose key is already known gets its account
    back here and skips straight to the token endpoint.
    """

    @behaviour Plug

    alias Noizu.MCP.Auth.Server.Agent
    alias Noizu.MCP.Auth.Server.Config
    alias Noizu.MCP.Auth.Server.PlugSupport

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
      conn = conn |> PlugSupport.cors() |> PlugSupport.no_store()

      with :ok <- PlugSupport.rate_limit(conn, config, :agent_session),
           {:ok, conn, params} <- PlugSupport.read_params(conn),
           {:ok, body} <- Agent.start_session(config, params, remote_ip: conn.remote_ip) do
        PlugSupport.json(conn, 200, body)
      else
        {:error, %Plug.Conn{} = rate_limited} -> rate_limited
        {:error, code} when is_atom(code) -> agent_error(conn, code)
      end
    end

    defp serve(conn, _config), do: PlugSupport.method_not_allowed(conn, "POST, OPTIONS")

    defp agent_error(conn, code) do
      {status, body} = Agent.error(code)
      PlugSupport.json(conn, status, body)
    end
  end
end
