defmodule Noizu.MCP.Test.ClosedConnAdapter do
  @moduledoc """
  Minimal Plug.Conn.Adapter for the SSE client-disconnect regression: serves
  one request body, completes the chunked-response handshake, and then reports
  `{:error, :closed}` on every chunk — the shape Plug returns when the client
  went away mid-stream. Swap it onto a `Plug.Test` conn via
  `%{conn | adapter: {__MODULE__, __MODULE__.init(body)}}`.
  """

  @behaviour Plug.Conn.Adapter

  def init(body), do: %{body: body, read?: false}

  @impl true
  def read_req_body(%{body: body, read?: false} = state, _opts),
    do: {:ok, body, %{state | read?: true}}

  def read_req_body(state, _opts), do: {:ok, "", state}

  @impl true
  def send_resp(payload, _status, _headers, body), do: {:ok, body, payload}

  @impl true
  def send_file(payload, _status, _headers, _file, _offset, _length), do: {:ok, nil, payload}

  @impl true
  def send_chunked(payload, _status, _headers), do: {:ok, nil, payload}

  @impl true
  def chunk(_payload, _body), do: {:error, :closed}

  @impl true
  def inform(payload, _status, _headers), do: {:ok, payload}

  @impl true
  def upgrade(payload, _protocol, _opts), do: {:ok, payload}

  @impl true
  def get_peer_data(_payload),
    do: %{address: {127, 0, 0, 1}, port: 0, ssl_cert: nil, ssl_dn: nil, ssl_serial: nil}

  @impl true
  def get_http_protocol(_payload), do: :"HTTP/1.1"
end
