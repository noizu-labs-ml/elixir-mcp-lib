defmodule Noizu.MCP.Transport.VFSSocketTest do
  use ExUnit.Case, async: false

  alias Noizu.MCP.Transport.VFSClient
  alias Noizu.MCP.VFS.Cache
  alias Noizu.MCP.VFS.Fixture.Memory

  @key "vfs-test-key"
  @bad_key "vfs-wrong-key"
  @size_limit 16 * 1024 * 1024 + 1

  defmodule MemoryServer do
    use Noizu.MCP.Server, name: "vfs-socket-memory", version: "1.0.0"
    vfs(Noizu.MCP.VFS.Fixture.Memory)
  end

  defmodule NullServer do
    use Noizu.MCP.Server, name: "vfs-socket-null", version: "1.0.0"
    vfs(Noizu.MCP.VFS.Null)
  end

  defp socket_path(name), do: Path.join(System.tmp_dir(), "mcp-vfs-test-#{name}.sock")

  defp auth_opts do
    verifier_opts = [
      keys: [{@key, %{"sub" => "vfs-tester"}}],
      default_claims: %{"scope" => "mcp"}
    ]

    [auth: [verifier: {Noizu.MCP.Auth.ApiKeyVerifier, verifier_opts}]]
  end

  defp start_server(module, path, context) do
    File.rm(path)

    spec =
      Supervisor.child_spec(
        {module,
         transport:
           {:vfs_socket, [socket_path: path, acceptors: 2, context: context] ++ auth_opts()}},
        restart: :temporary
      )

    start_supervised!(spec)
    wait_for_socket(path)
    path
  end

  defp wait_for_socket(path) do
    unless File.exists?(path), do: wait_for_socket(path)
  end

  defp connect!(path) do
    {:ok, client} = VFSClient.connect(path)
    on_exit(fn -> VFSClient.close(client) end)
    client
  end

  defp authed!(path) do
    client = connect!(path)

    assert {:ok, %{"authenticated" => true, "session_id" => sid}} =
             VFSClient.auth(client, @key)

    assert is_binary(sid) and sid != ""
    client
  end

  # Standard fixture tree plus 60 extra files so list/search pagination
  # (page size 50) spans multiple pages.
  defp big_tree_spec do
    extra =
      Map.new(1..60, fn i ->
        {"/page-#{String.pad_leading(Integer.to_string(i), 3, "0")}.txt", "tick #{i}\n"}
      end)

    Map.merge(
      %{
        "/" => :dir,
        "/hello.txt" => "hello world\n",
        "/docs" => :dir,
        "/docs/a.md" => "# alpha\nbeta gamma\n",
        "/docs/b.md" => "delta\n"
      },
      extra
    )
  end

  setup do
    tree = Memory.seed(big_tree_spec()).assigns.tree
    tree_ctx = fn _claims -> %{tree: tree} end

    memory = start_server(MemoryServer, socket_path("memory"), tree_ctx)
    null = start_server(NullServer, socket_path("null"), fn _claims -> %{} end)

    on_exit(fn ->
      Cache.purge(Memory)
      File.rm(socket_path("memory"))
      File.rm(socket_path("null"))
    end)

    %{memory: memory, null: null}
  end

  # ── handshake ─────────────────────────────────────────────────────────────

  test "auth success binds the session", %{memory: path} do
    authed!(path)
  end

  test "auth failure returns -32001 and closes the connection", %{memory: path} do
    client = connect!(path)

    assert {:error, %{"code" => -32001, "message" => message}} =
             VFSClient.auth(client, @bad_key)

    assert message =~ "auth"
    assert {:error, :closed} = VFSClient.request(client, "vfs/stat", %{"path" => "/"})
  end

  test "ops before auth are refused with -32001 and close", %{memory: path} do
    client = connect!(path)

    assert {:error, %{"code" => -32001}} =
             VFSClient.request(client, "vfs/stat", %{"path" => "/"})

    assert {:error, :closed} = VFSClient.request(client, "vfs/stat", %{"path" => "/"})
  end

  test "missing api_key is a failed handshake", %{memory: path} do
    client = connect!(path)
    assert {:error, %{"code" => -32001}} = VFSClient.request(client, "vfs/auth", %{})
    assert {:error, :closed} = VFSClient.request(client, "vfs/stat", %{"path" => "/"})
  end

  test "second vfs/auth after success is invalid_request", %{memory: path} do
    client = authed!(path)

    assert {:error, %{"code" => -32600}} =
             VFSClient.request(client, "vfs/auth", %{"api_key" => @key})

    assert {:ok, _} = VFSClient.stat(client, "/hello.txt")
  end

  # ── ops ───────────────────────────────────────────────────────────────────

  test "vfs_stat returns a string-keyed node", %{memory: path} do
    client = authed!(path)

    assert {:ok, %{"type" => "file", "size" => 12, "writable" => true, "xattrs" => %{}}} =
             VFSClient.stat(client, "/hello.txt")

    assert {:ok, %{"type" => "dir"}} = VFSClient.stat(client, "/")
  end

  test "vfs_stat miss: -32002 with errno_atom enoent", %{memory: path} do
    client = authed!(path)

    assert {:error, %{"code" => -32002, "data" => %{"errno_atom" => "enoent"}}} =
             VFSClient.stat(client, "/nope")
  end

  test "vfs_list returns string-keyed entries", %{memory: path} do
    client = authed!(path)

    assert {:ok, %{"entries" => entries}} = VFSClient.list(client, "/")

    assert %{"name" => "hello.txt", "type" => "file", "size" => 12} =
             Enum.find(entries, &(&1["name"] == "hello.txt"))
  end

  test "vfs_list on a file: -32044 enotdir", %{memory: path} do
    client = authed!(path)

    assert {:error, %{"code" => -32044, "data" => %{"errno_atom" => "enotdir"}}} =
             VFSClient.list(client, "/hello.txt")
  end

  test "vfs_read returns content and version; vfs_write updates it", %{memory: path} do
    client = authed!(path)

    assert {:ok, %{"content" => "hello world\n", "version" => v1}} =
             VFSClient.read(client, "/hello.txt")

    assert {:ok, %{"version" => v2, "size" => 4}} = VFSClient.write(client, "/hello.txt", "new\n")
    assert v2 > v1

    assert {:ok, %{"content" => "new\n", "version" => ^v2}} = VFSClient.read(client, "/hello.txt")
  end

  test "vfs_read on a dir: -32043 eisdir", %{memory: path} do
    client = authed!(path)

    assert {:error, %{"code" => -32043, "data" => %{"errno_atom" => "eisdir"}}} =
             VFSClient.read(client, "/")
  end

  test "vfs_create makes files and dirs; re-create is -32041 eexist", %{memory: path} do
    client = authed!(path)

    assert {:ok, %{"type" => "file"}} = VFSClient.create(client, "/made.txt", "data")
    assert {:ok, %{"type" => "dir"}} = VFSClient.create(client, "/made-dir")

    assert {:error, %{"code" => -32041, "data" => %{"errno_atom" => "eexist"}}} =
             VFSClient.create(client, "/made.txt", "again")
  end

  test "vfs_remove deletes empty paths; enotempty and eacces errors", %{memory: path} do
    client = authed!(path)

    assert {:ok, %{"removed" => "/docs/b.md"}} = VFSClient.remove(client, "/docs/b.md")

    assert {:error, %{"code" => -32045, "data" => %{"errno_atom" => "enotempty"}}} =
             VFSClient.remove(client, "/docs")

    assert {:error, %{"code" => -32040, "data" => %{"errno_atom" => "eacces"}}} =
             VFSClient.remove(client, "/")
  end

  test "vfs_search returns string-keyed matches", %{memory: path} do
    client = authed!(path)

    assert {:ok, %{"matches" => [%{"path" => "/docs/a.md", "line" => 1, "text" => "# alpha"}]}} =
             VFSClient.search(client, "alpha")
  end

  test "vfs_xattr returns the attribute map", %{memory: path} do
    client = authed!(path)
    assert {:ok, %{}} = VFSClient.xattr(client, "/hello.txt")
  end

  test "read-only backend refuses writes with -32046 enosys", %{null: path} do
    client = authed!(path)

    assert {:error, %{"code" => -32046, "data" => %{"errno_atom" => "enosys"}}} =
             VFSClient.write(client, "/x", "y")
  end

  test "unknown method is -32601 and the connection survives", %{memory: path} do
    client = authed!(path)

    assert {:error, %{"code" => -32601}} = VFSClient.request(client, "vfs/chmod", %{})

    assert {:ok, _} = VFSClient.stat(client, "/hello.txt")
  end

  test "invalid params surface as -32602", %{memory: path} do
    client = authed!(path)
    assert {:error, %{"code" => -32602}} = VFSClient.request(client, "vfs/stat", %{})
  end

  # ── pagination ────────────────────────────────────────────────────────────

  test "list pagination cursor round-trips to cover every entry", %{memory: path} do
    client = authed!(path)

    names =
      stream_pages(client, "name", fn cursor ->
        case cursor do
          nil -> VFSClient.list(client, "/")
          cursor -> VFSClient.list(client, "/", cursor: cursor)
        end
      end)

    assert "hello.txt" in names
    assert length(names) == length(Enum.uniq(names))
    assert length(names) > 50
  end

  test "search pagination cursor round-trips", %{memory: path} do
    client = authed!(path)

    paths =
      stream_pages(client, "path", fn cursor ->
        case cursor do
          nil -> VFSClient.search(client, "tick")
          cursor -> VFSClient.search(client, "tick", cursor: cursor)
        end
      end)

    assert length(paths) == 60
    assert length(paths) == length(Enum.uniq(paths))
  end

  defp stream_pages(client, item_key, call, cursor \\ nil, acc \\ []) do
    assert {:ok, page} = call.(cursor)
    items = page["entries"] || page["matches"]
    acc = acc ++ Enum.map(items, & &1[item_key])

    case page do
      %{"nextCursor" => next} when is_binary(next) ->
        stream_pages(client, item_key, call, next, acc)

      _ ->
        acc
    end
  end

  # ── framing / lifecycle ───────────────────────────────────────────────────

  test "malformed frames get protocol errors without closing the connection", %{memory: path} do
    client = authed!(path)

    :gen_tcp.send(client.socket, Jason.encode!(%{"nope" => true}))

    assert {:ok, %{"type" => "file"}} = VFSClient.stat(client, "/hello.txt")
  end

  test "a frame header beyond the size limit does not kill the transport", %{memory: path} do
    client = authed!(path)
    :gen_tcp.send(client.socket, <<@size_limit::size(32), "x">>)

    # The socket-level guard degrades this stream (the connection closes or
    # the garbage is answered with a parse error); either way the transport
    # itself must stay up and serve fresh connections.
    case VFSClient.stat(client, "/hello.txt") do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end

    fresh = authed!(path)
    assert {:ok, %{"type" => "file"}} = VFSClient.stat(fresh, "/hello.txt")
  end

  test "connection close cleans up without disturbing other clients", %{memory: path} do
    client_a = authed!(path)
    client_b = authed!(path)

    assert {:ok, _} = VFSClient.stat(client_a, "/hello.txt")
    VFSClient.close(client_a)
    Process.sleep(20)

    assert {:ok, _} = VFSClient.stat(client_b, "/hello.txt")
  end

  test "concurrent connections each run under their own ctx", %{memory: path} do
    clients = for _ <- 1..4, do: authed!(path)

    results =
      clients
      |> Enum.map(fn client ->
        Task.async(fn ->
          Enum.each(1..5, fn i ->
            assert {:ok, _} = VFSClient.write(client, "/hello.txt", "gen-#{i}\n")
          end)

          {:ok, %{"content" => content}} = VFSClient.read(client, "/hello.txt")
          content
        end)
      end)
      |> Task.await_many()

    assert Enum.all?(results, &String.contains?(&1, "gen-"))
  end

  test "socket file is mode 0600 and removed on shutdown", %{memory: path} do
    assert %File.Stat{mode: mode} = File.stat!(path)
    assert :erlang.band(mode, 0o777) == 0o600

    assert :ok = stop_supervised!(MemoryServer)
    refute File.exists?(path)
  end

  test "stale socket file is unlinked at startup", %{memory: path} do
    assert :ok = stop_supervised!(MemoryServer)
    File.touch!(path)

    tree = Memory.seed(big_tree_spec()).assigns.tree
    start_server(MemoryServer, path, fn _claims -> %{tree: tree} end)

    client = authed!(path)
    assert {:ok, _} = VFSClient.stat(client, "/hello.txt")
  end
end
