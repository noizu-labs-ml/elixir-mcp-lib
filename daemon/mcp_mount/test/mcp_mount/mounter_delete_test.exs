defmodule McpMount.MounterDeleteTest do
  # Delete push (VFS-FEATURES-DESIGN §2 + D2, opt-in --deletes): a tracked
  # file removed locally pushes vfs/remove; a page dir removed locally
  # pushes its <dir>/.confirm-delete marker FIRST and only then the remove.
  # Each test pins one rule of the gate/order/recursion/park flow.
  #
  # Harness lessons from the move suite (#64) apply: rm events cannot be
  # re-fired once the path is gone, so the watcher is not in the loop — the
  # filesystem legs are laid by hand, pending is injected for the real
  # flush, and delete_pending/delete_auths state is injected directly for
  # the tick-level decision tests (marker capture is driven with a
  # synthetic :file_event message, not fsevents).
  use ExUnit.Case, async: false

  import McpMount.Support

  alias McpMount.{FakeConn, Manifest, Mounter}
  alias McpMount.Test.FakeVfs

  setup do
    dir = Path.join(System.tmp_dir!(), "mcp-mount-del-#{System.unique_integer()}")
    name = String.to_atom("mounter_del_#{System.unique_integer()}")

    _fake = start_supervised!({FakeVfs, tree()})

    # default server advertises rmdir (post-server-half); the gate tests
    # build their own mounter with caps: [] / no caps
    mounter = start_mounter(dir, name, deletes: true, caps: ["move", "rmdir"])

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
      {"/docs/note.md", %{type: :file, version: 1, content: "# note\n\nseed body\n"}},
      {"/docs/dir", %{type: :dir, version: 1}},
      {"/docs/dir/a.md", %{type: :file, version: 1, content: "a\n"}},
      {"/docs/dir/sub", %{type: :dir, version: 1}},
      {"/docs/dir/sub/b.md", %{type: :file, version: 1, content: "b\n"}}
    ]
  end

  defp start_mounter(dir, name, opts) do
    {deletes, conn_opts} = Keyword.pop(opts, :deletes, false)

    start_supervised!(
      Supervisor.child_spec(
        {
          Mounter,
          url: "ws://fake/vfs",
          token: "t",
          mount: dir,
          deletes: deletes,
          conn_mod: FakeConn,
          conn_opts: [handler: FakeVfs.handler()] ++ conn_opts,
          flush_retry_ms: 100,
          name: name
        },
        id: name
      )
    )
  end

  defp live?(mounter), do: elem(Mounter.state(mounter), 0) == :live
  defp fake_conn(mounter), do: :sys.get_state(mounter).conn

  # ── harness helpers ───────────────────────────────────────────────────────

  # Queue rels for the real flush without depending on watcher delivery.
  defp inject_pending(mounter, rels) do
    :sys.replace_state(mounter, fn st ->
      %{st | pending: MapSet.union(st.pending, MapSet.new(rels)), timer: nil}
    end)

    send(mounter, :flush)
  end

  # White-box: lay the delete state the detection pass would have produced
  # and let the test fire the confirm tick by hand. The tick only consults
  # delete_pending + disk state.
  defp inject_delete(mounter, rel, kind) do
    :sys.replace_state(mounter, fn st ->
      %{st | delete_pending: Map.put(st.delete_pending, rel, %{kind: kind, attempts: 1})}
    end)

    :ok
  end

  defp inject_auth(mounter, dirs) do
    :sys.replace_state(mounter, fn st ->
      %{st | delete_auths: MapSet.union(st.delete_auths, MapSet.new(dirs))}
    end)

    :ok
  end

  defp confirm_delete(mounter, rel), do: send(mounter, {:delete_confirm, rel})

  defp delete_pending(mounter), do: :sys.get_state(mounter).delete_pending
  defp parked_deletes(mounter), do: :sys.get_state(mounter).parked_deletes

  defp parked_delete?(mounter, rel), do: MapSet.member?(parked_deletes(mounter), rel)

  defp pending?(mounter, rel), do: MapSet.member?(:sys.get_state(mounter).pending, rel)

  # Simulate the watcher delivering a marker event (fsevents is not in the
  # loop — same reasoning as the move suite).
  defp deliver_marker_event(mounter, dir, rel) do
    File.write!(Path.join(dir, rel), "")
    send(mounter, {:file_event, nil, {Path.join(dir, rel), [:created]}})
    :ok
  end

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

  # Position of a call in the full wire log (order assertions).
  defp call_index(mounted_calls, method, params) do
    Enum.find_index(mounted_calls, fn {m, p} -> m == method and p == params end)
  end

  # ── flag gate ─────────────────────────────────────────────────────────────

  test "flag off: a local rm is a silent no-op, byte for byte today", %{
    dir: _dir,
    mounter: _mounter
  } do
    dir2 = Path.join(System.tmp_dir!(), "mcp-mount-del-#{System.unique_integer()}")
    name = String.to_atom("mounter_del_#{System.unique_integer()}")
    # reuses the setup FakeVfs (a fresh one per test)
    m2 = start_mounter(dir2, name, deletes: false, caps: ["move", "rmdir"])
    wait_until(fn -> if live?(m2), do: :ok end)

    File.rm!(Path.join(dir2, "docs/hello.txt"))
    inject_pending(m2, ["docs/hello.txt"])

    wait_until(fn -> if MapSet.size(:sys.get_state(m2).pending) == 0, do: :ok end, 8_000)

    assert FakeVfs.calls("vfs/remove") == []
    assert FakeVfs.calls("vfs/write") == []
    # today's ghost-state: the manifest entry survives the silent no-op
    assert Manifest.read(dir2)["docs/hello.txt"] != nil
    File.rm_rf!(dir2)
  end

  # ── file deletes ──────────────────────────────────────────────────────────

  test "deletes on: rm of a tracked file pushes exactly one vfs/remove", %{
    dir: dir,
    mounter: mounter
  } do
    File.rm!(Path.join(dir, "docs/hello.txt"))
    inject_pending(mounter, ["docs/hello.txt"])

    wait_until(fn -> if Manifest.read(dir)["docs/hello.txt"] == nil, do: :ok end, 8_000)

    assert FakeVfs.calls("vfs/remove") == [%{"path" => "/docs/hello.txt"}]
    assert FakeVfs.calls("vfs/create") == []
    assert delete_pending(mounter) == %{}
    assert {:error, :enoent} = FakeVfs.handler().("vfs/read", %{"path" => "/docs/hello.txt"})
  end

  # ── caps gate ─────────────────────────────────────────────────────────────

  test "caps list without rmdir parks the delete, no rpc" do
    dir = Path.join(System.tmp_dir!(), "mcp-mount-del-#{System.unique_integer()}")
    name = String.to_atom("mounter_del_#{System.unique_integer()}")
    mounter = start_mounter(dir, name, deletes: true, caps: [])
    wait_until(fn -> if live?(mounter), do: :ok end)

    File.rm!(Path.join(dir, "docs/hello.txt"))
    inject_pending(mounter, ["docs/hello.txt"])

    wait_until(fn -> if parked_delete?(mounter, "docs/hello.txt"), do: :ok end, 8_000)

    assert FakeVfs.calls("vfs/remove") == []
    assert delete_pending(mounter) == %{}
    File.rm_rf!(dir)
  end

  test "caps unknown (pre-handshake server) parks the delete, no rpc" do
    dir = Path.join(System.tmp_dir!(), "mcp-mount-del-#{System.unique_integer()}")
    name = String.to_atom("mounter_del_#{System.unique_integer()}")
    mounter = start_mounter(dir, name, deletes: true)
    wait_until(fn -> if live?(mounter), do: :ok end)

    assert FakeConn.caps(fake_conn(mounter)) == :unknown

    File.rm!(Path.join(dir, "docs/hello.txt"))
    inject_pending(mounter, ["docs/hello.txt"])

    wait_until(fn -> if parked_delete?(mounter, "docs/hello.txt"), do: :ok end, 8_000)

    assert FakeVfs.calls("vfs/remove") == []
    File.rm_rf!(dir)
  end

  # ── marker protocol (D2): order is binding ────────────────────────────────

  test "dir delete pushes marker write BEFORE remove; marker consumed on :ok", %{
    dir: dir,
    mounter: mounter
  } do
    inject_auth(mounter, ["docs/dir/sub"])

    File.rm!(Path.join(dir, "docs/dir/sub/b.md"))
    File.rmdir!(Path.join(dir, "docs/dir/sub"))
    inject_pending(mounter, ["docs/dir/sub/b.md", "docs/dir/sub"])

    # dirs are not manifest rows — wait for the server-side dir remove
    # itself (the b.md manifest row drops when its own push acks)
    wait_until(
      fn ->
        if call_index(FakeVfs.calls(), "vfs/remove", %{"path" => "/docs/dir/sub"}) != nil,
          do: :ok
      end,
      8_000
    )

    calls = FakeVfs.calls()

    marker_idx =
      Enum.find_index(calls, fn {m, p} ->
        m == "vfs/write" and String.ends_with?(p["path"], "/docs/dir/sub/.confirm-delete")
      end)

    b_idx = call_index(calls, "vfs/remove", %{"path" => "/docs/dir/sub/b.md"})
    dir_idx = call_index(calls, "vfs/remove", %{"path" => "/docs/dir/sub"})

    assert marker_idx != nil and b_idx != nil and dir_idx != nil
    # marker write and child remove both precede the dir remove
    assert marker_idx < dir_idx
    assert b_idx < dir_idx

    # marker content names the deletion target (design leaves the format open)
    {_, params} = Enum.at(calls, marker_idx)
    assert params["path"] == "/docs/dir/sub/.confirm-delete"
    assert params["data"] =~ "/docs/dir/sub"

    # the marker was consumed server-side and never became a page
    assert FakeVfs.markers() == []
    assert FakeVfs.calls("vfs/create") == []
    assert Manifest.read(dir)["docs/dir/sub/.confirm-delete"] == nil
    assert {:error, :enoent} = FakeVfs.handler().("vfs/read", %{"path" => "/docs/dir/sub"})
    assert delete_auths_empty?(mounter)
  end

  defp delete_auths_empty?(mounter), do: MapSet.size(:sys.get_state(mounter).delete_auths) == 0

  # ── childless-only recursion (bottom-up) ──────────────────────────────────

  test "rm -r decomposes bottom-up: children land first, each childless dir gets marker→remove",
       %{
         dir: dir,
         mounter: mounter
       } do
    inject_auth(mounter, ["docs/dir", "docs/dir/sub"])

    File.rm!(Path.join(dir, "docs/dir/a.md"))
    File.rm!(Path.join(dir, "docs/dir/sub/b.md"))
    File.rmdir!(Path.join(dir, "docs/dir/sub"))
    File.rmdir!(Path.join(dir, "docs/dir"))
    inject_pending(mounter, ["docs/dir/a.md", "docs/dir/sub/b.md", "docs/dir/sub", "docs/dir"])

    # dirs are not manifest rows — completion is the parent dir's
    # server-side remove (which implies every child landed first)
    wait_until(
      fn ->
        if call_index(FakeVfs.calls(), "vfs/remove", %{"path" => "/docs/dir"}) != nil, do: :ok
      end,
      8_000
    )

    calls = FakeVfs.calls()

    a_idx = call_index(calls, "vfs/remove", %{"path" => "/docs/dir/a.md"})
    b_idx = call_index(calls, "vfs/remove", %{"path" => "/docs/dir/sub/b.md"})
    sub_idx = call_index(calls, "vfs/remove", %{"path" => "/docs/dir/sub"})
    dir_idx = call_index(calls, "vfs/remove", %{"path" => "/docs/dir"})

    assert a_idx != nil and b_idx != nil and sub_idx != nil and dir_idx != nil
    # both files before the deepest dir, deepest dir before its parent
    assert a_idx < dir_idx and b_idx < sub_idx and sub_idx < dir_idx

    # each dir carried its own marker, written before its remove
    for {dir_rel, idx} <- [{"docs/dir/sub", sub_idx}, {"docs/dir", dir_idx}] do
      marker_idx =
        Enum.find_index(calls, fn {m, p} ->
          m == "vfs/write" and String.ends_with?(p["path"], "/#{dir_rel}/.confirm-delete")
        end)

      assert marker_idx != nil and marker_idx < idx
    end

    # the whole subtree is gone server-side, markers consumed
    assert FakeVfs.markers() == []
    assert {:error, :enoent} = FakeVfs.handler().("vfs/read", %{"path" => "/docs/dir/a.md"})
    assert {:error, :enoent} = FakeVfs.handler().("vfs/read", %{"path" => "/docs/dir"})
  end

  # ── atomic-save double-confirm ────────────────────────────────────────────

  test "path back at the tick aborts the delete (atomic-save race)", %{
    dir: dir,
    mounter: mounter
  } do
    inject_delete(mounter, "docs/hello.txt", :file)

    # editor atomic-save: the path is back before the tick fires
    File.write!(Path.join(dir, "docs/hello.txt"), "hello world\n")
    confirm_delete(mounter, "docs/hello.txt")

    wait_until(fn -> if delete_pending(mounter) == %{}, do: :ok end)

    assert FakeVfs.calls("vfs/remove") == []
    # the path re-entered the ordinary write-back
    assert pending?(mounter, "docs/hello.txt")
    assert File.read!(Path.join(dir, "docs/hello.txt")) == "hello world\n"

    assert {:ok, %{"content" => "hello world\n"}} =
             FakeVfs.handler().("vfs/read", %{"path" => "/docs/hello.txt"})
  end

  # ── save-aside composition + :enoent success ──────────────────────────────

  test "server remove saves an unpushed edit aside; the follow-up delete is :enoent-clean", %{
    dir: dir,
    mounter: mounter
  } do
    # unpushed local edit (every write fails), then the server removes the page
    FakeVfs.set_write_failure(:eio)

    # the watcher is not in the loop — queue the edit for the real flush
    File.write!(Path.join(dir, "docs/hello.txt"), "local edit\n")
    inject_pending(mounter, ["docs/hello.txt"])

    wait_until(fn -> if FakeVfs.calls("vfs/write") != [], do: :ok end, 8_000)

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

    FakeVfs.set_write_failure(nil)

    # the delete intent (queued before the server event won the race) still
    # resolves: the server is already gone, :enoent counts as success
    inject_delete(mounter, "docs/hello.txt", :file)
    confirm_delete(mounter, "docs/hello.txt")

    wait_until(fn -> if delete_pending(mounter) == %{}, do: :ok end)

    assert FakeVfs.calls("vfs/remove") == [%{"path" => "/docs/hello.txt"}]
    assert parked_deletes(mounter) == MapSet.new()
    # the save-aside copy survived the delete round-trip
    assert length(conflict_paths(dir, "docs/hello.txt")) == 1
    assert Process.alive?(mounter)
  end

  # ── errno mapping ─────────────────────────────────────────────────────────

  for {errno, why} <- [
        {:eperm, "marker missing/stale"},
        {:eacces, "flags off"},
        {:enotempty, "children remain"},
        {{:code, -32601}, "method_not_found"}
      ] do
    @tag errno_tag: errno
    test "refusal #{why} parks the delete after one attempt, no retry-spam", %{
      dir: dir,
      mounter: mounter
    } do
      # the local leg of the gesture: the file must actually be gone, or the
      # tick sees the path back and aborts instead of reaching the wire
      File.rm!(Path.join(dir, "docs/hello.txt"))
      FakeVfs.fail_next_remove(unquote(errno))
      inject_delete(mounter, "docs/hello.txt", :file)
      confirm_delete(mounter, "docs/hello.txt")

      wait_until(fn -> if parked_delete?(mounter, "docs/hello.txt"), do: :ok end, 8_000)

      assert length(FakeVfs.calls("vfs/remove")) == 1
      assert delete_pending(mounter) == %{}
      # parked means quiet: no retry churn
      Process.sleep(300)
      assert length(FakeVfs.calls("vfs/remove")) == 1
    end
  end

  test "unknown error (:eio) retries on the cadence, then parks after the cap", %{
    dir: dir,
    mounter: mounter
  } do
    File.rm!(Path.join(dir, "docs/hello.txt"))
    FakeVfs.set_remove_failure(:eio)
    inject_delete(mounter, "docs/hello.txt", :file)
    confirm_delete(mounter, "docs/hello.txt")

    wait_until(fn -> if parked_delete?(mounter, "docs/hello.txt"), do: :ok end, 8_000)

    FakeVfs.set_remove_failure(nil)

    # 4 attempts (initial + 3 retries), then the loop is over
    assert length(FakeVfs.calls("vfs/remove")) == 4
    Process.sleep(300)
    assert length(FakeVfs.calls("vfs/remove")) == 4
    assert delete_pending(mounter) == %{}
  end

  # ── reconnect re-arm ──────────────────────────────────────────────────────

  test "delete armed before a drop re-arms and completes after reconnect", %{
    dir: dir,
    mounter: mounter
  } do
    File.rm!(Path.join(dir, "docs/hello.txt"))
    inject_delete(mounter, "docs/hello.txt", :file)

    FakeConn.drop(fake_conn(mounter), :test_drop)
    wait_until(fn -> if live?(mounter), do: :ok end, 10_000)

    # go_live re-arms the confirm tick; the resync skipped the still-
    # version-matched (now missing) file, so the tick fires the remove
    wait_until(
      fn ->
        if FakeVfs.calls("vfs/remove") == [%{"path" => "/docs/hello.txt"}], do: :ok
      end,
      10_000
    )

    assert Manifest.read(dir)["docs/hello.txt"] == nil
  end

  test "parked delete re-queues after reconnect and re-attempts once", %{
    dir: dir,
    mounter: mounter
  } do
    FakeVfs.fail_next_remove(:eperm)
    File.rm!(Path.join(dir, "docs/hello.txt"))
    inject_delete(mounter, "docs/hello.txt", :file)
    confirm_delete(mounter, "docs/hello.txt")
    wait_until(fn -> if parked_delete?(mounter, "docs/hello.txt"), do: :ok end, 8_000)

    FakeConn.drop(fake_conn(mounter), :test_drop)
    wait_until(fn -> if live?(mounter), do: :ok end, 10_000)

    # the park lifted at go_live; the fresh attempt lands (the one-shot
    # refusal was already consumed) — one clean push per connection
    wait_until(fn -> if length(FakeVfs.calls("vfs/remove")) == 2, do: :ok end, 10_000)

    refute parked_delete?(mounter, "docs/hello.txt")
    assert delete_pending(mounter) == %{}
    assert Manifest.read(dir)["docs/hello.txt"] == nil
  end

  # ── marker lifecycle ──────────────────────────────────────────────────────

  test "marker capture authorizes the dir; re-authoring a parked delete re-arms it", %{
    dir: dir,
    mounter: mounter
  } do
    # author the marker, watcher delivers the event, capture records the auth
    deliver_marker_event(mounter, dir, "docs/dir/sub/.confirm-delete")

    wait_until(fn ->
      if MapSet.member?(:sys.get_state(mounter).delete_auths, "docs/dir/sub"), do: :ok
    end)

    # the marker itself was never queued as content
    refute pending?(mounter, "docs/dir/sub/.confirm-delete")

    # Round 1 — the child file first, clean: its remove lands and its
    # manifest row drops. (Doing both in one flush would race the one-shot
    # refusal onto whichever remove fires first.)
    File.rm!(Path.join(dir, "docs/dir/sub/b.md"))
    File.rm!(Path.join(dir, "docs/dir/sub/.confirm-delete"))
    File.rmdir!(Path.join(dir, "docs/dir/sub"))
    inject_pending(mounter, ["docs/dir/sub/b.md"])

    wait_until(
      fn ->
        if FakeVfs.calls("vfs/remove") == [%{"path" => "/docs/dir/sub/b.md"}], do: :ok
      end,
      8_000
    )

    # Round 2 — rm the dir and refuse ITS remove once (marker stale
    # server-side): the dir delete parks after marker-write + refused remove
    FakeVfs.fail_next_remove(:eperm)
    inject_pending(mounter, ["docs/dir/sub"])

    wait_until(fn -> if parked_delete?(mounter, "docs/dir/sub"), do: :ok end, 8_000)

    assert length(FakeVfs.calls("vfs/remove")) == 2
    assert FakeVfs.markers() == ["/docs/dir/sub/.confirm-delete"]

    # Round 3 — re-author the marker at the same path: the park lifts and the
    # delete re-queues (design §2.3 — "creating the marker and re-flushing
    # retries"); this time the server accepts
    File.mkdir_p!(Path.join(dir, "docs/dir/sub"))
    deliver_marker_event(mounter, dir, "docs/dir/sub/.confirm-delete")

    wait_until(fn -> if pending?(mounter, "docs/dir/sub"), do: :ok end, 8_000)

    File.rm!(Path.join(dir, "docs/dir/sub/.confirm-delete"))
    File.rmdir!(Path.join(dir, "docs/dir/sub"))
    inject_pending(mounter, ["docs/dir/sub"])

    wait_until(
      fn ->
        # calls/1 is newest-first; the newest remove must be the dir's
        calls = FakeVfs.calls("vfs/remove")

        if length(calls) == 3 and hd(calls) == %{"path" => "/docs/dir/sub"}, do: :ok
      end,
      8_000
    )

    assert FakeVfs.markers() == []
    assert parked_deletes(mounter) == MapSet.new()
    refute parked_delete?(mounter, "docs/dir/sub/b.md")
  end

  test "self-echo no-loop: marker events and the dir remove event never pull or resurrect", %{
    dir: dir,
    mounter: mounter
  } do
    manifest_before = Manifest.read(dir)

    FakeConn.inject_event(fake_conn(mounter), %{
      op: "write",
      path: "/docs/dir/sub/.confirm-delete",
      version: 2,
      seq: 2,
      by: "test",
      at: 0
    })

    FakeConn.inject_event(fake_conn(mounter), %{
      op: "remove",
      path: "/docs/dir/sub/.confirm-delete",
      version: 2,
      seq: 3,
      by: "test",
      at: 0
    })

    FakeConn.inject_event(fake_conn(mounter), %{
      op: "remove",
      path: "/docs/dir/sub",
      version: 2,
      seq: 4,
      by: "test",
      at: 0
    })

    Process.sleep(400)

    # no pull of the marker (would mkdir the deleted dir back), no resurrection
    refute Enum.any?(FakeVfs.calls("vfs/read"), fn p ->
             String.contains?(p["path"], ".confirm-delete")
           end)

    refute File.exists?(Path.join(dir, "docs/dir/sub/.confirm-delete"))
    assert Manifest.read(dir) == manifest_before
    assert delete_pending(mounter) == %{}
    assert MapSet.size(:sys.get_state(mounter).pending) == 0
    assert Process.alive?(mounter)
  end

  test "flag off: a locally authored marker never pushes as a page" do
    dir = Path.join(System.tmp_dir!(), "mcp-mount-del-#{System.unique_integer()}")
    name = String.to_atom("mounter_del_#{System.unique_integer()}")
    mounter = start_mounter(dir, name, deletes: false, caps: ["move", "rmdir"])
    wait_until(fn -> if live?(mounter), do: :ok end)

    File.write!(Path.join(dir, "docs/dir/sub/.confirm-delete"), "")

    send(
      mounter,
      {:file_event, nil, {Path.join(dir, "docs/dir/sub/.confirm-delete"), [:created]}}
    )

    inject_pending(mounter, ["docs/dir/sub/.confirm-delete"])

    Process.sleep(400)

    assert FakeVfs.calls("vfs/write") == []
    assert FakeVfs.calls("vfs/create") == []
    File.rm_rf!(dir)
  end

  # ── space dirs are never deletable ────────────────────────────────────────

  test "space-dir delete is refused even with a marker", %{dir: dir, mounter: mounter} do
    inject_auth(mounter, ["docs"])

    File.rm!(Path.join(dir, "docs/hello.txt"))
    File.rm!(Path.join(dir, "docs/note.md"))
    File.rm!(Path.join(dir, "docs/dir/a.md"))
    File.rm!(Path.join(dir, "docs/dir/sub/b.md"))
    File.rmdir!(Path.join(dir, "docs/dir/sub"))
    File.rmdir!(Path.join(dir, "docs/dir"))
    File.rmdir!(Path.join(dir, "docs"))
    inject_pending(mounter, ["docs"])

    wait_until(fn -> if MapSet.size(:sys.get_state(mounter).pending) == 0, do: :ok end, 8_000)

    assert FakeVfs.calls("vfs/remove") == []
    assert FakeVfs.calls("vfs/write") == []
  end

  # ── robot review, head 80b7506 ────────────────────────────────────────────

  test "server materialization under an authorized dir drops the stale grant",
       %{dir: dir, mounter: mounter} do
    # gesture 1: marker event authorizes docs/dir
    deliver_marker_event(mounter, dir, "docs/dir/.confirm-delete")

    wait_until(fn ->
      if MapSet.member?(:sys.get_state(mounter).delete_auths, "docs/dir"), do: :ok
    end)

    # the dir comes back from the server (another client bumped a child):
    # an inbound create/write event materializes it — the grant must die
    send(mounter, {:mcp_mount_event, %{op: "write", path: "/docs/dir/a.md", version: 9}})

    # the resurrected dir later rm -r'd WITHOUT a fresh gesture: no auth,
    # no marker write, no remove — the dir simply does not delete. (700ms:
    # a leaked grant's confirm tick fires at 500ms and would show up as a
    # marker vfs/write here.)
    File.rm_rf!(Path.join(dir, "docs/dir"))
    inject_pending(mounter, ["docs/dir"])

    Process.sleep(700)

    assert FakeVfs.calls("vfs/remove") == []
    assert FakeVfs.calls("vfs/write") == []
  end

  test "duplicate confirm ticks converge to a park without crashing",
       %{dir: dir, mounter: mounter} do
    FakeVfs.set_remove_failure(:eio)

    File.rm!(Path.join(dir, "docs/hello.txt"))
    inject_delete(mounter, "docs/hello.txt", :file)
    confirm_delete(mounter, "docs/hello.txt")
    confirm_delete(mounter, "docs/hello.txt")

    wait_until(fn -> if parked_delete?(mounter, "docs/hello.txt"), do: :ok end, 8_000)
    assert Process.alive?(mounter)

    FakeVfs.set_remove_failure(nil)
  end

  test "parent park names the parked child deletes", %{dir: dir, mounter: mounter} do
    import ExUnit.CaptureLog

    # child b.md parks first: fs leg laid (a tick aborts on an existing
    # path), one refusal errno — a single tick, no retry churn
    FakeVfs.fail_next_remove(:eperm)
    File.rm!(Path.join(dir, "docs/dir/sub/b.md"))
    inject_delete(mounter, "docs/dir/sub/b.md", :file)
    confirm_delete(mounter, "docs/dir/sub/b.md")

    wait_until(fn -> if parked_delete?(mounter, "docs/dir/sub/b.md"), do: :ok end)

    # parent dir (same white-box injection; the local dir must be gone or
    # the tick aborts): b.md's manifest row survives its parked delete, so
    # the parent waits out its budget, then parks naming the parked child
    File.rm_rf!(Path.join(dir, "docs/dir"))
    inject_delete(mounter, "docs/dir/sub", :dir)
    confirm_delete(mounter, "docs/dir/sub")

    log =
      capture_log(fn ->
        wait_until(fn -> if parked_delete?(mounter, "docs/dir/sub"), do: :ok end, 8_000)
      end)

    assert log =~ "parked child deletes: docs/dir/sub/b.md"
  end
end
