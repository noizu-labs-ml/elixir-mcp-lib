defmodule Noizu.MCP.VFSServerE2ETest do
  @moduledoc """
  End-to-end VFS server test: a real `Noizu.MCP.Server` with a registered VFS
  backend, exercised over the wire from real clients —
  `Noizu.MCP.Transport.VFSClient` against the `VFSSocket` unix-socket
  transport and a Mint WebSocket client against the `VFSWS` Bandit plug —
  including the cross-connection pubsub loop (subscribe on one connection,
  write from a second, event delivered over the first's socket).

  Complements (does not replace) the per-feature suites: `vfs_socket_test`
  owns socket framing/lifecycle, `vfs_ws_test` owns WS framing/subscription
  mechanics against the `Fixture.Memory` backend; here a versioned, mutable
  ETS backend drives the full read/write loop.
  """

  use ExUnit.Case, async: false

  alias Noizu.MCP.Server.VFSPubSub
  alias Noizu.MCP.Transport.VFSClient
  alias Noizu.MCP.VFS.Cache

  @key "vfs-e2e-key"
  @bad_key "vfs-e2e-wrong-key"
  @event_timeout 1000

  # ── fixtures: shared mutable tree ─────────────────────────────────────────

  defmodule Tree do
    @moduledoc false
    # A unique named ETS table per test; the name travels via
    # :persistent_term so transport handler processes (other pids) and the
    # read-only twin backend can all reach the same tree.

    def seed(spec) do
      name = :"vfs_e2e_tree_#{System.unique_integer([:positive])}"
      :persistent_term.put({__MODULE__, :table}, name)
      table = :ets.new(name, [:set, :public, :named_table, read_concurrency: true])
      now = System.system_time(:millisecond)

      Enum.each(spec, fn
        {path, :dir} ->
          :ets.insert(
            table,
            {path, %{type: :dir, content: nil, version: 1, mtime: now, locked: false}}
          )

        {path, {:file, content, locked?}} ->
          :ets.insert(
            table,
            {path, %{type: :file, content: content, version: 1, mtime: now, locked: locked?}}
          )
      end)

      table
    end

    def table, do: :persistent_term.get({__MODULE__, :table})
  end

  # ── fixtures: backends ────────────────────────────────────────────────────

  defmodule Backend do
    @moduledoc false
    # Versioned, writable ETS backend over the shared Tree. Locking a node
    # denies its content ops (:eacces) while stat/list keep working — the
    # read-side of a permission bit.
    use Noizu.MCP.VFS

    alias Noizu.MCP.VFS

    @impl true
    def stat(path, _ctx) do
      case lookup(path) do
        {:ok, node} -> {:ok, to_node(node)}
        :error -> {:error, :enoent}
      end
    end

    @impl true
    def list(path, _cursor, _ctx) do
      case lookup(path) do
        :error ->
          {:error, :enoent}

        {:ok, %{type: :file}} ->
          {:error, :enotdir}

        {:ok, _dir} ->
          children =
            table()
            |> :ets.tab2list()
            |> Enum.filter(fn {child, _node} -> Path.dirname(child) == path end)
            |> Enum.sort()
            |> Enum.map(fn {child, node} ->
              %{
                name: Path.basename(child),
                type: node.type,
                size: size_of(node),
                mtime: node.mtime,
                version: node.version
              }
            end)

          {:ok, children, nil}
      end
    end

    @impl true
    def read(path, _ctx) do
      case lookup(path) do
        :error -> {:error, :enoent}
        {:ok, %{type: :dir}} -> {:error, :eisdir}
        {:ok, %{locked: true}} -> {:error, :eacces}
        {:ok, node} -> {:ok, node.content, node.version}
      end
    end

    @impl true
    def write(path, data, _ctx) do
      case lookup(path) do
        :error ->
          {:error, :enoent}

        {:ok, %{type: :dir}} ->
          {:error, :eisdir}

        {:ok, %{locked: true}} ->
          {:error, :eacces}

        {:ok, node} ->
          node = %{node | content: data, version: node.version + 1, mtime: now()}
          :ets.insert(table(), {path, node})
          {:ok, to_node(node)}
      end
    end

    @impl true
    def create(path, data, _ctx) do
      case lookup(path) do
        {:ok, _} ->
          {:error, :eexist}

        :error ->
          case lookup(Path.dirname(path)) do
            {:ok, %{type: :dir}} ->
              node =
                case data do
                  :dir -> %{type: :dir, content: nil, version: 1, mtime: now(), locked: false}
                  content when is_binary(content) -> new_node(content)
                end

              :ets.insert(table(), {path, node})
              {:ok, to_node(node)}

            {:ok, %{type: :file}} ->
              {:error, :enotdir}

            :error ->
              {:error, :enoent}
          end
      end
    end

    @impl true
    def remove("/", _ctx), do: {:error, :eacces}

    def remove(path, _ctx) do
      case lookup(path) do
        :error ->
          {:error, :enoent}

        {:ok, %{locked: true}} ->
          {:error, :eacces}

        {:ok, %{type: :dir}} ->
          if any_children?(path) do
            {:error, :enotempty}
          else
            :ets.delete(table(), path)
            :ok
          end

        {:ok, _file} ->
          :ets.delete(table(), path)
          :ok
      end
    end

    @impl true
    def search(root, query, _ctx) do
      case lookup(root) do
        :error ->
          {:error, :enoent}

        {:ok, %{type: :file}} ->
          {:error, :enotdir}

        {:ok, _} ->
          matches =
            table()
            |> :ets.tab2list()
            |> Enum.filter(fn {path, node} ->
              node.type == :file and not node.locked and under?(path, root)
            end)
            |> Enum.sort()
            |> Enum.flat_map(fn {path, node} ->
              node.content
              |> String.split("\n")
              |> Enum.with_index(1)
              |> Enum.filter(fn {line, _no} -> String.contains?(line, query) end)
              |> Enum.map(fn {line, no} -> %{path: path, line: no, text: line} end)
            end)

          {:ok, matches, nil}
      end
    end

    # ── internals ───────────────────────────────────────────────────────────

    defp table, do: Noizu.MCP.VFSServerE2ETest.Tree.table()
    defp now, do: System.system_time(:millisecond)

    defp new_node(content),
      do: %{type: :file, content: content, version: 1, mtime: now(), locked: false}

    defp lookup(path) do
      case :ets.lookup(table(), path) do
        [{^path, node}] -> {:ok, node}
        [] -> :error
      end
    end

    defp any_children?(path) do
      :ets.tab2list(table())
      |> Enum.any?(fn {child, _node} -> Path.dirname(child) == path end)
    end

    defp under?(_path, "/"), do: true
    defp under?(path, root), do: String.starts_with?(path, root <> "/")

    defp size_of(%{type: :file, content: content}), do: byte_size(content)
    defp size_of(%{type: :dir}), do: 0

    defp to_node(node) do
      %VFS{
        type: node.type,
        size: size_of(node),
        mtime: node.mtime,
        version: node.version,
        writable: node.type == :file and not node.locked,
        executable: false
      }
    end
  end

  defmodule ReadOnlyBackend do
    @moduledoc false
    # stat/list/read only — the write/create/remove/search defaults are
    # :enosys, so a server registering this backend is read-only at the wire
    # (capability, stat flag, and rejection all agree).
    use Noizu.MCP.VFS

    alias Noizu.MCP.VFS

    @impl true
    def stat(path, _ctx) do
      case lookup(path) do
        {:ok, node} -> {:ok, to_node(node)}
        :error -> {:error, :enoent}
      end
    end

    @impl true
    def list(path, _cursor, _ctx) do
      case lookup(path) do
        :error ->
          {:error, :enoent}

        {:ok, %{type: :file}} ->
          {:error, :enotdir}

        {:ok, _dir} ->
          children =
            table()
            |> :ets.tab2list()
            |> Enum.filter(fn {child, _node} -> Path.dirname(child) == path end)
            |> Enum.sort()
            |> Enum.map(fn {child, node} ->
              %{name: Path.basename(child), type: node.type, version: node.version}
            end)

          {:ok, children, nil}
      end
    end

    @impl true
    def read(path, _ctx) do
      case lookup(path) do
        :error -> {:error, :enoent}
        {:ok, %{type: :dir}} -> {:error, :eisdir}
        {:ok, %{locked: true}} -> {:error, :eacces}
        {:ok, node} -> {:ok, node.content, node.version}
      end
    end

    defp table, do: Noizu.MCP.VFSServerE2ETest.Tree.table()

    defp lookup(path) do
      case :ets.lookup(table(), path) do
        [{^path, node}] -> {:ok, node}
        [] -> :error
      end
    end

    defp size_of(%{type: :file, content: content}), do: byte_size(content)
    defp size_of(%{type: :dir}), do: 0

    defp to_node(node) do
      %VFS{type: node.type, size: size_of(node), version: node.version, writable: false}
    end
  end

  # ── fixtures: servers ─────────────────────────────────────────────────────

  defmodule Server do
    use Noizu.MCP.Server, name: "vfs-e2e", version: "1.0.0"
    vfs(Backend)
  end

  defmodule ReadOnlyServer do
    use Noizu.MCP.Server, name: "vfs-e2e-ro", version: "1.0.0"
    vfs(ReadOnlyBackend)
  end

  # Pins the documented first-registration-wins rule: ops dispatch to the
  # writable backend, never to the read-only one registered after it.
  defmodule FirstWinsServer do
    use Noizu.MCP.Server, name: "vfs-e2e-first", version: "1.0.0"
    vfs(Backend)
    vfs(ReadOnlyBackend)
  end

  # ── Mint.WebSocket test client (house pattern, cf. vfs_ws_test.exs) ──────

  defmodule WSClient do
    defstruct [:conn, :ref, :ws, :queue, :auto_pong?, :close]

    def connect(port, path, headers, opts \\ []) do
      auto_pong? = Keyword.get(opts, :auto_pong?, true)

      with {:ok, conn} <-
             Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1], mode: :passive),
           {:ok, conn, ref} <- Mint.WebSocket.upgrade(:ws, conn, path, headers),
           {:ok, conn, responses} <- Mint.HTTP.recv(conn, 0, 2000) do
        with {:ok, 101, resp_headers} <- upgrade_response(responses, ref),
             {:ok, conn, ws} <- Mint.WebSocket.new(conn, ref, 101, resp_headers) do
          {:ok, %__MODULE__{conn: conn, ref: ref, ws: ws, queue: [], auto_pong?: auto_pong?}}
        else
          {:ok, status, _headers} -> {:error, :not_upgraded, status}
          error -> error
        end
      else
        {:error, conn, reason} -> {:error, conn, reason}
        error -> error
      end
    end

    defp upgrade_response(responses, ref) do
      status =
        Enum.find_value(responses, fn
          {:status, ^ref, status} -> status
          _ -> nil
        end)

      headers =
        Enum.find_value(responses, fn
          {:headers, ^ref, headers} -> headers
          _ -> nil
        end)

      if status && headers, do: {:ok, status, headers}, else: {:error, :incomplete_upgrade}
    end

    def send_text(%__MODULE__{} = client, term) do
      {:ok, ws, data} = Mint.WebSocket.encode(client.ws, {:text, Jason.encode!(term)})
      {:ok, conn} = Mint.WebSocket.stream_request_body(client.conn, client.ref, data)
      %{client | ws: ws, conn: conn}
    end

    def recv(client, timeout \\ 2000)

    def recv(%__MODULE__{close: close} = client, _timeout) when close != nil do
      {:closed, client, close}
    end

    def recv(%__MODULE__{queue: [text | rest]} = client, _timeout) do
      {:ok, %{client | queue: rest}, Jason.decode!(text)}
    end

    def recv(%__MODULE__{} = client, timeout) do
      case Mint.WebSocket.recv(client.conn, 0, timeout) do
        {:ok, conn, responses} ->
          datas = for {:data, _, data} <- responses, do: data
          decode(client, conn, IO.iodata_to_binary(datas), timeout)

        {:error, conn, reason, responses} ->
          datas = for {:data, _, data} <- responses, do: data

          if datas == [] do
            closed? = reason == :closed or match?(%Mint.TransportError{reason: :closed}, reason)

            if closed? do
              {:closed, %{client | conn: conn}, :closed}
            else
              {:error, %{client | conn: conn}, reason}
            end
          else
            # The server's WS close frame can land in the same TCP read as the
            # FIN — Mint hands those bytes back in the error tuple's responses.
            # Decode them before reporting, or the close frame is lost.
            decode(client, conn, IO.iodata_to_binary(datas), timeout)
          end
      end
    end

    defp decode(client, conn, data, timeout) do
      case Mint.WebSocket.decode(client.ws, data) do
        {:ok, ws, frames} ->
          client = maybe_pong(%{client | ws: ws, conn: conn}, frames)

          {texts, rest} = Enum.split_with(frames, &match?({:text, _}, &1))
          texts = Enum.map(texts, fn {:text, t} -> t end)

          closed? =
            Enum.any?(rest, &match?({:close, _, _}, &1)) or
              Enum.any?(rest, &match?({:close, _}, &1))

          close =
            Enum.find(rest, &match?({:close, _, _}, &1)) ||
              Enum.find(rest, &match?({:close, _}, &1))

          cond do
            texts != [] ->
              [text | queued] = texts
              {:ok, %{client | queue: queued, close: close || client.close}, Jason.decode!(text)}

            closed? ->
              {:closed, client, close}

            true ->
              recv(client, timeout)
          end

        {:error, ws, reason} ->
          {:error, %{client | ws: ws, conn: conn}, reason}
      end
    end

    defp maybe_pong(client, frames) do
      if client.auto_pong? do
        Enum.reduce(frames, client, fn
          {:ping, data}, acc ->
            {:ok, ws, payload} = Mint.WebSocket.encode(acc.ws, {:pong, data})
            {:ok, conn} = Mint.WebSocket.stream_request_body(acc.conn, acc.ref, payload)
            %{acc | ws: ws, conn: conn}

          _, acc ->
            acc
        end)
      else
        client
      end
    end

    def request(client, method, params, id, timeout \\ 2000) do
      client = send_text(client, %{"v" => 2, "id" => id, "method" => method, "params" => params})
      wait_response(client, id, timeout)
    end

    defp wait_response(client, id, timeout) do
      case recv(client, timeout) do
        {:ok, client, %{"id" => ^id} = frame} -> {:ok, client, frame}
        {:ok, client, _other} -> wait_response(client, id, timeout)
        error -> error
      end
    end

    def close(client) do
      {:ok, ws, data} = Mint.WebSocket.encode(client.ws, :close)
      {:ok, conn} = Mint.WebSocket.stream_request_body(client.conn, client.ref, data)
      %{client | ws: ws, conn: conn}
    end
  end

  # ── bring-up ──────────────────────────────────────────────────────────────

  @seed_content %{
    "/docs/a.txt" => "alpha contents\nsecond line\n",
    "/docs/b.md" => "# b heading\nneedle in the haystack\n",
    "/data/list/one.txt" => "one\n",
    "/data/list/two.txt" => "two\nneedle again\n",
    "/etc/locked.conf" => "secret\n"
  }

  defp seeds do
    %{
      "/" => :dir,
      "/docs" => :dir,
      "/docs/a.txt" => {:file, @seed_content["/docs/a.txt"], false},
      "/docs/b.md" => {:file, @seed_content["/docs/b.md"], false},
      "/data" => :dir,
      "/data/list" => :dir,
      "/data/list/one.txt" => {:file, @seed_content["/data/list/one.txt"], false},
      "/data/list/two.txt" => {:file, @seed_content["/data/list/two.txt"], false},
      "/etc" => :dir,
      "/etc/locked.conf" => {:file, @seed_content["/etc/locked.conf"], true}
    }
  end

  defp socket_path(name), do: Path.join(System.tmp_dir(), "mcp-vfs-e2e-#{name}.sock")

  defp auth_opts do
    verifier_opts = [
      keys: [{@key, %{"sub" => "vfs-e2e-tester"}}],
      default_claims: %{"scope" => "mcp"}
    ]

    [auth: [verifier: {Noizu.MCP.Auth.ApiKeyVerifier, verifier_opts}]]
  end

  defp start_socket_server(module, name) do
    path = socket_path(name)
    File.rm(path)

    spec =
      Supervisor.child_spec(
        {module, transport: {:vfs_socket, [socket_path: path, acceptors: 2] ++ auth_opts()}},
        restart: :temporary
      )

    start_supervised!(spec)
    wait_for_socket(path)
    path
  end

  defp wait_for_socket(path, attempts \\ 100)

  defp wait_for_socket(path, 0), do: flunk("socket #{path} never appeared")

  defp wait_for_socket(path, attempts) do
    if File.exists?(path) do
      path
    else
      Process.sleep(10)
      wait_for_socket(path, attempts - 1)
    end
  end

  defp start_bandit(module) do
    start_supervised!(
      {Bandit,
       plug: {Noizu.MCP.Transport.VFSWS, Keyword.put(auth_opts(), :server, module)},
       port: 0,
       ip: :loopback,
       startup_log: false,
       thousand_island_options: [shutdown_timeout: 10]},
      id: make_ref()
    )
    |> then(fn pid ->
      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      port
    end)
  end

  setup do
    start_supervised!(VFSPubSub)
    Tree.seed(seeds())

    socket = start_socket_server(Server, "main")
    ro_socket = start_socket_server(ReadOnlyServer, "ro")
    ws = start_bandit(Server)
    ro_ws = start_bandit(ReadOnlyServer)

    on_exit(fn ->
      Cache.purge(Backend)
      Cache.purge(ReadOnlyBackend)
      File.rm(socket_path("main"))
      File.rm(socket_path("ro"))
    end)

    %{socket: socket, ro_socket: ro_socket, ws: ws, ro_ws: ro_ws}
  end

  # ── client helpers ────────────────────────────────────────────────────────

  defp connect!(path) do
    {:ok, client} = VFSClient.connect(path)
    on_exit(fn -> VFSClient.close(client) end)
    client
  end

  defp authed!(path) do
    client = connect!(path)

    assert {:ok, %{"authenticated" => true, "session_id" => sid}} = VFSClient.auth(client, @key)
    assert is_binary(sid) and sid != ""
    client
  end

  defp ws_connect!(port) do
    assert {:ok, client} = WSClient.connect(port, "/vfs", [{"authorization", "Bearer " <> @key}])
    client
  end

  defp ws_authed!(port) do
    client = ws_connect!(port)

    assert {:ok, client, %{"result" => %{"authenticated" => true, "session_id" => sid}}} =
             WSClient.request(client, "vfs/auth", %{"api_key" => @key}, 1)

    assert is_binary(sid) and sid != ""
    client
  end

  defp ws_event(client, timeout \\ @event_timeout) do
    case WSClient.recv(client, timeout) do
      {:ok, client, %{"type" => "vfs/event"} = frame} -> {:ok, client, frame}
      {:ok, client, _other} -> ws_event(client, timeout)
      other -> other
    end
  end

  # True when the connection went quiet for `ms` (no events) or was closed.
  defp ws_quiet?(client, ms) do
    case WSClient.recv(client, ms) do
      {:closed, _, _} -> true
      {:error, _, :timeout} -> true
      {:error, _, _} -> true
      {:ok, _, _} -> false
    end
  end

  # ── socket transport (VFSClient ↔ VFSSocket) ──────────────────────────────

  describe "socket transport" do
    test "vfs/auth: good key binds a session", %{socket: path} do
      authed!(path)
    end

    test "vfs/auth: bad key is -32001 and the connection closes", %{socket: path} do
      client = connect!(path)

      assert {:error, %{"code" => -32001, "message" => message}} =
               VFSClient.auth(client, @bad_key)

      assert message =~ "auth"
      assert {:error, :closed} = VFSClient.request(client, "vfs/stat", %{"path" => "/"})
    end

    test "vfs_stat exposes type, size, version and writability flags", %{socket: path} do
      client = authed!(path)
      a_size = byte_size(@seed_content["/docs/a.txt"])

      assert {:ok,
              %{
                "type" => "file",
                "size" => ^a_size,
                "version" => version,
                "writable" => true,
                "executable" => false
              }} = VFSClient.stat(client, "/docs/a.txt")

      assert is_integer(version) and version >= 1

      assert {:ok, %{"type" => "dir"}} = VFSClient.stat(client, "/docs")

      # A locked node keeps its metadata but advertises itself unwritable.
      assert {:ok, %{"writable" => false}} = VFSClient.stat(client, "/etc/locked.conf")
    end

    test "vfs_list returns names, types and sizes", %{socket: path} do
      client = authed!(path)

      assert {:ok, %{"entries" => root}} = VFSClient.list(client, "/")
      assert %{"name" => "docs", "type" => "dir"} = entry(root, "docs")
      assert %{"name" => "data", "type" => "dir"} = entry(root, "data")
      assert %{"name" => "etc", "type" => "dir"} = entry(root, "etc")

      assert {:ok, %{"entries" => docs}} = VFSClient.list(client, "/docs")
      a_size = byte_size(@seed_content["/docs/a.txt"])

      assert %{"name" => "a.txt", "type" => "file", "size" => ^a_size} = entry(docs, "a.txt")

      assert {:ok, %{"entries" => list}} = VFSClient.list(client, "/data/list")
      assert %{"name" => "one.txt", "type" => "file"} = entry(list, "one.txt")
      assert %{"name" => "two.txt", "type" => "file"} = entry(list, "two.txt")
    end

    test "vfs_read returns the seeded content and version", %{socket: path} do
      client = authed!(path)

      # Wire versions are the backend's version stamped with the backend's
      # cache generation, which advances across tests — assert shape, not 1.
      assert {:ok, %{"content" => "alpha contents\nsecond line\n", "version" => version}} =
               VFSClient.read(client, "/docs/a.txt")

      assert is_integer(version) and version >= 1
    end

    test "vfs_write round-trips, bumps the version, and is visible to a second connection", %{
      socket: path
    } do
      client_a = authed!(path)

      assert {:ok, %{"content" => "alpha contents\nsecond line\n", "version" => v1}} =
               VFSClient.read(client_a, "/docs/a.txt")

      # The write comes from a different connection than the reads.
      client_b = authed!(path)
      rewritten = "rewritten"
      rewritten_size = byte_size(rewritten)

      assert {:ok, %{"version" => v2, "size" => ^rewritten_size}} =
               VFSClient.write(client_b, "/docs/a.txt", rewritten)

      assert v2 > v1

      assert {:ok, %{"content" => "rewritten", "version" => ^v2}} =
               VFSClient.read(client_a, "/docs/a.txt")
    end

    test "vfs_create lands in vfs_list; duplicate is -32041; missing parent is -32002", %{
      socket: path
    } do
      client = authed!(path)

      assert {:ok, %{"type" => "file", "version" => version}} =
               VFSClient.create(client, "/docs/new.txt", "fresh")

      assert is_integer(version) and version >= 1

      assert {:ok, %{"entries" => docs}} = VFSClient.list(client, "/docs")
      assert %{"name" => "new.txt", "type" => "file"} = entry(docs, "new.txt")

      assert {:error, %{"code" => -32041, "data" => %{"errno_atom" => "eexist"}}} =
               VFSClient.create(client, "/docs/new.txt", "again")

      assert {:error, %{"code" => -32002, "data" => %{"errno_atom" => "enoent"}}} =
               VFSClient.create(client, "/nope/child.txt", "orphan")

      assert {:ok, %{"type" => "dir"}} = VFSClient.create(client, "/docs/newdir")
    end

    test "vfs_remove: file goes away, non-empty dir is -32045, locked and root are -32040", %{
      socket: path
    } do
      client = authed!(path)

      assert {:ok, %{"type" => "file"}} = VFSClient.create(client, "/docs/doomed.txt", "bye")

      assert {:ok, %{"removed" => "/docs/doomed.txt"}} =
               VFSClient.remove(client, "/docs/doomed.txt")

      assert {:error, %{"code" => -32002, "data" => %{"errno_atom" => "enoent"}}} =
               VFSClient.stat(client, "/docs/doomed.txt")

      assert {:error, %{"code" => -32045, "data" => %{"errno_atom" => "enotempty"}}} =
               VFSClient.remove(client, "/docs")

      assert {:error, %{"code" => -32040, "data" => %{"errno_atom" => "eacces"}}} =
               VFSClient.remove(client, "/etc/locked.conf")

      assert {:error, %{"code" => -32040, "data" => %{"errno_atom" => "eacces"}}} =
               VFSClient.remove(client, "/")
    end

    test "vfs_search finds seeded lines with path, line number and text", %{socket: path} do
      client = authed!(path)

      assert {:ok, %{"matches" => matches}} = VFSClient.search(client, "needle")

      assert Enum.sort(matches) == [
               %{"path" => "/data/list/two.txt", "line" => 2, "text" => "needle again"},
               %{"path" => "/docs/b.md", "line" => 2, "text" => "needle in the haystack"}
             ]

      assert {:ok,
              %{
                "matches" => [%{"path" => "/docs/a.txt", "line" => 1, "text" => "alpha contents"}]
              }} =
               VFSClient.search(client, "alpha", root: "/docs")
    end

    test "error paths: unknown read is -32002, locked read/write are -32040, dir write is -32043",
         %{
           socket: path
         } do
      client = authed!(path)

      assert {:error, %{"code" => -32002, "data" => %{"errno_atom" => "enoent"}}} =
               VFSClient.read(client, "/nope")

      assert {:error, %{"code" => -32040, "data" => %{"errno_atom" => "eacces"}}} =
               VFSClient.read(client, "/etc/locked.conf")

      assert {:error, %{"code" => -32040, "data" => %{"errno_atom" => "eacces"}}} =
               VFSClient.write(client, "/etc/locked.conf", "tamper")

      assert {:error, %{"code" => -32043, "data" => %{"errno_atom" => "eisdir"}}} =
               VFSClient.write(client, "/docs", "into a dir")
    end

    test "read-only registration: stat is unwritable and writes are -32046 enosys", %{
      ro_socket: path
    } do
      client = authed!(path)

      assert {:ok, %{"writable" => false}} = VFSClient.stat(client, "/docs/a.txt")

      assert {:ok, %{"content" => "alpha contents\nsecond line\n"}} =
               VFSClient.read(client, "/docs/a.txt")

      assert {:error, %{"code" => -32046, "data" => %{"errno_atom" => "enosys"}}} =
               VFSClient.write(client, "/docs/a.txt", "nope")

      assert {:error, %{"code" => -32046, "data" => %{"errno_atom" => "enosys"}}} =
               VFSClient.create(client, "/docs/new.txt", "nope")

      assert {:error, %{"code" => -32046, "data" => %{"errno_atom" => "enosys"}}} =
               VFSClient.remove(client, "/docs/a.txt")
    end

    test "with multiple registrations the first backend wins" do
      spec =
        Supervisor.child_spec(
          {FirstWinsServer,
           transport:
             {:vfs_socket, [socket_path: socket_path("first"), acceptors: 2] ++ auth_opts()}},
          restart: :temporary
        )

      start_supervised!(spec)
      wait_for_socket(socket_path("first"))
      on_exit(fn -> File.rm(socket_path("first")) end)

      client = authed!(socket_path("first"))

      # The writable backend (first) serves ops; the read-only registration
      # behind it must never intercept.
      assert {:ok, %{"writable" => true}} = VFSClient.stat(client, "/docs/a.txt")

      assert {:ok, %{"version" => _}} = VFSClient.write(client, "/docs/a.txt", "via first")
      assert {:ok, %{"content" => "via first"}} = VFSClient.read(client, "/docs/a.txt")
    end

    test "a socket write is visible to a websocket reader on the same backend", %{
      socket: path,
      ws: ws_port
    } do
      socket_client = authed!(path)
      ws_client = ws_authed!(ws_port)

      assert {:ok, %{"version" => v}} =
               VFSClient.write(socket_client, "/docs/a.txt", "via socket")

      assert {:ok, _, %{"result" => %{"content" => "via socket", "version" => ^v}}} =
               WSClient.request(ws_client, "vfs/read", %{"path" => "/docs/a.txt"}, 2)
    end
  end

  # ── websocket transport (Mint WS client ↔ VFSWS/Bandit) ──────────────────

  describe "websocket transport" do
    test "vfs/auth: good key binds a session", %{ws: port} do
      ws_authed!(port)
    end

    test "vfs/auth: bad key is -32001 and the connection closes", %{ws: port} do
      client = ws_connect!(port)

      assert {:ok, _client, %{"error" => %{"code" => -32001, "message" => message}}} =
               WSClient.request(client, "vfs/auth", %{"api_key" => @bad_key}, 1)

      assert message =~ "auth"
      assert {:closed, _, _} = WSClient.recv(client)
    end

    test "stat, list and read round-trip over the wire", %{ws: port} do
      client = ws_authed!(port)

      assert {:ok, _, %{"result" => %{"type" => "file", "size" => size, "writable" => true}}} =
               WSClient.request(client, "vfs/stat", %{"path" => "/docs/a.txt"}, 2)

      assert size == byte_size(@seed_content["/docs/a.txt"])

      assert {:ok, _, %{"result" => %{"entries" => docs}}} =
               WSClient.request(client, "vfs/list", %{"path" => "/docs"}, 3)

      assert %{"name" => "a.txt", "type" => "file"} = entry(docs, "a.txt")
      assert %{"name" => "b.md", "type" => "file"} = entry(docs, "b.md")

      assert {:ok, _, %{"result" => %{"content" => "one\n", "version" => version}}} =
               WSClient.request(client, "vfs/read", %{"path" => "/data/list/one.txt"}, 4)

      assert is_integer(version) and version >= 1
    end

    test "vfs_write round-trips with a bumped version", %{ws: port} do
      client = ws_authed!(port)

      assert {:ok, _, %{"result" => %{"content" => "one\n", "version" => v1}}} =
               WSClient.request(client, "vfs/read", %{"path" => "/data/list/one.txt"}, 1)

      assert {:ok, _, %{"result" => %{"version" => v2}}} =
               WSClient.request(
                 client,
                 "vfs/write",
                 %{"path" => "/data/list/one.txt", "data" => "uno\n"},
                 2
               )

      assert v2 > v1

      assert {:ok, _, %{"result" => %{"content" => "uno\n", "version" => ^v2}}} =
               WSClient.request(client, "vfs/read", %{"path" => "/data/list/one.txt"}, 3)
    end

    test "vfs_create appears in vfs_list; duplicate is -32041", %{ws: port} do
      client = ws_authed!(port)

      assert {:ok, _, %{"result" => %{"type" => "file"}}} =
               WSClient.request(
                 client,
                 "vfs/create",
                 %{"path" => "/data/list/three.txt", "data" => "3"},
                 1
               )

      assert {:ok, _, %{"result" => %{"entries" => entries}}} =
               WSClient.request(client, "vfs/list", %{"path" => "/data/list"}, 2)

      assert %{"name" => "three.txt", "type" => "file"} = entry(entries, "three.txt")

      assert {:ok, _, %{"error" => %{"code" => -32041, "data" => %{"errno_atom" => "eexist"}}}} =
               WSClient.request(
                 client,
                 "vfs/create",
                 %{"path" => "/data/list/three.txt", "data" => "again"},
                 3
               )
    end

    test "vfs_remove: gone after removal; non-empty dir is -32045", %{ws: port} do
      client = ws_authed!(port)

      assert {:ok, _, %{"result" => %{"removed" => "/data/list/one.txt"}}} =
               WSClient.request(client, "vfs/remove", %{"path" => "/data/list/one.txt"}, 1)

      assert {:ok, _, %{"error" => %{"code" => -32002, "data" => %{"errno_atom" => "enoent"}}}} =
               WSClient.request(client, "vfs/stat", %{"path" => "/data/list/one.txt"}, 2)

      assert {:ok, _, %{"error" => %{"code" => -32045, "data" => %{"errno_atom" => "enotempty"}}}} =
               WSClient.request(client, "vfs/remove", %{"path" => "/data/list"}, 3)
    end

    test "vfs_search finds a seeded line", %{ws: port} do
      client = ws_authed!(port)

      assert {:ok, _, %{"result" => %{"matches" => matches}}} =
               WSClient.request(client, "vfs/search", %{"query" => "alpha"}, 1)

      assert [%{"path" => "/docs/a.txt", "line" => 1, "text" => "alpha contents"}] = matches
    end

    test "error paths: unknown read is -32002, locked write is -32040", %{ws: port} do
      client = ws_authed!(port)

      assert {:ok, _, %{"error" => %{"code" => -32002, "data" => %{"errno_atom" => "enoent"}}}} =
               WSClient.request(client, "vfs/read", %{"path" => "/nope"}, 1)

      assert {:ok, _, %{"error" => %{"code" => -32040, "data" => %{"errno_atom" => "eacces"}}}} =
               WSClient.request(
                 client,
                 "vfs/write",
                 %{"path" => "/etc/locked.conf", "data" => "x"},
                 2
               )
    end

    test "read-only registration refuses writes with -32046 enosys", %{ro_ws: port} do
      client = ws_authed!(port)

      assert {:ok, _, %{"result" => %{"writable" => false}}} =
               WSClient.request(client, "vfs/stat", %{"path" => "/docs/a.txt"}, 1)

      assert {:ok, _, %{"error" => %{"code" => -32046, "data" => %{"errno_atom" => "enosys"}}}} =
               WSClient.request(client, "vfs/write", %{"path" => "/docs/a.txt", "data" => "y"}, 2)
    end

    # ── liveness: the pubsub loop through real sockets ──────────────────────

    test "a subscriber receives write/create/remove events issued by a second connection", %{
      ws: port
    } do
      subscriber = ws_authed!(port)
      writer = ws_authed!(port)

      assert {:ok, subscriber, %{"result" => %{"subscribed" => true}}} =
               WSClient.request(subscriber, "vfs/subscribe", %{"paths" => ["/docs"]}, 1)

      # write from the other connection
      assert {:ok, writer, %{"result" => %{"version" => write_version}}} =
               WSClient.request(
                 writer,
                 "vfs/write",
                 %{"path" => "/docs/a.txt", "data" => "live\n"},
                 2
               )

      assert {:ok, subscriber,
              %{"op" => "write", "path" => "/docs/a.txt", "version" => ^write_version}} =
               ws_event(subscriber)

      # create from the other connection
      assert {:ok, writer, %{"result" => %{"type" => "file"}}} =
               WSClient.request(
                 writer,
                 "vfs/create",
                 %{"path" => "/docs/live.txt", "data" => "born"},
                 3
               )

      assert {:ok, subscriber, %{"op" => "create", "path" => "/docs/live.txt", "version" => _}} =
               ws_event(subscriber)

      # remove from the other connection
      assert {:ok, _writer, %{"result" => %{"removed" => "/docs/live.txt"}}} =
               WSClient.request(writer, "vfs/remove", %{"path" => "/docs/live.txt"}, 4)

      assert {:ok, _subscriber, %{"op" => "remove", "path" => "/docs/live.txt"}} =
               ws_event(subscriber)
    end

    test "an unrelated connection receives no events for another's subscription", %{ws: port} do
      subscriber = ws_authed!(port)
      bystander = ws_authed!(port)
      writer = ws_authed!(port)

      assert {:ok, subscriber, %{"result" => %{"subscribed" => true}}} =
               WSClient.request(subscriber, "vfs/subscribe", %{"paths" => ["/docs"]}, 1)

      assert {:ok, _writer, %{"result" => %{"version" => _}}} =
               WSClient.request(
                 writer,
                 "vfs/write",
                 %{"path" => "/docs/a.txt", "data" => "shh\n"},
                 2
               )

      assert {:ok, _subscriber, %{"op" => "write"}} = ws_event(subscriber)
      assert ws_quiet?(bystander, 150)
    end

    test "unsubscribe stops event delivery", %{ws: port} do
      client = ws_authed!(port)

      assert {:ok, client, %{"result" => %{"subscribed" => true}}} =
               WSClient.request(client, "vfs/subscribe", %{"paths" => ["/docs"]}, 1)

      assert {:ok, client, %{"result" => %{"version" => _}}} =
               WSClient.request(
                 client,
                 "vfs/write",
                 %{"path" => "/docs/a.txt", "data" => "1\n"},
                 2
               )

      assert {:ok, client, %{"op" => "write"}} = ws_event(client)

      assert {:ok, client, %{"result" => %{"unsubscribed" => true}}} =
               WSClient.request(client, "vfs/unsubscribe", %{"paths" => ["/docs"]}, 3)

      assert {:ok, _client, %{"result" => %{"version" => _}}} =
               WSClient.request(
                 client,
                 "vfs/write",
                 %{"path" => "/docs/a.txt", "data" => "2\n"},
                 4
               )

      assert ws_quiet?(client, 150)
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp entry(entries, name), do: Enum.find(entries, &(&1["name"] == name))
end
