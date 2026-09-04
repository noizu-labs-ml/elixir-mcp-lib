defmodule Noizu.MCP.Transport.StreamableHTTPTest do
  @moduledoc """
  Streamable HTTP transport tests: Plug-level request/response matrix via
  Plug.Test, and full client ↔ server round-trips over a real Bandit listener.
  """
  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 3]
  import Plug.Conn

  alias Noizu.MCP.Fixtures
  alias Noizu.MCP.Transport.StreamableHTTP

  # `sse_commit_after` is generous here on purpose. The plug waits this long for
  # a handler's final response and then *deliberately* commits to SSE, so a slow
  # call reaches the client promptly with keepalives. At the 200ms default, a
  # busy machine — the full suite runs 20 cases wide alongside Bandit listeners
  # and Postgres pools — can starve a microsecond-fast `tools/list` past the
  # window, the plug correctly upgrades, and a test asserting the JSON fast path
  # fails for reasons that have nothing to do with the transport.
  #
  # The property under test is "a handler that answers promptly answers as
  # JSON". Widening the window keeps that property and removes its dependency on
  # the machine being idle. The timer-driven upgrade is pinned deliberately, with
  # its own explicit window, in "commits to SSE when the handler is slow" below.
  @plug_opts StreamableHTTP.Plug.init(server: Fixtures.Server, sse_commit_after: 5_000)

  setup_all do
    Noizu.MCP.Test.ensure_server_started(Fixtures.Server)
  end

  defp poll_until(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && poll_until(fun, attempts - 1)
    end
  end

  defp post_json(body, headers \\ []) do
    conn =
      conn(:post, "/", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")

    headers
    |> Enum.reduce(conn, fn {key, value}, conn -> put_req_header(conn, key, value) end)
    |> StreamableHTTP.Plug.call(@plug_opts)
  end

  defp initialize do
    conn =
      post_json(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-11-25",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "plug_test", "version" => "1.0.0"}
        }
      })

    assert conn.status == 200
    [session_id] = get_resp_header(conn, "mcp-session-id")
    body = Jason.decode!(conn.resp_body)

    # Complete the handshake.
    notify_conn =
      post_json(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}, [
        {"mcp-session-id", session_id}
      ])

    assert notify_conn.status == 202
    {session_id, body}
  end

  describe "plug request matrix" do
    test "initialize creates a session and returns Mcp-Session-Id" do
      {session_id, body} = initialize()

      assert is_binary(session_id) and byte_size(session_id) > 16
      assert body["result"]["protocolVersion"] == "2025-11-25"
      assert body["result"]["serverInfo"]["name"] == "fixture"
    end

    test "request without a session id is 400" do
      conn = post_json(%{"jsonrpc" => "2.0", "id" => 5, "method" => "tools/list"})
      assert conn.status == 400
    end

    test "request with an unknown session id is 404" do
      conn =
        post_json(%{"jsonrpc" => "2.0", "id" => 5, "method" => "tools/list"}, [
          {"mcp-session-id", "nope"}
        ])

      assert conn.status == 404
    end

    test "json-path request answers as application/json" do
      {session_id, _} = initialize()

      conn =
        post_json(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}, [
          {"mcp-session-id", session_id},
          {"mcp-protocol-version", "2025-11-25"}
        ])

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
      assert %{"result" => %{"tools" => tools}} = Jason.decode!(conn.resp_body)
      assert is_list(tools)
    end

    test "commits to SSE when the handler is slow, with no message to prompt it" do
      # The timer branch, pinned. Until now nothing exercised it deliberately —
      # it was reached only by accident, when load starved a fast handler past
      # the window, which is exactly why that presented as a flake. Here the
      # window is explicit and tiny and the tool genuinely outlives it, so the
      # upgrade is caused by the timer and by nothing else: `slow` emits no
      # progress, so there is no non-final message to trigger the other path.
      opts = StreamableHTTP.Plug.init(server: Fixtures.Server, sse_commit_after: 50)
      {session_id, _} = initialize()

      conn =
        conn(
          :post,
          "/",
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 7,
            "method" => "tools/call",
            "params" => %{"name" => "slow", "arguments" => %{"ms" => 400}}
          })
        )
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("mcp-protocol-version", "2025-11-25")
        |> StreamableHTTP.Plug.call(opts)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/event-stream"
    end

    test "request that emits progress upgrades to SSE" do
      {session_id, _} = initialize()

      conn =
        post_json(
          %{
            "jsonrpc" => "2.0",
            "id" => 3,
            "method" => "tools/call",
            "params" => %{
              "name" => "get_weather",
              "arguments" => %{"location" => "NYC"},
              "_meta" => %{"progressToken" => "pt"}
            }
          },
          [{"mcp-session-id", session_id}]
        )

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/event-stream"

      {events, ""} = Noizu.MCP.Transport.SSE.parse("", conn.resp_body)
      decoded = Enum.map(events, &Jason.decode!(&1.data))

      assert Enum.any?(decoded, &(&1["method"] == "notifications/progress"))
      assert Enum.any?(decoded, &(&1["id"] == 3 and &1["result"]))
    end

    test "invalid protocol version header is 400" do
      {session_id, _} = initialize()

      conn =
        post_json(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}, [
          {"mcp-session-id", session_id},
          {"mcp-protocol-version", "1999-01-01"}
        ])

      assert conn.status == 400
    end

    test "disallowed browser origin is 403" do
      conn =
        post_json(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"}, [
          {"origin", "https://evil.example.com"}
        ])

      assert conn.status == 403
    end

    test "localhost origin is allowed by default" do
      {session_id, _} = initialize()

      conn =
        post_json(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}, [
          {"mcp-session-id", session_id},
          {"origin", "http://localhost:5173"}
        ])

      assert conn.status == 200
    end

    test "DELETE terminates the session; subsequent requests are 404" do
      {session_id, _} = initialize()

      conn =
        conn(:delete, "/", "")
        |> put_req_header("mcp-session-id", session_id)
        |> StreamableHTTP.Plug.call(@plug_opts)

      assert conn.status == 200

      # Registry cleanup on session death is asynchronous — poll briefly.
      assert poll_until(fn ->
               conn =
                 post_json(%{"jsonrpc" => "2.0", "id" => 9, "method" => "tools/list"}, [
                   {"mcp-session-id", session_id}
                 ])

               conn.status == 404
             end)
    end

    test "GET without Accept: text/event-stream is 406" do
      {session_id, _} = initialize()

      conn =
        conn(:get, "/", "")
        |> put_req_header("mcp-session-id", session_id)
        |> put_req_header("accept", "application/json")
        |> StreamableHTTP.Plug.call(@plug_opts)

      assert conn.status == 406
    end

    test "unsupported method is 405" do
      conn = conn(:put, "/", "") |> StreamableHTTP.Plug.call(@plug_opts)
      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["GET, POST, DELETE"]
    end

    test "non-JSON body is 400" do
      conn =
        conn(:post, "/", "{nope")
        |> put_req_header("content-type", "application/json")
        |> StreamableHTTP.Plug.call(@plug_opts)

      assert conn.status == 400
    end
  end

  # ── client-disconnect teardown (noizu_mcp stage noise ×3) ─────────────────

  describe "client disconnects mid-stream" do
    defp closed_conn(method, path, body, headers) do
      base =
        conn(method, path, body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream")

      headers
      |> Enum.reduce(base, fn {key, value}, c -> put_req_header(c, key, value) end)
      # Swap in an adapter whose chunk/2 reports the client as gone.
      |> then(fn c ->
        %{
          c
          | adapter:
              {Noizu.MCP.Test.ClosedConnAdapter, Noizu.MCP.Test.ClosedConnAdapter.init(body)}
        }
      end)
    end

    test "a chunk against a closed client tears down instead of MatchError-raising" do
      # Pre-fix: the stream loop matched bare `{:ok, conn} = chunk(conn, ...)`;
      # a client that disconnected mid-call (tab closed, client timeout) made
      # Plug return {:error, :closed} and the request process died with
      # ** (MatchError) {:error, :closed} — the noise seen in stage logs.
      opts = StreamableHTTP.Plug.init(server: Fixtures.Server, sse_commit_after: 5_000)
      {session_id, _} = initialize()

      body =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 11,
          "method" => "tools/call",
          "params" => %{
            "name" => "get_weather",
            "arguments" => %{"location" => "NYC"},
            "_meta" => %{"progressToken" => "pt"}
          }
        })

      conn =
        closed_conn(:post, "/", body, [
          {"mcp-session-id", session_id},
          {"mcp-protocol-version", "2025-11-25"}
        ])

      # get_weather emits progress (non-final) first: the loop upgrades to SSE
      # and chunks into the closed connection. Post-fix that folds to a clean
      # teardown; pre-fix Plug.call/2 raised here.
      assert %Plug.Conn{status: 200} = StreamableHTTP.Plug.call(conn, opts)
    end
  end

  describe "full round-trip over Bandit" do
    setup do
      start_supervised!(
        {Bandit,
         plug: {StreamableHTTP.Plug, server: Fixtures.Server},
         port: 0,
         ip: :loopback,
         startup_log: false,
         thousand_island_options: [shutdown_timeout: 10]},
        id: make_ref()
      )
      |> then(fn pid ->
        {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
        %{url: "http://127.0.0.1:#{port}/"}
      end)
    end

    defp start_http_client(url, opts \\ []) do
      opts =
        Keyword.merge(
          [transport: {:streamable_http, url: url}, client_info: %{name: "http", version: "1"}],
          opts
        )

      client = start_supervised!({Noizu.MCP.Client, opts}, id: make_ref())
      :ok = Noizu.MCP.Client.await_ready(client, 15_000)
      client
    end

    test "handshake, tools, progress over HTTP", %{url: url} do
      client = start_http_client(url)

      assert Noizu.MCP.Client.server_info(client).name == "fixture"

      assert {:ok, tools} = Noizu.MCP.Client.list_tools(client)
      assert Enum.any?(tools, &(&1.name == "echo"))

      me = self()

      assert {:ok, result} =
               Noizu.MCP.Client.call_tool(client, "get_weather", %{"location" => "NYC"},
                 progress: fn params -> send(me, {:progress, params}) end
               )

      assert result.structured["temperature"] == 21.5
      assert_receive {:progress, %{"progress" => 0.5}}, 5_000
    end

    test "bidirectional sampling over the POST SSE stream", %{url: url} do
      client = start_http_client(url, handler: {Fixtures.ClientHandler, self()})

      assert {:ok, result} = Noizu.MCP.Client.call_tool(client, "consult", %{"question" => "?"})
      assert [%{text: "sampled: 42"}] = result.content
      assert_receive {:sampling_request, _}, 5_000
    end

    test "unsolicited notifications arrive via the general GET stream", %{url: url} do
      client =
        start_http_client(url,
          handler: {Fixtures.ClientHandler, self()},
          on_notification: self()
        )

      :ok = Noizu.MCP.Client.subscribe_resource(client, "config://app")
      Fixtures.Server.notify_resource_updated("config://app")

      assert_receive {:mcp_notification, "notifications/resources/updated",
                      %{"uri" => "config://app"}},
                     5_000
    end

    test "resources and prompts over HTTP", %{url: url} do
      client = start_http_client(url)

      assert {:ok, [contents]} = Noizu.MCP.Client.read_resource(client, "config://app")
      assert contents.text == ~s({"env":"test"})

      assert {:ok, %{messages: [_, _]}} =
               Noizu.MCP.Client.get_prompt(client, "code_review", %{"code" => "x"})
    end
  end

  describe "event store" do
    test "append, replay_after, prune ordering" do
      alias Noizu.MCP.Server.EventStore

      id1 = EventStore.append(Fixtures.Server, "es-test", "one")
      id2 = EventStore.append(Fixtures.Server, "es-test", "two")
      id3 = EventStore.append(Fixtures.Server, "es-test", "three")

      assert [{^id1, "one"}, {^id2, "two"}, {^id3, "three"}] =
               EventStore.replay_after(Fixtures.Server, "es-test", nil)

      assert [{^id3, "three"}] = EventStore.replay_after(Fixtures.Server, "es-test", id2)

      EventStore.drop(Fixtures.Server, "es-test")
      assert [] = EventStore.replay_after(Fixtures.Server, "es-test", nil)
    end
  end
end
