defmodule McpMount.MounterMoveTest do
  # Move pairing (VFS-FEATURES-DESIGN §1 + D1): a tracked file vanishing from
  # disk while an untracked file with identical content appears is an editor
  # rename — promoted to ONE vfs/move instead of "create the new path, drop
  # the old one". Each test pins one rule of the pairing/gate/fallback flow.
  #
  # Two harness styles:
  #   * formation tests queue the legs for the real flush directly — rm
  #     events cannot be re-fired once the file is gone, so the watcher is
  #     not in the loop here (its plumbing is covered by the write-back
  #     suite);
  #   * gate/refusal/abort tests inject the pairing state directly
  #     (:sys.replace_state) and fire the confirm tick by hand — they pin the
  #     decision logic, not the watcher.
  use ExUnit.Case, async: false

  import McpMount.Support

  alias McpMount.{FakeConn, Manifest, Mounter}
  alias McpMount.Test.FakeVfs

  setup do
    dir = Path.join(System.tmp_dir!(), "mcp-mount-mv-#{System.unique_integer()}")
    name = String.to_atom("mounter_mv_#{System.unique_integer()}")

    _fake = start_supervised!({FakeVfs, tree()})

    # default server advertises move (proto/caps extras); the gate tests
    # build their own mounter with caps: [] / no caps
    mounter = start_mounter(dir, name, caps: ["move"])

    wait_until(fn -> if live?(mounter), do: :ok end)

    on_exit(fn ->
      File.rm_rf!(dir)
      FakeVfs.stop()
    end)

    %{dir: dir, mounter: mounter}
  end

  defp tree do
    [
      {"/docs", %{type: :dir, version: 1}},
      {"/docs/hello.txt", %{type: :file, version: 1, content: "hello world\n"}},
      {"/docs/note.md", %{type: :file, version: 1, content: "# note\n\nseed body\n"}}
    ]
  end

  defp start_mounter(dir, name, extra_conn_opts) do
    start_supervised!(
      Supervisor.child_spec(
        {
          Mounter,
          url: "ws://fake/vfs",
          token: "t",
          mount: dir,
          conn_mod: FakeConn,
          conn_opts: [handler: FakeVfs.handler()] ++ extra_conn_opts,
          name: name
        },
        id: name
      )
    )
  end

  defp live?(mounter), do: elem(Mounter.state(mounter), 0) == :live

  defp fake_conn(mounter), do: :sys.get_state(mounter).conn

  # ── harness helpers ───────────────────────────────────────────────────────

  defp poll_until(check, deadline) do
    if check.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(50)
        poll_until(check, deadline)
      end
    end
  end

  # Single-file edit re-drive: rewrites the same content until `check` passes
  # (a dropped first fsevents batch must not fail the test).
  defp drive_write(dir, rel, content, check, timeout \\ 8_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_drive_write(dir, rel, content, check, deadline)
  end

  defp do_drive_write(dir, rel, content, check, deadline) do
    File.write!(Path.join(dir, rel), content)

    quiet_deadline = (System.monotonic_time(:millisecond) + 2_000) |> Kernel.min(deadline)

    if poll_until(check, quiet_deadline) do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        raise ExUnit.AssertionError, message: "drive_write: condition not met within timeout"
      end

      do_drive_write(dir, rel, content, check, deadline)
    end
  end

  # White-box: record the pairing the detection pass would have produced and
  # let the test fire the confirm tick itself. The filesystem legs are laid
  # by the caller; the tick only consults move_pairing + disk state.
  defp inject_pairing(mounter, dir, from_rel, to_rel) do
    hash = Manifest.read(dir)[from_rel].hash

    :sys.replace_state(mounter, fn st ->
      %{
        st
        | move_pairing: Map.put(st.move_pairing, from_rel, %{to: to_rel, hash: hash, attempts: 1})
      }
    end)

    :ok
  end

  defp confirm_move(mounter, from_rel), do: send(mounter, {:move_confirm, from_rel})

  # Queue legs for the real flush without depending on watcher delivery.
  defp inject_pending(mounter, rels) do
    :sys.replace_state(mounter, fn st ->
      %{st | pending: MapSet.union(st.pending, MapSet.new(rels)), timer: nil}
    end)

    send(mounter, :flush)
  end

  defp parked?(mounter, rel), do: Map.has_key?(:sys.get_state(mounter).parked, rel)

  defp conflict_paths(dir, rel) do
    parent = Path.dirname(Path.join(dir, rel))
    base = Path.basename(rel)

    case File.ls(parent) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.starts_with?(&1, base <> ".conflict-"))
        |> Enum.map(&Path.join(parent, &1))

      _ ->
        []
    end
  end

  # ── formation (real flush path) ───────────────────────────────────────────

  test "hash match promotes the rename to one vfs/move, never a create", %{
    dir: dir,
    mounter: mounter
  } do
    # the legs are laid on disk and queued for the real flush (the watcher
    # plumbing is covered by the write-back suite; rm events cannot be
    # re-fired once the file is gone, so the move shape is driven directly)
    File.rm!(Path.join(dir, "docs/hello.txt"))
    File.write!(Path.join(dir, "docs/renamed.txt"), "hello world\n")
    inject_pending(mounter, ["docs/hello.txt", "docs/renamed.txt"])

    # wait on the END state (manifest moved); the wire call itself is then
    # asserted exactly-once with its exact shape
    wait_until(
      fn ->
        m = Manifest.read(dir)
        if m["docs/hello.txt"] == nil and m["docs/renamed.txt"] != nil, do: :ok
      end,
      8_000
    )

    assert FakeVfs.calls("vfs/move") == [
             %{"from" => "/docs/hello.txt", "to" => "/docs/renamed.txt"}
           ]

    # no decayed create churn around the move
    assert FakeVfs.calls("vfs/create") == []

    # the server tree moved: the old path is gone, the new path holds the content
    assert FakeVfs.handler().("vfs/read", %{"path" => "/docs/hello.txt"}) ==
             {:error, :enoent}

    assert {:ok, %{"content" => "hello world\n"}} =
             FakeVfs.handler().("vfs/read", %{"path" => "/docs/renamed.txt"})

    # manifest follows the move: from gone, to present with the server version
    manifest = Manifest.read(dir)
    assert manifest["docs/hello.txt"] == nil
    assert is_integer(manifest["docs/renamed.txt"].version)
    assert File.read!(Path.join(dir, "docs/renamed.txt")) == "hello world\n"
  end

  test "content mismatch decays to the ordinary create flow (no move)", %{
    dir: dir,
    mounter: mounter
  } do
    File.rm!(Path.join(dir, "docs/hello.txt"))
    File.write!(Path.join(dir, "docs/renamed.txt"), "DIFFERENT content\n")
    inject_pending(mounter, ["docs/hello.txt", "docs/renamed.txt"])

    wait_until(
      fn -> if Manifest.read(dir)["docs/renamed.txt"] != nil, do: :ok end,
      8_000
    )

    assert FakeVfs.calls("vfs/move") == []

    assert {:ok, %{"content" => "DIFFERENT content\n"}} =
             FakeVfs.handler().("vfs/read", %{"path" => "/docs/renamed.txt"})
  end

  test "pairing recorded before a drop completes after reconnect", %{dir: dir, mounter: mounter} do
    # the rename is recorded while live (state laid on disk, pairing written
    # directly — the watcher path is covered by the formation tests above);
    # both the pairing and the disk legs must survive the reconnect cycle
    File.rm!(Path.join(dir, "docs/hello.txt"))
    File.write!(Path.join(dir, "docs/renamed.txt"), "hello world\n")
    inject_pairing(mounter, dir, "docs/hello.txt", "docs/renamed.txt")

    FakeConn.drop(fake_conn(mounter), :test_drop)
    wait_until(fn -> if live?(mounter), do: :ok end, 10_000)

    # the resync skips the still-version-matched (now missing) source — the
    # pairing is not silently healed away — and go_live re-arms the confirm,
    # which then completes the move on the new connection
    wait_until(
      fn ->
        if FakeVfs.calls("vfs/move") == [
             %{"from" => "/docs/hello.txt", "to" => "/docs/renamed.txt"}
           ],
           do: :ok
      end,
      10_000
    )

    manifest = Manifest.read(dir)
    assert manifest["docs/hello.txt"] == nil
    assert manifest["docs/renamed.txt"] != nil
  end

  # ── confirm-tick decisions (pairing injected, tick fired by hand) ─────────

  test "double-confirm: file back at the origin path aborts the move", %{
    dir: dir,
    mounter: mounter
  } do
    # editor atomic-save shape: old path removed, same content at a temp
    # path, then renamed BACK to the origin before the tick
    File.rm!(Path.join(dir, "docs/hello.txt"))
    File.write!(Path.join(dir, "docs/hello.txt.tmp"), "hello world\n")
    inject_pairing(mounter, dir, "docs/hello.txt", "docs/hello.txt.tmp")

    File.rename!(Path.join(dir, "docs/hello.txt.tmp"), Path.join(dir, "docs/hello.txt"))
    confirm_move(mounter, "docs/hello.txt")

    wait_until(fn -> if :sys.get_state(mounter).move_pairing == %{}, do: :ok end)

    assert FakeVfs.calls("vfs/move") == []
    assert FakeVfs.calls("vfs/create") == []

    # both legs were re-queued for the ordinary write-back
    assert MapSet.member?(:sys.get_state(mounter).pending, "docs/hello.txt")

    # origin intact on disk and on the server; the temp path is gone
    assert File.read!(Path.join(dir, "docs/hello.txt")) == "hello world\n"
    refute File.exists?(Path.join(dir, "docs/hello.txt.tmp"))

    assert {:ok, %{"content" => "hello world\n", "version" => 1}} =
             FakeVfs.handler().("vfs/read", %{"path" => "/docs/hello.txt"})
  end

  test "gate refusal: caps unknown parks the new path, no rpc" do
    dir = Path.join(System.tmp_dir!(), "mcp-mount-mv-#{System.unique_integer()}")
    name = String.to_atom("mounter_mv_#{System.unique_integer()}")
    mounter = start_mounter(dir, name, [])
    wait_until(fn -> if live?(mounter), do: :ok end)

    assert FakeConn.caps(fake_conn(mounter)) == :unknown

    File.rm!(Path.join(dir, "docs/hello.txt"))
    File.write!(Path.join(dir, "docs/renamed.txt"), "hello world\n")
    inject_pairing(mounter, dir, "docs/hello.txt", "docs/renamed.txt")

    confirm_move(mounter, "docs/hello.txt")

    wait_until(fn -> if parked?(mounter, "docs/renamed.txt"), do: :ok end)

    assert FakeVfs.calls("vfs/move") == []
    assert FakeVfs.calls("vfs/create") == []
    assert :sys.get_state(mounter).move_pairing == %{}

    # the local file stays in place (park keeps the content, copy saved aside)
    assert File.read!(Path.join(dir, "docs/renamed.txt")) == "hello world\n"
    assert conflict_paths(dir, "docs/renamed.txt") != []
    File.rm_rf!(dir)
  end

  test "gate refusal: caps list without move parks the new path, no rpc" do
    dir = Path.join(System.tmp_dir!(), "mcp-mount-mv-#{System.unique_integer()}")
    name = String.to_atom("mounter_mv_#{System.unique_integer()}")
    mounter = start_mounter(dir, name, caps: [])

    wait_until(fn -> if live?(mounter), do: :ok end)

    File.rm!(Path.join(dir, "docs/hello.txt"))
    File.write!(Path.join(dir, "docs/renamed.txt"), "hello world\n")
    inject_pairing(mounter, dir, "docs/hello.txt", "docs/renamed.txt")

    confirm_move(mounter, "docs/hello.txt")

    wait_until(fn -> if parked?(mounter, "docs/renamed.txt"), do: :ok end)

    assert FakeVfs.calls("vfs/move") == []
    assert FakeVfs.calls("vfs/create") == []
    File.rm_rf!(dir)
  end

  test "protocol refusal (-32601) parks the new path, never create-fallback", %{
    dir: dir,
    mounter: mounter
  } do
    File.rm!(Path.join(dir, "docs/hello.txt"))
    File.write!(Path.join(dir, "docs/renamed.txt"), "hello world\n")
    inject_pairing(mounter, dir, "docs/hello.txt", "docs/renamed.txt")

    FakeVfs.fail_next_move({:code, -32601})
    confirm_move(mounter, "docs/hello.txt")

    wait_until(fn -> if parked?(mounter, "docs/renamed.txt"), do: :ok end)

    # exactly one move attempt, then the park — no retry storm, no create
    assert length(FakeVfs.calls("vfs/move")) == 1
    assert FakeVfs.calls("vfs/create") == []
    assert :sys.get_state(mounter).move_pairing == %{}
    assert File.read!(Path.join(dir, "docs/renamed.txt")) == "hello world\n"
  end

  test "move target already on server (:eexist) conflicts the target", %{
    dir: dir,
    mounter: mounter
  } do
    # a server-side create the daemon never saw an event for
    FakeVfs.handler().("vfs/create", %{
      "path" => "/docs/renamed.txt",
      "data" => "server b\n"
    })

    File.rm!(Path.join(dir, "docs/hello.txt"))
    File.write!(Path.join(dir, "docs/renamed.txt"), "hello world\n")
    inject_pairing(mounter, dir, "docs/hello.txt", "docs/renamed.txt")

    confirm_move(mounter, "docs/hello.txt")

    wait_until(
      fn -> if File.read!(Path.join(dir, "docs/renamed.txt")) == "server b\n", do: :ok end,
      8_000
    )

    # the local (rename-source) content was saved aside, server truth won
    assert length(conflict_paths(dir, "docs/renamed.txt")) == 1
    assert File.read!(hd(conflict_paths(dir, "docs/renamed.txt"))) == "hello world\n"
    assert :sys.get_state(mounter).move_pairing == %{}
  end

  test "transport failures retry on the cadence, then park after the cap" do
    dir = Path.join(System.tmp_dir!(), "mcp-mount-mv-#{System.unique_integer()}")
    name = String.to_atom("mounter_mv_#{System.unique_integer()}")

    mounter =
      start_supervised!(
        Supervisor.child_spec(
          {
            Mounter,
            url: "ws://fake/vfs",
            token: "t",
            mount: dir,
            conn_mod: FakeConn,
            conn_opts: [handler: FakeVfs.handler(), caps: ["move"]],
            flush_retry_ms: 100,
            name: name
          },
          id: name
        )
      )

    wait_until(fn -> if live?(mounter), do: :ok end)

    File.rm!(Path.join(dir, "docs/hello.txt"))
    File.write!(Path.join(dir, "docs/renamed.txt"), "hello world\n")
    inject_pairing(mounter, dir, "docs/hello.txt", "docs/renamed.txt")

    FakeVfs.set_move_failure(:eio)
    confirm_move(mounter, "docs/hello.txt")

    wait_until(fn -> if parked?(mounter, "docs/renamed.txt"), do: :ok end, 8_000)

    FakeVfs.set_move_failure(nil)

    # 4 attempts (initial + 3 retries), then the loop is over
    assert length(FakeVfs.calls("vfs/move")) == 4
    assert FakeVfs.calls("vfs/create") == []
    assert :sys.get_state(mounter).move_pairing == %{}
    Process.sleep(300)
    assert length(FakeVfs.calls("vfs/move")) == 4
    File.rm_rf!(dir)
  end

  # ── server-remove save-aside (design §1/D1) ───────────────────────────────

  test "server remove of an unpushed local edit saves a conflict copy", %{
    dir: dir,
    mounter: mounter
  } do
    # keep the local edit unpushed: every write fails, so the manifest hash
    # stays at the synced content while disk holds the edit. The edit is
    # re-written until the push attempt is observed (fsevents wobble);
    # note.md is left strictly untouched so its later remove is clean.
    FakeVfs.set_write_failure(:eio)

    drive_write(dir, "docs/hello.txt", "local edit\n", fn ->
      FakeVfs.calls("vfs/write") != []
    end)

    assert FakeVfs.calls("vfs/write") != []

    FakeConn.inject_event(fake_conn(mounter), %{
      op: "remove",
      path: "/docs/hello.txt",
      version: 1,
      seq: 2,
      by: "test",
      at: 0
    })

    wait_until(fn -> if !File.exists?(Path.join(dir, "docs/hello.txt")), do: :ok end, 8_000)

    copies = conflict_paths(dir, "docs/hello.txt")
    assert length(copies) == 1
    assert File.read!(hd(copies)) == "local edit\n"

    # a remove whose content still matches the manifest deletes plainly:
    # note.md is untouched locally, so no second conflict copy appears
    FakeConn.inject_event(fake_conn(mounter), %{
      op: "remove",
      path: "/docs/note.md",
      version: 1,
      seq: 3,
      by: "test",
      at: 0
    })

    wait_until(fn -> if !File.exists?(Path.join(dir, "docs/note.md")), do: :ok end, 8_000)
    assert conflict_paths(dir, "docs/note.md") == []
    assert length(conflict_paths(dir, "docs/hello.txt")) == 1
    assert Process.alive?(mounter)
  end
end
