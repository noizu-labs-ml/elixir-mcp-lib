defmodule McpMount.IntegrationWSTest do
  use ExUnit.Case, async: false

  import McpMount.Support

  alias McpMount.{Manifest, Mounter}

  @token "test-token"

  setup do
    dir = Path.join(System.tmp_dir!(), "mcp-mount-ws-#{System.unique_integer()}")
    name = String.to_atom("mounter_ws_#{System.unique_integer()}")

    _server = start_supervised!(McpMount.Test.VfsServer)
    url = "ws://127.0.0.1:#{McpMount.Test.VfsServer.port()}/vfs"

    mounter =
      start_supervised!(
        {Mounter, url: url, token: @token, mount: dir, conn_mod: McpMount.WSConn, name: name}
      )

    wait_until(fn -> if elem(Mounter.state(mounter), 0) == :live, do: :ok end, 10_000)

    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir, mounter: mounter, server: McpMount.Test.VfsServer}
  end

  test "end-to-end: snapshot matches seed", %{dir: dir} do
    assert File.read!(Path.join(dir, "docs/hello.txt")) == "hello world\n"
    assert File.read!(Path.join(dir, "docs/note.md")) == "# note\n\nseed body\n"
    assert Manifest.read(dir)["docs/hello.txt"].version == 1
  end

  test "remote mutate updates the mounted file", %{dir: dir} do
    McpMount.Test.VfsServer.mutate("/docs/hello.txt", :write, "changed over the wire\n")

    wait_until(fn ->
      if File.read!(Path.join(dir, "docs/hello.txt")) == "changed over the wire\n", do: :ok
    end)

    assert Manifest.read(dir)["docs/hello.txt"].version == 2
  end

  test "local edit bumps the server version", %{dir: dir} do
    write_and_wait_push(dir, "docs/hello.txt", "pushed from mount\n", fn ->
      case server_read("/docs/hello.txt") do
        {:ok, %{"content" => "pushed from mount\n", "version" => v}} -> v >= 2
        _ -> false
      end
    end)
  end

  test "kill conn -> reconnect + resync picks up changes made while down", %{
    dir: dir,
    mounter: mounter
  } do
    conn = :sys.get_state(mounter).conn
    Process.exit(conn, :kill)

    # while the mounter is backing off, the server moves ahead
    McpMount.Test.VfsServer.mutate("/docs/note.md", :write, "written during outage\n")

    wait_until(
      fn ->
        if elem(Mounter.state(mounter), 0) == :live and
             File.read!(Path.join(dir, "docs/note.md")) == "written during outage\n",
           do: :ok
      end,
      15_000
    )

    assert Manifest.read(dir)["docs/note.md"].version == 2
  end

  defp server_read(path) do
    handler_result =
      case :sys.get_state(Process.whereis(McpMount.Test.VfsServer.Store)) do
        %{nodes: nodes} ->
          case nodes[path] do
            %{content: c, version: v} -> {:ok, %{"content" => c, "version" => v}}
          end
      end

    handler_result
  end
end
