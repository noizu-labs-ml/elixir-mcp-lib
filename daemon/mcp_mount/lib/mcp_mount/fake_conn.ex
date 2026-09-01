defmodule McpMount.FakeConn do
  @moduledoc """
  In-memory `McpMount.Conn` for unit tests. Ops dispatch to an injected
  handler fun `(method, params) -> {:ok, map()} | {:error, atom() | map()}`;
  errno atoms are wrapped into the wire error map shape. Tests inject events
  (and simulate drops) with `inject_event/2` and `drop/1`.
  """

  @behaviour McpMount.Conn

  defstruct [:owner, :handler]

  @impl McpMount.Conn
  def connect(opts) do
    {:ok,
     %__MODULE__{
       owner: Keyword.fetch!(opts, :owner),
       handler: Keyword.fetch!(opts, :handler)
     }}
  end

  @impl McpMount.Conn
  def call(%__MODULE__{handler: handler}, method, params, _timeout) do
    case handler.(method, params || %{}) do
      {:ok, result} ->
        {:ok, result}

      {:error, errno} when is_atom(errno) ->
        {:error, %{code: nil, errno: errno, message: "fake error"}}

      {:error, %{code: _} = error} ->
        {:error, error}

      {:error, other} ->
        {:error, %{code: nil, errno: nil, message: inspect(other)}}
    end
  end

  @impl McpMount.Conn
  def subscribe(%__MODULE__{}, _paths, _depth), do: :ok

  @impl McpMount.Conn
  def unsubscribe(%__MODULE__{}, _paths), do: :ok

  @impl McpMount.Conn
  def close(%__MODULE__{}), do: :ok

  @doc "Deliver a server event to the mounter as if the server had sent it."
  def inject_event(%__MODULE__{owner: owner}, event) do
    send(owner, {:mcp_mount_event, event})
    :ok
  end

  @doc "Simulate the connection dropping."
  def drop(%__MODULE__{owner: owner}, reason \\ :fake_drop) do
    send(owner, {:mcp_mount_down, reason})
    :ok
  end
end
