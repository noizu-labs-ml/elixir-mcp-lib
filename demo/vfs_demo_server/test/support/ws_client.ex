defmodule VfsDemoServer.WSClient do
  @moduledoc """
  Minimal sequential WebSocket client (mint_web_socket, passive mode) for
  endpoint tests — same style as the lib transport's own test client. Incoming
  frames are buffered, so frames arriving between `recv_frame/2` calls are not
  lost; server pings are answered automatically.
  """

  use GenServer

  defstruct [:conn, :ref, :ws, queue: [], closed: false]

  def connect(port, token \\ VfsDemoServer.token(), path \\ "/vfs", timeout \\ 5_000) do
    headers = [{"authorization", "Bearer " <> token}]

    with {:ok, conn} <- Mint.HTTP.connect(:http, "127.0.0.1", port, mode: :passive),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(:ws, conn, path, headers),
         {:ok, conn, responses} <- Mint.HTTP.recv(conn, 0, timeout) do
      with {:ok, 101, resp_headers} <- upgrade_response(responses, ref),
           {:ok, conn, ws} <- Mint.WebSocket.new(conn, ref, 101, resp_headers),
           {:ok, pid} <- GenServer.start_link(__MODULE__, %{conn: conn, ref: ref, ws: ws}) do
        {:ok, pid}
      else
        {:ok, status, _headers} -> {:error, {:handshake_failed, status}}
        error -> error
      end
    else
      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:error, reason}

      error ->
        error
    end
  end

  def send_frame(pid, map), do: GenServer.call(pid, {:send, map})

  def recv_frame(pid, timeout \\ 2_000),
    do: GenServer.call(pid, {:recv, timeout}, timeout + 1_000)

  def close(pid), do: GenServer.stop(pid, :normal)

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

  @impl GenServer
  def init(state), do: {:ok, struct!(__MODULE__, state)}

  @impl GenServer
  def handle_call({:send, map}, _from, state) do
    {:ok, ws, data} = Mint.WebSocket.encode(state.ws, {:text, Jason.encode!(map)})
    {:ok, conn} = Mint.WebSocket.stream_request_body(state.conn, state.ref, data)
    {:reply, :ok, %{state | conn: conn, ws: ws}}
  end

  def handle_call({:recv, timeout}, _from, state) do
    case pop(state) do
      :empty -> wait_for_frame(state, timeout)
      {reply, state} -> {:reply, reply, state}
    end
  end

  defp pop(%__MODULE__{queue: [frame | rest]} = state),
    do: {{:ok, frame}, %{state | queue: rest}}

  defp pop(%__MODULE__{queue: [], closed: true} = state), do: {{:error, :closed}, state}
  defp pop(_state), do: :empty

  defp wait_for_frame(state, timeout) do
    case Mint.WebSocket.recv(state.conn, 0, timeout) do
      {:ok, conn, responses} ->
        {conn, ws, frames, closed} = extract(state, conn, responses)

        state = %{
          state
          | conn: conn,
            ws: ws,
            queue: state.queue ++ frames,
            closed: state.closed or closed
        }

        case pop(state) do
          :empty ->
            if state.closed,
              do: {:reply, {:error, :closed}, state},
              else: wait_for_frame(state, timeout)

          {reply, state} ->
            {:reply, reply, state}
        end

      {:error, conn, %Mint.TransportError{reason: :closed}, _} ->
        {:reply, {:error, :closed}, %{state | conn: conn, closed: true}}

      {:error, conn, reason, _} ->
        {:reply, {:error, reason}, %{state | conn: conn, closed: true}}
    end
  end

  defp extract(state, conn, responses) do
    ref = state.ref

    Enum.reduce(responses, {conn, state.ws, [], false}, fn
      {:data, ^ref, data}, {conn, ws, frames, closed} ->
        case Mint.WebSocket.decode(ws, data) do
          {:ok, ws, more} ->
            maybe_pong(conn, ws, ref, more, frames, closed)

          {:error, ws, _reason} ->
            {conn, ws, frames, closed}
        end

      _other, acc ->
        acc
    end)
  end

  # Answer server keepalive pings so the transport never drops us mid-test.
  defp maybe_pong(conn, ws, ref, frames, acc_frames, closed) do
    Enum.reduce(frames, {conn, ws, acc_frames, closed}, fn
      {:ping, payload}, {conn, ws, acc_frames, closed} ->
        case Mint.WebSocket.encode(ws, {:pong, payload}) do
          {:ok, ws, data} ->
            {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, data)
            {conn, ws, acc_frames, closed}

          {:error, ws, _reason} ->
            {conn, ws, acc_frames, closed}
        end

      {:text, bin}, {conn, ws, acc_frames, closed} ->
        {conn, ws, acc_frames ++ [Jason.decode!(bin)], closed}

      {:close, _, _}, {conn, ws, acc_frames, _closed} ->
        {conn, ws, acc_frames, true}

      {:close, _}, {conn, ws, acc_frames, _closed} ->
        {conn, ws, acc_frames, true}

      _, acc ->
        acc
    end)
  end
end
