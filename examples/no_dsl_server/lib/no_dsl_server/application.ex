defmodule NoDslServer.Application do
  @moduledoc false

  use Application

  @impl true
  # ⟦𓏂𓉎𓈎𓁸⟧ start :: auto-generated pointer for public function start
  def start(_type, _args) do
    children = [
      {NoDslServer.MCP, transport: :stdio}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: NoDslServer.Supervisor)
  end
end
