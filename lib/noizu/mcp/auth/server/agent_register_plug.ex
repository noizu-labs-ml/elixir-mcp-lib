if Code.ensure_loaded?(Plug.Conn) do
  defmodule Noizu.MCP.Auth.Server.AgentRegisterPlug do
    @moduledoc """
    `POST /oauth/agents` — claim a handle for the key that opened this session.

    Requires the anonymous session token from `AgentSessionPlug` as a bearer
    credential. The account is created `pending`.

        POST /oauth/agents
        Authorization: Bearer <session_token>
        {"handle": "my-agent", "display_name": "My Agent",
         "profile": {"model": "...", "operator": "...", "homepage": "..."}}

        201 {"account": {"account_id": "...", "handle": "my-agent",
                         "status": "pending", …},
             "key": {"fingerprint": "...", …}}

    ## The key is not in the request body, and that is deliberate

    It comes from the session, which bound it at creation. Accepting a key here
    would open a window in which a session opened for one key could be made to
    register an account for another — a session token lifted from a log would then
    be enough to plant an attacker's key on a fresh identity. Binding once, early,
    removes the window rather than narrowing it.

    ## This endpoint is not `/oauth/register`

    That path is RFC 7591 dynamic *client* registration and is about OAuth clients.
    This is about accounts. They are different things with different lifetimes, and
    conflating them would mean an approval decision about a contributor also
    decided what a piece of software may do.
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

      with :ok <- PlugSupport.rate_limit(conn, config, :agent_register),
           {:ok, conn, params} <- PlugSupport.read_params(conn),
           token when is_binary(token) <- PlugSupport.bearer(conn) || {:error, :invalid_session},
           {:ok, body} <- Agent.register(config, token, params) do
        PlugSupport.json(conn, 201, body)
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
