# Supervision Tree

Each `use Noizu.MCP.Server` module (e.g. `MyApp.MCP`) starts as a `Supervisor` with this shape:

```
MyApp.MCP (Supervisor, one_for_one)
├── MyApp.MCP.Registry              # Session lookup (Registry, :unique)
├── MyApp.MCP.TaskSupervisor        # Handler execution (Task.Supervisor)
├── MyApp.MCP.SessionSupervisor     # Per-client sessions (DynamicSupervisor)
├── MyApp.MCP.EventStore            # Only for Streamable HTTP (ETS ring buffer)
├── Persistence.Ping (boot gate)    # Only for external providers (e.g. Ecto)
└── Noizu.MCP.Transport.Stdio       # Only when transport: :stdio (or :vfs_socket)
```

## Components

**Registry** — Keyed by `{:session, session_id}`. Used for session lookup, list-changed fan-out (`notify_changed/1`), and resource-updated notifications. The supervisor self-registers in a `:persistent_term` registry that `running_servers/0` reads — the source of the Store facade's `server: :all` notify fan-out.

**TaskSupervisor** — Every feature request (tools/call, resources/read, etc.) runs as a `Task.Supervisor.async_nolink` task. This isolates handler crashes from the session process and enables cancellation via `Process.exit(pid, :kill)`.

**SessionSupervisor** — `DynamicSupervisor` managing `Noizu.MCP.Server.Session` GenServers. Each connected client gets one session. Sessions are `:temporary` — they don't restart on crash. The resolved persistence provider rides into session init opts.

**EventStore** — Present when using the Streamable HTTP transport. Bounded per-session ETS ring buffer (default 1000 events) that backs SSE `Last-Event-ID` resumability and buffers messages emitted while no stream is live. Node-local.

**Persistence boot gate (`Persistence.Ping`)** — A permanent child started for every resolved provider except the Memory/Disabled built-ins. At init it pings the provider (`version/2` roundtrip; Ecto shape reports `{:tables_missing, names}`). Failure ⇒ `{:stop, reason}` ⇒ the supervisor's `start_link` fails ⇒ **the server does not boot** — a misconfigured store must not degrade into a server pretending persistence works. Survives as a `:ping` `handle_call` for post-boot health checks.

**Stdio Transport** — When `transport: :stdio` is passed, `Noizu.MCP.Transport.Stdio` starts as a child and automatically creates one implicit session. It reads newline-delimited JSON-RPC from stdin and writes responses to stdout. (`:vfs_socket` starts the VFS unix-socket transport instead.)

One persistence resolution per server happens at boot and is stashed in `:persistent_term` (`{server, :persistence}`); reads stay lazy — explicit per-call opts still win.

## Session startup

Transports call `Noizu.MCP.Server.Supervisor.start_session/2` which adds a `Session` to the `SessionSupervisor`. The session receives a **sink** (`{module, term}`) — the transport's callback for writing outbound messages.

## Client supervision

`Noizu.MCP.Client` is a standalone GenServer (not a supervisor tree). It starts its own `Task.Supervisor` for handler tasks and the chosen client transport as a linked process.
