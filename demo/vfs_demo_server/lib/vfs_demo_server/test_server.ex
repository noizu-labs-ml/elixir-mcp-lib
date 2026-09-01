defmodule VfsDemoServer.TestServer do
  @moduledoc """
  Boots an isolated demo server stack (Store + VFSPubSub + bandit on an
  ephemeral port) for tests and ad-hoc dev. The full application supervision
  tree is skipped under :test (see `VfsDemoServer.Application`).

      {:ok, sup, port} = VfsDemoServer.TestServer.start_link(seed: :default)

  Options: `:seed` — `:default` (priv/seed/tree.yaml) or a list of seed nodes
  (as produced by `VfsDemoServer.Seed.build/1`); `:port` — listener port
  (default: a free ephemeral port).
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Port the test server's HTTP/WS listener is bound to."
  def port do
    port!()
  end

  @impl Supervisor
  def init(opts) do
    port = Keyword.get_lazy(opts, :port, &free_port/0)
    :persistent_term.put({__MODULE__, :port}, port)

    seed =
      case Keyword.get(opts, :seed, :default) do
        :default -> VfsDemoServer.Seed.load(default_seed_path())
        seed_nodes when is_list(seed_nodes) -> seed_nodes
      end

    children = [
      {VfsDemoServer.Store, seed: seed},
      {Noizu.MCP.Server.VFSPubSub, []},
      {Bandit,
       plug: {Noizu.MCP.Transport.VFSWS, VfsDemoServer.ws_plug_opts()}, scheme: :http, port: port}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp default_seed_path, do: Path.join(:code.priv_dir(:vfs_demo_server), "seed/tree.yaml")

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp port! do
    case :persistent_term.get({__MODULE__, :port}, nil) do
      nil -> raise "TestServer not started"
      port -> port
    end
  end
end
