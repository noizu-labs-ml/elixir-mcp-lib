defmodule McpMount.WSConn do
  @moduledoc """
  Real `McpMount.Conn` implementation: mint + mint_web_socket client speaking
  the v2 JSON text-frame protocol at `ws://host:port/vfs`. `connect/1` runs
  the TCP connect, WS upgrade and `vfs/auth` handshake before returning, so a
  successful connect implies an authenticated connection.
  """

  use GenServer

  require Logger

  @behaviour McpMount.Conn

  @default_timeout 5_000
  @keepalive_ms 20_000
  @stale_ms 60_000

  defstruct [:conn, :ref, :websocket, :owner, :awaiting, :next_id, :last_recv, :ping_timer]

  # ── Conn API ──────────────────────────────────────────────────────────────

  @impl McpMount.Conn
  def connect(opts) do
    case GenServer.start_link(__MODULE__, opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:auth_failed, _reason}} -> {:error, :auth_failed}
      {:error, {:handshake_failed, reason}} -> {:error, {:handshake_failed, reason}}
      {:error, reason} -> {:error, reason}
      {:error, _reason, _stack} = other -> other
    end
  end

  @impl McpMount.Conn
  def call(pid, method, params, timeout \\ @default_timeout) when is_pid(pid) do
    GenServer.call(pid, {:call, method, params}, timeout + 1_000)
  end

  @impl McpMount.Conn
  def subscribe(pid, paths, depth) do
    depth_wire = if depth == :infinity, do: "infinity", else: depth

    call(pid, "vfs/subscribe", %{"paths" => paths, "depth" => depth_wire})
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @impl McpMount.Conn
  def unsubscribe(pid, paths) do
    case call(pid, "vfs/unsubscribe", %{"paths" => paths}) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @impl McpMount.Conn
  def close(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal)
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    url = Keyword.fetch!(opts, :url)
    token = Keyword.fetch!(opts, :token)
    owner = Keyword.fetch!(opts, :owner)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # start_link linked us to the owner; death is signalled via the owner's
    # monitor instead, so a killed conn doesn't take the mounter down.
    Process.unlink(owner)

    with {:ok, parts} <- parse_url(url, token),
         {:ok, conn, ref, websocket} <- handshake(parts, timeout),
         {:ok, conn, websocket} <- auth(conn, ref, websocket, token, owner, timeout) do
      {:ok, ping_timer} = :timer.send_after(@keepalive_ms, :keepalive)

      {:ok,
       %__MODULE__{
         conn: conn,
         ref: ref,
         websocket: websocket,
         owner: owner,
         awaiting: %{},
         next_id: 0,
         last_recv: now(),
         ping_timer: ping_timer
       }}
    else
      {:error, reason} -> {:stop, {:shutdown, reason}}
      {:error, reason, _responses} -> {:stop, {:shutdown, reason}}
    end
  end

  defp parse_url(url, token) do
    uri = URI.parse(url)
    default_port = if uri.scheme == "wss", do: 443, else: 80

    if uri.host in [nil, ""] do
      {:error, {:bad_url, url}}
    else
      {:ok,
       %{
         transport: if(uri.scheme == "wss", do: :https, else: :http),
         ws_scheme: if(uri.scheme == "wss", do: :wss, else: :ws),
         host: uri.host,
         port: uri.port || default_port,
         path: if(uri.path in [nil, ""], do: "/", else: uri.path),
         token: token
       }}
    end
  end

  defp handshake(parts, timeout) do
    headers = [{"authorization", "Bearer " <> parts.token}]

    # Pin HTTP/1.1: mint_web_socket upgrades over h1 only, and on TLS
    # endpoints mint's ALPN otherwise negotiates h2 → the upgrade fails with
    # {:shutdown, %Mint.HTTP2{}} (plain ws:// was unaffected, so the
    # local-test suite never saw this).
    with {:ok, conn} <- Mint.HTTP.connect(parts.transport, parts.host, parts.port, protocols: [:http1]),
         # :wss vs :ws matters: mint_web_socket keys its h1 send/recv
         # transport (:ssl vs :gen_tcp) off this scheme — passing :ws on a
         # TLS socket made every frame send hit gen_tcp.send(sslsocket).
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(parts.ws_scheme, conn, parts.path, headers),
         {:ok, conn, status, headers} <- await_upgrade(conn, ref, timeout),
         101 <- status,
         {:ok, conn, websocket} <- Mint.WebSocket.new(conn, ref, status, headers) do
      {:ok, conn, ref, websocket}
    end
  end

  defp await_upgrade(conn, ref, timeout) do
    receive do
      msg ->
        case Mint.WebSocket.stream(conn, msg) do
          {:ok, conn, responses} ->
            status =
              Enum.find_value(responses, fn
                {:status, ^ref, s} -> s
                _ -> nil
              end)

            headers =
              Enum.find_value(responses, fn
                {:headers, ^ref, h} -> h
                _ -> nil
              end)

            cond do
              status == 101 and headers != nil ->
                {:ok, conn, status, headers}

              status != nil and status >= 400 ->
                {:error, {:handshake_failed, status}}

              true ->
                await_upgrade(conn, ref, timeout)
            end

          {:error, conn, reason, _responses} ->
            Mint.HTTP.close(conn)
            {:error, {:handshake_failed, reason}}
        end
    after
      timeout -> {:error, {:handshake_failed, :timeout}}
    end
  end

  # The handshake MUST be vfs/auth; a non-ok result aborts startup.
  defp auth(conn, ref, websocket, token, _owner, timeout) do
    id = 1

    frame =
      Jason.encode!(%{
        "v" => 2,
        "id" => id,
        "method" => "vfs/auth",
        "params" => %{"token" => token}
      })

    with {:ok, websocket, data} <- Mint.WebSocket.encode(websocket, {:text, frame}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, ref, data) do
      await_auth(conn, ref, websocket, id, timeout)
    end
  end

  defp await_auth(conn, ref, websocket, id, timeout) do
    receive do
      msg ->
        case Mint.WebSocket.stream(conn, msg) do
          {:ok, conn, responses} ->
            {conn, websocket, frames} = extract(conn, ref, websocket, responses)

            case find_response(frames, id) do
              {:ok, _result} ->
                {:ok, conn, websocket}

              {:error, error} ->
                Mint.HTTP.close(conn)
                {:error, {:auth_failed, error}}

              nil ->
                await_auth(conn, ref, websocket, id, timeout)
            end

          {:error, conn, reason, _responses} ->
            Mint.HTTP.close(conn)
            {:error, {:auth_failed, reason}}
        end
    after
      timeout -> {:error, {:auth_failed, :timeout}}
    end
  end

  @impl GenServer
  def handle_call({:call, method, params}, from, state) do
    id = state.next_id + 1
    frame = Jason.encode!(%{"v" => 2, "id" => id, "method" => method, "params" => params})

    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, {:text, frame}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
      {:noreply,
       %{
         state
         | conn: conn,
           websocket: websocket,
           next_id: id,
           awaiting: Map.put(state.awaiting, id, from)
       }}
    else
      {:error, _conn, _reason, _responses} ->
        {:reply, {:error, :closed}, state}

      {:error, %Mint.WebSocketError{} = reason} ->
        {:reply, {:error, {:ws_error, reason}}, state}
    end
  end

  @impl GenServer
  def handle_info(:keepalive, state) do
    {:ok, ping_timer} = :timer.send_after(@keepalive_ms, :keepalive)

    if now() - state.last_recv > @stale_ms do
      {:stop, :normal, %{state | ping_timer: ping_timer}}
    else
      case Mint.WebSocket.encode(state.websocket, {:ping, "keepalive"}) do
        {:ok, websocket, data} ->
          {:ok, conn} = Mint.WebSocket.stream_request_body(state.conn, state.ref, data)
          {:noreply, %{state | conn: conn, websocket: websocket, ping_timer: ping_timer}}

        _ ->
          {:noreply, %{state | ping_timer: ping_timer}}
      end
    end
  end

  def handle_info(msg, state) do
    # A malformed/unexpected transport or stream result must never kill the
    # connection — observed live as case_clause crashes that drop the mount
    # into reconnect churn. Log and ride through instead.
    try do
      case Mint.WebSocket.stream(state.conn, msg) do
        {:ok, conn, responses} ->
          {conn, websocket, frames} = extract(conn, state.ref, state.websocket, responses)
          state = %{state | conn: conn, websocket: websocket, last_recv: now()}
          state = Enum.reduce(frames, state, &handle_frame/2)
          {:noreply, state}

        {:error, conn, reason, _responses} ->
          Mint.HTTP.close(conn)
          notify_down(state.owner, reason)
          {:stop, :normal, state}

        other ->
          Logger.warning(
            "mcp-mount: unexpected stream return #{inspect(other)} (msg #{inspect(msg)})"
          )

          {:noreply, state}
      end
    rescue
      e ->
        Logger.warning("mcp-mount: stream error #{Exception.message(e)} (msg #{inspect(msg)})")
        {:noreply, state}
    end
  end

  # ── frame plumbing ────────────────────────────────────────────────────────

  defp extract(conn, ref, websocket, responses) do
    Enum.reduce(responses, {conn, websocket, []}, fn
      {:data, ^ref, data}, {conn, websocket, frames} ->
        case Mint.WebSocket.decode(websocket, data) do
          {:ok, websocket, more} -> {conn, websocket, frames ++ more}
          {:error, _websocket, _reason} -> {conn, websocket, frames}
        end

      _other, acc ->
        acc
    end)
  end

  defp find_response(frames, id) do
    Enum.find_value(frames, fn
      {:text, text} ->
        case Jason.decode(text) do
          {:ok, %{"id" => ^id, "result" => result}} -> {:ok, result}
          {:ok, %{"id" => ^id, "error" => error}} -> {:error, error}
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp handle_frame({:text, text}, state) do
    case Jason.decode(text) do
      {:ok, %{"type" => "vfs/event"} = event} ->
        send(state.owner, {:mcp_mount_event, normalize_event(event)})
        state

      {:ok, %{"id" => id, "result" => result}} ->
        reply_awaiting(state, id, {:ok, result})

      {:ok, %{"id" => id, "error" => error}} ->
        reply_awaiting(state, id, {:error, normalize_error(error)})

      _ ->
        state
    end
  end

  defp handle_frame({:ping, payload}, state) do
    case Mint.WebSocket.encode(state.websocket, {:pong, payload}) do
      {:ok, websocket, data} ->
        {:ok, conn} = Mint.WebSocket.stream_request_body(state.conn, state.ref, data)
        %{state | conn: conn, websocket: websocket}

      {:error, websocket, _reason} ->
        %{state | websocket: websocket}
    end
  end

  defp handle_frame({:pong, _payload}, state), do: state

  defp handle_frame({:close, code, reason}, state) do
    notify_down(state.owner, {:ws_close, code, reason})
    send(self(), :ws_closed)
    state
  end

  # Reserved/unknown opcodes decode to the bare atom :unknown; binary frames
  # arrive as {:binary, _}. Neither is part of the v2 protocol — ignore rather
  # than crash the conn (seen live against the stage server).
  defp handle_frame(frame, state) do
    Logger.debug("mcp-mount: ignoring frame #{inspect(frame)}")
    state
  end

  defp reply_awaiting(state, id, reply) do
    case Map.pop(state.awaiting, id) do
      {nil, _} ->
        state

      {from, awaiting} ->
        GenServer.reply(from, reply)
        %{state | awaiting: awaiting}
    end
  end

  defp normalize_event(event) do
    %{
      op: event["op"],
      path: event["path"],
      version: event["version"],
      seq: event["seq"],
      by: event["by"],
      at: event["at"]
    }
  end

  defp normalize_error(error) do
    errno =
      case get_in(error, ["data", "errno_atom"]) do
        atom when is_binary(atom) -> String.to_existing_atom(atom)
        _ -> nil
      end

    %{code: error["code"], errno: errno, message: error["message"]}
  rescue
    _ -> %{code: error["code"], errno: nil, message: error["message"]}
  end

  defp notify_down(owner, reason), do: send(owner, {:mcp_mount_down, reason})

  defp now, do: System.monotonic_time(:millisecond)
end
