defmodule Mix.Tasks.Mcp.Engine do
  @shortdoc "Run the Noizu MCP federation engine as a standalone Streamable HTTP server"

  @moduledoc """
  Run `Noizu.MCP.Engine` standalone (PRD-11 §4.9) on Bandit, serving the
  engine's federated surface over Streamable HTTP:

      mix mcp.engine --port 4040 --persistence ecto --repo MyApp.Repo
      mix mcp.engine --attach 'github=stdio:npx -y @modelcontextprotocol/server-github'
      mix mcp.engine --no-auth   # loopback-only, no verifier — local use

  ## Options

    * `--port PORT` — Bandit listener port (default 4040)
    * `--persistence memory|ecto` — `servers` store provider (default memory)
    * `--repo MODULE` — Ecto repo when `--persistence ecto`
    * `--attach SPEC` — repeatable; `name=stdio:CMD` or `name=http:URL`
    * `--no-auth` — bind loopback-only with no verifier, for local use
      (mirrors the `auth 'none'` loopback rule: any other bind address is
      refused)

  `--attach` seeds `servers` rows through the SAME dataset path SQL uses
  (D1 — static config seeds rows, it never bypasses them).
  """

  use Mix.Task

  alias Noizu.MCP.Engine
  alias Noizu.MCP.Engine.Servers
  alias Noizu.MCP.Transport.StreamableHTTP.Plug

  @switches [
    port: :integer,
    persistence: :string,
    repo: :string,
    attach: :keep,
    no_auth: :boolean
  ]
  @default_port 4040

  @impl Mix.Task
  def run(args) do
    opts = parse_args!(args)
    Mix.Task.run("app.start")

    ensure_bandit!()
    configure_persistence!(opts)

    children = [Engine]

    {:ok, _} = Supervisor.start_link(children, strategy: :one_for_one)
    {:ok, _} = seed_rows!(opts)

    {:ok, _} =
      Bandit.start_link(
        plug: {Plug, server: Engine},
        scheme: :http,
        port: opts[:port] || @default_port,
        ip: bind_address(opts)
      )

    Mix.shell().info("""
    Noizu MCP Engine listening on port #{opts[:port] || @default_port} \
    (#{if opts[:no_auth], do: "no auth, loopback-only", else: "auth: host-configured verifier"}).
    Attach upstreams: engine.attach, or INSERT INTO the servers relation via sql/modify.
    Press Ctrl-C to stop.
    """)

    Process.sleep(:infinity)
  end

  @doc false
  # Parse + validate ONLY — unit-testable without booting Bandit (AC-11.14).
  @spec parse_args!([String.t()]) :: keyword()
  def parse_args!(args) do
    {opts, [], invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    if opts[:no_auth] && not loopback_only?(opts) do
      Mix.raise("--no-auth binds 127.0.0.1 only — a non-loopback bind is refused")
    end

    attach =
      opts
      |> Keyword.get_values(:attach)
      |> Enum.map(&parse_attach!/1)

    Keyword.put(opts, :attach, attach)
  end

  # The task exposes no --bind option: without auth the ONLY bind is the
  # loopback. A future host option must re-check here (fail closed).
  defp loopback_only?(opts), do: bind_address(opts) == {127, 0, 0, 1}

  @doc "Parse one `--attach` SPEC: `name=stdio:CMD` or `name=http:URL`."
  @spec parse_attach!(String.t()) :: map()
  def parse_attach!(spec) do
    case String.split(spec, "=", parts: 2) do
      [name, target] ->
        attach_row(name, target)

      _other ->
        Mix.raise("--attach expects name=stdio:CMD or name=http:URL, got: #{inspect(spec)}")
    end
  end

  defp attach_row(name, "stdio:" <> command) when command != "" do
    %{"name" => name, "transport" => "stdio", "command" => command, "enabled" => true}
  end

  defp attach_row(name, "http:" <> url) when url != "" do
    %{"name" => name, "transport" => "http", "url" => url, "enabled" => true}
  end

  defp attach_row(_name, other) do
    Mix.raise("--attach target must be stdio:CMD or http:URL, got: #{inspect(other)}")
  end

  @doc false
  # `--no-auth` binds 127.0.0.1 ONLY (PRD-11 §4.9) — any other bind address is
  # refused outright. Public for the loopback-enforcement test.
  @spec bind_address(keyword()) :: :inet.ip_address()
  def bind_address(opts) do
    if opts[:no_auth], do: {127, 0, 0, 1}, else: :any
  end

  defp ensure_bandit! do
    unless Code.ensure_loaded?(Bandit) and Code.ensure_loaded?(Plug.Conn) do
      Mix.raise("mix mcp.engine needs the optional :bandit and :plug dependencies")
    end
  end

  defp configure_persistence!(opts) do
    engine =
      case {opts[:persistence], opts[:repo]} do
        {"ecto", repo} when is_binary(repo) ->
          [persistence: {Noizu.MCP.Persistence.Ecto, repo: Module.concat([repo])}]

        {"ecto", nil} ->
          Mix.raise("--persistence ecto requires --repo MODULE")

        _other ->
          []
      end

    if engine != [], do: Application.put_env(:noizu_mcp, :engine, engine)
  end

  defp seed_rows!(opts) do
    rows = Keyword.get(opts, :attach, [])

    if rows == [] do
      {:ok, []}
    else
      case Servers.insert(rows, nil) do
        {:ok, inserted} ->
          Mix.shell().info("Attached: #{Enum.map_join(inserted, ", ", & &1["name"])}")
          {:ok, inserted}

        {:error, error} ->
          Mix.raise("attach failed: #{Exception.message(error)}")
      end
    end
  end
end
