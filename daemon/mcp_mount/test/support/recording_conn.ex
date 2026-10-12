defmodule McpMount.Test.RecordingConn do
  @moduledoc """
  Test `McpMount.Conn` that records the deadline budget each call was given,
  delegating the operation itself to an inner `McpMount.FakeConn`. Lets tests
  assert the Mounter's per-op timeout table end to end (what the Mounter
  actually passes, not what its constants claim).
  """

  @behaviour McpMount.Conn

  defstruct [:inner, :recorder]

  @impl McpMount.Conn
  def connect(opts) do
    {:ok, inner} = McpMount.FakeConn.connect(opts)
    {:ok, %__MODULE__{inner: inner, recorder: Keyword.fetch!(opts, :recorder)}}
  end

  @impl McpMount.Conn
  def call(%__MODULE__{inner: inner, recorder: recorder}, method, params, timeout) do
    Agent.update(recorder, fn rec -> Map.update(rec, method, [timeout], &[timeout | &1]) end)
    McpMount.FakeConn.call(inner, method, params, timeout)
  end

  @impl McpMount.Conn
  def subscribe(%__MODULE__{inner: inner}, paths, depth),
    do: McpMount.FakeConn.subscribe(inner, paths, depth)

  @impl McpMount.Conn
  def unsubscribe(%__MODULE__{inner: inner}, paths),
    do: McpMount.FakeConn.unsubscribe(inner, paths)

  @impl McpMount.Conn
  def close(%__MODULE__{inner: inner}), do: McpMount.FakeConn.close(inner)

  @doc "Recorded budgets for `method`, most recent first."
  def recorded(recorder, method), do: Agent.get(recorder, &Map.get(&1, method, []))

  @doc false
  def inject_event(%__MODULE__{inner: inner}, event),
    do: McpMount.FakeConn.inject_event(inner, event)

  @doc false
  def drop(%__MODULE__{inner: inner}, reason \\ :fake_drop),
    do: McpMount.FakeConn.drop(inner, reason)
end
