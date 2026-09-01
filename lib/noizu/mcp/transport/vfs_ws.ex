if Code.ensure_loaded?(Plug.Conn) and Code.ensure_loaded?(Bandit) and Code.ensure_loaded?(WebSock) do
  defmodule Noizu.MCP.Transport.VFSWS do
    @moduledoc """
    WebSocket VFS transport: a Plug that upgrades `GET /vfs` (bandit-hosted)
    into a WebSocket speaking the `vfs/*` operation family directly — the
    TCP-addressable sibling of `Noizu.MCP.Transport.VFSSocket` (the unix-socket
    M2 transport), plus live change events.

        children = [
          {Bandit,
           plug: {Noizu.MCP.Transport.VFSWS,
            server: MyApp.MCP,
            auth: [verifier: {Noizu.MCP.Auth.ApiKeyVerifier, keys: [...]}],
            context: {MyApp.MCP, :vfs_assigns}},
           port: 4100}
        ]

    ## Wire protocol (JSON text frames, one message per frame, envelope `v: 2`)

      * **Upgrade** — when `:auth` is configured the request must carry a valid
        `Authorization: Bearer` header (same verifier pipeline as
        `Noizu.MCP.Transport.StreamableHTTP.Plug`); failures are rejected 401
        before the socket exists.
      * **Handshake** — the *first* frame must be
        `{"v": 2, "id": ..., "method": "vfs/auth", "params": {"api_key" | "token": "..."}}`
        with the same semantics as the socket transport: identity binds to the
        connection's `Noizu.MCP.Ctx` (`assigns.auth_claims` plus any
        `context/1` assigns); failure or any other method first draws a
        `-32001` error and the connection closes; a second `vfs/auth` is
        `-32600`.
      * **Requests** — `{"v": 2, "id": ..., "method": "vfs/stat", "params": {...}}`
        over the same op set as the socket transport (`vfs/stat|list|read|
        write|create|remove|search|xattr`), dispatched through
        `Noizu.MCP.Server.Features.VFS` so caching, pagination, and
        authorization match. Responses are `{"v": 2, "id": ..., "result"|"error"}`;
        all wire maps are string-keyed and errors carry the errno→code map
        (`-32040..-32046`, `:eio` → `-32048`) with `error.data.errno_atom`, as on
        the socket.
      * **Events** — `vfs/subscribe {"paths": ["/docs"], "depth": n|"infinity"}`
        registers a subtree watch (`Noizu.MCP.Server.VFSPubSub`); mutating
        writes anywhere under a watched path push
        `{"v": 2, "type": "vfs/event", "seq": ..., "op": "write", "path": ...,
        "version": ..., "by": ..., "at": ...}` — metadata only, coalesced per
        path (50 ms debounce, final version wins). `vfs/unsubscribe` stops the
        watch. Per-connection watch cap 10_000 → `-32047`.
      * **Ping** — `vfs/ping` replies `{"pong": true}`; the server also sends
        WebSocket-level pings every 30 s (`:keepalive_ms` to override) and
        drops the connection after two missed pongs.
      * **Malformed frames** draw a parse/invalid-request error; the
        connection stays open.
    """

    @behaviour Plug

    import Plug.Conn
    require Logger

    alias Noizu.MCP.Server.VFSPubSub

    @impl Plug
    # ⟦𓆒⟧ init
    def init(opts) do
      %{
        server: Keyword.fetch!(opts, :server),
        path: Keyword.get(opts, :path, "/vfs"),
        auth: Keyword.get(opts, :auth),
        context: Keyword.get(opts, :context),
        keepalive_ms: Keyword.get(opts, :keepalive_ms, 30_000)
      }
    end

    @impl Plug
    # ⟦𓆒⟧ call
    def call(conn, opts) do
      cond do
        conn.method != "GET" ->
          send_resp(conn, 405, "Method not allowed")

        conn.path_info != path_segments(opts.path) ->
          send_resp(conn, 404, "Not found")

        not websocket_request?(conn) ->
          send_resp(conn, 400, "Not a websocket upgrade request")

        true ->
          case authenticate(conn, opts.auth) do
            {:ok, conn} -> upgrade(conn, opts)
            {:halt, conn} -> conn
          end
      end
    end

    defp path_segments(path) do
      path |> String.split("/", trim: true) |> Enum.map(&URI.decode/1)
    end

    defp websocket_request?(conn) do
      get_req_header(conn, "upgrade") |> Enum.any?(&(&1 =~ ~r/websocket/i)) and
        get_req_header(conn, "sec-websocket-key") != []
    end

    # Same bearer+verifier pipeline as the StreamableHTTP plug, lifted onto
    # the upgrade request so unauthenticated sockets are never created.
    defp authenticate(conn, nil), do: {:ok, conn}

    defp authenticate(conn, auth) do
      {verifier, verifier_opts} = normalize_verifier(Keyword.fetch!(auth, :verifier))

      case bearer_token(conn) do
        nil ->
          {:halt,
           conn
           |> put_resp_header(
             "www-authenticate",
             Noizu.MCP.Auth.WWWAuthenticate.bearer_challenge(error: nil)
           )
           |> send_resp(401, "Unauthorized")}

        token ->
          conn_info = %{method: conn.method, peer: conn.remote_ip, headers: conn.req_headers}

          case verifier.verify(token, conn_info, verifier_opts) do
            {:ok, claims} -> {:ok, assign(conn, :mcp_auth_claims, claims)}
            {:error, _} -> {:halt, send_resp(conn, 401, "Unauthorized")}
          end
      end
    end

    defp normalize_verifier({module, opts}), do: {module, opts}
    defp normalize_verifier(module) when is_atom(module), do: {module, []}

    defp bearer_token(conn) do
      case get_req_header(conn, "authorization") do
        ["Bearer " <> token | _] -> token
        ["bearer " <> token | _] -> token
        _ -> nil
      end
    end

    defp upgrade(conn, opts) do
      Plug.Conn.upgrade_adapter(conn, :websocket, {__MODULE__.Sock, opts, []})
    end

    defmodule Sock do
      @moduledoc false
      # Per-connection WebSock handler: owns the auth handshake, the op
      # dispatch loop, and the subscription set (it registers itself with
      # VFSPubSub, so a dead connection unregisters automatically).

      @behaviour WebSock

      alias Noizu.MCP.{Ctx, Error}
      alias Noizu.MCP.Server.Features.VFS
      alias Noizu.MCP.Server.VFSPubSub

      @auth_code -32001
      @ewouldwatch_code -32047

      @impl WebSock
      def init(opts) do
        Process.send_after(self(), :vfs_ws_ping, opts.keepalive_ms)
        {:ok, %{opts: opts, ctx: nil, missed_pongs: 0}}
      end

      # ── inbound frames ────────────────────────────────────────────────────

      @impl WebSock
      def handle_in({data, opcode: :text}, state) when is_binary(data) do
        case Jason.decode(data) do
          {:ok, %{} = frame} -> route(frame, state)
          _ -> push_error(nil, Error.parse_error("invalid json"), state)
        end
      end

      def handle_in({data, opcode: :binary}, state) when is_binary(data) do
        push_error(nil, Error.invalid_request("binary frames not supported"), state)
      end

      @impl WebSock
      def handle_control({_data, opcode: :pong}, state) do
        {:ok, %{state | missed_pongs: 0}}
      end

      def handle_control(_frame, state), do: {:ok, state}

      # ── routing ───────────────────────────────────────────────────────────

      defp route(%{"method" => "vfs/auth"} = frame, %{ctx: nil} = state) do
        authenticate(frame, state)
      end

      defp route(%{"method" => "vfs/auth", "id" => id}, state) do
        push_error(id, Error.invalid_request("connection already authenticated"), state)
      end

      defp route(%{"method" => method} = frame, state) when is_binary(method) do
        case state.ctx do
          nil ->
            # Same handshake rule as the socket transport: the first frame
            # must be vfs/auth; anything else closes the connection.
            {:stop, :normal, 1008,
             [
               {:text,
                error_frame(
                  frame["id"],
                  Error.custom(@auth_code, "vfs/auth required before #{method}")
                )}
             ], state}

          ctx ->
            dispatch(frame, method, ctx, state)
        end
      end

      defp route(_frame, state) do
        push_error(nil, Error.invalid_request("invalid request"), state)
      end

      defp authenticate(%{"id" => id} = frame, state) do
        params = frame["params"] || %{}
        api_key = params["api_key"] || params["token"]

        conn_info = %{transport: :vfs_ws}

        case verify(state.opts[:auth], api_key, conn_info) do
          {:ok, claims} ->
            ctx = build_ctx(state.opts[:server], claims, state.opts)

            push_result(id, %{"authenticated" => true, "session_id" => ctx.session_id}, %{
              state
              | ctx: ctx
            })

          {:error, reason} ->
            Logger.warning("MCP VFS websocket auth rejected: #{inspect(reason)}")

            {:stop, :normal, 1008,
             [{:text, error_frame(id, Error.custom(@auth_code, "vfs auth failed"))}], state}
        end
      end

      defp dispatch(frame, method, ctx, state) do
        id = frame["id"]
        params = frame["params"] || %{}
        server = state.opts[:server]

        cond do
          op = op_for(method, server) ->
            case op.(server, params, ctx) do
              {:ok, value} ->
                push_result(id, deep_stringify(value), state)

              {:error, %Error{}} = error ->
                push_error(id, elem(error, 1), state)

              {:error, other} ->
                push_error(id, Error.internal("vfs error: #{inspect(other)}"), state)
            end

          method == "vfs/ping" ->
            push_result(id, %{"pong" => true}, state)

          method == "vfs/subscribe" ->
            subscribe(id, params, state)

          method == "vfs/unsubscribe" ->
            unsubscribe(id, params, state)

          true ->
            push_error(id, Error.method_not_found(method), state)
        end
      end

      defp op_for("vfs/stat", _), do: &VFS.vfs_stat/3
      defp op_for("vfs/list", _), do: &VFS.vfs_list/3
      defp op_for("vfs/read", _), do: &VFS.vfs_read/3
      defp op_for("vfs/write", _), do: &VFS.vfs_write/3
      defp op_for("vfs/create", _), do: &VFS.vfs_create/3
      defp op_for("vfs/remove", _), do: &VFS.vfs_remove/3
      defp op_for("vfs/search", _), do: &VFS.vfs_search/3
      defp op_for("vfs/xattr", _), do: &VFS.vfs_xattr/3
      defp op_for(_, _), do: nil

      defp subscribe(id, params, state) do
        paths = params["paths"]

        depth =
          case params["depth"] do
            "infinity" -> :infinity
            n when is_integer(n) and n >= 0 -> n
            _ -> :infinity
          end

        with {:ok, backend} <- backend(state),
             paths when is_list(paths) and paths != [] <- paths do
          case VFSPubSub.watch(backend, paths, depth: depth) do
            :ok ->
              push_result(id, %{"subscribed" => true}, state)

            {:error, :ewouldwatch} ->
              push_error(id, Error.custom(@ewouldwatch_code, "vfs watch cap exceeded"), state)

            {:error, :ebaddepth} ->
              push_error(id, Error.invalid_params("vfs/subscribe requires a valid depth"), state)
          end
        else
          {:error, %Error{}} = error -> push_error(id, elem(error, 1), state)
          _ -> push_error(id, Error.invalid_params("vfs/subscribe requires paths"), state)
        end
      end

      defp unsubscribe(id, params, state) do
        with {:ok, backend} <- backend(state),
             paths when is_list(paths) and paths != [] <- params["paths"] do
          VFSPubSub.unwatch(backend, paths)
          push_result(id, %{"unsubscribed" => true}, state)
        else
          {:error, %Error{}} = error -> push_error(id, elem(error, 1), state)
          _ -> push_error(id, Error.invalid_params("vfs/unsubscribe requires paths"), state)
        end
      end

      defp backend(state) do
        case state.opts[:server].__mcp__(:vfs) do
          [{backend, _opts} | _] -> {:ok, backend}
          _ -> {:error, Error.capability_not_supported("vfs")}
        end
      end

      # ── server pushes ─────────────────────────────────────────────────────

      @impl WebSock
      def handle_info({:vfs_event, event}, state) do
        frame =
          Jason.encode_to_iodata!(%{
            "v" => 2,
            "type" => "vfs/event",
            "seq" => event.seq,
            "op" => Atom.to_string(event.op),
            "path" => event.path,
            "version" => event.version,
            "by" => event.by,
            "at" => event.at
          })

        {:push, {:text, frame}, state}
      end

      def handle_info(:vfs_ws_ping, state) do
        Process.send_after(self(), :vfs_ws_ping, state.opts.keepalive_ms)

        if state.missed_pongs >= 2 do
          Logger.warning("MCP VFS websocket dropped after missed pongs")
          {:stop, :normal, state}
        else
          {:push, :ping, %{state | missed_pongs: state.missed_pongs + 1}}
        end
      end

      def handle_info(_msg, state), do: {:ok, state}

      @impl WebSock
      def terminate(_reason, _state), do: :ok

      # ── auth plumbing (mirrors VFSSocket) ─────────────────────────────────

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

      defp build_ctx(server, claims, opts) do
        extra =
          case opts[:context] do
            {module, fun} -> apply(module, fun, [claims])
            fun when is_function(fun, 1) -> fun.(claims)
            nil -> %{}
          end

        %Ctx{
          server: server,
          session_id: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
          transport: :vfs_ws,
          assigns: Map.put(Map.new(extra), :auth_claims, claims)
        }
      end

      # ── wire helpers (mirror VFSSocket: string-keyed, errno atoms) ────────

      defp push_result(id, value, state) do
        {:push, {:text, Jason.encode_to_iodata!(%{"v" => 2, "id" => id, "result" => value})},
         state}
      end

      defp push_error(id, %Error{} = error, state) do
        {:push, {:text, error_frame(id, error)}, state}
      end

      defp error_frame(id, %Error{} = error) do
        Jason.encode_to_iodata!(%{
          "v" => 2,
          "id" => id,
          "error" => error_object(error)
        })
      end

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
    end
  end
end
