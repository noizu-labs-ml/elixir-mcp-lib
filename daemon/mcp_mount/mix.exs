defmodule McpMount.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :mcp_mount,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      escript: [main_module: McpMount.CLI, name: "mcp-mount", emu_args: "-noshell"],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssl, :crypto],
      mod: {McpMount.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:file_system, "~> 1.0"},
      {:mint, "~> 1.6"},
      {:mint_web_socket, "~> 1.0"},
      # In-repo WS fixture server for integration tests (kept out of the escript)
      {:bandit, "~> 1.5", only: :test}
    ]
  end
end
