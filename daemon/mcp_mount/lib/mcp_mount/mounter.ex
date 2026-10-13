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
    the server version re-pulled. Control paths (`etc/**`) are read-only
    except `etc/dev/config/**` (the runtime writes toggle), which pushes
    through the ordinary `vfs/write`. `--ro` mounts have no watcher and
    never push.
  * **Move pairing** — a tracked path that vanished locally while an
    untracked regular file with the SAME content hash appeared in the same
    flush is an editor rename: the daemon double-confirms the pair one tick
    later and pushes a single `vfs/move` (server keeps identity/history)
    instead of letting the rename decay into a duplicated `vfs/create`.
    Pairing is always on. A refused or unsupported move parks the new path
    — it never falls back to create.
  """

  use GenServer

  require Logger

  alias McpMount.Manifest

  @backoff_start 1_000
  @backoff_max 30_000
  @debounce_ms 250
  # Per-op-class deadline budgets (ms). WSConn adds its own +1s GenServer.call
  # margin on top. Ops not listed fall back to @call_timeout.
  @timeouts %{
    "vfs/ping" => 5_000,
    "vfs/stat" => 5_000,
    "vfs/list" => 10_000,
    "vfs/read" => 15_000,
    "vfs/create" => 15_000,
    "vfs/write" => 30_000,
    "vfs/move" => 15_000
  }

  @call_timeout 5_000
  # initial push + this many retries, then the path is parked (see park/4)
  @max_push_attempts 4
  # retry cadence for write-backs that raised mid-flush (or hit a transport
  # timeout — deferred retries use this cadence too)
  @flush_retry_ms 2_000
  # pulls: event-driven read/stat retries at 1s -> 4s -> 16s (3 backoff
  # attempts); exhausted pulls are dropped and a resync nudge is queued.
  # Pulls are the system's healing direction — they are never parked. The
  # retry cap derives from this list's length (not a separate constant), so
  # a shorter test-seam list can never run Enum.at past its end and hand a
  # nil delay to Process.send_after/3 (robot review follow-up, PR #57).
  @pull_backoff_ms [1_000, 4_000, 16_000]
  # delay before the double-confirm tick of an inferred move (design §1/D1):
  # long enough for an editor atomic-save dance (temp file, remove, rename)
  # to settle, so a phantom rename is detected and aborted at the tick
  @move_confirm_ms 500

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
    pushed_ack: MapSet.new(),
    # rel => scheduled pull retries (bounded by length(pull_backoff_ms))
    pull_attempts: %{},
    # set when an event pull exhausted its backoff: quiescence (live, nothing
    # pending) triggers an in-place diff resync; persistent failure escalates
    # to a full reconnect
    resync_nudge: false,
    flush_retry_ms: @flush_retry_ms,
    pull_backoff_ms: @pull_backoff_ms,
    # from_rel => %{to: to_rel, hash: content_hash, attempts: n}; a pairing
    # lives from detection until the double-confirm tick resolves it
    move_pairing: %{},
    # bumped on every go_live: {:pull_retry, rel, path, epoch} timers from an
    # older epoch are stale (their path was already re-pulled by that
    # reconnect's resync) and are dropped instead of re-pulled (robot
    # follow-up F12)
    pull_epoch: 0
  ]

  # ── API ───────────────────────────────────────────────────────────────────

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  def state(name \\ __MODULE__), do: GenServer.call(name, :state)

  # Conn dispatch: pid -> WSConn, struct -> its module (FakeConn in tests).
  # The deadline budget comes from the per-op table; WSConn adds its +1s
  # GenServer.call margin and returns `{:error, :timeout}` as a value.
  defp call(conn, method, params), do: impl(conn).call(conn, method, params, budget(method))

  defp budget(method), do: Map.get(@timeouts, method, @call_timeout)

  # The sync Task.async_stream deadline must cover a whole materialize pass,
  # not one op: a task can issue several sequential budgeted calls (stat +
  # read, plus an event_mode stat on the pull path), so sum every per-op
  # budget (plus WSConn's +1s call margin) instead of scaling the largest
  # single one (robot follow-up F11).
  defp sync_task_timeout, do: Enum.sum(Map.values(@timeouts)) + @call_timeout

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
      manifest: Manifest.read(mount),
      # test seams: production defaults are the module constants
      flush_retry_ms: Keyword.get(opts, :flush_retry_ms, @flush_retry_ms),
      pull_backoff_ms: Keyword.get(opts, :pull_backoff_ms, @pull_backoff_ms)
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
    {:noreply, maybe_resync(apply_event(ev, s))}
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

    if rel != nil and !Manifest.ignored?(rel) and
         (!control_path?(rel) or control_config_path?(rel)) and s.state == :live do
      timer = start_debounce(s.timer)
      {:noreply, %{s | pending: MapSet.put(s.pending, rel), timer: timer}}
    else
      {:noreply, s}
    end
  end

  # Write-backs only run against a live connection; a flush that arrives while
  # disconnected is deferred — pending is preserved and flushed after the
  # reconnect resync (see go_live/1). Write-back itself is failure-isolated:
  # a raising push must never take the daemon down out of handle_info. A push
  # that hit a transport error (timeout/closed) is deferred the same way —
  # the path retries on the @flush_retry_ms cadence and each retry counts as
  # a push attempt (park after @max_push_attempts).
  def handle_info(:flush, %__MODULE__{state: :live, conn: conn} = s) when conn != nil do
    # mv-pairing runs BEFORE the write-back reduction: a rename that would
    # otherwise decay into "create the new path, silently drop the old one"
    # is promoted to a single vfs/move
    s = pair_moves(s)

    {s, deferred} =
      s.pending
      |> Enum.sort()
      |> Enum.reduce({s, MapSet.new()}, fn rel, {st, acc} ->
        try do
          case writeback(st, rel) do
            {st, true} -> {st, MapSet.put(acc, rel)}
            {st, false} -> {st, acc}
          end
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
      Process.send_after(self(), :flush, s.flush_retry_ms)
      {:noreply, maybe_resync(s)}
    else
      {:noreply, maybe_resync(s)}
    end
  end

  # Disconnected (or mid-resync): defer, pending flushes after reconnect resync.
  def handle_info(:flush, s), do: {:noreply, s}

  # A scheduled pull retry. Pulls are the healing direction — re-read the
  # path; pull/3 owns the backoff bookkeeping. The epoch must match the live
  # connection: a timer fired from a previous connection's schedule is stale
  # (the reconnect resync already re-pulled every path against fresh state)
  # and is dropped (robot follow-up F12). Retries that arrive while not live
  # are dropped for the same reason.
  def handle_info({:pull_retry, rel, path, epoch}, %__MODULE__{state: :live, conn: conn} = s)
      when conn != nil and epoch == s.pull_epoch do
    {:noreply, maybe_resync(pull(s, rel, path))}
  end

  def handle_info({:pull_retry, _rel, _path, _epoch}, s), do: {:noreply, s}

  # Double-confirm tick for an inferred move (design §1/D1 step 4). At tick
  # time the source must STILL be absent and the target must still hold the
  # paired content — an editor atomic-save (remove + recreate via rename)
  # mimics a rename for one debounce window and is defeated here; the legs
  # re-enter the ordinary flush instead. Only a confirmed pair reaches for
  # the wire, gated on the server's advertised `move` cap.
  def handle_info({:move_confirm, from_rel}, %__MODULE__{state: :live, conn: conn} = s)
      when conn != nil do
    case Map.get(s.move_pairing, from_rel) do
      nil ->
        {:noreply, s}

      pair ->
        abs_from = Path.join(s.mount, from_rel)
        abs_to = Path.join(s.mount, pair.to)

        cond do
          File.exists?(abs_from) or not File.regular?(abs_to) or
              file_hash(abs_to) != pair.hash ->
            Logger.info(
              "mcp-mount[#{s.name}]: move #{from_rel} -> #{pair.to} no longer holds; " <>
                "falling back to ordinary write-back"
            )

            s = %{s | move_pairing: Map.delete(s.move_pairing, from_rel)}
            pending = s.pending |> MapSet.put(from_rel) |> MapSet.put(pair.to)
            {:noreply, %{s | pending: pending, timer: start_debounce(s.timer)}}

          true ->
            case move_gate(conn) do
              :supported ->
                {:noreply, do_move(s, from_rel, pair)}

              {:unsupported, why} ->
                Logger.warning(
                  "mcp-mount[#{s.name}]: rename unsupported (#{why}); parking #{pair.to} — " <>
                    "edit the note's frontmatter (title:/parent:) to move it instead"
                )

                s = %{s | move_pairing: Map.delete(s.move_pairing, from_rel)}
                {:noreply, park(s, pair.to, abs_to, "move refused by server (#{why})")}
            end
        end
    end
  end

  # A confirm tick while not live is a no-op: go_live re-arms live pairings.
  def handle_info({:move_confirm, _from_rel}, s), do: {:noreply, s}

  # ── sync ──────────────────────────────────────────────────────────────────

  # Full tree diff against the manifest: unchanged files skip stat only;
  # mismatches re-read; server-side deletions remove local files. Also used
  # verbatim as the reconnect resync.
  defp sync(s) do
    with {:ok, _} <- call(s.conn, "vfs/ping", nil),
         {:ok, files} <- walk(s.conn) do
      # server-side deletions since last sync
      files
      |> Map.keys()
      |> MapSet.new()
      |> then(&MapSet.difference(MapSet.new(Map.keys(s.manifest)), &1))
      |> Enum.each(fn rel -> remove_local(s, rel) end)

      # per-task safety net: sum of every per-op budget (see sync_task_timeout)
      files
      |> Task.async_stream(
        fn {path, stat} -> materialize(s, path, stat) end,
        max_concurrency: 8,
        timeout: sync_task_timeout()
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
        case call(conn, "vfs/stat", %{"path" => dir}) do
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

    case call(conn, "vfs/list", params) do
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
               call(s.conn, "vfs/read", %{"path" => path}) do
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

      # moves paired before the drop re-arm their confirm ticks (the previous
      # tick either fired while disconnected — a no-op — or never fired). The
      # attempt budget resets to the formation value (attempts: 1), so the
      # fresh connection gets the full 4-call cadence again — same precedent
      # as pull_attempts above: the resync healed the tree, so budget burned
      # against the dead transport does not carry into it (robot review,
      # head d7dea15).
      move_pairing =
        Map.new(s.move_pairing, fn {from_rel, pair} ->
          Process.send_after(self(), {:move_confirm, from_rel}, @move_confirm_ms)
          {from_rel, Map.put(pair, :attempts, 1)}
        end)

      # the fresh resync healed the tree: pull backoff counters and any
      # resync nudge that survived into the reconnect are cleared — and the
      # pull epoch bumps, so any {:pull_retry, ...} timer still in flight
      # from the previous connection is recognized as stale and dropped
      # instead of re-pulling against the freshly resynced state (F12)
      %{
        s
        | state: :live,
          backoff_ms: @backoff_start,
          watcher: watcher,
          watcher_mon: watcher_mon,
          pull_attempts: %{},
          move_pairing: move_pairing,
          resync_nudge: false,
          pull_epoch: s.pull_epoch + 1
      }
    else
      error ->
        Logger.error("mcp-mount[#{s.name}]: subscribe failed: #{inspect(error)}")
        s
    end
  end

  # ── event apply ───────────────────────────────────────────────────────────

  defp apply_event(%{op: op, path: path, version: version}, s) when op in ["write", "create"] do
    rel = String.trim_leading(path, "/")

    cond do
      Manifest.ignored?(rel) ->
        s

      # Control tree paths skip the self-echo version check and ALWAYS
      # re-pull (F5): etc/** is server-owned configuration — an inbound
      # event means the server changed something we must not second-guess,
      # even when the version matches what the manifest recorded. The cost
      # is one extra read on our own etc/dev/config write-back echo.
      control_path?(rel) ->
        pull(s, rel, path)

      s.manifest[rel] != nil and s.manifest[rel].version == version ->
        # self-echo: our own write-back came back to us
        s

      true ->
        pull(s, rel, path)
    end
  end

  defp apply_event(%{op: "remove", path: path}, s) do
    rel = String.trim_leading(path, "/")

    if !Manifest.ignored?(rel) do
      # a server-side remove must not silently destroy unpushed local work:
      # if the local file's content differs from the manifest hash (an edit
      # that never reached the server), a `.conflict-<ts>` copy is saved
      # aside before the delete (design §1/D1); matching content just deletes
      save_aside_unpushed_edit(s, rel)

      remove_local(s, rel)
      save_manifest(s, Map.delete(s.manifest, rel))
    else
      s
    end
  end

  defp apply_event(_ev, s), do: s

  # Copy an unpushed local edit out of harm's way before a server-remove
  # applies. No-op when there is no local file, no manifest entry, or the
  # content still matches what was synced.
  defp save_aside_unpushed_edit(s, rel) do
    abs = Path.join(s.mount, rel)
    cached = s.manifest[rel]

    if cached != nil and File.regular?(abs) do
      hash = file_hash(abs)

      if hash != nil and hash != cached.hash do
        backup = abs <> ".conflict-" <> ts()

        case File.copy(abs, backup) do
          {:ok, _} ->
            Logger.warning(
              "mcp-mount[#{s.name}]: server removed #{rel} with unpushed local edits; " <>
                "copy saved to #{backup}"
            )

          _ ->
            :ok
        end
      end
    end

    s
  end

  # ── move pairing (VFS-FEATURES-DESIGN §1 + D1) ────────────────────────────

  # Detection pass, run at the top of every live flush. A tracked path whose
  # file is GONE from disk, paired 1:1 with an untracked regular file whose
  # content hash matches the vanished entry's manifest hash, is an editor
  # rename. Both legs leave `pending`: the confirm tick either completes the
  # move or re-queues the legs for the ordinary write-back.
  defp pair_moves(s) do
    sources =
      for rel <- s.pending,
          s.manifest[rel] != nil,
          not control_path?(rel),
          not File.exists?(Path.join(s.mount, rel)),
          do: rel,
          into: MapSet.new()

    targets =
      for rel <- s.pending,
          s.manifest[rel] == nil,
          not control_path?(rel),
          File.regular?(Path.join(s.mount, rel)),
          do: rel,
          into: MapSet.new()

    if MapSet.size(sources) == 0 or MapSet.size(targets) == 0 do
      s
    else
      open = Enum.sort(MapSet.to_list(targets))

      {pairs, _leftover} =
        Enum.reduce(Enum.sort(MapSet.to_list(sources)), {[], open}, fn from_rel, {pairs, pool} ->
          want = s.manifest[from_rel].hash

          case want &&
                 Enum.find(pool, fn to_rel ->
                   file_hash(Path.join(s.mount, to_rel)) == want
                 end) do
            nil -> {pairs, pool}
            to_rel -> {pairs ++ [{from_rel, to_rel}], List.delete(pool, to_rel)}
          end
        end)

      Enum.reduce(pairs, s, fn {from_rel, to_rel}, st ->
        Logger.info("mcp-mount[#{st.name}]: inferred move #{from_rel} -> #{to_rel}")

        Process.send_after(self(), {:move_confirm, from_rel}, @move_confirm_ms)

        %{
          st
          | pending: st.pending |> MapSet.delete(from_rel) |> MapSet.delete(to_rel),
            move_pairing:
              Map.put(st.move_pairing, from_rel, %{
                to: to_rel,
                hash: st.manifest[from_rel].hash,
                attempts: 1
              })
        }
      end)
    end
  end

  # Ask the conn whether the server advertises `move`. Unknown caps (an
  # older server without the proto/caps handshake) are treated as
  # unsupported — the daemon never gambles a create on an unadvertised op.
  # The function_exported? probe keeps custom Conn implementations that
  # predate caps/1 degrading to "unsupported" instead of crashing.
  defp move_gate(conn) do
    mod = impl(conn)

    if function_exported?(mod, :caps, 1) do
      case mod.caps(conn) do
        caps when is_list(caps) ->
          if "move" in caps, do: :supported, else: {:unsupported, "no move cap advertised"}

        _ ->
          {:unsupported, "server caps unknown"}
      end
    else
      {:unsupported, "conn cannot report caps"}
    end
  end

  defp do_move(s, from_rel, pair) do
    case call(s.conn, "vfs/move", %{"from" => "/" <> from_rel, "to" => "/" <> pair.to}) do
      {:ok, node} ->
        Logger.info("mcp-mount[#{s.name}]: moved #{from_rel} -> #{pair.to} on server")

        mode = mode_from_node(node)
        abs_to = Path.join(s.mount, pair.to)
        File.chmod(abs_to, mode)

        s = %{
          s
          | move_pairing: Map.delete(s.move_pairing, from_rel),
            pull_attempts: Map.delete(s.pull_attempts, from_rel),
            parked: Map.delete(s.parked, from_rel),
            pushed_ack: s.pushed_ack |> MapSet.delete(from_rel) |> MapSet.put(pair.to)
        }

        # the from entry leaves the manifest, the to leg takes its place with
        # the server's acked version; the remove/create event pair this
        # triggers server-side self-echoes harmlessly (content matches what
        # we just recorded)
        #
        # the local read degrades instead of raising: the target can vanish
        # or turn unreadable in the window between the wire ack and this
        # update (user action, a racing server event). A failed read drops
        # the from leg and lets the server's own create self-echo heal the
        # target — never File.read!, whose raise would kill the daemon
        # (robot review, head d7dea15).
        case File.read(abs_to) do
          {:ok, content} ->
            save_manifest(
              s,
              s.manifest
              |> Map.delete(from_rel)
              |> Map.put(pair.to, entry(content, node["version"], mode))
            )

          {:error, reason} ->
            Logger.warning(
              "mcp-mount[#{s.name}]: move acked for #{pair.to} but local read failed " <>
                "(#{inspect(reason)}); target heals via server self-echo"
            )

            save_manifest(s, Map.delete(s.manifest, from_rel))
        end

      # server already holds something at the target: the inference raced a
      # real server-side create. Ordinary conflict semantics on the target.
      {:error, %{errno: :eexist}} ->
        Logger.warning(
          "mcp-mount[#{s.name}]: move target #{pair.to} already exists on server; conflict"
        )

        s = %{s | move_pairing: Map.delete(s.move_pairing, from_rel)}
        conflict(s, pair.to, Path.join(s.mount, pair.to))

      # The server refuses the op itself. Park the target — NEVER fall back
      # to create: a refused move must not duplicate the server-side
      # resource under a second identity (design D1).
      {:error, %{code: -32601}} ->
        move_refused(s, from_rel, pair, "server answered method_not_found")

      {:error, %{errno: :enosys}} ->
        move_refused(s, from_rel, pair, "server backend lacks move")

      {:error, reason} ->
        retry_or_give_up_move(s, from_rel, pair, reason)
    end
  end

  defp move_refused(s, from_rel, pair, why) do
    Logger.warning(
      "mcp-mount[#{s.name}]: vfs/move #{from_rel} -> #{pair.to} refused (#{why}); " <>
        "parking #{pair.to} — edit the note's frontmatter (title:/parent:) to move it instead"
    )

    s = %{s | move_pairing: Map.delete(s.move_pairing, from_rel)}
    park(s, pair.to, Path.join(s.mount, pair.to), why)
  end

  # Transport failure (or an unclassified error) on the move call: retry on
  # the flush cadence, park after @max_push_attempts like any push.
  defp retry_or_give_up_move(s, from_rel, pair, reason) do
    Logger.warning(
      "mcp-mount[#{s.name}]: vfs/move #{from_rel} -> #{pair.to} failed (#{inspect(reason)})"
    )

    n = pair.attempts + 1

    # attempts counts calls made (first call records 1); park once the count
    # would exceed the cap, matching capped_push's 4-actual-attempts cadence
    if n > @max_push_attempts do
      s = %{s | move_pairing: Map.delete(s.move_pairing, from_rel)}
      park(s, pair.to, Path.join(s.mount, pair.to), "move failed #{n}x (#{inspect(reason)})")
    else
      Process.send_after(self(), {:move_confirm, from_rel}, s.flush_retry_ms)
      %{s | move_pairing: Map.put(s.move_pairing, from_rel, Map.put(pair, :attempts, n))}
    end
  end

  # Event-driven pull of one path (server truth), with bounded backoff.
  # Pulls are never parked — they are the system's healing direction. A pull
  # that exhausts its backoff schedule is dropped, the per-path counter
  # is cleared, a resync nudge is queued (the quiescence check runs the diff
  # resync in place) and the drop is logged once.
  defp pull(s, rel, path) do
    case call(s.conn, "vfs/read", %{"path" => path}) do
      {:ok, %{"content" => content, "version" => v}} ->
        mode = event_mode(s.conn, path, s.manifest[rel])
        write_local(s, rel, content, mode)

        # a successful read-back confirms any earlier unconfirmed push
        s = %{s | pushed_ack: MapSet.delete(s.pushed_ack, rel)}

        save_manifest(
          pull_done(s, rel),
          Map.put(s.manifest, rel, entry(content, v, mode))
        )

      {:error, %{errno: :eisdir}} ->
        File.mkdir_p!(Path.join(s.mount, rel))
        pull_done(s, rel)

      {:error, %{errno: :enoent}} ->
        if MapSet.member?(s.pushed_ack, rel) do
          # self-echo for a path we just pushed acked, but the server no
          # longer has it at the requested path (canonicalized elsewhere?):
          # stranded — park instead of re-pushing (an unconditional re-push
          # here duplicated server-side resources unboundedly; seen live).
          pull_done(
            park(s, rel, Path.join(s.mount, rel), "echo for acked push, path missing on server"),
            rel
          )
        else
          pull_failed(s, rel, path, :enoent)
        end

      {:error, reason} ->
        pull_failed(s, rel, path, reason)
    end
  end

  defp pull_done(s, rel), do: %{s | pull_attempts: Map.delete(s.pull_attempts, rel)}

  defp pull_failed(s, rel, path, reason) do
    n = Map.get(s.pull_attempts, rel, 0)

    if n >= length(s.pull_backoff_ms) do
      Logger.warning(
        "mcp-mount[#{s.name}]: pull for #{path} failed #{n + 1}x " <>
          "(last: #{inspect(reason)}); dropping event — resync queued"
      )

      %{s | pull_attempts: Map.delete(s.pull_attempts, rel), resync_nudge: true}
    else
      delay = Enum.at(s.pull_backoff_ms, n)
      # the epoch rides along: a retry scheduled now is only valid for THIS
      # connection — a reconnect that goes live before it fires voids it
      Process.send_after(self(), {:pull_retry, rel, path, s.pull_epoch}, delay)

      %{s | pull_attempts: Map.put(s.pull_attempts, rel, n + 1)}
    end
  end

  defp event_mode(conn, path, cached) do
    case call(conn, "vfs/stat", %{"path" => path}) do
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

  # Returns {state, retry?}. retry? puts the path back into the deferred set
  # (flush retry timer): a push that hit a transport error (timeout/closed)
  # retries on the @flush_retry_ms cadence, each retry counted as an attempt.
  # The flush loop threads the state through, so ack-as-synced manifest
  # updates stick in memory — dropping them here is what made every later
  # writeback see a stale version and churn.
  defp writeback(s, rel) do
    abs = Path.join(s.mount, rel)

    cond do
      # control tree (/etc/**) is a server-side configuration surface. One
      # corner is writable: etc/dev/config/** (the runtime writes toggle)
      # pushes through the ordinary vfs/write below — the server validates
      # the data, so a malformed edit fails like any write error (retries,
      # then park; the gate is untouched). Every other etc/** path stays a
      # documented no-op: never queued, never pushed, never conflict-saved.
      control_path?(rel) and !control_config_path?(rel) ->
        {s, false}

      s.ro ->
        Logger.warning("mcp-mount[#{s.name}]: ro mount, refusing write-back for #{rel}")
        {s, false}

      true ->
        s = unpark_if_changed(s, rel, abs)

        cond do
          parked?(s, rel, abs) -> {s, false}
          File.dir?(abs) -> {s, false}
          File.regular?(abs) -> capped_push(s, rel, abs)
          true -> {s, false}
        end
    end
  end

  # Per-path retry cap: a push that keeps failing or going unconfirmed is
  # attempted at most @max_push_attempts times, then parked — it is never
  # re-pushed until the local file changes (user modification). Transport
  # timeouts count as attempts (the retry cadence is the flush retry timer).
  defp capped_push(s, rel, abs) do
    n = Map.get(s.push_attempts, rel, 0)

    if n >= @max_push_attempts do
      {park(s, rel, abs, "no confirmed push after #{n} attempts"), false}
    else
      push_local(%{s | push_attempts: Map.put(s.push_attempts, rel, n + 1)}, rel, abs)
    end
  end

  # Every push failure defers and retries on the flush cadence — transport
  # timeouts AND server-side application errors alike (robot follow-up F9).
  # Previously only {:error, :timeout}/:closed retried, so e.g.
  # {:error, %{errno: :eio}} sat unhandled until the next watcher event;
  # now it gets the same bounded cadence. The @max_push_attempts cap bounds
  # it: persistent failures of either kind park after the same number of
  # attempts, so an app error cannot churn forever.
  defp push_local(s, rel, abs) do
    path = "/" <> rel
    local = s.manifest[rel]
    local_hash = file_hash(abs)

    case call(s.conn, "vfs/stat", %{"path" => path}) do
      {:ok, %{"version" => v}} ->
        cond do
          # already synced: the server holds the version we recorded and the
          # local content is unchanged since then — watcher noise (chmod/touch
          # refires), not an edit. Pushing would bump the server version for
          # no change.
          local != nil and v == local.version and Map.get(local, :unconfirmed) == nil and
            local_hash != nil and local_hash == local.hash ->
            {s, false}

          local != nil and local.version == v ->
            with {:ok, content} <- File.read(abs) do
              case call(s.conn, "vfs/write", %{"path" => path, "data" => content}) do
                {:ok, node} ->
                  {acked_sync(s, rel, content, local.mode, node["version"], local.version), false}

                {:error, reason} ->
                  Logger.warning(
                    "mcp-mount[#{s.name}]: write failed for #{path}: #{inspect(reason)}"
                  )

                  {s, true}
              end
            else
              _ -> {s, false}
            end

          true ->
            {conflict(s, rel, abs), false}
        end

      {:error, %{errno: :enoent}} ->
        cond do
          # stranded: we hold an ack for exactly this content but the server
          # no longer has the requested path (canonicalized elsewhere). Do not
          # re-create — that duplicates server-side resources.
          local != nil and MapSet.member?(s.pushed_ack, rel) and
            local_hash != nil and local_hash == local.hash ->
            {park(s, rel, abs, "push acked but path missing on server"), false}

          true ->
            # locally created file — create it on the server
            with {:ok, content} <- File.read(abs),
                 {:ok, node} <- call(s.conn, "vfs/create", %{"path" => path, "data" => content}) do
              mode = mode_from_node(node)
              File.chmod(abs, mode)

              # ack-as-synced: a successful ack always marks the path synced.
              # An ack without a version records the pre-push version flagged
              # unconfirmed until a read-back confirms it.
              {acked_sync(s, rel, content, mode, node["version"], local && local.version), false}
            else
              {:error, reason} ->
                Logger.warning(
                  "mcp-mount[#{s.name}]: create failed for #{path}: #{inspect(reason)}"
                )

                {s, true}
            end
        end

      {:error, reason} ->
        Logger.warning("mcp-mount[#{s.name}]: stat failed for #{path}: #{inspect(reason)}")
        {s, true}
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
    # a confirmed push resets the retry counter — attempts count *unconfirmed*
    # pushes, and a healthy path must never drift into park on watcher noise
    s = %{s | push_attempts: Map.delete(s.push_attempts, rel)}
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
           call(s.conn, "vfs/read", %{"path" => "/" <> rel}) do
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

  # Resync nudge: a dropped pull queued a heal. When the mount is live and
  # quiescent (nothing pending), run the existing sync/1 IN PLACE — it is the
  # same diff resync the reconnect uses, so drift heals without dropping the
  # watcher or the manifest. Only if the resync itself fails do we escalate
  # to a full reconnect (its own backoff cycle).
  defp maybe_resync(%__MODULE__{resync_nudge: true, state: :live, conn: conn} = s)
       when conn != nil do
    if MapSet.size(s.pending) > 0, do: s, else: do_resync(s)
  end

  defp maybe_resync(s), do: s

  defp do_resync(s) do
    Logger.info("mcp-mount[#{s.name}]: resync nudge — diff resync in place")

    case sync(s) do
      {:ok, s} ->
        Logger.info("mcp-mount[#{s.name}]: nudge resync ok (#{map_size(s.manifest)} files)")
        %{s | resync_nudge: false, pull_attempts: %{}}

      {:error, reason} ->
        Logger.warning(
          "mcp-mount[#{s.name}]: nudge resync failed (#{inspect(reason)}); escalating to reconnect"
        )

        reconnect_state(s, reason)
    end
  end

  defp reconnect(s, reason), do: {:noreply, reconnect_state(s, reason)}

  defp reconnect_state(s, reason) do
    if s.mon_ref, do: Process.demonitor(s.mon_ref, [:flush])

    if s.watcher != nil and is_pid(s.watcher) do
      Process.exit(s.watcher, :kill)
    end

    Logger.warning("mcp-mount[#{s.name}]: reconnecting in #{s.backoff_ms}ms (#{inspect(reason)})")
    Process.send_after(self(), {:reconnect_tick, nil}, s.backoff_ms)

    %{
      s
      | state: :reconnecting,
        conn: nil,
        mon_ref: nil,
        backoff_ms: min(s.backoff_ms * 2, @backoff_max)
    }
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

  # Control tree: server-side configuration surfaces. etc/dev/config/** is
  # the one writable corner (runtime toggle writes reach the ordinary
  # vfs/write — VFS-FEATURES-DESIGN §3/D3, zero protocol change); every
  # other control path is read-only: never queued, never pushed.
  defp control_path?("etc"), do: true
  defp control_path?(rel), do: String.starts_with?(rel, "etc/")

  defp control_config_path?(rel), do: String.starts_with?(rel, "etc/dev/config/")

  defp ts, do: DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(":", "-")

  defp join_path("/", name), do: "/" <> name
  defp join_path(dir, name), do: dir <> "/" <> name
end
