defmodule McpMount.Conn do
  @moduledoc """
  Transport behaviour for the mounter: one authenticated VFS connection.

  Implementations ship in this app:

    * `McpMount.WSConn` — real WebSocket client (mint + mint_web_socket);
      `connect/1` performs the TCP connect, upgrade and `vfs/auth` handshake.
    * `McpMount.FakeConn` — in-memory fake for unit tests (ops dispatch to an
      injected handler fun).

  ## Contract

    * `connect(opts)` — opts: `:url` (`ws://host:port/vfs`), `:token`,
      `:owner` (pid), `:timeout`. Returns a connection handle (pid for
      WSConn, struct for FakeConn).
    * `call(conn, method, params, timeout)` — one request/response round
      trip: `{:ok, result_map}` | `{:error, %{code, errno, message}}` |
      `{:error, :closed | :timeout}`. `errno` is the wire `errno_atom`.
    * `subscribe(conn, paths, depth)` / `unsubscribe(conn, paths)`.
    * `close(conn)`.
    * `caps(conn)` — the server's advertised capability list from the
      `vfs/auth` result (`proto`/`caps` handshake extras, §5.1), or
      `:unknown` when the server predates the extras. Callers MUST treat
      `:unknown` as "no optional op advertised"; optional ops (`vfs/move`)
      gate on membership.

  ## Async messages to `owner`

    * `{:mcp_mount_event, %{op:, path:, version:, seq:, by:, at:}}` —
      server change notifications (metadata only; pull content via read).
    * `{:mcp_mount_down, reason}` — connection lost; reconnect is the
      mounter's job.
  """

  @type conn :: term()

  @type error ::
          %{code: integer(), errno: atom() | nil, message: String.t()}
          | :closed
          | :timeout

  @type depth :: :infinity | non_neg_integer()

  @callback connect(keyword()) :: {:ok, conn()} | {:error, term()}

  @callback call(conn(), method :: String.t(), params :: map() | nil, timeout :: pos_integer()) ::
              {:ok, map()} | {:error, error()}

  @callback subscribe(conn(), paths :: [String.t()], depth()) :: :ok | {:error, term()}

  @callback unsubscribe(conn(), paths :: [String.t()]) :: :ok

  @callback close(conn()) :: :ok

  # Optional-op gate for the mv-pairing flow: the advertised cap list from
  # the vfs/auth result, or :unknown when the server predates the extras.
  # NOT dispatched polymorphically — callers probe function_exported?/3 and
  # treat a miss as :unknown, so a Conn implementation written before this
  # callback keeps working.
  @callback caps(conn()) :: [String.t()] | :unknown
end
