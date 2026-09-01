defmodule Noizu.MCP.Transport.VFSWSTest do
  use ExUnit.Case, async: false

  alias Noizu.MCP.Server.Features.VFS
  alias Noizu.MCP.Server.VFSPubSub
  alias Noizu.MCP.VFS.Cache
  alias Noizu.MCP.VFS.Fixture.Memory

  @backend Memory
  @key "vfs-ws-test-key"
  @bad_key "vfs-ws-wrong-key"
  @event_timeout 1000

  defmodule MemoryServer do
    use Noizu.MCP.Server, name: "vfs-ws-memory", version: "1.0.0"
    vfs(Noizu.MCP.VFS.Fixture.Memory)
  end

  defmodule NullServer do
    use Noizu.MCP.Server, name: "vfs-ws-null", version: "1.0.0"
    vfs(Noizu.MCP.VFS.Null)
  end

  # ── Mint.WebSocket test client ────────────────────────────────────────────

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

        {:error, conn, %Mint.TransportError{reason: :closed}, _} ->
          {:closed, %{client | conn: conn}, :closed}

        {:error, conn, reason, _} ->
          {:error, %{client | conn: conn}, reason}
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
            # Deliver queued texts before honouring a same-chunk close; the
            # follow-up recv then reports the deferred close frame.
            texts != [] ->
              [text | queued] = texts
              {:ok, %{client | queue: queued, close: close || client.close}, Jason.decode!(text)}

            close != nil ->
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

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp tree_spec do
    %{
      "/" => :dir,
      "/hello.txt" => "hello world\n",
      "/docs" => :dir,
      "/docs/a.md" => "# alpha\nbeta gamma\n",
      "/docs/b.md" => "delta\n",
      "/docs/sub" => :dir,
      "/docs/sub/deep.md" => "deep\n"
    }
  end

  defp auth_opts do
    verifier_opts = [
      keys: [{@key, %{"sub" => "vfs-ws-tester"}}],
      default_claims: %{"scope" => "mcp"}
    ]

    [auth: [verifier: {Noizu.MCP.Auth.ApiKeyVerifier, verifier_opts}]]
  end

  defp start_bandit(plug_opts) do
    start_supervised!(
      {Bandit,
       plug: {Noizu.MCP.Transport.VFSWS, plug_opts},
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

    ctx = Memory.seed(tree_spec())
    tree = ctx.assigns.tree

    memory =
      start_bandit(
        [server: MemoryServer, context: fn _claims -> %{tree: tree} end] ++ auth_opts()
      )

    null = start_bandit([server: NullServer] ++ auth_opts())

    on_exit(fn -> Cache.purge(Memory) end)

    %{port: memory, null_port: null, ctx: ctx}
  end

  defp connect_ok!(port, headers, opts \\ []) do
    assert {:ok, client} = WSClient.connect(port, "/vfs", headers, opts)
    client
  end

  defp authed!(port, opts \\ []) do
    client = connect_ok!(port, [{"authorization", "Bearer " <> @key}], opts)

    assert {:ok, client, %{"result" => %{"authenticated" => true, "session_id" => sid}}} =
             WSClient.request(client, "vfs/auth", %{"api_key" => @key}, 1)

    assert is_binary(sid) and sid != ""
    client
  end

  defp event(client, timeout \\ @event_timeout) do
    case WSClient.recv(client, timeout) do
      {:ok, client, %{"type" => "vfs/event"} = frame} -> {:ok, client, frame}
      {:ok, client, _other} -> event(client, timeout)
      other -> other
    end
  end

  # True when the connection went quiet for `ms` (no events) or was closed.
  defp quiet?(client, ms) do
    case WSClient.recv(client, ms) do
      {:closed, _, _} -> true
      {:error, _, :timeout} -> true
      {:error, _, _} -> true
      {:ok, _, _} -> false
    end
  end

  # ── upgrade auth ──────────────────────────────────────────────────────────

  test "upgrade without a bearer token is 401", %{port: port} do
    assert {:error, :not_upgraded, 401} = WSClient.connect(port, "/vfs", [])
  end

  test "upgrade with a bad bearer token is 401", %{port: port} do
    assert {:error, :not_upgraded, 401} =
             WSClient.connect(port, "/vfs", [{"authorization", "Bearer " <> @bad_key}])
  end

  test "upgrade with a valid bearer token succeeds", %{port: port} do
    connect_ok!(port, [{"authorization", "Bearer " <> @key}])
  end

  test "a verifier-less transport still requires the vfs/auth frame" do
    unauth_port = start_bandit(server: NullServer)
    client = connect_ok!(unauth_port, [])

    assert {:ok, client, %{"result" => %{"authenticated" => true}}} =
             WSClient.request(client, "vfs/auth", %{"token" => "anything"}, 1)

    assert {:ok, _, %{"error" => %{"code" => -32046, "data" => %{"errno_atom" => "enosys"}}}} =
             WSClient.request(client, "vfs/write", %{"path" => "/x", "data" => "y"}, 2)
  end

  # ── handshake ─────────────────────────────────────────────────────────────

  test "auth failure returns -32001 and closes the connection", %{port: port} do
    client = connect_ok!(port, [{"authorization", "Bearer " <> @key}])

    assert {:ok, client, %{"error" => %{"code" => -32001, "message" => message}}} =
             WSClient.request(client, "vfs/auth", %{"api_key" => @bad_key}, 1)

    assert message =~ "auth"
    assert {:closed, _, _} = WSClient.recv(client)
  end

  test "ops before auth are refused with -32001 and close", %{port: port} do
    client = connect_ok!(port, [{"authorization", "Bearer " <> @key}])

    assert {:ok, client, %{"error" => %{"code" => -32001}}} =
             WSClient.request(client, "vfs/stat", %{"path" => "/"}, 1)

    assert {:closed, _, _} = WSClient.recv(client)
  end

  test "missing api_key is a failed handshake", %{port: port} do
    client = connect_ok!(port, [{"authorization", "Bearer " <> @key}])

    assert {:ok, _client, %{"error" => %{"code" => -32001}}} =
             WSClient.request(client, "vfs/auth", %{}, 1)
  end

  test "second vfs/auth after success is invalid_request", %{port: port} do
    client = authed!(port)

    assert {:ok, client, %{"error" => %{"code" => -32600}}} =
             WSClient.request(client, "vfs/auth", %{"api_key" => @key}, 2)

    assert {:ok, _, %{"result" => %{"type" => "file"}}} =
             WSClient.request(client, "vfs/stat", %{"path" => "/hello.txt"}, 3)
  end

  # ── ops ───────────────────────────────────────────────────────────────────

  test "vfs_stat returns a string-keyed node", %{port: port} do
    client = authed!(port)

    assert {:ok, _, %{"result" => %{"type" => "file", "size" => 12, "writable" => true}}} =
             WSClient.request(client, "vfs/stat", %{"path" => "/hello.txt"}, 1)

    assert {:ok, _, %{"result" => %{"type" => "dir"}}} =
             WSClient.request(client, "vfs/stat", %{"path" => "/"}, 2)
  end

  test "vfs_stat miss: -32002 with errno_atom enoent", %{port: port} do
    client = authed!(port)

    assert {:ok, _, %{"error" => %{"code" => -32002, "data" => %{"errno_atom" => "enoent"}}}} =
             WSClient.request(client, "vfs/stat", %{"path" => "/nope"}, 1)
  end

  test "vfs_list returns string-keyed entries", %{port: port} do
    client = authed!(port)

    assert {:ok, _, %{"result" => %{"entries" => entries}}} =
             WSClient.request(client, "vfs/list", %{"path" => "/"}, 1)

    assert Enum.any?(entries, &(&1["name"] == "hello.txt" and &1["size"] == 12))
  end

  test "vfs_list on a file: -32044 enotdir", %{port: port} do
    client = authed!(port)

    assert {:ok, _, %{"error" => %{"code" => -32044, "data" => %{"errno_atom" => "enotdir"}}}} =
             WSClient.request(client, "vfs/list", %{"path" => "/hello.txt"}, 1)
  end

  test "vfs_read and vfs_write round-trip", %{port: port} do
    client = authed!(port)

    assert {:ok, client, %{"result" => %{"content" => "hello world\n", "version" => v1}}} =
             WSClient.request(client, "vfs/read", %{"path" => "/hello.txt"}, 1)

    assert {:ok, client, %{"result" => %{"version" => v2}}} =
             WSClient.request(
               client,
               "vfs/write",
               %{"path" => "/hello.txt", "data" => "new\n"},
               2
             )

    assert v2 > v1

    assert {:ok, _, %{"result" => %{"content" => "new\n", "version" => ^v2}}} =
             WSClient.request(client, "vfs/read", %{"path" => "/hello.txt"}, 3)
  end

  test "vfs_read on a dir: -32043 eisdir", %{port: port} do
    client = authed!(port)

    assert {:ok, _, %{"error" => %{"code" => -32043, "data" => %{"errno_atom" => "eisdir"}}}} =
             WSClient.request(client, "vfs/read", %{"path" => "/"}, 1)
  end

  test "vfs_create makes files and dirs; re-create is -32041 eexist", %{port: port} do
    client = authed!(port)

    assert {:ok, _, %{"result" => %{"type" => "file"}}} =
             WSClient.request(client, "vfs/create", %{"path" => "/made.txt", "data" => "data"}, 1)

    assert {:ok, _, %{"error" => %{"code" => -32041, "data" => %{"errno_atom" => "eexist"}}}} =
             WSClient.request(
               client,
               "vfs/create",
               %{"path" => "/made.txt", "data" => "again"},
               2
             )
  end

  test "vfs_remove: ok, enotempty and eacces errors", %{port: port} do
    client = authed!(port)

    assert {:ok, _, %{"result" => %{"removed" => "/docs/b.md"}}} =
             WSClient.request(client, "vfs/remove", %{"path" => "/docs/b.md"}, 1)

    assert {:ok, _, %{"error" => %{"code" => -32045, "data" => %{"errno_atom" => "enotempty"}}}} =
             WSClient.request(client, "vfs/remove", %{"path" => "/docs"}, 2)

    assert {:ok, _, %{"error" => %{"code" => -32040, "data" => %{"errno_atom" => "eacces"}}}} =
             WSClient.request(client, "vfs/remove", %{"path" => "/"}, 3)
  end

  test "vfs_search and vfs_xattr", %{port: port} do
    client = authed!(port)

    assert {:ok, _, %{"result" => %{"matches" => [%{"path" => "/docs/a.md"}]}}} =
             WSClient.request(client, "vfs/search", %{"query" => "alpha"}, 1)

    assert {:ok, _, %{"result" => %{}}} =
             WSClient.request(client, "vfs/xattr", %{"path" => "/hello.txt"}, 2)
  end

  test "read-only backend refuses writes with -32046 enosys", %{null_port: port} do
    client = authed!(port)

    assert {:ok, _, %{"error" => %{"code" => -32046, "data" => %{"errno_atom" => "enosys"}}}} =
             WSClient.request(client, "vfs/write", %{"path" => "/x", "data" => "y"}, 1)
  end

  test "unknown method is -32601 and the connection survives", %{port: port} do
    client = authed!(port)

    assert {:ok, client, %{"error" => %{"code" => -32601}}} =
             WSClient.request(client, "vfs/chmod", %{}, 1)

    assert {:ok, _, %{"result" => %{"type" => "file"}}} =
             WSClient.request(client, "vfs/stat", %{"path" => "/hello.txt"}, 2)
  end

  test "invalid params surface as -32602", %{port: port} do
    client = authed!(port)

    assert {:ok, _, %{"error" => %{"code" => -32602}}} =
             WSClient.request(client, "vfs/stat", %{}, 1)
  end

  # ── framing / lifecycle ───────────────────────────────────────────────────

  test "malformed json draws a parse error without closing the connection", %{port: port} do
    client = authed!(port)
    {:ok, ws, data} = Mint.WebSocket.encode(client.ws, {:text, "not json {"})
    {:ok, conn} = Mint.WebSocket.stream_request_body(client.conn, client.ref, data)
    client = %{client | ws: ws, conn: conn}

    assert {:ok, _, %{"error" => %{"code" => -32700}}} = WSClient.recv(client)

    assert {:ok, _, %{"result" => %{"type" => "file"}}} =
             WSClient.request(client, "vfs/stat", %{"path" => "/hello.txt"}, 2)
  end

  test "binary frames are refused without closing the connection", %{port: port} do
    client = authed!(port)
    {:ok, ws, data} = Mint.WebSocket.encode(client.ws, {:binary, <<1, 2, 3>>})
    {:ok, conn} = Mint.WebSocket.stream_request_body(client.conn, client.ref, data)
    client = %{client | ws: ws, conn: conn}

    assert {:ok, _, %{"error" => %{"code" => -32600}}} = WSClient.recv(client)

    assert {:ok, _, %{"result" => %{"type" => "file"}}} =
             WSClient.request(client, "vfs/stat", %{"path" => "/hello.txt"}, 2)
  end

  test "connection close cleans up without disturbing other clients", %{port: port} do
    client_a = authed!(port)
    client_b = authed!(port)

    assert {:ok, _, %{"result" => _}} =
             WSClient.request(client_a, "vfs/stat", %{"path" => "/"}, 1)

    WSClient.close(client_a)
    Process.sleep(20)

    assert {:ok, _, %{"result" => _}} =
             WSClient.request(client_b, "vfs/stat", %{"path" => "/"}, 1)
  end

  # ── vfs/ping ──────────────────────────────────────────────────────────────

  test "vfs/ping replies promptly", %{port: port} do
    client = authed!(port)

    assert {:ok, _, %{"result" => %{"pong" => true}}} =
             WSClient.request(client, "vfs/ping", %{}, 1)
  end

  # ── subscribe / events ────────────────────────────────────────────────────

  test "subscribe receives debounced events from programmatic writes", %{port: port, ctx: ctx} do
    client = authed!(port)

    assert {:ok, client, %{"result" => %{"subscribed" => true}}} =
             WSClient.request(client, "vfs/subscribe", %{"paths" => ["/docs"]}, 1)

    {:ok, _node} = VFS.write(@backend, "/docs/a.md", "updated\n", ctx)

    {:ok, client, %{"seq" => seq, "op" => "write", "path" => path, "version" => version}} =
      event(client)

    assert path == "/docs/a.md"
    assert is_integer(seq) and is_integer(version)

    # A write issued over this same WS connection also lands as an event.
    assert {:ok, client, %{"result" => %{"version" => _}}} =
             WSClient.request(client, "vfs/write", %{"path" => "/docs/b.md", "data" => "w\n"}, 2)

    assert {:ok, _, %{"op" => "write", "path" => "/docs/b.md"}} = event(client)
  end

  test "event coalescing: a burst produces one event with the final version", %{
    port: port,
    ctx: ctx
  } do
    client = authed!(port)

    {:ok, client, _} = WSClient.request(client, "vfs/subscribe", %{"paths" => ["/"]}, 1)

    {:ok, _} = VFS.write(@backend, "/hello.txt", "1\n", ctx)
    {:ok, _} = VFS.write(@backend, "/hello.txt", "22\n", ctx)
    {:ok, final} = VFS.write(@backend, "/hello.txt", "333\n", ctx)

    {:ok, _, %{"path" => "/hello.txt", "version" => version, "seq" => 1}} = event(client)
    assert version == final.version

    assert quiet?(client, 150)
  end

  test "ancestor watch: subscribing to / catches nested writes", %{port: port, ctx: ctx} do
    client = authed!(port)

    {:ok, client, _} = WSClient.request(client, "vfs/subscribe", %{"paths" => ["/"]}, 1)

    {:ok, _} = VFS.write(@backend, "/docs/sub/deep.md", "x\n", ctx)

    assert {:ok, _, %{"path" => "/docs/sub/deep.md"}} = event(client)
  end

  test "depth bounds event delivery", %{port: port, ctx: ctx} do
    client = authed!(port)

    {:ok, client, _} =
      WSClient.request(client, "vfs/subscribe", %{"paths" => ["/docs"], "depth" => 1}, 1)

    # delta 1 — delivered.
    {:ok, _} = VFS.write(@backend, "/docs/a.md", "x\n", ctx)
    {:ok, client, %{"path" => "/docs/a.md"}} = event(client)

    # delta 2 — filtered.
    {:ok, _} = VFS.write(@backend, "/docs/sub/deep.md", "y\n", ctx)
    assert quiet?(client, 150)
  end

  test "unsubscribe stops events", %{port: port, ctx: ctx} do
    client = authed!(port)

    {:ok, client, _} = WSClient.request(client, "vfs/subscribe", %{"paths" => ["/hello.txt"]}, 1)

    {:ok, _} = VFS.write(@backend, "/hello.txt", "1\n", ctx)
    {:ok, client, %{"path" => "/hello.txt"}} = event(client)

    {:ok, client, _} =
      WSClient.request(client, "vfs/unsubscribe", %{"paths" => ["/hello.txt"]}, 2)

    {:ok, _} = VFS.write(@backend, "/hello.txt", "2\n", ctx)
    assert quiet?(client, 150)
  end

  test "watch cap returns -32047", %{port: port} do
    client = authed!(port)
    paths = Enum.map(1..10_001, &"/cap-#{String.pad_leading(Integer.to_string(&1), 5, "0")}")

    assert {:ok, _, %{"error" => %{"code" => -32047}}} =
             WSClient.request(client, "vfs/subscribe", %{"paths" => paths}, 1)
  end

  test "subscribe without paths is -32602", %{port: port} do
    client = authed!(port)

    assert {:ok, _, %{"error" => %{"code" => -32602}}} =
             WSClient.request(client, "vfs/subscribe", %{}, 1)
  end

  test "disconnect unregisters the connection's watches", %{port: port} do
    client = authed!(port)

    {:ok, _, _} = WSClient.request(client, "vfs/subscribe", %{"paths" => ["/docs"]}, 1)
    assert VFSPubSub.watchers(@backend, "/docs") != []

    WSClient.close(client)
    Process.sleep(50)

    assert VFSPubSub.watchers(@backend, "/docs") == []
  end

  # ── keepalive ─────────────────────────────────────────────────────────────

  test "the server pings and drops the connection after missed pongs", %{port: _port, ctx: ctx} do
    port =
      start_bandit(
        [
          server: MemoryServer,
          context: fn _claims -> %{tree: ctx.assigns.tree} end,
          keepalive_ms: 50
        ] ++ auth_opts()
      )

    client = authed!(port, auto_pong?: false)

    # Three pings at 50 ms with no pongs → drop. The client sees the close.
    assert {:closed, _, _} = WSClient.recv(client, 1000)
  end
end
