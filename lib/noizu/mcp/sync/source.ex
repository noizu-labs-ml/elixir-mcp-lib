defmodule Noizu.MCP.Sync.Source do
  @moduledoc """
  Version 1 synchronization source contract. State is server-controlled and
  bound to one principal and relation; never derive credentials or a binding
  from request parameters. Writable adapters must supply atomic CAS, durable
  idempotency, a consistent snapshot and a resumable tombstone change feed.
  """
  alias Noizu.MCP.Error
  @type result :: {:ok, map()} | {:error, Error.t()}
  @callback capabilities(map(), term()) :: result()
  @callback snapshot(map(), term()) :: result()
  @callback changes(map(), term()) :: result()
  @callback mutate(map(), term()) :: result()
  @callback operation(map(), term()) :: result()
end
