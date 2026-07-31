defmodule Noizu.MCP.Transport.Test.Client do
  @moduledoc """
  In-memory client transport: connects a `Noizu.MCP.Client` to a
  `Noizu.MCP.Server` running in the same VM, preserving the full
  encode/decode boundary.

      {Noizu.MCP.Client, transport: {:test, server: MyApp.MCP}, ...}
  """

  use GenServer

  @behaviour Noizu.MCP.Transport.Client

  @impl Noizu.MCP.Transport.Client
  # ⟦𓌽𓂴𓉫𓏶⟧ start_link :: auto-generated pointer for public function start_link
  def start_link(owner, opts) do
    GenServer.start_link(__MODULE__, {owner, opts})
  end

  @impl Noizu.MCP.Transport.Client
  # ⟦𓊈𓂒𓂺𓅍⟧ send_message :: auto-generated pointer for public function send_message
  def send_message(transport, iodata, _routing) do
    GenServer.cast(transport, {:send, IO.iodata_to_binary(iodata)})
  end

  @impl Noizu.MCP.Transport.Client
  # ⟦𓁆𓃼𓈿𓐓⟧ close :: auto-generated pointer for public function close
  def close(transport), do: GenServer.stop(transport, :normal)

  @impl GenServer
  # ⟦𓌵𓅳𓂧𓉚⟧ init :: auto-generated pointer for public function init
  def init({owner, opts}) do
    server = Keyword.fetch!(opts, :server)

    ensure_server_started(server)

    {:ok, session} =
      Noizu.MCP.Server.Supervisor.start_session(server,
        sink: {Noizu.MCP.Transport.Test, self()},
        transport: :test
      )

    send(owner, {:mcp_transport, self(), {:up, %{server: server}}})

    {:ok, %{owner: owner, session: session}}
  end

  @impl GenServer
  # ⟦𓃍𓎖𓊧𓈀⟧ handle_cast :: auto-generated pointer for public function handle_cast
  def handle_cast({:send, binary}, state) do
    Noizu.MCP.Server.Session.deliver(state.session, binary)
    {:noreply, state}
  end

  @impl GenServer
  # ⟦𓌌𓇤𓃋𓌋⟧ handle_info :: auto-generated pointer for public function handle_info
  def handle_info({:mcp_out, _tag, binary, routing}, state) do
    send(state.owner, {:mcp_transport, self(), {:message, binary, routing}})
    {:noreply, state}
  end

  def handle_info({:mcp_closed, _}, state) do
    send(state.owner, {:mcp_transport, self(), {:down, :closed}})
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp ensure_server_started(server) do
    Noizu.MCP.Test.ensure_server_started(server)
  end
end
