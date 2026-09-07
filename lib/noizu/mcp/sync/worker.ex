defmodule Noizu.MCP.Sync.Worker do
  @moduledoc """
  Opt-in, bounded per-binding synchronization worker. No process starts unless
  explicitly added to the host supervision tree with `enabled: true`.

      {Noizu.MCP.Sync.Worker,
       enabled: true, store_repo: CacheWorkerRepo, binding_id: cache_binding,
       source: {Noizu.MCP.Sync.RevisionedDataset,
                %{repo: SourceRepo, binding_id: source_binding, relation: "notes"}}}

  Each claim/apply/ack commits before any Source call. Leases and fencing live
  in PostgreSQL, so restarts and duplicate workers remain safe. Unknown outcomes
  retry the immutable operation ID only inside the source's dedupe guarantee.
  One worker processes one operation and one change page per polling interval.
  More bindings use more supervised children; no unbounded task spawning.
  """
  use GenServer
  alias Noizu.MCP.Sync.{Protocol, Store}

  def child_spec(opts),
    do: %{
      id: {__MODULE__, Keyword.fetch!(opts, :binding_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @impl true
  def init(opts) do
    if Keyword.get(opts, :enabled, false) do
      send(self(), :poll)
      {:ok, opts}
    else
      :ignore
    end
  end

  @impl true
  def format_status(status) do
    Map.put(status, :state, %{binding_id: Keyword.get(status.state, :binding_id)})
  end

  @impl true
  def handle_info(:poll, opts) do
    push = run_once(opts)
    pull = pull_once(opts)

    :telemetry.execute([:noizu_mcp, :sync, :poll], %{count: 1}, %{
      binding_id: Keyword.fetch!(opts, :binding_id),
      push: outcome(push),
      pull: outcome(pull)
    })

    Process.send_after(self(), :poll, Keyword.get(opts, :poll_interval, 1000))
    {:noreply, opts}
  end

  @doc "Claims and delivers at most one durable operation; never call inside a DB transaction."
  def run_once(opts), do: pause_on_auth(run_active(opts), opts)

  defp run_active(opts) do
    repo = Keyword.fetch!(opts, :store_repo)

    with :ok <- outside_transaction(repo),
         {:ok, checkpoint} <- Store.checkpoint(repo, Keyword.fetch!(opts, :binding_id)),
         :ok <- active(checkpoint),
         {:ok, caps} <- remote(opts, "sync/capabilities", %{}),
         :ok <- Protocol.writable(caps),
         {:ok, operation} <-
           Store.claim(
             repo,
             Keyword.fetch!(opts, :binding_id),
             Keyword.get(opts, :lease_seconds, 30)
           ) do
      if is_nil(operation), do: {:ok, :idle}, else: deliver(opts, operation, caps)
    end
  end

  @doc "Applies one change page atomically with its checkpoint, or starts a missing snapshot."
  def pull_once(opts), do: pause_on_auth(pull_active(opts), opts)

  defp pull_active(opts) do
    repo = Keyword.fetch!(opts, :store_repo)
    binding = Keyword.fetch!(opts, :binding_id)

    with :ok <- outside_transaction(repo),
         {:ok, checkpoint} <- Store.checkpoint(repo, binding),
         :ok <- active(checkpoint) do
      case checkpoint do
        %{"cursor" => cursor} when is_binary(cursor) ->
          with {:ok, %{"events" => events, "nextCursor" => next_cursor}} <-
                 remote(opts, "sync/changes", %{"cursor" => cursor, "limit" => 500}) do
            Store.apply_changes(repo, binding, events, next_cursor)
          end

        _ ->
          snapshot(opts)
      end
    end
  end

  @doc "Stages a bounded immutable snapshot in memory and publishes only when all pages complete."
  def snapshot(opts) do
    with :ok <- outside_transaction(Keyword.fetch!(opts, :store_repo)) do
      snapshot_page(opts, nil, nil, nil, [], MapSet.new(), 0, 0)
    end
  end

  defp snapshot_page(opts, cursor, id, boundary, rows, seen, count, bytes) do
    with {:ok, page} <-
           remote(opts, "sync/snapshot", %{"snapshotCursor" => cursor, "limit" => 500}),
         %{"snapshotId" => snapshot, "rows" => entries, "changeCursor" => change_cursor} <- page,
         true <-
           is_list(entries) and (is_nil(id) or id == snapshot) and
             (is_nil(boundary) or boundary == change_cursor),
         {:ok, encoded} <- Jason.encode(entries),
         total_bytes = bytes + byte_size(encoded),
         :ok <- snapshot_budget(opts, count + length(entries), total_bytes, MapSet.size(seen) + 1) do
      accumulated = [entries | rows]

      case page["nextCursor"] do
        nil ->
          Store.publish_snapshot(
            Keyword.fetch!(opts, :store_repo),
            Keyword.fetch!(opts, :binding_id),
            accumulated |> Enum.reverse() |> List.flatten(),
            change_cursor,
            snapshot
          )

        next when is_binary(next) ->
          if MapSet.member?(seen, next) do
            {:error, Protocol.error("invalid_response")}
          else
            snapshot_page(
              opts,
              next,
              snapshot,
              change_cursor,
              accumulated,
              MapSet.put(seen, next),
              count + length(entries),
              total_bytes
            )
          end

        _ ->
          {:error, Protocol.error("invalid_response")}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, Protocol.error("invalid_response")}
    end
  end

  defp snapshot_budget(opts, rows, bytes, pages) do
    if rows <= Keyword.get(opts, :max_snapshot_rows, 100_000) and
         bytes <= Keyword.get(opts, :max_snapshot_bytes, 67_108_864) and
         pages <= Keyword.get(opts, :max_snapshot_pages, 1_000),
       do: :ok,
       else: {:error, Protocol.error("snapshot_limit_exceeded")}
  end

  defp deliver(opts, operation, caps) do
    repo = Keyword.fetch!(opts, :store_repo)
    id = operation["operationId"]
    fence = operation["fencingToken"]
    prior? = (operation["attempts"] || 1) > 1

    expired =
      expired?(
        operation["firstAttemptAt"],
        caps["idempotencyRetentionSeconds"],
        Keyword.get(opts, :timeout, 5000)
      )

    remembered =
      if prior? or expired,
        do: remote(opts, "sync/operation", %{"operationId" => id}),
        else: {:ok, %{"status" => "unknown"}}

    case remembered do
      {:ok, %{"revision" => _} = result} ->
        Store.ack(repo, id, fence, result)

      {:ok, %{"status" => "unknown"}} when expired ->
        Store.fail(repo, id, fence, "blocked", %{"reason" => "dedupe_horizon_expired"})

      {:ok, %{"status" => "unknown"}} ->
        mutate(opts, operation)

      {:error, %Noizu.MCP.Error{data: data}} ->
        Store.fail(
          repo,
          id,
          fence,
          if(is_map(data), do: Map.get(data, "syncCode", "unknown"), else: "unknown"),
          if(is_map(data), do: data, else: %{})
        )

      _ ->
        Store.fail(repo, id, fence, "unknown", %{})
    end
  end

  defp mutate(opts, operation) do
    repo = Keyword.fetch!(opts, :store_repo)
    request = Map.take(operation, ~w(operationId key operation precondition value))

    case remote(opts, "sync/mutate", request) do
      {:ok, result} ->
        Store.ack(repo, operation["operationId"], operation["fencingToken"], result)

      {:error, %Noizu.MCP.Error{data: data}} ->
        code = if is_map(data), do: Map.get(data, "syncCode", "unknown"), else: "unknown"

        Store.fail(
          repo,
          operation["operationId"],
          operation["fencingToken"],
          code,
          if(is_map(data), do: data, else: %{})
        )
    end
  end

  defp expired?(nil, _, _), do: false

  defp expired?(%DateTime{} = first, retention, timeout),
    do: DateTime.diff(DateTime.utc_now(), first, :millisecond) + timeout >= retention * 1000

  defp expired?(first, retention, timeout) when is_binary(first) do
    case DateTime.from_iso8601(first) do
      {:ok, time, _} -> expired?(time, retention, timeout)
      _ -> true
    end
  end

  defp expired?(_, _, _), do: true

  defp remote(opts, method, params) do
    {_, state} = source = Keyword.fetch!(opts, :source)
    relation = Keyword.get(opts, :relation) || if(is_map(state), do: Map.get(state, :relation))
    params = Map.put(params, "relation", relation)
    caller = self()
    reference = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        guarded_remote(caller, reference, source, method, params)
      end)

    receive do
      {^reference, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, Protocol.error("unknown")}
    after
      Keyword.get(opts, :timeout, 5000) ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])

        receive do
          {^reference, _} -> :ok
        after
          0 -> :ok
        end

        {:error, Protocol.error("unknown")}
    end
  end

  # The guardian links to the callback and monitors its owner. Killing either
  # the worker or its timeout guardian cancels the callback, including a source
  # blocked on a DB checkout. A remote commit can still have happened: retry
  # always reconciles the original operation ID.
  defp guarded_remote(owner, reference, source, method, params) do
    Process.flag(:trap_exit, true)
    owner_monitor = Process.monitor(owner)
    guardian = self()

    callback =
      spawn_link(fn ->
        result =
          try do
            Protocol.dispatch(source, method, params)
          rescue
            _ -> {:error, Protocol.error("unknown")}
          catch
            _, _ -> {:error, Protocol.error("unknown")}
          end

        send(guardian, {:result, result})
      end)

    receive do
      {:result, result} -> send(owner, {reference, result})
      {:DOWN, ^owner_monitor, :process, ^owner, _} -> Process.exit(callback, :kill)
      {:EXIT, ^callback, _} -> send(owner, {reference, {:error, Protocol.error("unknown")}})
    end
  end

  defp active(%{"status" => "paused_auth"}), do: {:error, Protocol.error("permission_denied")}
  defp active(_), do: :ok

  defp pause_on_auth({:error, %Noizu.MCP.Error{data: %{"syncCode" => code}}} = result, opts)
       when code in ["permission_denied", "invalid_token", "insufficient_scope"] do
    Store.pause(Keyword.fetch!(opts, :store_repo), Keyword.fetch!(opts, :binding_id), code)
    result
  end

  defp pause_on_auth(result, _), do: result

  defp outside_transaction(repo) do
    if repo.in_transaction?(), do: {:error, Protocol.error("invalid_request")}, else: :ok
  end

  defp outcome({:ok, _}), do: :ok
  defp outcome(_), do: :error
end
