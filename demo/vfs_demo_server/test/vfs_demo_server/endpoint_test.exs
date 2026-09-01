defmodule VfsDemoServer.EndpointTest do
  use ExUnit.Case, async: false

  alias VfsDemoServer.{TestServer, WSClient}

  setup do
    _sup = start_supervised!({TestServer, seed: :default})
    port = TestServer.port()
    %{port: port}
  end

  defp auth(port, token \\ "demo-token") do
    {:ok, client} = WSClient.connect(port)

    :ok =
      WSClient.send_frame(client, %{
        "v" => 2,
        "id" => 1,
        "method" => "vfs/auth",
        "params" => %{"token" => token}
      })

    {:ok, frame} = WSClient.recv_frame(client)
    {client, frame}
  end

  defp rpc(client, id, method, params) do
    :ok =
      WSClient.send_frame(client, %{"v" => 2, "id" => id, "method" => method, "params" => params})

    WSClient.recv_frame(client)
  end

  test "vfs/auth with the right token", %{port: port} do
    {client, frame} = auth(port)

    assert %{"v" => 2, "id" => 1, "result" => %{"authenticated" => true, "session_id" => sid}} =
             frame

    assert is_binary(sid)
    WSClient.close(client)
  end

  test "vfs/auth with a bad token draws -32001 and closes", %{port: port} do
    # upgrade-level auth passes (good Bearer); the frame-level vfs/auth fails.
    {:ok, client} = WSClient.connect(port)

    :ok =
      WSClient.send_frame(client, %{
        "v" => 2,
        "id" => 1,
        "method" => "vfs/auth",
        "params" => %{"token" => "wrong"}
      })

    assert {:ok, %{"error" => %{"code" => -32001}}} = WSClient.recv_frame(client)
    assert {:error, :closed} = WSClient.recv_frame(client)
  end

  test "upgrade without a valid Bearer token is rejected 401", %{port: port} do
    assert {:error, {:handshake_failed, 401}} = WSClient.connect(port, "wrong")
  end

  test "ops before auth are refused", %{port: port} do
    {:ok, client} = WSClient.connect(port)
    {:ok, frame} = rpc(client, 7, "vfs/stat", %{"path" => "/"})
    assert %{"error" => %{"code" => -32001}} = frame
    assert {:error, :closed} = WSClient.recv_frame(client)
  end

  test "stat/read/list round-trips over the wire", %{port: port} do
    {client, _} = auth(port)

    assert {:ok, %{"result" => %{"type" => "dir"}}} = rpc(client, 2, "vfs/stat", %{"path" => "/"})

    {:ok, %{"result" => %{"content" => content, "version" => v}}} =
      rpc(client, 3, "vfs/read", %{"path" => "/notes/welcome.md"})

    assert content =~ "real files"
    assert is_integer(v)

    {:ok, %{"result" => %{"entries" => entries}}} =
      rpc(client, 4, "vfs/list", %{"path" => "/notes"})

    assert %{"name" => "welcome.md", "type" => "file", "version" => v_entry} =
             Enum.find(entries, &(&1["name"] == "welcome.md"))

    assert is_integer(v_entry)
  end

  test "write over the wire bumps the version; errno maps carry data.errno_atom", %{port: port} do
    {client, _} = auth(port)

    {:ok, %{"result" => %{"version" => v1}}} =
      rpc(client, 5, "vfs/write", %{"path" => "/etc/dev/flag", "data" => "on\n"})

    {:ok, %{"result" => %{"version" => v2}}} =
      rpc(client, 6, "vfs/write", %{"path" => "/etc/dev/flag", "data" => "off\n"})

    assert v2 > v1

    {:ok, %{"error" => %{"code" => -32002, "data" => %{"errno_atom" => "enoent"}}}} =
      rpc(client, 7, "vfs/read", %{"path" => "/missing"})

    {:ok, %{"error" => %{"code" => -32043}}} = rpc(client, 8, "vfs/read", %{"path" => "/notes"})
  end

  test "search over the wire + ping", %{port: port} do
    {client, _} = auth(port)

    {:ok, %{"result" => %{"matches" => matches}}} =
      rpc(client, 9, "vfs/search", %{"query" => "Welcome"})

    assert [%{"path" => "/notes/welcome.md", "line" => 1}] = matches

    {:ok, %{"result" => %{"pong" => true}}} = rpc(client, 10, "vfs/ping", nil)
  end

  test "subscribe + wire write delivers a versioned event frame", %{port: port} do
    {client, _} = auth(port)

    # regression: root watches receive every event (VFSPubSub ancestor
    # dispatch now includes the "/" key)
    {:ok, %{"result" => %{"subscribed" => true}}} =
      rpc(client, 11, "vfs/subscribe", %{"paths" => ["/etc/dev"], "depth" => "infinity"})

    {:ok, %{"result" => %{"version" => mutated_version}}} =
      rpc(client, 12, "vfs/write", %{"path" => "/etc/dev/tuning.yaml", "data" => "depth: deep\n"})

    # events are debounced 50ms server-side
    assert {:ok,
            %{
              "type" => "vfs/event",
              "op" => "write",
              "path" => "/etc/dev/tuning.yaml",
              "version" => ^mutated_version,
              "by" => "demo"
            }} = WSClient.recv_frame(client, 1_000)
  end

  test "Test.mutate events carry by=test and reach subscribers", %{port: port} do
    {client, _} = auth(port)

    {:ok, %{"result" => %{"subscribed" => true}}} =
      rpc(client, 13, "vfs/subscribe", %{"paths" => ["/etc/dev"], "depth" => "infinity"})

    {:ok, %{"version" => version}} =
      VfsDemoServer.Test.mutate("/etc/dev/flag", :write, "mutated\n")

    assert is_integer(version)

    assert {:ok,
            %{
              "type" => "vfs/event",
              "op" => "write",
              "path" => "/etc/dev/flag",
              "version" => ^version,
              "by" => "test"
            }} = WSClient.recv_frame(client, 1_000)
  end

  test "root watch (\"/\") receives events from anywhere in the tree", %{port: port} do
    {client, _} = auth(port)

    {:ok, %{"result" => %{"subscribed" => true}}} =
      rpc(client, 20, "vfs/subscribe", %{"paths" => ["/"], "depth" => "infinity"})

    {:ok, %{"result" => %{"version" => version}}} =
      rpc(client, 21, "vfs/write", %{"path" => "/personas/loom.md", "data" => "root-watch\n"})

    assert {:ok,
            %{
              "type" => "vfs/event",
              "op" => "write",
              "path" => "/personas/loom.md",
              "version" => ^version
            }} = WSClient.recv_frame(client, 1_000)
  end

  test "unknown method draws -32601", %{port: port} do
    {client, _} = auth(port)
    {:ok, %{"error" => %{"code" => -32601}}} = rpc(client, 14, "vfs/frobnicate", %{})
    WSClient.close(client)
  end
end
