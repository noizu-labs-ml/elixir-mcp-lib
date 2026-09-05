# Virtual Filesystem

## Behaviour

`Noizu.MCP.VFS` exposes a node tree (dirs / files / `:control` nodes)
over paths. Backends implement stat/list/read (+ write/remove/search/
xattr when writable). Transports mount backends as `vfs/*` extension
ops (M2); mount clients consume them — the companion
`daemon/mcp_mount` escript mounts a VFS server as real local files
over WebSocket, so grep / cat / `tail -f` / cron work on MCP data.

## Node contract

Nodes are `%Noizu.MCP.VFS{type, size, mtime, version, writable,
executable, xattrs}`. `version` bumps on every write and embeds the
backend's cache generation — clients key content caches on it.

Errors are standard errno atoms (`:enoent`, `:eacces`, `:erofs`, …)
mapped to JSON-RPC codes by the transport. Read-only backends
implement only stat/list/read; write/remove/search/xattr default to
`:enosys`, and `__mcp_vfs__(:implemented)` derives the `vfs_write`
capability flag (`Server.VFS` derives both flags from the configured
backends).

## Cache

`VFS.Cache` is a per-backend `:persistent_term` TTL cache (default
60s) over stat/list/read, keyed by a generation counter. Every
successful write bumps the generation and drops all entries — no key
bookkeeping; the TTL is the backstop for out-of-band writes.

## Control tree

`VFS.Control` composes an `/etc/dev` introspection and control tree
into any backend by delegation (the generated module IS the registered
backend; root listings merge `etc/dev` in):

- `/etc/dev/tools/<tool>` — write a JSON line to invoke a tool; the
  result is buffered into the next read
- `/etc/dev/runtime/*` — status, sessions
- `/etc/dev/cache/{stats,flush}`
- `/etc/dev/config/<toggle>` — validated JSON writes applied as toggles

VFS change pubsub (`Server.VFSPubsub`) fans per-path changes to
subtree watchers.

## Transports

Three VFS-specific transports carry `vfs/*` ops to local clients:

| Transport | Wire |
|-----------|------|
| `Transport.VFS.Socket` | Length-prefixed JSON-RPC over unix domain socket |
| `Transport.VFS.WS` | WebSocket, `GET /vfs` upgrade |
| `Transport.VFS.Client` | Elixir client for the socket transport |

## mcp-mount daemon

`daemon/mcp_mount` is an Elixir escript speaking the same wire ops:
bidirectional sync (server `vfs/event` changes apply down; a debounced
250ms local watcher pushes writes up), `.mcp-mount/manifest.json`
tracks `{path → version}`, version conflicts are saved aside as
`.conflict-<ts>` and re-pulled from server state, and reconnect does a
version-diff resync (no event log). State machine:
`init → authing → syncing → live ⇄ reconnecting` with exponential
backoff. The connection is a swappable `McpMount.Conn` behaviour
(`mint_web_socket` in production, `FakeConn` in tests).
