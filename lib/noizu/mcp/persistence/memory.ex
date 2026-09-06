defmodule Noizu.MCP.Persistence.Memory do
  @moduledoc """
  The default persistence provider (PRD-4 §4.2): one lazily-created public ETS
  table (`:noizu_mcp_persistence`), rows `{{store_key, id}, json, expires_at,
  sort}`. The JSON payload and the record codec are shared with every other
  provider through `Noizu.MCP.Persistence.encode_record/2` /
  `decode_record/2` — this module owns storage mechanics only (AP-8: no
  per-provider semantics).

  `version/2` is an in-ETS monotonic counter per store_key (rendered as a
  decimal string), bumped by every put and delete — Store-driven bumps rotate
  catalog_version / cache keys without record reads (FR-4.11). Rows sort
  `inserted_at desc` via `{inserted_at, sort}` where `sort` is a monotonic
  unique integer — the negotiation "most recent wins" rule reads straight off
  list order.
  """

  @behaviour Noizu.MCP.Persistence

  alias Noizu.MCP.Persistence

  @table :noizu_mcp_persistence
  @version_marker :__version__

  @impl true
  def put(store_key, id, record, _opts) when is_binary(id) do
    with :ok <- Persistence.guard_store_key(store_key),
         {:ok, json, _fields, meta} <- Persistence.encode_record(store_key, record) do
      table()

      :ets.insert(@table, {
        {store_key, id},
        json,
        meta.expires_at,
        {meta.inserted_at, :erlang.unique_integer([:monotonic])}
      })

      bump_version(store_key)
      :ok
    end
  end

  def put(_store_key, _id, _record, _opts), do: {:error, {:invalid_id, "id must be a string"}}

  @impl true
  def get(store_key, id, _opts) when is_binary(id) do
    with :ok <- Persistence.guard_store_key(store_key) do
      case lookup(store_key, id) do
        [{_key, json, expires_at, _sort}] ->
          if expired?(expires_at) do
            :error
          else
            Persistence.decode_record(store_key, json)
          end

        [] ->
          :error
      end
    end
  end

  def get(_store_key, _id, _opts), do: {:error, {:invalid_id, "id must be a string"}}

  @impl true
  def list(store_key, filter, _opts) do
    with :ok <- Persistence.guard_store_key(store_key) do
      filter = filter || %{}
      at = Map.get(filter, :at) || DateTime.utc_now()

      rows =
        try do
          :ets.match_object(@table, {{store_key, :_}, :_, :_, :_})
        catch
          # Table raced away / never existed — an empty store lists empty.
          :error, _ -> []
        end

      records =
        rows
        |> Enum.reject(fn {_key, _json, expires_at, _sort} -> expired?(expires_at, at) end)
        |> Enum.sort_by(
          fn {_key, _json, _expires_at, {inserted_at, sort}} ->
            {DateTime.to_unix(inserted_at, :microsecond), sort}
          end,
          :desc
        )
        |> Enum.map(fn {_key, json, _expires_at, _sort} ->
          case Persistence.decode_record(store_key, json) do
            {:ok, record} ->
              record

            {:error, reason} ->
              # A corrupted row corrupts the SET (PRD-4 D5: "corrupt stored
              # set ⇒ disabled with reason + telemetry"): raise so the context
              # pass degrades THIS toolset loudly instead of silently serving
              # half a policy.
              raise "corrupt #{store_key} row: #{inspect(reason)}"
          end
        end)
        |> Enum.filter(&Persistence.match_filter?(&1, filter))

      {:ok, records}
    end
  end

  @impl true
  def delete(store_key, id, _opts) when is_binary(id) do
    with :ok <- Persistence.guard_store_key(store_key) do
      try do
        :ets.delete(@table, {store_key, id})
      catch
        :error, _ -> :ok
      end

      bump_version(store_key)
      :ok
    end
  end

  def delete(_store_key, _id, _opts), do: {:error, {:invalid_id, "id must be a string"}}

  @impl true
  def version(store_key, _opts) do
    with :ok <- Persistence.guard_store_key(store_key) do
      counter =
        try do
          case :ets.lookup(@table, {store_key, @version_marker}) do
            [{_key, n}] when is_integer(n) -> n
            [] -> 0
          end
        catch
          :error, _ -> 0
        end

      {:ok, Integer.to_string(counter)}
    end
  end

  @doc """
  Wipe every row (records AND version counters). Test/dev hygiene only — the
  conformance battery needs a store that starts empty; production callers have
  no business resetting a shared table.
  """
  # ⟦𓊪𓅱𓏏⟧ reset :: Wipe every row (records AND version counters). Test/dev hygiene only — the.
  @spec reset() :: :ok
  def reset do
    try do
      :ets.delete_all_objects(@table)
    catch
      :error, _ -> :ok
    end

    :ok
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp lookup(store_key, id) do
    try do
      :ets.lookup(@table, {store_key, id})
    catch
      :error, _ -> []
    end
  end

  defp expired?(nil), do: false

  defp expired?(%DateTime{} = expires_at),
    do: Persistence.expired?(%{expires_at: expires_at}, DateTime.utc_now())

  defp expired?(_other), do: false

  defp expired?(nil, _at), do: false

  defp expired?(%DateTime{} = expires_at, at),
    do: Persistence.expired?(%{expires_at: expires_at}, at)

  defp expired?(_other, _at), do: false

  defp bump_version(store_key) do
    try do
      table()

      :ets.update_counter(
        @table,
        {store_key, @version_marker},
        1,
        {{store_key, @version_marker}, 0}
      )
    catch
      :error, _ -> :ok
    end

    :ok
  end

  # Lazily-created named public table; the catch makes the create race-safe
  # (the loser of a race keeps using the winner's table) — same posture as
  # Noizu.MCP.Toolset.Cache.
  defp table do
    case :ets.whereis(@table) do
      :undefined ->
        owner = spawn_table_owner()

        try do
          :ets.new(@table, [
            :named_table,
            :public,
            read_concurrency: true,
            write_concurrency: true,
            # PRD-11: a put can arrive from an EPHEMERAL process (a session
            # handler task). Without an heir the table would die with its
            # creator, silently dropping every stored record — so ownership
            # transfers to a parked owner process that never exits.
            heir: owner
          ])
        catch
          _kind, _reason -> :ok
        end

        @table

      ref ->
        ref
    end
  end

  # The parked heir: keeps the table alive no matter which process created it.
  defp spawn_table_owner do
    spawn(fn ->
      Process.flag(:trap_exit, true)
      receive_loop()
    end)
  end

  defp receive_loop do
    receive do
      :stop -> :ok
      _other -> receive_loop()
    end
  end
end
