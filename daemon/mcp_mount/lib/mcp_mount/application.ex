defmodule McpMount.Application do
  @moduledoc """
  App entry. No supervision tree of its own — `McpMount.CLI` starts the
  `McpMount.Mounter` directly so the escript stays a simple foreground
  process.
  """

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: McpMount.Supervisor)
  end
end
