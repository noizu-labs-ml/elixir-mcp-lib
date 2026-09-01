# mcp-mount

Mount an MCP VFS server as **real local files**, kept live over WebSocket.

`mcp-mount` connects to a VFS WebSocket endpoint (v2 JSON text-frame protocol),
snapshots the tree into a real directory, then keeps it in sync both ways:

- **server → local**: subscribed change events (`vfs/event`) are applied to the
  mounted files in real time.
- **local → server**: a filesystem watcher (250 ms debounce) pushes local edits
  back as `vfs/write` / `vfs/create` calls. If the server moved ahead of a local
  edit, the local file is saved aside as `<path>.conflict-<ISO-timestamp>` and
  the server version is re-pulled.

Result: `grep`, `cat`, `tail -f`, pipes and cron all work on your MCP data.

## Usage

```bash
mix escript.build
./mcp-mount --url ws://127.0.0.1:4000/vfs --token TOKEN --mount ~/tmp/mcp [--ro]
```

| Flag | Meaning |
|---|---|
| `--url` | VFS WebSocket endpoint (`ws://` or `wss://`, path usually `/vfs`) |
| `--token` | bearer token (falls back to `MCP_MOUNT_TOKEN` env var) |
| `--mount` | local directory to materialize the tree into (created if missing) |
| `--ro` | read-only: no watcher, never pushes local edits |

A `.mcp-mount/manifest.json` inside the mount dir tracks `{path → version,
mode, size}`; reconnects are a version-compare resync against it (no event
log). Server deletions are mirrored; `.mcp-mount/` and `*.conflict-*` are never
pushed.

## State machine

`init → authing → syncing → live ⇄ reconnecting` — reconnect uses exponential
backoff (1 s → 30 s) followed by a version-diff resync before going live again.

## Transport

All server interaction goes through the `McpMount.Conn` behaviour
(`connect/1`, `call/4`, `subscribe/3`, `unsubscribe/2`, `close/1`). The
production transport is `McpMount.WSConn` (mint + mint_web_socket); unit tests
use an in-memory `McpMount.FakeConn`. Swapping transports is a one-line change.

## Platform notes

- **macOS escript**: `file_system`'s native watcher binary (`mac_listener`)
  cannot be embedded in an escript archive, so an escript build degrades to
  **pull-only** (logged at startup; the mount stays live and resyncs on
  reconnect). Run from a `mix run`/release context — or ship `mac_listener`
  alongside the binary — for full write-back.
- `.tool-versions`-managed Elixir ≥ 1.18.

## Development

```bash
mix compile --warnings-as-errors
mix test                 # unit (FakeConn) + integration (in-repo bandit fixture)
mix escript.build
```

The integration tests boot a throwaway bandit WS fixture
(`McpMount.Test.VfsServer`) speaking the same wire protocol — no dependency on
any demo server app.
