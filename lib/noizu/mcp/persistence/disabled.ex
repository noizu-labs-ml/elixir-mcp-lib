defmodule Noizu.MCP.Persistence.Disabled do
  @moduledoc """
  The `:disabled` persistence provider (PRD-4 §4.2): every call is
  `{:error, :persistence_disabled}`.

  This is a POLICY of no persisted layers, not an outage (D5): the context
  pass treats it as "no persisted layers" and skips SILENTLY — no warning, no
  error telemetry — while an enabled provider's `{:error, _}` degrades loudly.
  The supervisor never starts a boot `ping` child for it (a policy must not
  block boot).
  """

  @behaviour Noizu.MCP.Persistence

  @impl true
  def put(_store_key, _id, _record, _opts), do: {:error, :persistence_disabled}

  @impl true
  def get(_store_key, _id, _opts), do: {:error, :persistence_disabled}

  @impl true
  def list(_store_key, _filter, _opts), do: {:error, :persistence_disabled}

  @impl true
  def delete(_store_key, _id, _opts), do: {:error, :persistence_disabled}

  @impl true
  def version(_store_key, _opts), do: {:error, :persistence_disabled}
end
