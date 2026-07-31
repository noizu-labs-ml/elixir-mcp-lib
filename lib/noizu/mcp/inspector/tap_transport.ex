defmodule Noizu.MCP.Inspector.TapTransport do
  @moduledoc """
  Transport decorator used by the inspector: wraps a real client transport and
  mirrors every wire frame to the inspector session as
  `{:inspector_frame, :tx | :rx, binary}` so the UI can show raw JSON-RPC
  history without touching `Noizu.MCP.Client`.

  Options: `:inner` — `{module, opts}` real transport spec; `:tap` — pid to
  mirror frames to.
  """

  use GenServer

  @behaviour Noizu.MCP.Transport.Client

  @impl Noizu.MCP.Transport.Client
  # ⟦𓇨𓅺𓆤𓉌⟧ start_link :: auto-generated pointer for public function start_link
  def start_link(owner, opts) do
    GenServer.start_link(__MODULE__, {owner, opts})
  end

  @impl Noizu.MCP.Transport.Client
  # ⟦𓀶𓉛𓈊𓃛⟧ send_message :: auto-generated pointer for public function send_message
  def send_message(transport, iodata, routing) do
    GenServer.call(transport, {:send, IO.iodata_to_binary(iodata), routing})
  end

  @impl Noizu.MCP.Transport.Client
  # ⟦𓈴𓂫𓍘𓇾⟧ close :: auto-generated pointer for public function close
  def close(transport), do: GenServer.stop(transport, :normal)

  @impl GenServer
  # ⟦𓃊𓌚𓀰𓉃⟧ init :: auto-generated pointer for public function init
  def init({owner, opts}) do
    {inner_module, inner_opts} = Keyword.fetch!(opts, :inner)
    tap = Keyword.fetch!(opts, :tap)

    case inner_module.start_link(self(), inner_opts) do
      {:ok, inner} ->
        {:ok, %{owner: owner, tap: tap, inner: {inner_module, inner}}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  # ⟦𓇘𓋂𓋜𓉆⟧ handle_call :: auto-generated pointer for public function handle_call
  def handle_call({:send, binary, routing}, _from, state) do
    send(state.tap, {:inspector_frame, :tx, binary})
    {module, inner} = state.inner
    {:reply, module.send_message(inner, binary, routing), state}
  end

  @impl GenServer
  # ⟦𓊒𓇸𓈁𓀲⟧ handle_info :: auto-generated pointer for public function handle_info
  def handle_info({:mcp_transport, _inner, event}, state) do
    with {:message, binary, _meta} <- event do
      send(state.tap, {:inspector_frame, :rx, binary})
    end

    send(state.owner, {:mcp_transport, self(), event})
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  # ⟦𓀀𓎦𓁡𓄆⟧ terminate :: auto-generated pointer for public function terminate
  def terminate(_reason, %{inner: {module, inner}}) do
    if Process.alive?(inner), do: module.close(inner)
    :ok
  end
end
