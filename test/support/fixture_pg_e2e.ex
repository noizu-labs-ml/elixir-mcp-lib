defmodule Noizu.MCP.Fixtures.PgE2E do
  @moduledoc """
  Harness for the PRD-10 end-to-end suite (`pg_mcp_e2e_test.exs`): a REAL
  `Noizu.MCP.Engine` behind a REAL Bandit listener, with REAL stdio fixture
  upstreams attached, reached by a REAL Postgres running the layered `pg_mcp`
  image through Postgrex.

  Topology (ADR-007: the engine is the first e2e target):

      Postgres (docker, layered image)
        └─ mcp_fdw ──HTTP──▶ Bandit :<ephemeral>
                              └─ /mcp → StreamableHTTP.Plug(server: Engine)
                                         upstreams: alpha, github (python
                                         stdio fixtures), broken (spawn fails)
                             └─ /fixture → StreamableHTTP.Plug(server:
                                         Fixtures.Server)   (E19 generic mode)

  The verifier records every request's token outcome in an Agent so the E9
  identity assertion can prove no principal was synthesized for a rejected
  token (ADR-004). Tokens map to claims the engine ACL fixture understands:
  `bob` is denied the whole `github` upstream, `alice` is allowed.

  Everything here requires `PG_MCP_URL`; the suite skips cleanly without it.
  """

  alias Noizu.MCP.Engine
  alias Noizu.MCP.Fixtures.Engine, as: EngineFixture
  alias Noizu.MCP.Test

  # ── token → claims (E9/E10 identity fixtures) ───────────────────────────────

  def tokens do
    %{
      "alice-token" => %{"sub" => "alice", "scope" => "mcp"},
      "bob-token" => %{"sub" => "bob", "scope" => "mcp"},
      # Never accepted: E9 drives this through Postgres and expects 42501.
      "bad-token" => nil
    }
  end

  defmodule PrincipalLog do
    @moduledoc "Records every verify/3 outcome; backs the E9 no-principal assertion."

    def start, do: Agent.start_link(fn -> [] end, name: __MODULE__)

    def record(token, outcome),
      do: Agent.cast(__MODULE__, &[{token, outcome, System.monotonic_time()} | &1])

    def entries, do: Agent.get(__MODULE__, & &1)

    @doc "The outcome recorded for `token`'s most recent request, or :never."
    def last(token) do
      case Enum.find(entries(), fn {t, _, _} -> t == token end) do
        {_t, outcome, _at} -> outcome
        nil -> :never
      end
    end
  end

  defmodule Verifier do
    @moduledoc false
    @behaviour Noizu.MCP.Auth.TokenVerifier

    @impl true
    def verify(token, _conn_info, _opts) do
      outcome =
        case Map.fetch(Noizu.MCP.Fixtures.PgE2E.tokens(), token) do
          {:ok, claims} when claims != nil -> {:ok, claims}
          _other -> {:error, :invalid_token}
        end

      PrincipalLog.record(token, outcome)
      outcome
    end
  end

  # ── Bandit routers (engine + generic fixture server) ────────────────────────

  defmodule EngineRouter do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    forward("/mcp",
      to: Noizu.MCP.Transport.StreamableHTTP.Plug,
      init_opts: [
        server: Noizu.MCP.Engine,
        sse_commit_after: 5_000,
        auth: [verifier: {Noizu.MCP.Fixtures.PgE2E.Verifier, []}]
      ]
    )
  end

  defmodule GenericRouter do
    @moduledoc false
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    forward("/fixture",
      to: Noizu.MCP.Transport.StreamableHTTP.Plug,
      init_opts: [
        server: Noizu.MCP.Fixtures.Server,
        sse_commit_after: 5_000,
        auth: [verifier: {Noizu.MCP.Fixtures.PgE2E.Verifier, []}]
      ]
    )
  end

  # ── boot ────────────────────────────────────────────────────────────────────

  @doc """
  Boot the whole host-side half: engine config, three stdio upstreams, two
  Bandit listeners. Returns `%{engine_port: p, generic_port: q}` for the
  `CREATE SERVER` URLs.
  """
  def boot do
    EngineFixture.setup_engine()
    EngineFixture.ensure_engine!()
    PrincipalLog.start()

    client = Test.connect(Engine)

    # alpha: the workhorse upstream — echo (non-read-only), fail (isError rows),
    # greet (READ-ONLY: the per-tool SELECT-invocation tool), emit_change
    # (adds `late_tool` after a list_changed; E12/E13).
    {:ok, _} =
      Test.attach_upstream(
        client,
        EngineFixture.row("alpha",
          tools: ["echo", "fail", "greet", "emit_change"],
          change_adds: "late_tool"
        )
      )

    # github: exists so bob's denial has a whole upstream to hide (E10/E18).
    {:ok, _} = Test.attach_upstream(client, EngineFixture.row("github", tools: ["echo", "token"]))

    # broken: spawn failure → status `error`, contributes no tools (E16/AP-P15).
    {:ok, _} =
      Test.attach_upstream(client, %{
        EngineFixture.row("broken")
        | "command" => "/nonexistent/pg_mcp_e2e_binary --nope"
      })

    Test.await_upstream_status(client, "alpha", "ready", timeout: 10_000)
    Test.await_upstream_status(client, "github", "ready", timeout: 10_000)
    Test.await_upstream_status(client, "broken", "error", timeout: 10_000)

    engine_port = start_listener(EngineRouter)
    generic_port = start_listener(GenericRouter)

    %{engine_port: engine_port, generic_port: generic_port, client: client}
  end

  # ── Postgrex URL plumbing ───────────────────────────────────────────────────

  @doc "Parse `PG_MCP_URL` (postgres:// or ecto://) into Postgrex options."
  def conn_opts(url) do
    uri = URI.parse(url)
    [username, password] = String.split(uri.userinfo || "postgres:postgres", ":", parts: 2)

    [
      hostname: uri.host || "localhost",
      port: uri.port || 5432,
      database: String.trim_leading(uri.path || "/", "/"),
      username: username,
      password: password,
      # The suite serializes everything through few connections; keep the
      # pool tiny and explicit.
      pool_size: 2
    ]
  end

  @doc """
  How the CONTAINER reaches the host-side Bandit listener. The default is
  `localhost` because the e2e compose file uses `network_mode: host` — which
  is also what makes the URL loopback-legitimate for the extension's
  plaintext-http rule (SEC-4). `PG_MCP_CALLBACK_HOST` overrides for other
  topologies (that host must still be loopback from Postgres's vantage).
  """
  def callback_host do
    System.get_env("PG_MCP_CALLBACK_HOST", "localhost")
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp start_listener(router) do
    port = free_port()

    {:ok, _} =
      Bandit.start_link(plug: router, scheme: :http, ip: {0, 0, 0, 0}, port: port)

    wait_for_listener(port)
    port
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp wait_for_listener(port, attempts \\ 100) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [], 100) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        :ok

      _error when attempts > 0 ->
        Process.sleep(50)
        wait_for_listener(port, attempts - 1)

      _error ->
        raise "Bandit listener on port #{port} never came up"
    end
  end
end
