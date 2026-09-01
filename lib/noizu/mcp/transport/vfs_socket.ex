defmodule Noizu.MCP.Transport.VFSSocket do
  @moduledoc """
  Unix-domain-socket VFS transport: a length-prefixed JSON-RPC listener that
  speaks the `vfs/*` operation family directly (no `initialize` handshake).

  Started as a child of the server supervision tree via
  `transport: {:vfs_socket, opts}` (or `transport: :vfs_socket`):

      children = [
        {MyApp.MCP,
         transport: {:vfs_socket,
          socket_path: "/run/mcp/vfs.sock",
          auth: [verifier: {Noizu.MCP.Auth.ApiKeyVerifier, keys: [{"mcp_live_...", %{}}]}],
          context: {MyApp.MCP, :vfs_assigns}}}
      ]

  ## Wire protocol (reference for non-Elixir clients — see
  `Noizu.MCP.Transport.VFSClient` for the Elixir implementation)

    * **Framing** — each frame is a 4-byte big-endian unsigned length prefix
      followed by exactly one JSON-RPC 2.0 message.
    * **Handshake** — the *first* frame on a connection must be a
      `vfs/auth` request: `{"method": "vfs/auth", "params": {"api_key": "..."}}`.
      The key is validated through the configured token verifier
      (`Noizu.MCP.Auth.*Verifier`); on success the resulting claims are bound
      to the connection's `Noizu.MCP.Ctx` (as `assigns.auth_claims`, plus any
      `context/1` assigns) and every subsequent operation on the connection
      runs under that identity. On failure the connection receives an error
      response and is closed. Any other method before `vfs/auth` is refused
      the same way; a second `vfs/auth` after success is an `invalid_request`.
    * **Operations** — `vfs/stat`, `vfs/list`, `vfs/read`, `vfs/write`,
      `vfs/create`, `vfs/remove`, `vfs/search`, `vfs/xattr`, with params
      `{path, cursor?, query?, root?, data?, version?}` (string-keyed). They
      route through `Noizu.MCP.Server.Features.VFS`, so caching, pagination,
      and authorization behave exactly as they do on the MCP-native surface.
    * **Responses** — results are string-keyed maps (`type` values render as
      strings). Errors carry the errno→code mapping from
      `Noizu.MCP.Server.Features.VFS.errno_error/1` (`:enoent` → `-32002`
      resource_not_found, `:eacces` → `-32040`, `:eexist` → `-32041`,
      `:erofs` → `-32042`, `:eisdir` → `-32043`, `:enotdir` → `-32044`,
      `:enotempty` → `-32045`, `:enosys` → `-32046`, `:eio` → `-32048`) with
      the originating errno echoed as `error.data.errno_atom` (e.g.
      `"eisdir"`). Failed auth uses `-32001`.
    * **Malformed frames** — a frame that is not valid JSON-RPC 2.0 draws a
      parse/invalid-request error response; the connection stays open.
  """

  use GenServer
  require Logger

  alias Noizu.MCP.{Ctx, Error, JsonRpc}
  alias Noizu.MCP.Server.Features.VFS

  @auth_code -32001
  @default_mode 0o600
  @default_max_frame 16 * 1024 * 1024

  # ── Supervisor child ──────────────────────────────────────────────────────

  # ⟦𓁍𓌍𓇇𓎀⟧ start_link :: auto-generated pointer for public function start_link
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  # ── Process ───────────────────────────────────────────────────────────────

  @impl GenServer
  # ⟦𓄸𓊇𓂁𓇇⟧ init :: auto-generated pointer for public function init
  def init(opts) do
    Process.flag(:trap_exit, true)
    server = Keyword.fetch!(opts, :server)
    socket_path = Keyword.get(opts, :socket_path) || default_path(server)
    max_frame = Keyword.get(opts, :max_frame, @default_max_frame)

    File.rm(socket_path)

    listen_opts = [
      :binary,
      packet: 4,
      packet_size: max_frame,
      active: false,
      reuseaddr: true,
      ip: {:local, String.to_charlist(socket_path)}
    ]

    case :gen_tcp.listen(0, listen_opts) do
      {:ok, listen} ->
        mode = Keyword.get(opts, :mode, @default_mode)
        File.chmod(socket_path, mode)

        acceptors = Keyword.get(opts, :acceptors, System.schedulers_online())
        parent = self()

        for _ <- 1..acceptors do
          spawn_link(fn -> acceptor(parent, listen, server, opts) end)
        end

        Logger.info("MCP VFS socket transport listening on #{socket_path}")

        {:ok, %{server: server, listen: listen, socket_path: socket_path}}

      {:error, reason} ->
        {:stop, {:socket_error, reason}}
    end
  end

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    catch_close(state.listen)
    File.rm(state.socket_path)
    :ok
  end

  # ── acceptors ─────────────────────────────────────────────────────────────

  defp acceptor(parent, listen, server, opts) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        me = self()
        conn = spawn(fn -> connection({:connected, sock}, server, opts) end)
        :gen_tcp.controlling_process(sock, conn)
        send(conn, {:go, me})

        receive do
          {:accepted, ^conn} -> :ok
        end

        acceptor(parent, listen, server, opts)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.error("MCP VFS socket transport accept error: #{inspect(reason)}")
        send(parent, {:accept_failed, self()})
        :ok
    end
  end

  # ── connection loop ───────────────────────────────────────────────────────

  defp connection({:connected, sock}, server, opts) do
    receive do
      {:go, from} ->
        send(from, {:accepted, self()})
        await_auth(sock, server, opts)
    end
  end

  # First frame must be vfs/auth; anything else is refused and the
  # connection is closed.
  defp await_auth(sock, server, opts) do
    case :gen_tcp.recv(sock, 0) do
      {:ok, frame} ->
        case JsonRpc.decode(frame) do
          {:ok, %JsonRpc.Request{id: id, method: "vfs/auth", params: params}} ->
            authenticate(sock, server, opts, id, params)

          {:ok, %JsonRpc.Request{id: id, method: method}} ->
            auth_error(sock, id, "vfs/auth required before #{method}")

          {:ok, %JsonRpc.Notification{}} ->
            await_auth(sock, server, opts)

          {:error, %JsonRpc.ErrorResponse{id: id, error: error}} ->
            send_error(sock, id, error)
            await_auth(sock, server, opts)
        end

      {:error, _closed} ->
        close(sock)
    end
  end

  defp authenticate(sock, server, opts, id, params) do
    api_key = (params || %{})["api_key"]
    conn_info = %{transport: :vfs_socket}

    case verify(Keyword.get(opts, :auth), api_key, conn_info) do
      {:ok, claims} ->
        ctx = build_ctx(server, claims, opts)
        send_result(sock, id, %{"authenticated" => true, "session_id" => ctx.session_id})
        serve(sock, server, opts, ctx)

      {:error, reason} ->
        Logger.warning("MCP VFS socket auth rejected: #{inspect(reason)}")
        auth_error(sock, id, "vfs auth failed")
    end
  end

  defp verify(nil, _key, _conn_info), do: {:ok, %{}}

  defp verify(auth, key, conn_info) when is_binary(key) do
    {verifier, verifier_opts} =
      auth
      |> Keyword.get(:verifier, auth)
      |> normalize_verifier()

    verifier.verify(key, conn_info, verifier_opts)
  end

  defp verify(_auth, _key, _conn_info), do: {:error, :invalid_token}

  defp normalize_verifier({module, opts}), do: {module, opts}
  defp normalize_verifier(module) when is_atom(module), do: {module, []}

  defp auth_error(sock, id, message) do
    send_error(sock, id, Error.custom(@auth_code, message))
    close(sock)
  end

  defp serve(sock, server, opts, ctx) do
    case :gen_tcp.recv(sock, 0) do
      {:ok, frame} ->
        case JsonRpc.decode(frame) do
          {:ok, %JsonRpc.Request{id: id, method: method, params: params}} ->
            dispatch(sock, server, opts, ctx, id, method, params)

          {:ok, %JsonRpc.Notification{}} ->
            serve(sock, server, opts, ctx)

          {:error, %JsonRpc.ErrorResponse{id: id, error: error}} ->
            send_error(sock, id, error)
            serve(sock, server, opts, ctx)
        end

      {:error, _closed} ->
        close(sock)
    end
  end

  defp dispatch(sock, server, opts, ctx, id, "vfs/auth", _params) do
    send_error(sock, id, Error.invalid_request("connection already authenticated"))
    serve(sock, server, opts, ctx)
  end

  defp dispatch(sock, server, opts, ctx, id, method, params) do
    case op(method) do
      nil ->
        send_error(sock, id, Error.method_not_found(method))
        serve(sock, server, opts, ctx)

      fun ->
        case fun.(server, params, ctx) do
          {:ok, value} ->
            send_result(sock, id, deep_stringify(value))

          {:error, %Error{} = error} ->
            send_error(sock, id, error)

          {:error, other} ->
            send_error(sock, id, Error.internal("vfs error: #{inspect(other)}"))
        end

        serve(sock, server, opts, ctx)
    end
  end

  defp op("vfs/stat"), do: &VFS.vfs_stat/3
  defp op("vfs/list"), do: &VFS.vfs_list/3
  defp op("vfs/read"), do: &VFS.vfs_read/3
  defp op("vfs/write"), do: &VFS.vfs_write/3
  defp op("vfs/create"), do: &VFS.vfs_create/3
  defp op("vfs/remove"), do: &VFS.vfs_remove/3
  defp op("vfs/search"), do: &VFS.vfs_search/3
  defp op("vfs/xattr"), do: &VFS.vfs_xattr/3
  defp op(_), do: nil

  # ── ctx ───────────────────────────────────────────────────────────────────

  defp build_ctx(server, claims, opts) do
    extra =
      case Keyword.get(opts, :context) do
        {module, fun} -> apply(module, fun, [claims])
        fun when is_function(fun, 1) -> fun.(claims)
        nil -> %{}
      end

    %Ctx{
      server: server,
      session_id: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
      transport: :vfs_socket,
      assigns: Map.put(Map.new(extra), :auth_claims, claims)
    }
  end

  # ── wire helpers ──────────────────────────────────────────────────────────

  defp send_result(sock, id, value) do
    send_frame(sock, JsonRpc.encode!(%JsonRpc.Response{id: id, result: value}))
  end

  defp send_error(sock, id, %Error{} = error) do
    send_frame(
      sock,
      Jason.encode_to_iodata!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => error_object(error)
      })
    )
  end

  defp send_frame(sock, iodata) do
    :gen_tcp.send(sock, iodata)
  end

  # Results carry atom keys/values internally (VFS nodes, list entries,
  # search matches); the wire contract is string keys and string enum values.
  defp deep_stringify(%_struct{} = value), do: value

  defp deep_stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {key_string(k), deep_stringify(v)} end)
  end

  defp deep_stringify(list) when is_list(list), do: Enum.map(list, &deep_stringify/1)
  defp deep_stringify(nil), do: nil
  defp deep_stringify(v) when is_boolean(v), do: v
  defp deep_stringify(v) when is_atom(v), do: Atom.to_string(v)
  defp deep_stringify(other), do: other

  defp key_string(k) when is_atom(k), do: Atom.to_string(k)
  defp key_string(k) when is_binary(k), do: k

  # Error objects carry the errno→code mapping plus `errno_atom` so Go
  # clients can switch on the errno without re-deriving it from the code.
  defp error_object(%Error{reason: :resource_not_found} = error) do
    error
    |> Error.to_map()
    |> Map.update("data", %{}, fn data -> Map.put(data || %{}, "errno_atom", "enoent") end)
  end

  defp error_object(%Error{} = error) do
    map = Error.to_map(error)

    case error.data do
      %{errno: errno} when is_atom(errno) ->
        Map.put(map, "data", %{"errno_atom" => Atom.to_string(errno)})

      _ ->
        map
    end
  end

  defp close(sock) do
    catch_close(sock)
    exit(:normal)
  end

  defp catch_close(sock) do
    :gen_tcp.close(sock)
  catch
    _, _ -> :ok
  end

  defp default_path(server) do
    name = server |> server_info_name() |> String.replace(~r/[^\w.-]/, "_")
    Path.join(System.tmp_dir(), "mcp-vfs-#{name}.sock")
  end

  defp server_info_name(server) do
    server.server_info().name
  rescue
    _ -> "unnamed"
  end
end
