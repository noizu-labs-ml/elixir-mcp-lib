defmodule Noizu.MCP.Fixtures.Engine do
  @moduledoc """
  Fixtures for the `Noizu.MCP.Engine` federation suite (PRD-11 §7).

  The upstream fixtures are REAL stdio subprocesses (`test/support/
  stdio_upstream.py`, a dependency-free MCP responder): attaching one exercises
  the spawn → handshake → catalog path end to end, including a broken binary
  (spawn failure), a dying process (transport-down → backoff → reconnect), and
  a pass-through upstream that receives the caller's token via env.

  Global engine config (backoff, ACL, the secret resolver) is set through
  `Application.put_env` in `setup_engine/0`; restore happens in the caller's
  `on_exit`. The `servers` store is the Memory provider's shared ETS —
  `reset!/0` stops sessions and clears rows between tests. Tests using these
  fixtures must not run `async: true`.
  """

  alias Noizu.MCP.Engine
  alias Noizu.MCP.Engine.Servers
  alias Noizu.MCP.Test

  @script Path.expand("stdio_upstream.py", __DIR__)

  @engine_config [
    persistence: :memory,
    backoff: {50, 200, 0.0},
    connect_timeout_ms: 5_000,
    refresh_interval_ms: 300_000,
    passthrough_idle_ms: 60_000,
    secret_resolver: {Noizu.MCP.Fixtures.Engine.Secrets, :resolve},
    acl: Noizu.MCP.Fixtures.Engine.ACL,
    static_servers: []
  ]

  @doc "Install the engine's test config. Use in `setup` (not async)."
  @spec setup_engine() :: :ok
  def setup_engine do
    previous = Application.get_env(:noizu_mcp, :engine)

    Application.put_env(:noizu_mcp, :engine, @engine_config)
    ensure_engine!()
    reset!()

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:noizu_mcp, :engine)
        config -> Application.put_env(:noizu_mcp, :engine, config)
      end
    end)

    :ok
  end

  @doc "Stop every upstream session and clear the `servers` store."
  @spec reset!() :: :ok
  def reset! do
    Noizu.MCP.Engine.Supervisor.stop_all()

    case Servers.scan(%{}, nil, %{}) do
      {:ok, rows, _cursor} ->
        for row <- rows do
          Servers.delete([%{column: "name", op: :eq, value: row["name"]}], nil)
        end

      _error ->
        :ok
    end

    :ok
  end

  @doc "The fixture stdio command line for the python responder."
  @spec command(keyword()) :: String.t()
  def command(opts \\ []) do
    flags =
      [
        "--name #{opts[:name] || "fixture"}",
        "--tools #{Enum.join(opts[:tools] || ["echo"], ",")}",
        if(opts[:advertise_sql], do: "--advertise-sql", else: nil),
        if(opts[:die_after], do: "--die-after #{opts[:die_after]}", else: nil),
        if(opts[:change_adds], do: "--change-adds #{opts[:change_adds]}", else: nil)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    "python3 #{@script} #{flags}"
  end

  @doc "A stdio row for the `servers` dataset."
  @spec row(String.t(), keyword()) :: map()
  def row(name, opts \\ []) do
    %{
      "name" => name,
      "transport" => "stdio",
      "command" => command(Keyword.put(opts, :name, name)),
      "url" => nil,
      "auth_ref" => opts[:auth_ref],
      "enabled" => opts[:enabled] != false
    }
  end

  @doc "Ensure the engine tree is running and seeded."
  @spec ensure_engine!() :: :ok
  def ensure_engine! do
    Test.ensure_server_started(Engine)
    :ok
  end

  defmodule Secrets do
    @moduledoc "The configured `secret:` resolver fixture (PRD-11 §4.7)."
    @secret "engine-fixture-resolved-secret-do-not-leak"

    def resolve("secret:engine/github"), do: {:ok, @secret}
    def resolve("secret:unresolved"), do: {:error, :nope}
    def resolve("infisical:proj/env/GITHUB"), do: {:ok, @secret}
    def resolve(_other), do: {:error, :unknown_ref}

    @doc "The distinctive value AC-11.10 greps every captured output for."
    def value, do: @secret
  end

  defmodule ACL do
    @moduledoc """
    Two-principal ACL fixture (AC-11.11): `bob` is denied the whole `github`
    upstream (every prefixed tool AND the registry row) and the single tool
    `alpha.private`. Everyone else is allowed.
    """
    @behaviour Noizu.MCP.ACL.Provider

    alias Noizu.MCP.ACL.Resource

    @impl true
    def check(subject, %Resource{kind: kind, id: id}, _action, _ctx, _opts) do
      cond do
        kind == :tool and subject_id(subject) == "bob" and String.starts_with?(id, "github") ->
          :deny

        kind == :tool and subject_id(subject) == "bob" and id == "alpha.private" ->
          :deny

        kind in [:tool, :dataset] ->
          :allow

        true ->
          :deny
      end
    end

    @impl true
    def supported_kinds, do: [:tool, :dataset]

    defp subject_id(%Noizu.MCP.Auth.Principal{subject: subject}), do: to_string(subject)
    defp subject_id(other), do: to_string(other)
  end
end
