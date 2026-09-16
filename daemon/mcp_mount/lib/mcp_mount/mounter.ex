defmodule McpMount.Mounter do
  @moduledoc """
  The sync daemon: materializes a remote VFS tree as real local files under
  `--mount DIR` and keeps them live.

  State machine: `init -> authing -> syncing -> live` with `live <->
  reconnecting` (backoff 1s -> 30s). Transport is any `McpMount.Conn`
  implementation (`McpMount.WSConn` in production, `McpMount.FakeConn` in
  unit tests).

  * **Snapshot/resync** — recursive `vfs/list` walk (cursor pagination), then
    `Task.async_stream` (max_concurrency 8) stat+read per file; unchanged
    files (manifest version matches) are skipped, so resync is a diff.
    `.mcp-mount/manifest.json` records `{path -> {version, mode, size}}`.
  * **Live** — `vfs/subscribe {"/", depth: infinity}`; events with a version
    matching the manifest are self-echo and skipped; `write|create` pulls via
    `vfs/read`, `remove` deletes locally.
  * **Write-back** — a `file_system` watcher on the mount dir debounces 250ms
    then pushes each dirty path: server version unchanged -> `vfs/write`;
    otherwise the local edit is moved aside to `<path>.conflict-<ISO-ts>` and
    the server version re-pulled. `--ro` mounts have no watcher and never
    push.
  """

  use GenServer

  require Logger

  alias McpMount.Manifest

  @backoff_start 1_000
  @backoff_max 30_000
  @debounce_ms 250
  @call_timeout 5_000
  # initial push + this many retries, then the path is parked (see park/4)
  @max_push_attempts 4
  # retry cadence for write-backs that raised mid-flush
  @flush_retry_ms 2_000

  defstruct [
    :conn_mod,
    :url,
    :token,
    :mount,
    :ro,
    :name,
    :conn_opts,
    :mount_raw,
    :watcher_mon,
    conn: nil,
    mon_ref: nil,
    state: :init,
    manifest: %{},
    backoff_ms: @backoff_start,
    watcher: nil,
    pending: MapSet.new(),
    timer: nil,
    # rel => attempts this debounce cycle (capped at @max_push_attempts)
    push_attempts: %{},
    # rel => content hash; parked paths are never re-pushed until the local
    # file changes (user modification)
    parked: %{},
    # rels whose last create/write was acked by the server but not yet
    # confirmed by a read-back (self-echo tolerance)
    pushed_ack: MapSet.new()
  ]

  # ── API ───────────────────────────────────────────────────────────────────

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  def state(name \\ __MODULE__), do: GenServer.call(name, :state)

  # Conn dispatch: pid -> WSConn, struct -> its module (FakeConn in tests).
  defp call(conn, method, params, timeout), do: impl(conn).call(conn, method, params, timeout)
  defp subscribe(conn, paths, depth), do: impl(conn).subscribe(conn, paths, depth)

  defp impl(conn) when is_pid(conn), do: McpMount.WSConn
  defp impl(conn) when is_struct(conn), do: conn.__struct__

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    mount_raw = Path.expand(Keyword.fetch!(opts, :mount))
    Manifest.prepare(mount_raw)
    # Canonicalize: on macOS the watcher reports /private/var/... for /var/...
    mount = canonicalize(mount_raw)

    state = %__MODULE__{
      conn_mod: Keyword.get(opts, :conn_mod, McpMount.WSConn),
      url: Keyword.fetch!(opts, :url),
      token: Keyword.fetch!(opts, :token),
      mount: mount,
      mount_raw: mount_raw,
      ro: !!opts[:ro],
      name: opts[:name],
      conn_opts: Keyword.get(opts, :conn_opts, []),
      manifest: Manifest.read(mount)
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, %__MODULE__{state: st} = s) do
    case s.conn_mod.connect([url: s.url, token: s.token, owner: self()] ++ s.conn_opts) do
      {:ok, conn} ->
        Logger.info("mcp-mount[#{s.name}]: connected (was #{st})")
        s = %{s | conn: conn, mon_ref: monitor(conn), state: :syncing}

        case sync(s) do
          {:ok, s} -> {:noreply, go_live(s)}
          {:error, reason} -> reconnect(s, reason)
        end

      {:error, reason} ->
        reconnect(%{s | conn: nil}, reason)
    end
  end

  @impl GenServer
  def handle_call(:state, _from, s), do: {:reply, {s.state, MapSet.size(s.pending)}, s}

  # ── live events ───────────────────────────────────────────────────────────

  @impl GenServer
  def handle_info({:mcp_mount_event, ev}, %__MODULE__{state: :live} = s) do
    {:noreply, apply_event(ev, s)}
  end

  # Events during sync/reconnect are redundant — the diff-resync covers them.
  def handle_info({:mcp_mount_event, _ev}, s), do: {:noreply, s}

  @impl GenServer
  def handle_info({:mcp_mount_down, reason}, s) do
    Logger.warning("mcp-mount[#{s.name}]: connection down: #{inspect(reason)}")
    reconnect(%{s | conn: nil}, reason)
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, %__MODULE__{mon_ref: ref} = s) do
    Logger.warning("mcp-mount[#{s.name}]: conn died: #{inspect(reason)}")
    reconnect(%{s | conn: nil, mon_ref: nil}, reason)
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, %__MODULE__{watcher_mon: ref} = s) do
    Logger.warning(
      "mcp-mount[#{s.name}]: watcher died (#{inspect(reason)}); mount continues pull-only"
    )

    {:noreply, %{s | watcher: nil, watcher_mon: nil}}
  end

  # Stray monitors: the double-down race (ws_close then transport error, then
  # the conn's :normal exit) leaves us with monitors we already demonitored —
  # a DOWN that matches no tracked ref must be ignored, not crash the Mounter
  # (seen live: FunctionClauseError here killed the whole mount).
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, s), do: {:noreply, s}

  def handle_info({:reconnect_tick, nil}, %__MODULE__{state: :reconnecting} = s),
    do: {:noreply, s, {:continue, :connect}}

  # A tick scheduled before a newer reconnect cycle must not fire a redundant
  # full sync out of :live/:syncing (seen live as "connected (was live)").
  def handle_info({:reconnect_tick, nil}, s), do: {:noreply, s}

  # ── watcher (write-back) ──────────────────────────────────────────────────

  def handle_info({:file_event, _watcher, {path, _events}}, s) do
    rel = relative(s, path)

    if rel != nil and !Manifest.ignored?(rel) and !control_path?(rel) and s.state == :live do
      timer = start_debounce(s.timer)
      {:noreply, %{s | pending: MapSet.put(s.pending, rel), timer: timer}}
    else
      {:noreply, s}
    end
  end

  # Write-backs only run against a live connection; a flush that arrives while
  # disconnected is deferred — pending is preserved and flushed after the
  # reconnect resync (see go_live/1). Write-back itself is failure-isolated:
  # a raising push must never take the daemon down out of handle_info.
  def handle_info(:flush, %__MODULE__{state: :live, conn: conn} = s) when conn != nil do
    {s, deferred} =
      s.pending
      |> Enum.sort()
      |> Enum.reduce({s, MapSet.new()}, fn rel, {st, acc} ->
        try do
          {writeback(st, rel), acc}
        rescue
          e ->
            Logger.error(
              "mcp-mount[#{st.name}]: write-back #{rel} raised, deferring: " <>
                Exception.format(:error, e, [])
            )

            {st, MapSet.put(acc, rel)}
        end
      end)

    s = %{s | pending: deferred, timer: nil}

    if MapSet.size(deferred) > 0 do
      Process.send_after(self(), :flush, @flush_retry_ms)
      {:noreply, s}
    else
      {:noreply, s}
    end
  end

  # Disconnected (or mid-resync): defer, pending flushes after reconnect resync.
  def handle_info(:flush, s), do: {:noreply, s}

  # ── sync ──────────────────────────────────────────────────────────────────

  # Full tree diff against the manifest: unchanged files skip stat only;
  # mismatches re-read; server-side deletions remove local files. Also used
  # verbatim as the reconnect resync.
  defp sync(s) do
    with {:ok, _} <- call(s.conn, "vfs/ping", nil, @call_timeout),
         {:ok, files} <- walk(s.conn) do
      # server-side deletions since last sync
      files
      |> Map.keys()
      |> MapSet.new()
      |> then(&MapSet.difference(MapSet.new(Map.keys(s.manifest)), &1))
      |> Enum.each(fn rel -> remove_local(s, rel) end)

      files
      |> Task.async_stream(
        fn {path, stat} -> materialize(s, path, stat) end,
        max_concurrency: 8,
        timeout: @call_timeout * 4
      )
      |> Enum.reduce_while({:ok, s.manifest}, fn
        {:ok, {:ok, rel, entry}}, {:ok, manifest} -> {:cont, {:ok, Map.put(manifest, rel, entry)}}
        {:ok, {:skip, _rel}}, acc -> {:cont, acc}
        {:ok, {:error, reason}}, _ -> {:halt, {:error, reason}}
        {:exit, reason}, _ -> {:halt, {:error, {:sync_exit, reason}}}
      end)
      |> case do
        {:ok, manifest} ->
          Manifest.write(s.mount, manifest)
          {:ok, %{s | manifest: manifest}}

        error ->
          error
      end
    end
  end

  # BFS walk with cursor pagination; returns %{rel_path => stat_map}.
  defp walk(conn) do
    do_walk(conn, ["/"], %{})
  end

  defp do_walk(_conn, [], acc), do: {:ok, acc}

  defp do_walk(conn, [dir | rest], acc) do
    case list_all(conn, dir) do
      {:ok, entries} ->
        {dirs, files} =
          Enum.split_with(entries, fn {_path, stat} -> stat["type"] == "dir" end)

        acc =
          Enum.reduce(files, acc, fn {path, stat}, acc ->
            Map.put(acc, String.trim_leading(path, "/"), stat)
          end)

        do_walk(conn, rest ++ Enum.map(dirs, &elem(&1, 0)), acc)

      # A queued dir refused listing (enotdir): the server's list/type view
      # skewed (e.g. a control node advertised as dir by its parent list).
      # Re-stat and keep walking it as a file instead of failing the whole
      # sync — a mismatch must never turn into a reconnect loop.
      {:error, {:list_failed, ^dir, %{errno: :enotdir}}} ->
        case call(conn, "vfs/stat", %{"path" => dir}, @call_timeout) do
          {:ok, %{"type" => type} = stat} when type != "dir" ->
            stat = Map.take(stat, ["type", "version"])
            do_walk(conn, rest, Map.put(acc, String.trim_leading(dir, "/"), stat))

          _ ->
            Logger.warning("mcp-mount: skipping unlistable path #{dir}")
            do_walk(conn, rest, acc)
        end

      error ->
        error
    end
  end

  defp list_all(conn, dir, cursor \\ nil, acc \\ []) do
    params = %{"path" => dir}
    params = if cursor, do: Map.put(params, "cursor", cursor), else: params

    case call(conn, "vfs/list", params, @call_timeout) do
      {:ok, %{"entries" => entries} = result} ->
        acc =
          Enum.reduce(entries, acc, fn entry, acc ->
            path = join_path(dir, entry["name"])
            acc ++ [{path, %{"type" => entry["type"], "version" => entry["version"]}}]
          end)

        case result["nextCursor"] do
          nil -> {:ok, acc}
          next -> list_all(conn, dir, next, acc)
        end

      {:error, error} ->
        {:error, {:list_failed, dir, error}}
    end
  end

  # Fetch one file (stat+read) and write it locally. Returns
  # {:ok, rel, entry} | {:skip, rel} | {:error, reason}.
  defp materialize(s, rel, listed_stat) do
    path = "/" <> rel
    cached = s.manifest[rel]

    cond do
      cached != nil and cached.version == listed_stat["version"] ->
        {:skip, rel}

      true ->
        with {:ok, %{"content" => content, "version" => version}} <-
               call(s.conn, "vfs/read", %{"path" => path}, @call_timeout) do
          mode = if listed_stat["executable"], do: 0o755, else: 0o644
          write_local(s, rel, content, mode)
          {:ok, rel, entry(content, version, mode)}
        end
    end
  end

  defp go_live(s) do
    with :ok <- subscribe(s.conn, ["/"], :infinity) do
      {watcher, watcher_mon} = if s.ro, do: {nil, nil}, else: watcher_pair(s.mount)
      Logger.info("mcp-mount[#{s.name}]: live (#{map_size(s.manifest)} files, ro=#{s.ro})")

      # write-backs deferred while disconnected flush now, after the resync
      if MapSet.size(s.pending) > 0, do: Process.send_after(self(), :flush, @debounce_ms)

      %{s | state: :live, backoff_ms: @backoff_start, watcher: watcher, watcher_mon: watcher_mon}
    else
      error ->
        Logger.error("mcp-mount[#{s.name}]: subscribe failed: #{inspect(error)}")
        s
    end
  end

  # ── event apply ───────────────────────────────────────────────────────────

  defp apply_event(%{op: op, path: path, version: version}, s) when op in ["write", "create"] do
    rel = String.trim_leading(path, "/")

    if !Manifest.ignored?(rel) and s.manifest[rel] != nil and s.manifest[rel].version == version do
      # self-echo: our own write-back came back to us
      s
    else
      case call(s.conn, "vfs/read", %{"path" => path}, @call_timeout) do
        {:ok, %{"content" => content, "version" => v}} ->
          mode = event_mode(s.conn, path, s.manifest[rel])
          write_local(s, rel, content, mode)

          # a successful read-back confirms any earlier unconfirmed push
          s = %{s | pushed_ack: MapSet.delete(s.pushed_ack, rel)}

          save_manifest(
            s,
            Map.put(s.manifest, rel, entry(content, v, mode))
          )

        {:error, %{errno: :eisdir}} ->
          File.mkdir_p!(Path.join(s.mount, rel))
          s

        {:error, %{errno: :enoent}} ->
          if MapSet.member?(s.pushed_ack, rel) do
            # self-echo for a path we just pushed acked, but the server no
            # longer has it at the requested path (canonicalized elsewhere?):
            # stranded — park instead of re-pushing (an unconditional re-push
            # here duplicated server-side resources unboundedly; seen live).
            park(s, rel, Path.join(s.mount, rel), "echo for acked push, path missing on server")
          else
            Logger.warning("mcp-mount[#{s.name}]: pull failed for #{path}: enoent")
            s
          end

        {:error, reason} ->
          Logger.warning("mcp-mount[#{s.name}]: pull failed for #{path}: #{inspect(reason)}")
          s
      end
    end
  end

  defp apply_event(%{op: "remove", path: path}, s) do
    rel = String.trim_leading(path, "/")

    if !Manifest.ignored?(rel) do
      remove_local(s, rel)
      save_manifest(s, Map.delete(s.manifest, rel))
    else
      s
    end
  end

  defp apply_event(_ev, s), do: s

  defp event_mode(conn, path, cached) do
    case call(conn, "vfs/stat", %{"path" => path}, @call_timeout) do
      {:ok, %{"executable" => true}} -> 0o755
      {:ok, _} -> if(cached, do: cached.mode, else: 0o644)
      _ -> if(cached, do: cached.mode, else: 0o644)
    end
  end

  # ── write-back ────────────────────────────────────────────────────────────

  defp start_watcher(mount) do
    case FileSystem.start_link(dirs: [mount]) do
      {:ok, watcher} ->
        # not supervised and linked to us by default — decouple so a dead
        # watcher degrades to a read-only mount instead of killing us
        Process.unlink(watcher)
        ref = Process.monitor(watcher)
        FileSystem.subscribe(watcher)
        {watcher, ref}

      {:error, reason} ->
        Logger.error("mcp-mount: watcher unavailable (mount stays pull-only): #{inspect(reason)}")
        nil

      :ignore ->
        Logger.error("mcp-mount: watcher bootstrap failed (mount stays pull-only)")
        nil
    end
  end

  defp start_debounce(timer) do
    if timer, do: Process.cancel_timer(timer)
    Process.send_after(self(), :flush, @debounce_ms)
  end

  # Returns the (possibly updated) state. The flush loop threads it through,
  # so ack-as-synced manifest updates stick in memory — dropping them here is
  # what made every later writeback see a stale version and churn.
  defp writeback(s, rel) do
    abs = Path.join(s.mount, rel)

    cond do
      # control tree (/etc/**) is a server-side configuration surface: never
      # pushed, local edits are a documented no-op (still materialized/readable)
      control_path?(rel) ->
        s

      s.ro ->
        Logger.warning("mcp-mount[#{s.name}]: ro mount, refusing write-back for #{rel}")
        s

      true ->
        s = unpark_if_changed(s, rel, abs)

        cond do
          parked?(s, rel, abs) -> s
          File.dir?(abs) -> s
          File.regular?(abs) -> capped_push(s, rel, abs)
          true -> s
        end
    end
  end

  # Per-path retry cap: a push that keeps failing or going unconfirmed is
  # attempted at most @max_push_attempts times, then parked — it is never
  # re-pushed until the local file changes (user modification).
  defp capped_push(s, rel, abs) do
    n = Map.get(s.push_attempts, rel, 0)

    if n >= @max_push_attempts do
      park(s, rel, abs, "no confirmed push after #{n} attempts")
    else
      push_local(%{s | push_attempts: Map.put(s.push_attempts, rel, n + 1)}, rel, abs)
    end
  end

  defp push_local(s, rel, abs) do
    path = "/" <> rel
    local = s.manifest[rel]
    local_hash = file_hash(abs)

    case call(s.conn, "vfs/stat", %{"path" => path}, @call_timeout) do
      {:ok, %{"version" => v}} ->
        cond do
          # already synced: the server holds the version we recorded and the
          # local content is unchanged since then — watcher noise (chmod/touch
          # refires), not an edit. Pushing would bump the server version for
          # no change.
          local != nil and v == local.version and Map.get(local, :unconfirmed) == nil and
            local_hash != nil and local_hash == local.hash ->
            s

          local != nil and local.version == v ->
            with {:ok, content} <- File.read(abs) do
              case call(s.conn, "vfs/write", %{"path" => path, "data" => content}, @call_timeout) do
                {:ok, node} ->
                  acked_sync(s, rel, content, local.mode, node["version"], local.version)

                {:error, reason} ->
                  Logger.warning(
                    "mcp-mount[#{s.name}]: write failed for #{path}: #{inspect(reason)}"
                  )

                  s
              end
            else
              _ -> s
            end

          true ->
            conflict(s, rel, abs)
        end

      {:error, %{errno: :enoent}} ->
        cond do
          # stranded: we hold an ack for exactly this content but the server
          # no longer has the requested path (canonicalized elsewhere). Do not
          # re-create — that duplicates server-side resources.
          local != nil and MapSet.member?(s.pushed_ack, rel) and
            local_hash != nil and local_hash == local.hash ->
            park(s, rel, abs, "push acked but path missing on server")

          true ->
            # locally created file — create it on the server
            with {:ok, content} <- File.read(abs),
                 {:ok, node} <-
                   call(s.conn, "vfs/create", %{"path" => path, "data" => content}, @call_timeout) do
              mode = mode_from_node(node)
              File.chmod(abs, mode)

              # ack-as-synced: a successful ack always marks the path synced.
              # An ack without a version records the pre-push version flagged
              # unconfirmed until a read-back confirms it.
              acked_sync(s, rel, content, mode, node["version"], local && local.version)
            else
              {:error, reason} ->
                Logger.warning(
                  "mcp-mount[#{s.name}]: create failed for #{path}: #{inspect(reason)}"
                )

                s
            end
        end

      {:error, reason} ->
        Logger.warning("mcp-mount[#{s.name}]: stat failed for #{path}: #{inspect(reason)}")
        s
    end
  end

  # A successful create/write ack marks the path synced immediately — the
  # daemon never leaves an acked path in "pending re-push". The content hash
  # recorded with the entry lets later flushes recognize unchanged content.
  defp acked_sync(s, rel, content, mode, acked_version, pre_version) do
    {version, unconfirmed} =
      if is_integer(acked_version) do
        {acked_version, false}
      else
        Logger.warning(
          "mcp-mount[#{s.name}]: ack for #{rel} carried no version; marked unconfirmed"
        )

        {pre_version, true}
      end

    e = entry(content, version, mode)
    e = if unconfirmed, do: Map.put(e, :unconfirmed, true), else: e

    s = %{s | pushed_ack: MapSet.put(s.pushed_ack, rel)}
    save_manifest(s, Map.put(s.manifest, rel, e))
  end

  # Park a problem path: one-time warning, a `.conflict-<ts>` copy of the
  # local content (the file itself stays in place), and no further pushes
  # until the local file changes.
  defp park(s, rel, abs, reason) do
    Logger.warning(
      "mcp-mount[#{s.name}]: parking #{rel} (#{reason}); will not re-push until edited"
    )

    backup = abs <> ".conflict-" <> ts()

    case File.copy(abs, backup) do
      {:ok, _} ->
        Logger.warning("mcp-mount[#{s.name}]: parked copy of #{rel} saved to #{backup}")

      _ ->
        :ok
    end

    %{
      s
      | parked: Map.put(s.parked, rel, file_hash(abs)),
        push_attempts: Map.delete(s.push_attempts, rel),
        pushed_ack: MapSet.delete(s.pushed_ack, rel)
    }
  end

  defp parked?(s, rel, abs), do: s.parked[rel] != nil and s.parked[rel] == file_hash(abs)

  defp unpark_if_changed(s, rel, abs) do
    case s.parked[rel] do
      nil ->
        s

      h ->
        if h == file_hash(abs) do
          s
        else
          Logger.info("mcp-mount[#{s.name}]: #{rel} changed since park; re-enabling write-back")

          %{
            s
            | parked: Map.delete(s.parked, rel),
              push_attempts: Map.delete(s.push_attempts, rel)
          }
        end
    end
  end

  defp conflict(s, rel, abs) do
    backup = abs <> ".conflict-" <> ts()

    with :ok <- File.rename(abs, backup),
         {:ok, %{"content" => content, "version" => version}} <-
           call(s.conn, "vfs/read", %{"path" => "/" <> rel}, @call_timeout) do
      Logger.warning(
        "mcp-mount[#{s.name}]: conflict on #{rel}; local edit saved to #{Path.basename(backup)}"
      )

      mode = if(s.manifest[rel], do: s.manifest[rel].mode, else: 0o644)
      write_local(s, rel, content, mode)

      save_manifest(
        s,
        Map.put(s.manifest, rel, entry(content, version, mode))
      )
    else
      error ->
        Logger.error(
          "mcp-mount[#{s.name}]: conflict resolution failed for #{rel}: #{inspect(error)}"
        )

        s
    end
  end

  defp watcher_pair(mount) do
    case start_watcher(mount) do
      nil -> {nil, nil}
      {watcher, ref} -> {watcher, ref}
    end
  end

  # ── lifecycle helpers ─────────────────────────────────────────────────────

  defp reconnect(s, reason) do
    if s.mon_ref, do: Process.demonitor(s.mon_ref, [:flush])

    if s.watcher != nil and is_pid(s.watcher) do
      Process.exit(s.watcher, :kill)
    end

    Logger.warning("mcp-mount[#{s.name}]: reconnecting in #{s.backoff_ms}ms (#{inspect(reason)})")
    Process.send_after(self(), {:reconnect_tick, nil}, s.backoff_ms)

    {:noreply,
     %{
       s
       | state: :reconnecting,
         conn: nil,
         mon_ref: nil,
         backoff_ms: min(s.backoff_ms * 2, @backoff_max)
     }}
  end

  defp monitor(conn) when is_pid(conn), do: Process.monitor(conn)
  defp monitor(_conn), do: nil

  defp relative(s, abs_path) do
    Enum.find_value([s.mount, s.mount_raw], fn base ->
      case Path.relative_to(abs_path, base) do
        ^abs_path -> nil
        rel -> rel
      end
    end)
  end

  # Resolve symlinks for an existing dir (File.realpath doesn't exist in Elixir).
  defp canonicalize(path) do
    prev = File.cwd!()

    with :ok <- File.cd(path),
         real <- File.cwd!(),
         :ok <- File.cd(prev) do
      real
    else
      _ -> path
    end
  end

  defp remove_local(s, rel) do
    abs = Path.join(s.mount, rel)

    cond do
      File.regular?(abs) -> File.rm(abs)
      File.dir?(abs) -> File.rmdir(abs)
      true -> :ok
    end
  rescue
    _ -> :ok
  end

  defp write_local(s, rel, content, mode) do
    abs = Path.join(s.mount, rel)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, content)
    File.chmod!(abs, mode)
    s
  end

  defp save_manifest(s, manifest) do
    Manifest.write(s.mount, manifest)
    %{s | manifest: manifest}
  end

  defp mode_from_node(%{"executable" => true}), do: 0o755
  defp mode_from_node(_), do: 0o644

  # Manifest entry with a stable content hash — lets flushes tell real edits
  # from watcher noise (chmod/touch refires of unchanged content).
  defp entry(content, version, mode) do
    %{version: version, mode: mode, size: byte_size(content), hash: content_hash(content)}
  end

  defp content_hash(content), do: Base.encode16(:crypto.hash(:sha256, content), case: :lower)

  defp file_hash(abs) do
    case File.read(abs) do
      {:ok, content} -> content_hash(content)
      _ -> nil
    end
  end

  # Control tree: server-side configuration surfaces. Local edits via the
  # mount are a documented no-op — never watched, never pushed.
  defp control_path?("etc"), do: true
  defp control_path?(rel), do: String.starts_with?(rel, "etc/")

  defp ts, do: DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(":", "-")

  defp join_path("/", name), do: "/" <> name
  defp join_path(dir, name), do: dir <> "/" <> name
end
