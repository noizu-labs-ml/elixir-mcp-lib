defmodule McpMount.MounterWritebackRegressionTest do
  # Regressions for the write-back amplifiers seen live against a real VFSWS
  # server (2026-09): a create acked at a canonicalized path re-pushed every
  # debounce (76 duplicate resources in 8s), flushes raised against a dead
  # conn and killed the daemon, and control-tree (/etc/**) edits conflict-
  # churned. Each test pins one of the defenses.
  use ExUnit.Case, async: false

  import McpMount.Support

  alias McpMount.{FakeConn, Manifest, Mounter}

  setup do
    dir = Path.join(System.tmp_dir!(), "mcp-mount-wb-#{System.unique_integer()}")
    name = String.to_atom("mounter_wb_#{System.unique_integer()}")

    _fake = start_supervised!({McpMount.Test.FakeVfs, tree()})

    mounter =
      start_supervised!(
        Supervisor.child_spec(
          {
            Mounter,
            url: "ws://fake/vfs",
            token: "t",
            mount: dir,
            conn_mod: FakeConn,
            conn_opts: [handler: McpMount.Test.FakeVfs.handler()],
            name: name
          },
          id: name
        )
      )

    wait_until(fn -> if live?(mounter), do: :ok end)

    on_exit(fn ->
      File.rm_rf!(dir)
      McpMount.Test.FakeVfs.stop()
    end)

    %{dir: dir, mounter: mounter}
  end

  defp tree do
    [
      {"/docs", %{type: :dir, version: 1}},
      {"/docs/hello.txt", %{type: :file, version: 1, content: "hello world\n"}},
      # control tree: server-side configuration surface, materialized but
      # never pushed
      {"/etc", %{type: :dir, version: 1}},
      {"/etc/dev", %{type: :dir, version: 1}},
      {"/etc/dev/config", %{type: :dir, version: 1}},
      {"/etc/dev/config/writes", %{type: :file, version: 1, content: "true\n"}}
    ]
  end

  defp live?(mounter), do: elem(Mounter.state(mounter), 0) == :live

  defp fake_conn(mounter), do: :sys.get_state(mounter).conn

  test "control tree /etc/** is materialized but excluded from write-back", %{
    dir: dir,
    mounter: mounter
  } do
    writes = Path.join(dir, "etc/dev/config/writes")
    assert File.read!(writes) == "true\n"
    assert Manifest.read(dir)["etc/dev/config/writes"] != nil

    # a local edit must be a no-op: no push, no conflict churn
    File.write!(writes, "false\n")
    Process.sleep(900)

    assert Process.alive?(mounter)

    {:ok, %{"content" => content, "version" => version}} =
      McpMount.Test.FakeVfs.handler().("vfs/read", %{"path" => "/etc/dev/config/writes"})

    assert content == "true\n"
    assert version == 1
    assert File.read!(writes) == "false\n"
    assert Manifest.read(dir)["etc/dev/config/writes"].version == 1

    # no conflict copies anywhere under the control tree
    refute conflict_under?(Path.join(dir, "etc"))
  end

  defp conflict_under?(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        Enum.any?(files, fn f ->
          String.contains?(f, ".conflict-") or
            (File.dir?(Path.join(dir, f)) and conflict_under?(Path.join(dir, f)))
        end)

      _ ->
        false
    end
  end

  test "flush with dead conn defers the write-back and pushes after resync", %{
    dir: dir,
    mounter: mounter
  } do
    conn = fake_conn(mounter)

    :sys.replace_state(
      mounter,
      fn st ->
        %{st | state: :reconnecting, conn: nil, pending: MapSet.new(["docs/hello.txt"]), timer: nil}
      end
    )

    File.write!(Path.join(dir, "docs/hello.txt"), "deferred edit\n")
    send(mounter, :flush)
    Process.sleep(400)

    # no raise, no push — pending preserved for the post-resync flush
    assert Process.alive?(mounter)
    assert MapSet.member?(:sys.get_state(mounter).pending, "docs/hello.txt")

    {:ok, %{"content" => content}} =
      McpMount.Test.FakeVfs.handler().("vfs/read", %{"path" => "/docs/hello.txt"})

    assert content == "hello world\n"

    # reconnect: resync, then the deferred pending is flushed
    FakeConn.drop(conn, :test_drop)
    wait_until(fn -> if live?(mounter), do: :ok end, 10_000)

    wait_until(
      fn ->
        case McpMount.Test.FakeVfs.handler().("vfs/read", %{"path" => "/docs/hello.txt"}) do
          {:ok, %{"content" => "deferred edit\n"}} -> :ok
          _ -> nil
        end
      end,
      8_000
    )
  end

  test "create acked at a canonicalized path strands + parks instead of re-pushing" do
    dir = Path.join(System.tmp_dir!(), "mcp-mount-ghost-#{System.unique_integer()}")
    name = String.to_atom("mounter_ghost_#{System.unique_integer()}")
    counter_name = String.to_atom("ghost_counter_#{System.unique_integer()}")
    {:ok, counter} = Agent.start_link(fn -> 0 end, name: counter_name)

    mounter =
      start_supervised!(
        Supervisor.child_spec(
          {
            Mounter,
            url: "ws://fake/vfs",
            token: "t",
            mount: dir,
            conn_mod: FakeConn,
            conn_opts: [handler: ghost_handler(counter_name)],
            name: name
          },
          id: name
        )
      )

    wait_until(fn -> if live?(mounter), do: :ok end)

    # locally create a file the server will canonicalize elsewhere: the
    # create is acked (version 7) but the requested path never exists
    write_and_wait_push(dir, "docs/ghost.txt", "ghost content\n", fn ->
      manifest = Manifest.read(dir)["docs/ghost.txt"]
      manifest != nil and manifest.version == 7
    end)

    # ack-as-synced: the manifest already records the acked version and hash
    assert Manifest.read(dir)["docs/ghost.txt"].version == 7

    # watcher noise (chmod/touch refire) must not re-create: the daemon
    # strands + parks the path when the read-back stays enoent
    File.touch!(Path.join(dir, "docs/ghost.txt"))

    wait_until(
      fn -> if map_size(:sys.get_state(mounter).parked) == 1, do: :ok end,
      8_000
    )

    assert Map.has_key?(:sys.get_state(mounter).parked, "docs/ghost.txt")

    # the loop is over: attempts stay bounded and the daemon survives
    Process.sleep(1_200)
    assert Agent.get(counter, & &1) <= 4
    assert Process.alive?(mounter)

    # a .conflict-<ts> copy of the local content was saved aside
    backup =
      dir |> Path.join("docs") |> File.ls!() |> Enum.find(&String.contains?(&1, ".conflict-"))

    assert backup != nil
    assert File.read!(Path.join([dir, "docs", backup])) == "ghost content\n"

    # editing the file unparks it (user modification re-enables write-back)
    File.write!(Path.join(dir, "docs/ghost.txt"), "ghost content v2\n")

    wait_until(
      fn -> if map_size(:sys.get_state(mounter).parked) == 0, do: :ok end,
      8_000
    )

    File.rm_rf!(dir)
  end

  test "create acked without a version is marked synced-unconfirmed and parks, not loops" do
    dir = Path.join(System.tmp_dir!(), "mcp-mount-nov-#{System.unique_integer()}")
    name = String.to_atom("mounter_nov_#{System.unique_integer()}")
    counter_name = String.to_atom("nov_counter_#{System.unique_integer()}")
    {:ok, counter} = Agent.start_link(fn -> 0 end, name: counter_name)

    base = ghost_handler(counter_name)

    handler = fn
      "vfs/create", %{"path" => "/docs/ghost.txt"} ->
        Agent.update(counter, &(&1 + 1))
        # ack carries no version — daemon must still mark the path synced
        {:ok, %{"executable" => false}}

      m, p ->
        base.(m, p)
    end

    mounter =
      start_supervised!(
        Supervisor.child_spec(
          {
            Mounter,
            url: "ws://fake/vfs",
            token: "t",
            mount: dir,
            conn_mod: FakeConn,
            conn_opts: [handler: handler],
            name: name
          },
          id: name
        )
      )

    wait_until(fn -> if live?(mounter), do: :ok end)

    write_and_wait_push(dir, "docs/ghost.txt", "ghost content\n", fn ->
      Manifest.read(dir)["docs/ghost.txt"] != nil
    end)

    entry = Manifest.read(dir)["docs/ghost.txt"]
    assert entry.unconfirmed == true
    assert entry.version == nil

    File.touch!(Path.join(dir, "docs/ghost.txt"))

    wait_until(
      fn -> if map_size(:sys.get_state(mounter).parked) == 1, do: :ok end,
      8_000
    )

    Process.sleep(1_000)
    assert Agent.get(counter, & &1) <= 4
    assert Process.alive?(mounter)

    File.rm_rf!(dir)
  end

  # Server that canonicalizes new pages: /docs/hello.txt round-trips normally,
  # but creates for /docs/ghost.txt are acked while the resource materializes
  # somewhere else (the requested path stays enoent forever).
  defp ghost_handler(counter_name) do
    fn
      "vfs/ping", _params ->
        {:ok, %{"pong" => true}}

      "vfs/list", %{"path" => "/"} ->
        {:ok, %{"entries" => [%{"name" => "docs", "type" => "dir", "version" => 1}]}}

      "vfs/list", %{"path" => "/docs"} ->
        {:ok, %{"entries" => [%{"name" => "hello.txt", "type" => "file", "version" => 1}]}}

      "vfs/read", %{"path" => "/docs/hello.txt"} ->
        {:ok, %{"content" => "hello world\n", "version" => 1}}

      "vfs/stat", %{"path" => "/docs/hello.txt"} ->
        {:ok, %{"type" => "file", "version" => 1, "executable" => false}}

      "vfs/stat", %{"path" => "/docs/ghost.txt"} ->
        {:error, :enoent}

      "vfs/create", %{"path" => "/docs/ghost.txt", "data" => _data} ->
        Agent.update(counter_name, &(&1 + 1))
        {:ok, %{"version" => 7, "executable" => false}}

      _method, _params ->
        {:error, :enosys}
    end
  end
end
