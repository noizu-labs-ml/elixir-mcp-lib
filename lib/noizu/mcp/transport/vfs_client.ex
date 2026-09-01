defmodule Noizu.MCP.Transport.VFSClient do
  @moduledoc """
  Elixir client for the `Noizu.MCP.Transport.VFSSocket` unix-socket VFS
  transport, and the executable reference for the wire protocol (the Go FUSE
  daemon implements this contract).

  ## Protocol contract

  * **Transport** — a unix-domain stream socket (`:gen_tcp` with the `:local`
    address family), typically mode `0600`.
  * **Framing** — `<<size::unsigned-big-integer-size(32), message::binary>>`:
    a 4-byte big-endian unsigned length prefix followed by exactly one
    JSON-RPC 2.0 message of `size` bytes. No trailing delimiter, no batching.
  * **Handshake** — the first frame on a connection MUST be

        {"jsonrpc": "2.0", "id": <id>, "method": "vfs/auth",
         "params": {"api_key": "<key>"}}

    The server answers `result: {"authenticated": true, "session_id": "..."}`,
    or an error (code `-32001`) followed by connection close. Any other first
    method is also refused with `-32001` and close.
  * **Operations** — requests `vfs/stat`, `vfs/list`, `vfs/read`,
    `vfs/write`, `vfs/create`, `vfs/remove`, `vfs/search`, `vfs/xattr` with
    string-keyed params (`path`, `cursor`, `query`, `root`, `data`,
    `version`). All results are string-keyed maps; `type` values are strings
    (`"file"`, `"dir"`). `vfs/list` and `vfs/search` return a `nextCursor`
    when more pages remain; pass it back as `cursor` to continue.
  * **Errors** — standard JSON-RPC error objects. VFS errnos map to codes
    (`:enoent` → `-32002` resource_not_found, `:eacces` → `-32040`,
    `:eexist` → `-32041`, `:erofs` → `-32042`, `:eisdir` → `-32043`,
    `:enotdir` → `-32044`, `:enotempty` → `-32045`, `:enosys` → `-32046`)
    and the error object carries `data.errno_atom` (e.g. `"eisdir"`).
    Protocol-level errors use the standard JSON-RPC codes (`-32700` parse,
    `-32600` invalid request, `-32601` method not found, `-32602` invalid
    params). A malformed frame draws an error response but does not close the
    connection; auth failures always close it.

  ## Usage

      {:ok, client} = VFSClient.connect("/run/mcp/vfs.sock")
      {:ok, _} = VFSClient.auth(client, System.fetch_env!("MCP_VFS_KEY"))
      {:ok, %{"content" => content, "version" => v}} = VFSClient.read(client, "/etc/dev/flag")
      VFSClient.close(client)

  Operation results are the decoded wire maps (`{:ok, map}` | `{:error,
  error_map}`); use `request/4` for a raw round-trip. A client is safe from a
  single process at a time — request/response pairs are not matched
  concurrently, so give each concurrent worker its own connection.
  """

  defstruct [:socket, :path]

  @default_timeout 5_000

  @type t :: %__MODULE__{socket: :gen_tcp.socket(), path: String.t()}

  @doc "Connect to the VFS socket at `path`. Does not authenticate."
  @spec connect(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  # ⟦𓍝𓊝𓄿⟧ connect :: Connect to the VFS socket at `path`. Does not authenticate.
  def connect(path, opts \\ []) do
    case :gen_tcp.connect(
           {:local, String.to_charlist(path)},
           0,
           [:binary, packet: 4, active: false, nodelay: true],
           Keyword.get(opts, :connect_timeout, @default_timeout)
         ) do
      {:ok, socket} -> {:ok, %__MODULE__{socket: socket, path: path}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Authenticate the connection with `api_key`. Must be the first call."
  @spec auth(t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, map() | term()}
  # ⟦𓂃𓎛𓃦⟧ auth :: Authenticate the connection with `api_key`. Must be the first call.
  def auth(client, api_key, opts \\ []) do
    case request(client, "vfs/auth", %{"api_key" => api_key}, opts) do
      {:ok, result} -> {:ok, result}
      {:error, error} -> {:error, error}
    end
  end

  @doc "vfs/stat: node metadata for `path`."
  @spec stat(t(), String.t(), keyword()) :: {:ok, map()} | {:error, map() | term()}
  # ⟦𓊓𓃰𓁶⟧ stat :: vfs/stat: node metadata for `path`.
  def stat(client, path, _opts \\ []), do: request(client, "vfs/stat", %{"path" => path})

  @doc """
  vfs/list: children of `path`. Options: `:cursor` to fetch the next page.
  Returns `{"entries" => [...], "nextCursor" => "..." (when more remain)}`.
  """
  @spec list(t(), String.t(), keyword()) :: {:ok, map()} | {:error, map() | term()}
  # ⟦𓃔𓍱𓆏⟧ list :: vfs/list: children of `path`. Options: `:cursor` to fetch the next page.
  def list(client, path, opts \\ []) do
    params = %{"path" => path} |> put_opt("cursor", opts[:cursor])
    request(client, "vfs/list", params)
  end

  @doc """
  vfs/read: `%{"content" => binary, "version" => int}` for `path`.
  Option: `:version` (optimistic concurrency check).
  """
  @spec read(t(), String.t(), keyword()) :: {:ok, map()} | {:error, map() | term()}
  # ⟦𓆓𓁢𓍺⟧ read :: vfs/read: `{"content" => binary, "version" => int}` for `path`. Option: `:version`.
  def read(client, path, opts \\ []) do
    params = %{"path" => path} |> put_opt("version", opts[:version])
    request(client, "vfs/read", params)
  end

  @doc "vfs/write: overwrite `path` with `data`."
  @spec write(t(), String.t(), binary(), keyword()) :: {:ok, map()} | {:error, map() | term()}
  # ⟦𓁂𓆑𓊩⟧ write :: vfs/write: overwrite `path` with `data`.
  def write(client, path, data, _opts \\ []),
    do: request(client, "vfs/write", %{"path" => path, "data" => data})

  @doc """
  vfs/create: make `path`; `nil` data creates a directory, a binary makes a
  file.
  """
  @spec create(t(), String.t(), binary() | nil, keyword()) ::
          {:ok, map()} | {:error, map() | term()}
  # ⟦𓄰𓍨𓎁⟧ create :: vfs/create: make `path`; `nil` data creates a directory, a binary makes a file.
  def create(client, path, data \\ nil, _opts \\ []) do
    params = %{"path" => path} |> put_opt("data", data)
    request(client, "vfs/create", params)
  end

  @doc "vfs/remove: delete `path`."
  @spec remove(t(), String.t(), keyword()) :: {:ok, map()} | {:error, map() | term()}
  # ⟦𓉾𓊬𓂋⟧ remove :: vfs/remove: delete `path`.
  def remove(client, path, _opts \\ []), do: request(client, "vfs/remove", %{"path" => path})

  @doc """
  vfs/search: line matches for `query` under `root` (default `"/"`). Option:
  `:cursor`. Returns `{"matches" => [...], "nextCursor" => ...}`.
  """
  @spec search(t(), String.t(), keyword()) :: {:ok, map()} | {:error, map() | term()}
  # ⟦𓍄𓋹𓆗⟧ search :: vfs/search: line matches for `query` under `root` (default `"/"`). Option: `:cursor`.
  def search(client, query, opts \\ []) do
    params =
      %{"query" => query}
      |> put_opt("root", opts[:root])
      |> put_opt("cursor", opts[:cursor])

    request(client, "vfs/search", params)
  end

  @doc "vfs/xattr: extended attributes for `path`."
  @spec xattr(t(), String.t(), keyword()) :: {:ok, map()} | {:error, map() | term()}
  # ⟦𓇢𓎛𓂀⟧ xattr :: vfs/xattr: extended attributes for `path`.
  def xattr(client, path, _opts \\ []), do: request(client, "vfs/xattr", %{"path" => path})

  @doc """
  Send one request and await its response. Returns the decoded `result` map,
  or `{:error, error_map | :closed | :timeout}`. `opts[:timeout]` bounds the
  wait (default 5s).
  """
  @spec request(t(), String.t(), map() | nil, keyword()) ::
          {:ok, map()} | {:error, map() | term()}
  # ⟦𓍝𓆡𓇳⟧ request :: Send one request and await its response.
  def request(client, method, params, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    id = :erlang.unique_integer([:positive, :monotonic])

    frame =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => params
      })

    with :ok <- :gen_tcp.send(client.socket, frame),
         {:ok, body} <- recv_response(client.socket, id, timeout) do
      decode_body(body)
    end
  end

  @doc "Close the connection."
  @spec close(t()) :: :ok
  # ⟦𓊝𓁼𓍁⟧ close :: Close the connection.
  def close(%__MODULE__{socket: socket}) do
    :gen_tcp.close(socket)
    :ok
  end

  # ── internals ─────────────────────────────────────────────────────────────

  # Frames are strictly request/response on this socket, but skip anything
  # that is not the response to our id (notifications, stray frames) so a
  # noisy server cannot desync a caller.
  defp recv_response(socket, id, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"id" => ^id}} ->
            {:ok, body}

          _other ->
            recv_response(socket, id, timeout)
        end

      error ->
        error
    end
  end

  defp decode_body(body) do
    case Jason.decode(body) do
      {:ok, %{"result" => result}} -> {:ok, result}
      {:ok, %{"error" => error}} -> {:error, error}
      _ -> {:error, {:bad_response, body}}
    end
  end

  defp put_opt(params, _key, nil), do: params
  defp put_opt(params, key, value), do: Map.put(params, key, value)
end
