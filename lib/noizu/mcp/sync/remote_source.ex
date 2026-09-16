defmodule Noizu.MCP.Sync.RemoteSource do
  @moduledoc """
  Sync Source over an already authenticated MCP Client. State contains
  `%{client: client_pid, relation: "upstream.notes"}`. The host owns the client
  and its credential lifecycle; use a distinct authenticated session per
  principal. Engine targets must negotiate sync/version 1 and use pass-through.
  """
  @behaviour Noizu.MCP.Sync.Source
  alias Noizu.MCP.{Client, Error}
  alias Noizu.MCP.Sync.Protocol

  for {function, method} <- [
        capabilities: "sync/capabilities",
        snapshot: "sync/snapshot",
        changes: "sync/changes",
        mutate: "sync/mutate",
        operation: "sync/operation"
      ] do
    @impl true
    def unquote(function)(params, state), do: request(unquote(method), params, state)
  end

  defp request(method, %{"relation" => relation} = params, %{client: client, relation: relation}) do
    with %{"version" => 1} <- get_in(Client.server_capabilities(client), ["experimental", "sync"]) do
      case Client.request(client, method, params) do
        {:ok, result} when is_map(result) -> {:ok, result}
        {:error, %Error{reason: :forbidden}} -> {:error, Protocol.error("permission_denied")}
        {:error, %Error{}} = error -> error
        _ -> {:error, Protocol.error("unknown")}
      end
    else
      _ -> {:error, Protocol.error("unsupported_consistency")}
    end
  end

  defp request(_, _, _), do: {:error, Protocol.error("permission_denied")}
end
