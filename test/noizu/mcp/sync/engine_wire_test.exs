defmodule Noizu.MCP.Sync.EngineWireTest do
  use ExUnit.Case, async: false
  import Noizu.MCP.Test
  alias Noizu.MCP.Engine
  alias Noizu.MCP.Engine.Supervisor
  alias Noizu.MCP.Fixtures.Engine, as: Fixture

  defmodule Upstream do
    use Noizu.MCP.Server, name: "sync-auth-upstream", version: "1", sync: true
    @impl true
    def handle_sync(_method, %{"relation" => "notes"}, %{auth: %{subject: subject}}),
      do: {:ok, %{"principal" => subject}}

    def handle_sync(_, _, _), do: {:error, Noizu.MCP.Sync.Protocol.error("permission_denied")}
  end

  setup do
    Fixture.setup_engine()

    Application.put_env(
      :noizu_mcp,
      :engine,
      Keyword.merge(Noizu.MCP.Engine.Config.all(), connect_timeout_ms: 1_000)
    )

    Fixture.ensure_engine!()
    ensure_server_started(Upstream)
    on_exit(fn -> Fixture.reset!() end)

    listener =
      start_supervised!(
        {Bandit,
         plug:
           {Noizu.MCP.Transport.StreamableHTTP.Plug,
            server: Upstream,
            auth: [
              verifier:
                {Noizu.MCP.Auth.ApiKeyVerifier,
                 keys: [{"sync-alice", %{"sub" => "alice"}}, {"sync-bob", %{"sub" => "bob"}}]}
            ]},
         ip: :loopback,
         port: 0,
         startup_log: false},
        id: make_ref()
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(listener)
    %{url: "http://127.0.0.1:#{port}/"}
  end

  test "authenticated sync preserves each principal over real HTTP and refuses pooled identities",
       %{url: url} do
    client = connect(Engine)

    assert {:ok, _} =
             attach_upstream(
               client,
               %{
                 "name" => "sync",
                 "transport" => "http",
                 "url" => url,
                 "auth_ref" => "passthrough",
                 "enabled" => true
               },
               timeout: 10_000
             )

    for {subject, token} <- [{"alice", "sync-alice"}, {"bob", "sync-bob"}] do
      assert {:ok, %{"principal" => ^subject}} =
               request(client, "sync/capabilities", %{"relation" => "sync.notes"},
                 claims: %{"sub" => subject, "token" => token},
                 timeout: 10_000
               )
    end

    alice = Supervisor.session_pid({"sync", "alice"})
    bob = Supervisor.session_pid({"sync", "bob"})
    assert is_pid(alice) and is_pid(bob) and alice != bob

    assert {:error, %{"data" => %{"syncCode" => "permission_denied"}}} =
             request(client, "sync/capabilities", %{"relation" => "sync.notes"})

    assert {:ok, _} =
             attach_upstream(
               client,
               %{
                 "name" => "shared",
                 "transport" => "http",
                 "url" => url,
                 "enabled" => true
               },
               timeout: 10_000
             )

    assert {:error, %{"data" => %{"syncCode" => "permission_denied"}}} =
             request(client, "sync/capabilities", %{"relation" => "shared.notes"},
               claims: %{"sub" => "alice", "token" => "sync-alice"}
             )

    # Close clients while the authenticated listener is still alive.
    Fixture.reset!()
  end
end
