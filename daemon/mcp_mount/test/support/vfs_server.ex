defmodule McpMount.Test.VfsServer do
  @moduledoc """
  TEST-ONLY minimal VFS protocol server: bandit + WebSock handler over an
  in-memory store, speaking the same v2 wire protocol the demo server speaks.
  Used by mcp_mount integration tests (the apps stay decoupled — this is a
  self-contained fixture, not a dependency on vfs_demo_server).
  """

  use Supervisor

  alias McpMount.Test.VfsServer.Store

  @token "test-token"

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def port, do: Store.port()

  @doc "Remote mutation; broadcasts an event to subscribed connections."
  def mutate(path, op, data \\ nil), do: Store.mutate(path, op, data)

  @impl Supervisor
  def init(_opts) do
    port = free_port()

    children = [
      {Store, port: port},
      {Bandit, plug: McpMount.Test.VfsServer.Endpoint, scheme: :http, port: port}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defmodule Store do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    def port, do: GenServer.call(__MODULE__, :port)

    def call(method, params, session),
      do: GenServer.call(__MODULE__, {:op, method, params, session})

    def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})
    def unsubscribe(pid), do: GenServer.call(__MODULE__, {:unsubscribe, pid})

    def mutate(path, op, data) do
      GenServer.call(__MODULE__, {:mutate, path, op, data})
    end

    @impl GenServer
    def init(opts) do
      seed = %{
        "/" => %{type: :dir, version: 1},
        "/docs" => %{type: :dir, version: 1},
        "/docs/hello.txt" => %{type: :file, version: 1, content: "hello world\n"},
        "/docs/note.md" => %{type: :file, version: 1, content: "# note\n\nseed body\n"}
      }

      {:ok, %{nodes: seed, port: Keyword.fetch!(opts, :port), subs: %{}, seq: 0}}
    end

    @impl GenServer
    def handle_call(:port, _from, state), do: {:reply, state.port, state}

    def handle_call({:subscribe, pid}, _from, state) do
      ref = Process.monitor(pid)
      {:reply, :ok, %{state | subs: Map.put(state.subs, pid, ref)}}
    end

    def handle_call({:unsubscribe, pid}, _from, state) do
      case Map.pop(state.subs, pid) do
        {nil, subs} ->
          {:reply, :ok, %{state | subs: subs}}

        {ref, subs} ->
          Process.demonitor(ref, [:flush])
          {:reply, :ok, %{state | subs: subs}}
      end
    end

    def handle_call({:op, method, params, _session}, _from, state) do
      case op(method, params, state) do
        {reply, state} -> {:reply, {:ok, reply}, state}
        {:error, errno} -> {:reply, {:error, errno}, state}
      end
    end

    def handle_call({:mutate, path, op, data}, _from, state) do
      {reply, state} = apply_mutation(state, path, op, data)
      {:reply, reply, state}
    end

    @impl GenServer
    def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
      {:noreply, %{state | subs: Map.delete(state.subs, pid)}}
    end

    # ── ops (mirror the demo/lib wire contract) ──────────────────────────

    defp op("vfs/list", %{"path" => path}, state) do
      children =
        state.nodes
        |> Enum.filter(fn {p, _} -> parent(p) == path end)
        |> Enum.sort()
        |> Enum.map(fn {p, node} ->
          %{"name" => basename(p), "type" => to_string(node.type), "version" => node.version}
        end)

      {%{"entries" => children}, state}
    end

    defp op("vfs/read", %{"path" => path}, state) do
      case state.nodes[path] do
        %{type: :file, content: c, version: v} -> {%{"content" => c, "version" => v}, state}
        %{type: :dir} -> {:error, :eisdir}
        nil -> {:error, :enoent}
      end
    end

    defp op("vfs/stat", %{"path" => path}, state) do
      case state.nodes[path] do
        nil ->
          {:error, :enoent}

        node ->
          {%{"type" => to_string(node.type), "version" => node.version, "executable" => false},
           state}
      end
    end

    defp op("vfs/write", %{"path" => path, "data" => data}, state) do
      case Map.get(state.nodes, path) do
        %{type: :file} ->
          version = state.nodes[path].version + 1
          state = put_in(state.nodes[path].content, data)
          state = put_in(state.nodes[path].version, version)
          broadcast(state, "write", path, version)
          {%{"version" => version, "executable" => false}, state}

        %{type: :dir} ->
          {:error, :eisdir}

        nil ->
          {:error, :enoent}
      end
    end

    defp op("vfs/ping", _, state), do: {%{"pong" => true}, state}
    defp op(_m, _p, state), do: {{}, state}

    # ── mutations (test hook + shared by write op) ───────────────────────

    defp apply_mutation(state, path, :write, content) do
      op("vfs/write", %{"path" => path, "data" => content}, state)
    end

    defp apply_mutation(state, path, :create, content) do
      node =
        if content == nil,
          do: %{type: :dir, version: 1},
          else: %{type: :file, version: 1, content: content}

      state = put_in(state.nodes[path], node)
      broadcast(state, "create", path, 1)
      {%{"version" => 1, "executable" => false}, state}
    end

    defp apply_mutation(state, path, :remove, _data) do
      state = %{state | nodes: Map.delete(state.nodes, path)}
      broadcast(state, "remove", path, 0)
      {%{"removed" => path}, state}
    end

    defp broadcast(state, op, path, version) do
      state = %{state | seq: state.seq + 1}

      Enum.each(state.subs, fn {pid, _ref} ->
        send(
          pid,
          {:vfs_event,
           %{
             op: op,
             path: path,
             version: version,
             seq: state.seq,
             by: "test",
             at: System.system_time(:millisecond)
           }}
        )
      end)

      state
    end

    defp parent("/"), do: nil

    defp parent(p) do
      case String.split(p, "/", trim: true) do
        [_] -> "/"
        parts -> "/" <> Enum.join(Enum.drop(parts, -1), "/")
      end
    end

    defp basename(p), do: p |> String.split("/", trim: true) |> List.last()
  end

  defmodule Endpoint do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(%Plug.Conn{path_info: ["vfs"]} = conn, _opts) do
      upgrade_adapter(conn, :websocket, {McpMount.Test.VfsServer.WS, %{}, []})
    end

    def call(conn, _opts), do: send_resp(conn, 404, "not found")
  end

  defmodule WS do
    @moduledoc false
    @behaviour WebSock

    @token "test-token"
    @auth_code -32001

    @impl WebSock
    def init(_), do: {:ok, %{authed: false}}

    @impl WebSock
    def handle_in({data, opcode: :text}, state) do
      case Jason.decode(data) do
        {:ok, %{"id" => id, "method" => method, "params" => params}} ->
          handle_frame(id, method, params || %{}, state)

        _ ->
          {:push, {:text, err(id_of(data), -32600, "invalid request")}, state}
      end
    end

    def handle_in({data, opcode: :binary}, state), do: handle_in({data, opcode: :text}, state)

    @impl WebSock
    def handle_info({:vfs_event, ev}, state) do
      frame = %{
        "v" => 2,
        "type" => "vfs/event",
        "seq" => ev.seq,
        "op" => ev.op,
        "path" => ev.path,
        "version" => ev.version,
        "by" => ev.by,
        "at" => ev.at
      }

      {:push, {:text, Jason.encode!(frame)}, state}
    end

    def handle_info(_, state), do: {:ok, state}

    defp handle_frame(id, "vfs/auth", %{"token" => @token}, state) do
      {:push, {:text, ok(id, %{"authenticated" => true, "session_id" => "test"})},
       %{state | authed: true}}
    end

    defp handle_frame(id, "vfs/auth", _, state) do
      {:stop, :normal, {3000, "auth failed"}, {:text, err(id, @auth_code, "auth failed")}, state}
    end

    defp handle_frame(id, _method, _params, %{authed: false} = state) do
      {:push, {:text, err(id, @auth_code, "not authenticated")}, state}
    end

    defp handle_frame(id, "vfs/subscribe", _params, state) do
      Store.subscribe(self())
      {:push, {:text, ok(id, %{"subscribed" => true})}, state}
    end

    defp handle_frame(id, "vfs/unsubscribe", _params, state) do
      Store.unsubscribe(self())
      {:push, {:text, ok(id, %{"unsubscribed" => true})}, state}
    end

    defp handle_frame(id, method, params, state) do
      case Store.call(method, params, nil) do
        {:ok, result} ->
          {:push, {:text, ok(id, result)}, state}

        {:error, errno} ->
          {:push,
           {:text,
            Jason.encode!(%{
              "v" => 2,
              "id" => id,
              "error" => %{
                "code" => -32000,
                "message" => "vfs error",
                "data" => %{"errno_atom" => Atom.to_string(errno)}
              }
            })}, state}
      end
    end

    defp ok(id, result), do: Jason.encode!(%{"v" => 2, "id" => id, "result" => result})

    defp err(id, code, msg),
      do: Jason.encode!(%{"v" => 2, "id" => id, "error" => %{"code" => code, "message" => msg}})

    defp id_of(_data), do: nil
  end
end
