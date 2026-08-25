defmodule Noizu.MCP.ClientTest do
  @moduledoc """
  Full client ↔ server integration over the in-memory transport: our
  `Noizu.MCP.Client` talking to our `Noizu.MCP.Server`, including
  server-initiated sampling/elicitation/roots.
  """
  use ExUnit.Case, async: true

  alias Noizu.MCP.Client
  alias Noizu.MCP.Client.Telemetry
  alias Noizu.MCP.Fixtures

  defp start_client(opts \\ []) do
    opts =
      Keyword.merge(
        [
          transport: {:test, server: Keyword.get(opts, :server, Fixtures.Server)},
          client_info: %{name: "client_test", version: "1.0.0"}
        ],
        Keyword.drop(opts, [:server])
      )

    client = start_supervised!({Client, opts}, id: make_ref())
    :ok = Client.await_ready(client)
    client
  end

  defp attach_client_telemetry(client) do
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        Telemetry.events(),
        &__MODULE__.handle_client_telemetry/4,
        {self(), client}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  @doc false
  def handle_client_telemetry(
        event,
        measurements,
        %{client_pid: client} = metadata,
        {test, client}
      ) do
    send(test, {:client_telemetry, event, measurements, metadata})
  end

  def handle_client_telemetry(_event, _measurements, _metadata, _config), do: :ok

  describe "handshake" do
    test "negotiates and exposes server info" do
      client = start_client()

      assert Client.server_info(client).name == "fixture"
      assert Client.server_capabilities(client)["tools"]
      assert Client.instructions(client) == "Fixture server for tests."
      assert :ok = Client.ping(client)
    end

    test "calls made before ready are queued, not lost" do
      opts = [
        transport: {:test, server: Fixtures.Server},
        client_info: %{name: "queued", version: "1.0.0"}
      ]

      client = start_supervised!({Client, opts}, id: make_ref())
      # No await_ready — fire immediately.
      assert {:ok, _tools} = Client.list_tools(client)
    end
  end

  describe "tools" do
    test "emits correlated request and tool spans without payloads" do
      client = start_client()
      attach_client_telemetry(client)

      assert {:ok, result} =
               Client.call_tool(client, "echo", %{"message" => "secret-payload"},
                 telemetry_metadata: %{
                   correlation_id: "chain-123",
                   secret: "must-not-escape"
                 }
               )

      assert [%{text: "secret-payload"}] = result.content

      assert_receive {:client_telemetry, [:noizu_mcp, :client, :request, :start],
                      %{system_time: system_time}, request_start}

      assert is_integer(system_time)
      assert request_start.client_pid == client
      assert request_start.method == "tools/call"
      assert request_start.tool_name == "echo"
      assert request_start.correlation_id == "chain-123"
      refute Map.has_key?(request_start, :secret)

      assert_receive {:client_telemetry, [:noizu_mcp, :client, :tool, :start], _, tool_start}

      assert tool_start.request_id == request_start.request_id

      assert_receive {:client_telemetry, [:noizu_mcp, :client, :request, :stop],
                      %{duration: duration}, request_stop}

      assert duration >= 0
      assert request_stop.request_id == request_start.request_id
      assert request_stop.status == :ok

      assert_receive {:client_telemetry, [:noizu_mcp, :client, :tool, :stop], _, tool_stop}
      assert tool_stop.request_id == request_start.request_id

      telemetry = inspect([request_start, request_stop, tool_start, tool_stop])
      refute telemetry =~ "secret-payload"
      refute telemetry =~ "must-not-escape"
    end

    test "emits timeout exceptions for the request and tool spans" do
      client = start_client()
      attach_client_telemetry(client)

      assert {:error, :timeout} =
               Client.call_tool(client, "slow", %{"ms" => 30_000},
                 timeout: 25,
                 telemetry_metadata: %{run_id: "run-7"}
               )

      assert_receive {:client_telemetry, [:noizu_mcp, :client, :request, :start], _, start}
      assert_receive {:client_telemetry, [:noizu_mcp, :client, :tool, :start], _, _}

      assert_receive {:client_telemetry, [:noizu_mcp, :client, :request, :exception],
                      %{duration: duration}, exception}

      assert duration >= 0
      assert exception.request_id == start.request_id
      assert exception.error_kind == :timeout
      assert exception.status == :error
      assert exception.run_id == "run-7"

      assert_receive {:client_telemetry, [:noizu_mcp, :client, :tool, :exception], _,
                      tool_exception}

      assert tool_exception.request_id == start.request_id
    end

    test "emits discovery spans for tool listing" do
      client = start_client()
      attach_client_telemetry(client)

      assert {:ok, tools} = Client.list_tools(client, telemetry_metadata: %{trace_id: "trace-9"})
      assert tools != []

      assert_receive {:client_telemetry, [:noizu_mcp, :client, :request, :start], _, start}
      assert_receive {:client_telemetry, [:noizu_mcp, :client, :discovery, :start], _, discovery}
      assert discovery.request_id == start.request_id
      assert discovery.discovery == :tools
      assert discovery.trace_id == "trace-9"

      assert_receive {:client_telemetry, [:noizu_mcp, :client, :request, :stop], _, _}
      assert_receive {:client_telemetry, [:noizu_mcp, :client, :discovery, :stop], _, stop}
      assert stop.status == :ok
    end

    test "list and call with typed results" do
      client = start_client()

      assert {:ok, tools} = Client.list_tools(client)
      assert Enum.any?(tools, &(&1.name == "echo"))

      assert {:ok, result} = Client.call_tool(client, "echo", %{"message" => "hi"})
      assert result.is_error == false
      assert [%{type: :text, text: "hi"}] = result.content
    end

    test "progress callbacks fire" do
      client = start_client()
      me = self()

      assert {:ok, _} =
               Client.call_tool(client, "get_weather", %{"location" => "NYC"},
                 progress: fn params -> send(me, {:progress, params}) end
               )

      assert_receive {:progress, %{"progress" => 0.5, "message" => "querying provider"}}, 1_000
    end

    test "timeout auto-cancels and the session stays usable" do
      client = start_client()

      assert {:error, :timeout} =
               Client.call_tool(client, "slow", %{"ms" => 30_000}, timeout: 150)

      assert {:ok, %{is_error: false}} = Client.call_tool(client, "echo", %{"message" => "ok"})
    end

    test "async request handles: await and cancel" do
      client = start_client()

      {:ok, ref} =
        Client.async(client, "tools/call", %{"name" => "echo", "arguments" => %{"message" => "x"}})

      assert {:ok, %{"content" => [%{"text" => "x"}]}} = Client.await(client, ref, 1_000)

      {:ok, slow_ref} =
        Client.async(client, "tools/call", %{"name" => "slow", "arguments" => %{"ms" => 30_000}})

      :ok = Client.cancel(client, slow_ref, "changed my mind")
      assert {:error, :unknown_request} = Client.await(client, slow_ref, 100)
    end

    test "protocol errors surface as Error structs" do
      client = start_client()
      assert {:error, %Noizu.MCP.Error{code: -32_602}} = Client.call_tool(client, "nope", %{})
    end
  end

  describe "resources and prompts" do
    test "read, list, templates" do
      client = start_client()

      assert {:ok, [contents]} = Client.read_resource(client, "config://app")
      assert contents.text == ~s({"env":"test"})

      assert {:ok, resources} = Client.list_resources(client)
      assert Enum.any?(resources, &(&1.uri == "config://app"))

      assert {:ok, [template]} = Client.list_resource_templates(client)
      assert template.uri_template == "db://{table}/schema"
    end

    test "manual paging" do
      client = start_client()

      assert {:ok, %{items: items, next: _}} = Client.list_tools(client, page: :first)
      assert is_list(items)
    end

    test "prompts and completion" do
      client = start_client()

      assert {:ok, prompts} = Client.list_prompts(client)
      assert Enum.any?(prompts, &(&1.name == "code_review"))

      assert {:ok, %{messages: [_, _]}} =
               Client.get_prompt(client, "code_review", %{"code" => "x = 1"})

      assert {:ok, %{values: ["strict"]}} =
               Client.complete(client, {:prompt, "code_review"}, "style", "st")
    end
  end

  describe "notifications" do
    test "handler callback and on_notification mirror both fire" do
      client =
        start_client(
          handler: {Fixtures.ClientHandler, self()},
          on_notification: self()
        )

      :ok = Client.subscribe_resource(client, "config://app")
      Fixtures.Server.notify_resource_updated("config://app")

      assert_receive {:handler_note, "notifications/resources/updated",
                      %{"uri" => "config://app"}},
                     1_000

      assert_receive {:mcp_notification, "notifications/resources/updated", _}, 1_000
    end

    test "server log messages reach the handler" do
      client = start_client(handler: {Fixtures.ClientHandler, self()})

      assert {:ok, _} = Client.call_tool(client, "get_weather", %{"location" => "NYC"})
      assert_receive {:handler_note, "notifications/message", %{"data" => "cache miss"}}, 1_000
    end
  end

  describe "server-initiated requests (bidirectional)" do
    test "sampling round-trip through the client handler" do
      client = start_client(handler: {Fixtures.ClientHandler, self()})

      assert {:ok, result} =
               Client.call_tool(client, "consult", %{"question" => "meaning of life?"})

      assert [%{text: "sampled: 42"}] = result.content
      assert_receive {:sampling_request, %{"maxTokens" => 100, "messages" => [message]}}
      assert message["content"]["text"] == "meaning of life?"
    end

    test "elicitation round-trip" do
      client = start_client(handler: {Fixtures.ClientHandler, self()})

      assert {:ok, result} = Client.call_tool(client, "ask_approval", %{})
      assert [%{text: "approved"}] = result.content
      assert_receive {:elicitation_request, %{"message" => "Proceed?"}}
    end

    test "roots/list answered from client state" do
      client =
        start_client(roots: [Noizu.MCP.Types.Root.new("file:///workspace", name: "ws")])

      assert {:ok, result} = Client.call_tool(client, "where_am_i", %{})
      assert [%{text: "file:///workspace"}] = result.content
    end

    test "set_roots emits roots/list_changed and updates answers" do
      client = start_client(roots: [Noizu.MCP.Types.Root.new("file:///a")])

      assert {:ok, %{content: [%{text: "file:///a"}]}} =
               Client.call_tool(client, "where_am_i", %{})

      :ok = Client.set_roots(client, [Noizu.MCP.Types.Root.new("file:///b")])

      assert {:ok, %{content: [%{text: "file:///b"}]}} =
               Client.call_tool(client, "where_am_i", %{})
    end

    test "missing capability yields a clean tool error" do
      # No handler, no roots — server-side Ctx calls fail fast with
      # :capability_not_supported, surfaced as isError results.
      client = start_client()

      assert {:ok, %{is_error: true, content: [%{text: text}]}} =
               Client.call_tool(client, "consult", %{"question" => "?"})

      assert text =~ "capability_not_supported"
    end
  end
end
