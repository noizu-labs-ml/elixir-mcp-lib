defmodule Noizu.MCP.Server.Supervisor do
  @moduledoc """
  Supervision tree for one logical MCP server: a session registry, a dynamic
  supervisor for per-client sessions, a task supervisor for handler execution,
  and (when `transport: :stdio`) the stdio transport with its single implicit
  session.

  Started for you by `use Noizu.MCP.Server` — add the server module to your
  application's supervision tree:

      children = [{MyApp.MCP, transport: :stdio}]

  PRD-4: `init/1` also resolves the server's persistence provider ONCE
  (`persistence:` / `providers:` opts > Application env > `:memory`) and
  stashes it in `:persistent_term` under `{server, :persistence}` — that stash
  is what non-session callers read through
  `Noizu.MCP.Persistence.resolved/2`. Providers other than the `Memory`/
  `Disabled` built-ins get a `Noizu.MCP.Persistence.Ping` boot child: a
  provider whose backing store is misconfigured fails the whole boot (D4 — a
  config error must not degrade silently). Supervisors self-register in a
  `:persistent_term` registry that `running_servers/0` reads — the Store write
  path fans its `notify_changed(:tools)` out over it (§4.7).
  """

  use Supervisor

  @running_servers {__MODULE__, :running_servers}

  @doc false
  # ⟦𓏪𓎚𓇛𓇏⟧ start_link :: auto-generated pointer for public function start_link
  def start_link(server, opts \\ []) do
    Supervisor.start_link(__MODULE__, {server, opts}, name: server)
  end

  @impl true
  # ⟦𓁥𓂱𓎥𓈁⟧ init :: auto-generated pointer for public function init
  def init({server, opts}) do
    # §4.3: one resolution per server, at boot. Use-time opts (the `use
    # Noizu.MCP.Server, persistence: ...` block) sit under the runtime opts
    # the child spec carries; per-server beats env beats :memory (inside
    # resolved/2). D3: the STASH is boot-time, but reads stay lazy — an
    # explicit per-call `persistence:`/`providers:` opt still wins (§4.3 (1)).
    resolved = Noizu.MCP.Persistence.resolved(server, effective_opts(server, opts))
    :persistent_term.put({server, :persistence}, resolved)
    register_running(server)

    children =
      [
        {Registry, keys: :unique, name: Module.concat(server, Registry)},
        {Task.Supervisor, name: Module.concat(server, TaskSupervisor)},
        {DynamicSupervisor,
         name: Module.concat(server, SessionSupervisor), strategy: :one_for_one},
        {Noizu.MCP.Server.EventStore, server: server}
      ] ++ persistence_children(server, resolved) ++ transport_children(server, opts)

    Supervisor.init(children, strategy: :one_for_one)
  end

  # The boot gate child (D4, §4.2): every resolved provider except the
  # Memory/Disabled built-ins must ping before the server serves. `Disabled`
  # is a POLICY, not a store (no ping); `Memory` cannot fail to boot.
  defp persistence_children(_server, {Noizu.MCP.Persistence.Memory, _}), do: []

  defp persistence_children(_server, {Noizu.MCP.Persistence.Disabled, _}), do: []

  defp persistence_children(server, {provider, provider_opts}) do
    [
      {Noizu.MCP.Persistence.Ping,
       server: server,
       provider: provider,
       provider_opts: provider_opts,
       name: Module.concat(server, PersistencePing)}
    ]
  end

  defp persistence_children(_server, _other), do: []

  defp effective_opts(server, opts) do
    use_opts =
      try do
        List.wrap(server.__mcp__(:opts))
      rescue
        _ -> []
      end

    Keyword.merge(use_opts, opts)
  end

  defp transport_children(server, opts) do
    case Keyword.get(opts, :transport) do
      nil ->
        []

      :stdio ->
        [{Noizu.MCP.Transport.Stdio, Keyword.put(opts, :server, server)}]

      {:vfs_socket, socket_opts} when is_list(socket_opts) ->
        [{Noizu.MCP.Transport.VFSSocket, Keyword.put(socket_opts, :server, server)}]

      :vfs_socket ->
        [{Noizu.MCP.Transport.VFSSocket, [server: server]}]

      other ->
        raise ArgumentError, "unknown MCP server transport: #{inspect(other)}"
    end
  end

  @doc """
  Start a new session for `server`. Used by transports; `opts` must include
  `:sink` and may include `:session_id` and `:transport`.

  The resolved persistence provider rides into the session's init opts (§4.3)
  — sessions hold it for ctx-facing calls; lazy `resolved/2` re-resolution
  keeps explicit opts authoritative (D3).
  """
  @spec start_session(module(), keyword()) :: DynamicSupervisor.on_start_child()
  # ⟦𓇴𓌒𓇘𓎧⟧ start_session :: Start a new session for `server`.
  def start_session(server, opts) do
    resolved = :persistent_term.get({server, :persistence}, nil)

    opts =
      if resolved do
        Keyword.put_new(opts, :persistence, resolved)
      else
        opts
      end

    DynamicSupervisor.start_child(
      Module.concat(server, SessionSupervisor),
      {Noizu.MCP.Server.Session, Keyword.put(opts, :server, server)}
    )
  end

  @doc "List the pids of all live sessions for `server`."
  @spec sessions(module()) :: [pid()]
  # ⟦𓆩𓌢𓐜𓁨⟧ sessions :: List the pids of all live sessions for `server`.
  def sessions(server) do
    Registry.select(Module.concat(server, Registry), [
      {{{:session, :_}, :"$1", :_}, [], [:"$1"]}
    ])
  end

  @doc """
  The server modules whose supervision tree is (or was, at boot) running —
  the `Store` notify fan-out (`server: :all`, §4.7) enumerates this. Entries
  whose supervisor process is gone are filtered lazily, so a crashed tree
  never receives notifications.
  """
  # ⟦𓂋𓎲𓈖𓈖𓇋𓈖𓎼⟧ running_servers :: The server modules whose supervision tree is (or was, at boot) running —.
  @spec running_servers() :: [module()]
  def running_servers do
    @running_servers
    |> :persistent_term.get(MapSet.new())
    |> MapSet.to_list()
    |> Enum.filter(fn server ->
      case Process.whereis(server) do
        nil ->
          deregister_running(server)
          false

        _pid ->
          true
      end
    end)
  end

  defp register_running(server) do
    :persistent_term.put(@running_servers, MapSet.put(current_running(), server))
  end

  defp deregister_running(server) do
    :persistent_term.put(@running_servers, MapSet.delete(current_running(), server))
  end

  defp current_running, do: :persistent_term.get(@running_servers, MapSet.new())

  # Best-effort deregistration on a clean stop; `running_servers/0` filters
  # crashed trees lazily either way (a dead supervisor's name is unregistered).
  @impl false
  def terminate(_reason, _state) do
    case Process.info(self(), :registered_name) do
      {:registered_name, [name]} -> deregister_running(name)
      _ -> :ok
    end

    :ok
  end
end
