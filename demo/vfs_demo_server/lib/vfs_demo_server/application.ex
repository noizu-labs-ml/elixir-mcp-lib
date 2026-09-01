defmodule VfsDemoServer.Application do
  @moduledoc """
  Demo server supervision tree: Store (seeded tree) + the lib's VFSPubSub +
  (outside :test) the bandit HTTP/WS listener. Under :test the app starts
  nothing — tests boot isolated stacks via `VfsDemoServer.TestServer`.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:vfs_demo_server, :auto_start_server, true) do
        [
          {VfsDemoServer.Store, seed: :default},
          {Noizu.MCP.Server.VFSPubSub, []},
          {Bandit,
           plug: {Noizu.MCP.Transport.VFSWS, VfsDemoServer.ws_plug_opts()},
           scheme: :http,
           port: port()}
        ]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_all, name: VfsDemoServer.Supervisor)
  end

  defp port do
    case Application.get_env(:vfs_demo_server, :port) do
      p when is_integer(p) -> p
      _ -> String.to_integer(System.get_env("VFS_DEMO_PORT") || "4000")
    end
  end
end
