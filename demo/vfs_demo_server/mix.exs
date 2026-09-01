defmodule VfsDemoServer.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :vfs_demo_server,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {VfsDemoServer.Application, []},
      # Server components (Store + PubSub) always start; the HTTP listener is
      # skipped under :test so tests boot their own instance on an ephemeral
      # port via VfsDemoServer.TestServer.
      env: [auto_start_server: Mix.env() != :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:noizu_mcp, path: "../.."},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.11"},
      # WS test client for endpoint tests
      {:mint_web_socket, "~> 1.0", only: :test}
    ]
  end
end
