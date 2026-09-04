defmodule Noizu.MCP.Persistence.Ping do
  @moduledoc """
  The D4 boot gate (PRD-4 §4.2/§4.3): the supervisor child `Noizu.MCP.Server.Supervisor`
  starts for every resolved persistence provider except the `Memory`/`Disabled`
  built-ins. `init/1` pings the provider; a failure STOPS the child, a failed
  child fails the supervisor's `start_link`, and a failed boot is exactly the
  contract — a provider whose backing store is misconfigured (`{:error,
  {:tables_missing, names}}`) must not degrade silently into a server that
  serves static surfaces while pretending persistence works.

  Run `Noizu.MCP.Migration.Runner.up/3` before booting an Ecto-backed server.
  """

  use GenServer, restart: :permanent

  require Logger

  @doc false
  # ⟦𓊪𓇋𓈖𓎼⟧ start_link :: auto-generated pointer for public function start_link
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @impl true
  def init(opts) do
    server = Keyword.fetch!(opts, :server)
    provider = Keyword.fetch!(opts, :provider)
    provider_opts = Keyword.get(opts, :provider_opts, [])

    case Noizu.MCP.Persistence.ping(provider, provider_opts) do
      :ok ->
        {:ok, %{server: server, provider: provider}}

      {:error, reason} ->
        Logger.error(
          "MCP server #{inspect(server)}: persistence provider #{inspect(provider)} " <>
            "failed its boot ping: #{inspect(reason)} — refusing to boot (D4)"
        )

        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, Noizu.MCP.Persistence.ping(state.provider, []), state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
