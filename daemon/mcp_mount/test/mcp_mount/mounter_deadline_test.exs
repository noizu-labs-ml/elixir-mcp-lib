defmodule McpMount.MounterDeadlineTest do
  # Deadline hardening (VFS-FEATURES-DESIGN §4): contracted timeout values (no
  # raise escaping the conn), per-op budgets, push timeouts counting as
  # attempts (defer + park), and the pull backoff -> drop -> resync-nudge ->
  # in-place diff sync state machine (full reconnect only as escalation).
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import McpMount.Support

  alias McpMount.{FakeConn, Manifest, Mounter}

  setup do
    dir = Path.join(System.tmp_dir!(), "mcp-mount-dl-#{System.unique_integer()}")
    name = String.to_atom("mounter_dl_#{System.unique_integer()}")

    _fake = start_supervised!({McpMount.Test.FakeVfs, tree()})

    on_exit(fn ->
      File.rm_rf!(dir)
      McpMount.Test.FakeVfs.stop()
    end)

    %{dir: dir, name: name}
  end

  defp tree do
    [
      {"/docs", %{type: :dir, version: 1}},
      {"/docs/hello.txt", %{type: :file, version: 1, content: "hello world\n"}},
      {"/docs/note.md", %{type: :file, version: 1, content: "# note\n\nseed body\n"}}
    ]
  end

  defp start_mount(dir, name, opts \\ []) do
    handler = Keyword.get(opts, :handler, McpMount.Test.FakeVfs.handler())

    mounter_opts =
      [
        url: "ws://fake/vfs",
        token: "t",
        mount: dir,
        conn_mod: Keyword.get(opts, :conn_mod, FakeConn),
        conn_opts: [handler: handler] ++ Keyword.get(opts, :conn_opts, []),
        name: name
      ] ++ Keyword.take(opts, [:flush_retry_ms, :pull_backoff_ms])

    start_supervised!(Supervisor.child_spec({Mounter, mounter_opts}, id: name))
  end

  defp live?(mounter), do: elem(Mounter.state(mounter), 0) == :live

  defp hello(dir), do: Path.join(dir, "docs/hello.txt")

  # ── per-op budgets ────────────────────────────────────────────────────────

  test "per-op budgets reach the conn (ping/stat 5s, list/read 15s tiers, write 30s)", %{
    dir: dir,
    name: name
  } do
    {:ok, recorder} = Agent.start_link(fn -> %{} end)

    mounter =
      start_mount(dir, name,
        conn_mod: McpMount.Test.RecordingConn,
        conn_opts: [recorder: recorder]
      )

    wait_until(fn -> if live?(mounter), do: :ok end)

    conn = :sys.get_state(mounter).conn

    # sync phase: ping + list + reads
    assert seen?(recorder, "vfs/ping", 5_000)
    assert seen?(recorder, "vfs/list", 10_000)
    assert seen?(recorder, "vfs/read", 15_000)

    # live pull: read at the read budget, stat (event_mode) at the stat budget
    McpMount.Test.FakeVfs.write("/docs/hello.txt", "remote v2\n")

    McpMount.Test.RecordingConn.inject_event(conn, %{
      op: "write",
      path: "/docs/hello.txt",
      version: 2
    })

    wait_until(fn -> if File.read!(hello(dir)) == "remote v2\n", do: :ok end)
    assert seen?(recorder, "vfs/read", 15_000)
    assert seen?(recorder, "vfs/stat", 5_000)

    # push: stat at the stat budget, write at the write budget
    write_and_wait_push(dir, "docs/hello.txt", "local edit\n", fn ->
      case McpMount.Test.FakeVfs.handler().("vfs/read", %{"path" => "/docs/hello.txt"}) do
        {:ok, %{"content" => "local edit\n"}} -> true
        _ -> false
      end
    end)

    assert seen?(recorder, "vfs/stat", 5_000)
    assert seen?(recorder, "vfs/write", 30_000)

    # create: stat (enoent) at the stat budget, create at the create budget
    write_and_wait_push(dir, "docs/new.txt", "created\n", fn ->
      case McpMount.Test.FakeVfs.handler().("vfs/read", %{"path" => "/docs/new.txt"}) do
        {:ok, %{"content" => "created\n"}} -> true
        _ -> false
      end
    end)

    assert seen?(recorder, "vfs/create", 15_000)

    # every call for each op class used exactly that op class's budget
    assert Enum.all?(McpMount.Test.RecordingConn.recorded(recorder, "vfs/ping"), &(&1 == 5_000))
    assert Enum.all?(McpMount.Test.RecordingConn.recorded(recorder, "vfs/stat"), &(&1 == 5_000))
    assert Enum.all?(McpMount.Test.RecordingConn.recorded(recorder, "vfs/list"), &(&1 == 10_000))
    assert Enum.all?(McpMount.Test.RecordingConn.recorded(recorder, "vfs/read"), &(&1 == 15_000))

    assert Enum.all?(
             McpMount.Test.RecordingConn.recorded(recorder, "vfs/create"),
             &(&1 == 15_000)
           )

    assert Enum.all?(McpMount.Test.RecordingConn.recorded(recorder, "vfs/write"), &(&1 == 30_000))
  end

  defp seen?(recorder, method, timeout),
    do: Enum.member?(McpMount.Test.RecordingConn.recorded(recorder, method), timeout)

  # ── pull backoff ──────────────────────────────────────────────────────────

  test "pull retries on the backoff schedule and lands when a retry succeeds", %{
    dir: dir,
    name: name
  } do
    McpMount.Test.FakeVfs.write("/docs/hello.txt", "remote v2\n")

    {:ok, fails} = Agent.start_link(fn -> 2 end)
    base = McpMount.Test.FakeVfs.handler()

    handler = fn
      "vfs/read", %{"path" => "/docs/hello.txt"} = params ->
        if Agent.get_and_update(fails, fn n -> {n > 0, max(n - 1, 0)} end) do
          {:error, :eio}
        else
          base.("vfs/read", params)
        end

      m, p ->
        base.(m, p)
    end

    mounter = start_mount(dir, name, handler: handler, pull_backoff_ms: [20, 40, 60])
    wait_until(fn -> if live?(mounter), do: :ok end)

    FakeConn.inject_event(fake_conn(mounter), %{
      op: "write",
      path: "/docs/hello.txt",
      version: 2
    })

    # pull 1 fails, retry at 20ms fails, retry at 40ms succeeds
    wait_until(fn -> if File.read!(hello(dir)) == "remote v2\n", do: :ok end)

    assert Manifest.read(dir)["docs/hello.txt"].version == 2

    state = :sys.get_state(mounter)
    assert state.pull_attempts == %{}
    assert state.resync_nudge == false
    assert live?(mounter)
  end

  test "exhausted pull drops the event, nudges, escalates to reconnect, heals on recovery", %{
    dir: dir,
    name: name
  } do
    # reads start out serving (go_live requires a full sync); the switch makes
    # only hello.txt reads fail once the mount is live
    {:ok, switch} = Agent.start_link(fn -> false end)
    base = McpMount.Test.FakeVfs.handler()

    handler = fn
      "vfs/read", %{"path" => "/docs/hello.txt"} ->
        if Agent.get(switch, & &1) do
          {:error, :eio}
        else
          base.("vfs/read", %{"path" => "/docs/hello.txt"})
        end

      m, p ->
        base.(m, p)
    end

    mounter = start_mount(dir, name, handler: handler, pull_backoff_ms: [20, 30, 40])
    wait_until(fn -> if live?(mounter), do: :ok end)

    # drift AFTER live: the manifest holds v1, so the v2 event is a real pull,
    # not a self-echo
    McpMount.Test.FakeVfs.write("/docs/hello.txt", "resync target\n")

    logs =
      capture_log(fn ->
        Agent.update(switch, fn _ -> true end)

        FakeConn.inject_event(fake_conn(mounter), %{
          op: "write",
          path: "/docs/hello.txt",
          version: 2
        })

        # 4 failed pulls (initial + 3 backoff retries) -> drop + nudge; the
        # nudge's in-place resync fails too (its read fails) -> reconnect
        wait_until(
          fn ->
            case :sys.get_state(mounter) do
              %{state: :reconnecting} -> :ok
              _ -> nil
            end
          end,
          5_000
        )
      end)

    assert logs =~ "dropping event"
    assert logs =~ "escalating to reconnect"

    # server recovers: the reconnect resync (same diff walk) lands the content
    Agent.update(switch, fn _ -> false end)

    wait_until(fn -> if live?(mounter), do: :ok end, 15_000)

    wait_until(fn -> if File.read!(hello(dir)) == "resync target\n", do: :ok end)
    assert Manifest.read(dir)["docs/hello.txt"].version == 2
    assert Process.alive?(mounter)
  end

  test "resync nudge heals drift in place, keeping the watcher and manifest", %{
    dir: dir,
    name: name
  } do
    mounter = start_mount(dir, name)
    wait_until(fn -> if live?(mounter), do: :ok end)

    %{watcher: watcher} = :sys.get_state(mounter)
    assert is_pid(watcher)

    # server drifts with no event delivered (the dropped-pull situation this
    # heals), then simulate the nudge and quiesce with an empty flush
    McpMount.Test.FakeVfs.write("/docs/hello.txt", "healed remotely\n")
    :sys.replace_state(mounter, fn st -> %{st | resync_nudge: true} end)
    send(mounter, :flush)

    wait_until(fn -> if File.read!(hello(dir)) == "healed remotely\n", do: :ok end)

    assert Manifest.read(dir)["docs/hello.txt"].version == 2

    state = :sys.get_state(mounter)
    assert state.state == :live
    assert state.resync_nudge == false
    assert state.pull_attempts == %{}
    # same watcher process — the in-place resync never dropped it
    assert state.watcher == watcher
    assert Process.alive?(mounter)
  end

  # ── push timeouts: defer, count attempts, park ────────────────────────────

  test "push transport timeout defers, counts attempts, parks after max attempts", %{
    dir: dir,
    name: name
  } do
    {:ok, stats} = Agent.start_link(fn -> 0 end)
    base = McpMount.Test.FakeVfs.handler()

    handler = fn
      "vfs/stat", %{"path" => "/docs/hello.txt"} ->
        Agent.update(stats, &(&1 + 1))
        {:error, :timeout}

      m, p ->
        base.(m, p)
    end

    mounter = start_mount(dir, name, handler: handler, flush_retry_ms: 20)
    wait_until(fn -> if live?(mounter), do: :ok end)

    # timeouts defer + retry on the flush cadence; each retry is an attempt;
    # after @max_push_attempts the path is parked (content saved aside)
    write_and_wait_push(dir, "docs/hello.txt", "will not push\n", fn ->
      map_size(:sys.get_state(mounter).parked) == 1
    end)

    assert Map.has_key?(:sys.get_state(mounter).parked, "docs/hello.txt")

    # exactly the capped number of attempts, then no further calls
    n = Agent.get(stats, & &1)
    assert n == 4
    Process.sleep(150)
    assert Agent.get(stats, & &1) == n

    assert Process.alive?(mounter)
    assert live?(mounter)

    # the local file stays in place, content safe in a .conflict-<ts> copy
    assert File.read!(hello(dir)) == "will not push\n"

    backup =
      dir |> Path.join("docs") |> File.ls!() |> Enum.find(&String.contains?(&1, ".conflict-"))

    assert backup != nil
    assert File.read!(Path.join([dir, "docs", backup])) == "will not push\n"
  end

  test "a confirmed push resets the attempt counter", %{dir: dir, name: name} do
    mounter = start_mount(dir, name)
    wait_until(fn -> if live?(mounter), do: :ok end)

    write_and_wait_push(dir, "docs/hello.txt", "acked once\n", fn ->
      case McpMount.Test.FakeVfs.handler().("vfs/read", %{"path" => "/docs/hello.txt"}) do
        {:ok, %{"content" => "acked once\n"}} -> true
        _ -> false
      end
    end)

    # the push consumed one attempt; the ack cleared that path's counter, so
    # later pushes of the same path start fresh instead of drifting toward
    # park (unrelated paths keep their own counters — machinery untouched)
    assert :sys.get_state(mounter).push_attempts["docs/hello.txt"] == nil
  end

  defp fake_conn(mounter), do: :sys.get_state(mounter).conn
end
