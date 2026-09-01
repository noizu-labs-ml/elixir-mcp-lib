defmodule McpMount.MounterFakeTest do
  use ExUnit.Case, async: false

  import McpMount.Support

  alias McpMount.{FakeConn, Manifest, Mounter}

  setup do
    dir = Path.join(System.tmp_dir!(), "mcp-mount-fake-#{System.unique_integer()}")
    name = String.to_atom("mounter_#{System.unique_integer()}")

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
      {"/docs/note.md", %{type: :file, version: 1, content: "# note\n\nseed body\n"}}
    ]
  end

  defp live?(mounter), do: elem(Mounter.state(mounter), 0) == :live

  defp fake_conn(mounter), do: :sys.get_state(mounter).conn

  test "snapshot materializes seed files + manifest", %{dir: dir} do
    assert File.read!(Path.join(dir, "docs/hello.txt")) == "hello world\n"
    assert File.read!(Path.join(dir, "docs/note.md")) == "# note\n\nseed body\n"

    manifest = Manifest.read(dir)
    assert manifest["docs/hello.txt"].version == 1
    assert manifest["docs/hello.txt"].size == byte_size("hello world\n")
  end

  test "remote write event pulls and applies the new content", %{dir: dir, mounter: mounter} do
    McpMount.Test.FakeVfs.write("/docs/hello.txt", "changed remotely\n")

    FakeConn.inject_event(fake_conn(mounter), %{
      op: "write",
      path: "/docs/hello.txt",
      version: 2
    })

    wait_until(fn ->
      if File.read!(Path.join(dir, "docs/hello.txt")) == "changed remotely\n", do: :ok
    end)

    assert Manifest.read(dir)["docs/hello.txt"].version == 2
  end

  test "self-echo suppression: event matching manifest version is skipped", %{
    dir: dir,
    mounter: mounter
  } do
    # local edit not yet pushed; an echo of the version we already have must not clobber it
    File.write!(Path.join(dir, "docs/hello.txt"), "local edit\n")

    FakeConn.inject_event(fake_conn(mounter), %{op: "write", path: "/docs/hello.txt", version: 1})

    Process.sleep(300)
    assert File.read!(Path.join(dir, "docs/hello.txt")) == "local edit\n"
  end

  test "remove event deletes the local file", %{dir: dir, mounter: mounter} do
    FakeConn.inject_event(fake_conn(mounter), %{op: "remove", path: "/docs/note.md", version: 0})

    wait_until(fn ->
      if !File.exists?(Path.join(dir, "docs/note.md")), do: :ok
    end)

    refute Map.has_key?(Manifest.read(dir), "docs/note.md")
  end

  test "local edit is written back to the server", %{dir: dir} do
    write_and_wait_push(dir, "docs/hello.txt", "local edit pushed\n", fn ->
      case McpMount.Test.FakeVfs.handler().("vfs/read", %{"path" => "/docs/hello.txt"}) do
        {:ok, %{"content" => "local edit pushed\n", "version" => v}} when v >= 2 ->
          Manifest.read(dir)["docs/hello.txt"].version >= 2

        _ ->
          false
      end
    end)
  end

  test "conflict: server moved ahead -> local edit saved as .conflict-, server version re-pulled",
       %{dir: dir} do
    # server moves ahead with no event (FakeConn delivers nothing on its own)
    McpMount.Test.FakeVfs.write("/docs/hello.txt", "server wins\n")

    # a local edit trips the 250ms watcher debounce -> conflict handling
    write_and_wait_push(dir, "docs/hello.txt", "my local edit\n", fn ->
      dir
      |> Path.join("docs")
      |> File.ls!()
      |> Enum.any?(&String.contains?(&1, ".conflict-"))
    end)

    conflict =
      dir
      |> Path.join("docs")
      |> File.ls!()
      |> Enum.find(&String.contains?(&1, ".conflict-"))

    # the re-pull of the server version happens right after the rename; the
    # restored file then re-triggers the watcher (echo cycles bump versions)
    wait_until(fn ->
      manifest = Manifest.read(dir)["docs/hello.txt"]

      if File.read!(Path.join(dir, "docs/hello.txt")) == "server wins\n" and
           manifest != nil and manifest.version >= 2 do
        :ok
      end
    end)

    assert File.read!(Path.join([dir, "docs", conflict])) == "my local edit\n"
  end

  test "ro mount never writes back" do
    dir = Path.join(System.tmp_dir!(), "mcp-mount-ro-#{System.unique_integer()}")
    name = String.to_atom("mounter_ro_#{System.unique_integer()}")

    mounter =
      start_supervised!(
        Supervisor.child_spec(
          {
            Mounter,
            url: "ws://fake/vfs",
            token: "t",
            mount: dir,
            ro: true,
            conn_mod: FakeConn,
            conn_opts: [handler: McpMount.Test.FakeVfs.handler()],
            name: name
          },
          id: name
        )
      )

    hello = Path.join(dir, "docs/hello.txt")

    wait_until(fn -> if File.exists?(hello), do: :ok end)
    File.write!(hello, "should not push\n")
    Process.sleep(600)

    {:ok, %{"content" => content}} =
      McpMount.Test.FakeVfs.handler().("vfs/read", %{"path" => "/docs/hello.txt"})

    assert content == "hello world\n"
    File.rm_rf!(dir)
  end

  test "connection drop triggers resync and returns to live", %{dir: dir, mounter: mounter} do
    FakeConn.drop(fake_conn(mounter), :test_drop)

    wait_until(fn -> if live?(mounter), do: :ok end, 10_000)

    assert File.read!(Path.join(dir, "docs/hello.txt")) == "hello world\n"
  end
end
