defmodule Noizu.MCP.Server.VFSPubSub do
  @moduledoc """
  Per-path change pubsub for VFS backends: subtree watches over `{backend,
  path}` keys with burst-coalesced, metadata-only events.

  A watcher (any process — in practice a `Noizu.MCP.Transport.VFSWS` connection)
  registers `watch(backend, paths, depth:)`. Publishing happens from
  `Noizu.MCP.Server.Features.VFS` right after a successful `write`/`create`/
  `remove` bumps the backend's cache generation. Events carry no content — the
  version is the pull trigger, subscribers re-read via `vfs/read`.

  ## Subtree semantics

  Watches are indexed on the exact `{backend, path}` key. A publish dispatches
  over the published path *and every ancestor*, so a watch on `/docs`
  (unbounded depth) catches `/docs/a/b.md` because `/docs` is an ancestor of
  the published path. `depth` bounds that delta: `depth: 0` matches only the
  exact path, `depth: 1` the path or its direct children, `:infinity` the
  whole subtree.

  ## Burst control

  Publishes per `{backend, path}` coalesce: each burst is written to a pending
  slot and one `flush` is scheduled 50 ms out; N writes inside the window
  produce a single event carrying the final version. Per-subscriber watch
  count is capped at 10_000; over-cap watches return
  `{:error, :ewouldwatch}`.

  ## Lifecycle

  The pubsub is an explicit supervisor (Registry-less: a single hub GenServer
  owns the watcher index and all event dispatch); it is not started
  automatically with a server. `publish/5` degrades to a no-op when it is not
  running, so the write path is unaffected. Dead subscribers are cleaned up
  via process monitoring — their watches, seq, and watch count are dropped on
  `DOWN`.
  """

  use Supervisor

  alias Noizu.MCP.Ctx

  @hub __MODULE__.Hub
  @table :noizu_mcp_vfs_pubsub

  @debounce_ms 50

  @type depth :: non_neg_integer() | :infinity
  @type op :: :write | :create | :remove

  @typedoc "Metadata-only change event delivered as `{:vfs_event, event}`."
  @type event :: %{
          required(:backend) => module(),
          required(:op) => op(),
          required(:path) => String.t(),
          required(:version) => non_neg_integer(),
          required(:seq) => non_neg_integer(),
          required(:by) => String.t() | nil,
          required(:at) => integer()
        }

  # ── Supervisor ────────────────────────────────────────────────────────────

  # ⟦𓆒⟧ start_link
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  # ⟦𓆒⟧ init
  def init(_opts) do
    Supervisor.init([{@hub, name: @hub}], strategy: :one_for_one)
  end

  # ── watch API (called from the subscriber process) ────────────────────────

  @doc """
  Watch `paths` on `backend` from the calling process. `opts[:depth]` bounds
  subtree delivery (default `:infinity`). Returns `:ok` or
  `{:error, :ewouldwatch}` when the caller is already at the watch cap.
  """
  # ⟦𓆒⟧ watch
  @spec watch(module(), [String.t()] | String.t(), keyword()) :: :ok | {:error, :ewouldwatch}
  def watch(backend, paths, opts \\ []) do
    paths = List.wrap(paths)
    depth = Keyword.get(opts, :depth, :infinity)

    if valid_depth?(depth) do
      GenServer.call(@hub, {:watch, self(), backend, paths, depth})
    else
      {:error, :ebaddepth}
    end
  end

  @doc "Stop watching `paths` on `backend` from the calling process."
  # ⟦𓆒⟧ unwatch
  @spec unwatch(module(), [String.t()] | String.t()) :: :ok
  def unwatch(backend, paths) do
    GenServer.call(@hub, {:unwatch, self(), backend, List.wrap(paths)})
  end

  @doc "Pids currently watching `{backend, path}` (debug/test aid)."
  # ⟦𓆒⟧ watchers
  @spec watchers(module(), String.t()) :: [pid()]
  def watchers(backend, path) do
    try do
      @table
      |> :ets.lookup({:watchers, backend, path})
      |> case do
        [{{:watchers, ^backend, ^path}, pids}] -> Map.keys(pids)
        [] -> []
      end
    rescue
      _ -> []
    end
  end

  @doc "Current watch count for a subscriber (cap bookkeeping; test/debug aid)."
  # ⟦𓆒⟧ watch_count
  @spec watch_count(pid()) :: non_neg_integer()
  def watch_count(pid) do
    try do
      :ets.lookup_element(@table, {:count, pid}, 2)
    rescue
      _ -> 0
    end
  end

  # ── publish (called from the write path) ──────────────────────────────────

  @doc """
  Record a successful mutation and schedule a debounced event. Cheap and
  crash-proof: a no-op when the pubsub is not running, never raises into the
  caller (the write path treats this as best-effort).
  """
  # ⟦𓆒⟧ publish
  @spec publish(module(), op(), String.t(), non_neg_integer(), term()) :: :ok
  def publish(backend, op, path, version, ctx) do
    case Process.whereis(@hub) do
      nil ->
        :ok

      hub ->
        event = {op, version, identity(ctx), System.system_time(:millisecond)}
        key = {backend, path}

        try do
          # One timer per key: the first publish of a burst schedules the flush.
          if :ets.insert_new(@table, {{:timer, key}, nil}) do
            Process.send_after(hub, {:vfs_flush, key}, @debounce_ms)
          end

          :ets.insert(@table, {{:pending, key}, event})
        rescue
          _ -> :ok
        end

        :ok
    end
  end

  # ── hub internals ─────────────────────────────────────────────────────────

  defmodule Hub do
    @moduledoc false

    use GenServer

    @table :noizu_mcp_vfs_pubsub
    @cap 10_000

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    @impl GenServer
    def init(_opts) do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
      {:ok, %{}}
    end

    @impl GenServer
    def handle_call({:watch, pid, backend, paths, depth}, _from, monitors) do
      count = count(pid)

      if count + length(paths) > @cap do
        {:reply, {:error, :ewouldwatch}, monitors}
      else
        Enum.each(paths, fn path ->
          # Re-watch overwrites the previous depth for this key.
          {_, subs} = lookup({:subs, pid}, %{})
          subs = Map.put(subs, {backend, path}, depth)

          {_, pids} = lookup({:watchers, backend, path}, %{})
          pids = Map.put(pids, pid, depth)

          :ets.insert(@table, {{:subs, pid}, subs})
          :ets.insert(@table, {{:watchers, backend, path}, pids})
        end)

        :ets.insert(@table, {{:count, pid}, count + length(paths)})
        {:reply, :ok, monitor(monitors, pid)}
      end
    end

    def handle_call({:unwatch, pid, backend, paths}, _from, monitors) do
      {_, subs} = lookup({:subs, pid}, %{})

      subs =
        Enum.reduce(paths, subs, fn path, subs ->
          {_, pids} = lookup({:watchers, backend, path}, %{})
          pids = Map.delete(pids, pid)

          if map_size(pids) == 0 do
            :ets.delete(@table, {:watchers, backend, path})
          else
            :ets.insert(@table, {{:watchers, backend, path}, pids})
          end

          Map.delete(subs, {backend, path})
        end)

      if map_size(subs) == 0 do
        :ets.delete(@table, {:count, pid})
        :ets.delete(@table, {:subs, pid})
      else
        :ets.insert(@table, {{:count, pid}, map_size(subs)})
        :ets.insert(@table, {{:subs, pid}, subs})
      end

      {:reply, :ok, monitors}
    end

    @impl GenServer
    def handle_info({:vfs_flush, {backend, path} = key}, monitors) do
      :ets.delete(@table, {:timer, key})

      case :ets.take(@table, {:pending, key}) do
        [{{:pending, ^key}, {op, version, by, at}}] ->
          for watch_path <- [path | ancestors(path)] do
            dispatch(backend, watch_path, path, op, version, by, at)
          end

        [] ->
          :ok
      end

      {:noreply, monitors}
    end

    def handle_info({:DOWN, _ref, :process, pid, _reason}, monitors) do
      {_, subs} = lookup({:subs, pid}, %{})

      Enum.each(subs, fn {{backend, path}, _depth} ->
        {_, pids} = lookup({:watchers, backend, path}, %{})
        pids = Map.delete(pids, pid)

        if map_size(pids) == 0 do
          :ets.delete(@table, {:watchers, backend, path})
        else
          :ets.insert(@table, {{:watchers, backend, path}, pids})
        end
      end)

      :ets.delete(@table, {:count, pid})
      :ets.delete(@table, {:seq, pid})
      :ets.delete(@table, {:subs, pid})

      {:noreply, Map.delete(monitors, pid)}
    end

    def handle_info(_msg, monitors), do: {:noreply, monitors}

    # Deliver to watchers whose registered key is an ancestor-or-equal of the
    # published path and whose depth covers the distance.
    defp dispatch(backend, watch_path, pub_path, op, version, by, at) do
      delta = segments(pub_path) - segments(watch_path)

      case lookup({:watchers, backend, watch_path}, %{}) do
        {_, pids} when map_size(pids) > 0 ->
          Enum.each(pids, fn
            {pid, depth} when depth == :infinity or delta <= depth ->
              seq = bump_seq(pid)
              send(pid, {:vfs_event, event(backend, op, pub_path, version, seq, by, at)})

            _ ->
              :ok
          end)

        _ ->
          :ok
      end
    end

    defp bump_seq(pid) do
      :ets.update_counter(@table, {:seq, pid}, {2, 1}, {{:seq, pid}, 0})
    end

    defp event(backend, op, path, version, seq, by, at) do
      %{backend: backend, op: op, path: path, version: version, seq: seq, by: by, at: at}
    end

    defp lookup(key, default) do
      case :ets.lookup(@table, key) do
        [{^key, value}] -> {key, value}
        [] -> {key, default}
      end
    end

    defp count(pid) do
      case :ets.lookup(@table, {:count, pid}) do
        [{{:count, ^pid}, n}] -> n
        [] -> 0
      end
    end

    defp monitor(monitors, pid) do
      case Map.fetch(monitors, pid) do
        {:ok, _ref} -> monitors
        :error -> Map.put(monitors, pid, Process.monitor(pid))
      end
    end

    defp ancestors("/"), do: []

    defp ancestors(path) do
      parts = String.split(path, "/", trim: true)

      # Proper ancestors only (the dispatch list already includes `path`),
      # rooted at "/" so a root watch sees every mutation.
      for i <- (length(parts) - 1)..1//-1 do
        "/" <> Enum.join(Enum.take(parts, i), "/")
      end
      |> List.insert_at(-1, "/")
    end

    defp segments(path), do: length(String.split(path, "/", trim: true))
  end

  defp valid_depth?(:infinity), do: true
  defp valid_depth?(depth) when is_integer(depth) and depth >= 0, do: true
  defp valid_depth?(_), do: false

  # `by` — the identity the mutation ran under, when the ctx carries claims.
  defp identity(%Ctx{} = ctx) do
    case ctx.assigns[:auth_claims] do
      claims when is_map(claims) -> claims["sub"] || claims[:sub]
      _ -> nil
    end
  end

  defp identity(_), do: nil
end
