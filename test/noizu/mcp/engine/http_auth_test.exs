defmodule Noizu.MCP.Engine.HTTPAuthTest do
  @moduledoc "Stored HTTP credentials must authenticate discovery and tool calls."
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Noizu.MCP.Test

  alias Noizu.MCP.Engine
  alias Noizu.MCP.Engine.{Session, Supervisor}
  alias Noizu.MCP.Fixtures.Engine, as: Fixture

  defmodule SparseServer do
    use Noizu.MCP.Server, name: "sparse-http-auth", version: "1"
    tool(Noizu.MCP.Fixtures.Echo)
    resource(Noizu.MCP.Fixtures.ConfigResource)
  end

  setup do
    Fixture.setup_engine()
    ensure_server_started(SparseServer)
    on_exit(fn -> Fixture.reset!() end)
    :ok
  end

  for {source, reference} <- [
        env: "env:MCP_ENGINE_HTTP_AUTH_TEST_TOKEN",
        secret: "secret:engine/github"
      ] do
    test "#{source} credential reaches protected HTTP discovery and invocation without leaking" do
      token = Fixture.Secrets.value()
      variable = "MCP_ENGINE_HTTP_AUTH_TEST_TOKEN"
      previous = System.get_env(variable)
      System.put_env(variable, token)

      on_exit(fn ->
        if previous,
          do: System.put_env(variable, previous),
          else: System.delete_env(variable)
      end)

      listener =
        start_supervised!(
          {Bandit,
           plug:
             {Noizu.MCP.Transport.StreamableHTTP.Plug,
              server: SparseServer,
              auth: [
                verifier: {Noizu.MCP.Auth.ApiKeyVerifier, keys: [{token, %{"sub" => "demo"}}]}
              ]},
           ip: :loopback,
           port: 0,
           startup_log: false},
          id: make_ref()
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)
      url = "http://127.0.0.1:#{port}/"
      assert Req.post!(url, json: %{}, retry: false).status == 401

      reference = unquote(reference)
      name = unquote("protected_#{source}")
      client = connect(Engine)

      logs =
        capture_log(fn ->
          assert {:ok, _} =
                   attach_upstream(client, %{
                     "name" => name,
                     "transport" => "http",
                     "url" => url,
                     "auth_ref" => reference,
                     "enabled" => true
                   })

          await_ready(name)
          assert {:ok, tools} = list_tools(client)
          assert Enum.any?(tools, &(&1.name == name <> ".echo"))
          assert {:ok, result} = call_tool(client, name <> ".echo", %{"message" => "authorized"})
          assert [%{text: "authorized"}] = result.content
          refute inspect(Session.status(Supervisor.pooled_pid(name))) =~ token
          Fixture.reset!()
        end)

      refute logs =~ token
    end
  end

  test "crash status hides credentials and terminate tolerates a dead client" do
    client = spawn(fn -> :ok end)
    ref = Process.monitor(client)
    assert_receive {:DOWN, ^ref, :process, ^client, _}

    state = %Session{
      name: "demo",
      status: :error,
      client: client,
      credential: "never-log-this",
      principal: %{token: "never-log-this"}
    }

    assert Session.terminate(:normal, state) == :ok
    refute inspect(Session.format_status(%{state: state})) =~ "never-log-this"
  end

  defp await_ready(name, attempts \\ 100)
  defp await_ready(_name, 0), do: flunk("protected upstream did not become ready")

  defp await_ready(name, attempts) do
    pid = Supervisor.pooled_pid(name)

    if pid && Session.status(pid).status == "ready" do
      :ok
    else
      Process.sleep(50)
      await_ready(name, attempts - 1)
    end
  end
end
