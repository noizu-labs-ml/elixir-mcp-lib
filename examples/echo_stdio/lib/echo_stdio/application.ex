defmodule EchoStdio.Application do
  @moduledoc false

  use Application

  @impl true
  # ⟦𓌘𓊦𓇦𓇡⟧ start :: auto-generated pointer for public function start
  def start(_type, _args) do
    children = [
      {EchoStdio.MCP, transport: :stdio}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: EchoStdio.Supervisor)
  end
end
