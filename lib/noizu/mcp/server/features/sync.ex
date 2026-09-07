defmodule Noizu.MCP.Server.Features.Sync do
  @moduledoc """
  Explicit synchronization wire dispatch. Hosts opt in with `sync: true` and
  implement `handle_sync/3`; that callback must resolve a Source from trusted
  authenticated context. An opted-out server never advertises or dispatches
  this extension. No automatic Dataset.update fallback is provided.
  """
  alias Noizu.MCP.{Error, Sync.Protocol}

  def dispatch(server, method, params, ctx) do
    with :ok <- Protocol.validate(method, params) do
      case server.handle_sync(method, params, ctx) do
        {:ok, result} when is_map(result) -> {:ok, result}
        {:error, %Error{}} = error -> error
        _ -> {:error, Protocol.error("invalid_response")}
      end
    end
  end
end
