defmodule Noizu.MCP.Sync.WireTest do
  use ExUnit.Case, async: true
  import Noizu.MCP.Test

  defmodule Enabled do
    use Noizu.MCP.Server, name: "sync-wire", version: "1", sync: true
    @impl true
    def handle_sync(method, params, _ctx),
      do: {:ok, %{"method" => method, "relation" => params["relation"]}}
  end

  defmodule Disabled do
    use Noizu.MCP.Server, name: "sync-opt-out", version: "1"
    @impl true
    def handle_sync(_, _, _), do: raise("must never dispatch without opt-in")
  end

  test "opt-in advertises exact version and routes five whitelisted methods" do
    client = connect(Enabled)
    assert %{"version" => 1} = get_in(client.capabilities, ["experimental", "sync"])

    assert {:ok, %{"method" => "sync/capabilities"}} =
             request(client, "sync/capabilities", %{"relation" => "notes"})

    assert {:error, %{"code" => -32601}} =
             request(client, "sync/execute", %{"relation" => "notes"})

    assert {:error, %{"data" => %{"syncCode" => "invalid_request"}}} =
             request(client, "sync/mutate", %{"relation" => "notes"})
  end

  test "callback alone cannot opt in and existing servers remain unchanged" do
    for server <- [Disabled, Noizu.MCP.Fixtures.EmptyServer] do
      client = connect(server)
      refute get_in(client.capabilities, ["experimental", "sync"])

      for method <- ~w(sync/capabilities sync/snapshot sync/changes sync/mutate sync/operation) do
        assert {:error, %{"code" => -32601}} = request(client, method, %{"relation" => "notes"})
      end
    end
  end
end
