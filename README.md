# Noizu MCP

[Model Context Protocol](https://modelcontextprotocol.io) for Elixir — **server
and client** — targeting spec revision **2025-11-25** (negotiates down to
2025-06-18).

- 🧩 **Declarative components** — tools (compile-time schema DSL → JSON Schema,
  validated atom-keyed args via [JSV](https://hex.pm/packages/jsv), 2020-12
  dialect), resources + RFC 6570 templates + subscriptions, prompts, completion
- 🧰 **Toolkits** — many small tools in one module via `@mcp` function
  annotations, with schemas as plain data or raw JSON text
- 🗂️ **Hidden items & discovery** — `hidden: true` keeps any tool, prompt, or
  resource callable but unlisted; a built-in catalog tool plus `category`
  metadata (`_meta.category`) give agents a discovery surface
- ⚙️ **Behaviour-driven core** — every macro is sugar over plain callbacks you
  can implement by hand
- 🔌 **Transports**: stdio and Streamable HTTP (Plug — mount in Phoenix or run
  standalone on Bandit) on both the server and the client side
- 📁 **VFS filesystem surface** — file-shaped backends (behaviour + DSL +
  conformance battery), unix-socket & WebSocket transports with live change
  events, a `/etc/dev` control tree, and an `mcp_fs_search` grep tool (see the
  VFS section below)
- ↔️ **Full bidirectionality**: server handlers can `sample`, `elicit`, and
  `list_roots` against the connected client mid-call
- 🔐 **OAuth 2.1**: resource-server enforcement (`TokenVerifier`,
  `WWW-Authenticate`, RFC 9728 metadata) and a full client flow (discovery,
  PKCE S256, refresh, `resource` indicators, scope step-up)
- 🧪 **First-class testing** with `Noizu.MCP.Test` over an in-memory transport
  (`async: true` safe), plus conformance checks against the official spec schema
- 📈 Concurrent request handling per session — slow tools never block ping,
  cancellation, or progress

> Status: pre-release (0.1.x). All protocol features above are implemented and
> covered by 240+ tests including real-subprocess stdio e2e and Bandit HTTP
> round-trips. Pre-1.0 API may still move.

## Quickstart: a stdio server

```elixir
# mix.exs
{:noizu_mcp, "~> 0.1"}
```

Define a tool and a server:

```elixir
defmodule MyApp.Tools.GetWeather do
  use Noizu.MCP.Server.Tool,
    name: "get_weather",
    description: "Get current weather for a location",
    annotations: [read_only_hint: true]

  input do
    field :location, :string, required: true, description: "City name or zip code"
    field :units, :enum, values: [:celsius, :fahrenheit], default: :celsius
  end

  output do
    field :temperature, :number, required: true
    field :conditions, :string, required: true
  end

  @impl true
  def call(%{location: location, units: _units}, ctx) do
    Noizu.MCP.Ctx.report_progress(ctx, 0.5, message: "querying provider")
    {:ok, %{temperature: 21.5, conditions: "clear over #{location}"}}
  end
end

defmodule MyApp.MCP do
  use Noizu.MCP.Server,
    name: "myapp",
    version: "1.0.0",
    instructions: "Weather tools for MyApp."

  tool MyApp.Tools.GetWeather
end
```

Run it over stdio from your application supervisor:

```elixir
children = [
  {MyApp.MCP, transport: :stdio}
]
```

Register with Claude Code:

```sh
claude mcp add myapp -- mix run --no-halt
```

Arguments arrive **validated and atom-keyed** (defaults applied, enums cast to
atoms). Validation failures are returned to the model as `isError: true` tool
results it can self-correct from. Return values can be a string, a structured
map (validated against `output`), `Noizu.MCP.Types.Content` blocks, or a full
`ToolResult`; `{:error, "msg"}` produces an execution error, raising produces a
sanitized one.

> **stdout is sacred.** On stdio transports, anything printed to stdout
> corrupts the protocol stream. The transport automatically diverts the default
> Logger handler to stderr — avoid `IO.puts/1` in handler code, and prefer OTP
> releases over `mix run` in production.

## Toolkits: multiple tools per module

For a bundle of small tools, skip the one-module-per-tool ceremony:
`use Noizu.MCP.Server.Toolkit` turns `@mcp`-annotated functions into tools,
with schemas declared as plain data (or raw JSON text):

```elixir
defmodule MyApp.Toolkit do
  use Noizu.MCP.Server.Toolkit, category: "Utility"   # default category

  @mcp name: "files.read", category: "Files", description: "Read a file",
       input: [path: [type: :string, required: true]]
  def read_file(%{path: path}, _ctx) do
    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, "read failed: #{reason}"}
    end
  end

  @mcp description: "Server time (name derives from the function)"
  def server_time, do: {:ok, to_string(DateTime.utc_now())}

  @mcp visible: false   # hidden from tools/list, still callable
  @mcp input: """
  {"type": "object", "properties": {"q": {"type": "string"}}}
  """
  def lookup(args, _ctx), do: {:ok, args["q"] || ""}
end

defmodule MyApp.MCP do
  use Noizu.MCP.Server, name: "myapp", version: "1.0.0"

  tool MyApp.Toolkit              # registers every annotated function
  # tool MyApp.Toolkit, category: "Admin", hidden: true  # opts apply kit-wide
end
```

Annotated functions take `(args, ctx)`, `(args)`, or no arguments. The
data-form `input:` spec gives you the same validated, atom-keyed,
default-applied, enum-cast arguments as the classic `input do ... end` DSL; a
map or JSON-text string is treated as a raw JSON Schema instead. `category:`
rides on the wire in `_meta.category` and is filterable through the catalog
tool below. Full details — `@mcp` option table, merge semantics, the three
schema forms — in the
[Toolkits, Categories & Hidden Tools](guides/toolkits_and_discovery.md) guide.

## Hidden tools & discovery

Mark any tool, prompt, resource, or resource template `hidden: true` to omit it
from `tools/list` / `prompts/list` / `resources/list` responses while keeping
it fully callable by name via `tools/call`, `prompts/get`, and
`resources/read` — useful for internal, privileged, or agent-only surface area
you don't want crowding the default listing.

```elixir
defmodule MyApp.Tools.Internal do
  use Noizu.MCP.Server.Tool,
    name: "internal_tool",
    description: "Agent-only tool",
    hidden: true
  # ...
end

defmodule MyApp.MCP do
  use Noizu.MCP.Server, name: "myapp", version: "1.0.0"

  tool MyApp.Tools.Internal                       # hidden via module flag
  tool MyApp.Tools.GetWeather, hidden: true      # hidden via registration override
  tool Noizu.MCP.Server.Tools.Catalog, hidden: true
end
```

The registration-level `hidden:` option overrides the module default in either
direction (`visible: false` is accepted as an alias for `hidden: true`; for
toolkit registrations it applies to every tool in the kit). The built-in
`Noizu.MCP.Server.Tools.Catalog` tool lets agents discover unpublished items:
it returns full wire definitions (input schemas included) for everything
registered, each tagged with a `"hidden"` flag, with
`type`/`query`/`category`/`include_hidden` filters.

Call dispatch never consults the hidden flag, so hidden items resolve whether
or not they were listed. For session-gated visibility (an "unlock" flow),
override `handle_list_tools/2` with `include_hidden:` driven by session state
and push `notify_changed(:tools)` when it flips — worked example in the
[Toolkits, Categories & Hidden Tools](guides/toolkits_and_discovery.md) guide.

## Streamable HTTP (Phoenix / Bandit)

```elixir
# Phoenix router
forward "/mcp", Noizu.MCP.Transport.StreamableHTTP.Plug, server: MyApp.MCP

# or standalone
{Bandit, plug: {Noizu.MCP.Transport.StreamableHTTP.Plug, server: MyApp.MCP}, port: 4040}
```

Sessions, SSE upgrades, `Last-Event-ID` resumability, origin validation, and
DELETE teardown are handled per spec. Protect it as an OAuth 2.1 resource
server with `auth: [verifier: {MyVerifier, []}, resource_metadata: "..."]`
(see `Noizu.MCP.Auth.TokenVerifier`).

## VFS — the filesystem surface

The VFS (virtual filesystem) layer makes MCP data browsable as files: a
behaviour + DSL for file-shaped backends, a generation-stamped cache, two
transports (unix socket + WebSocket with live change events), a `/etc/dev`
control-tree composer, and an `mcp_fs_search` grep tool. It is the substrate
of the MCP-FUSE mounter stack.

### Backends (behaviour + DSL)

A backend implements `Noizu.MCP.VFS` — `use Noizu.MCP.VFS` and write the
callbacks:

| Callback | Required | Contract |
|----------|----------|----------|
| `stat/2` | yes | `%VFS{}` node for `path` (or `:enoent`) |
| `list/3` | yes | children of `path`, paginated (`{:ok, entries, next_cursor}`) |
| `read/2` | yes | `{:ok, content, version}` for a file |
| `write/3` | optional | overwrite (default `:enosys` → read-only backend) |
| `create/3` | optional | create file (`binary`) or dir (`:dir`) |
| `remove/2` | optional | remove file or empty dir |
| `search/3` | optional | grep-style line matches under a root (default `:enosys`) |
| `xattr/2` | optional | extended attributes (default `{:ok, %{}}`) |

Match shapes are `%{path, line, text}`; errnos are plain atoms (`:enoent`,
`:eacces`, …) mapped to wire codes by the table below. A server registers one
or more backends with the `vfs MyBackend` DSL macro — the first registration
backs the `vfs/*` operations; *all* registrations are searched by
`mcp_fs_search`. Conformance is one macro away — the battery exercises any
backend against the full operation + errno contract:

```elixir
use Noizu.MCP.VFS.Conformance,
  backend: MyApp.VFS.Backend,
  seed: {MyApp.VFS.Backend, :seed}
```

### Cache & generations

`Noizu.MCP.VFS.Cache` caches reads/stats/lists per backend with a TTL and
stamps a monotonically increasing **generation** into every served version —
each successful write/create/remove bumps the backend's generation first, so
stale caches and mounter echoes are detected by a plain integer compare
(`version` going backwards or repeating means resync). `Cache.purge/1`,
`Cache.generation/1`, and `Cache.bump_generation/1` are public; the control
tree below exposes per-backend stats and a flush node.

### Socket transport (unix, M2)

For filesystem-shaped access, a server with a registered VFS backend can
expose the `vfs/*` operation family over a local unix-domain socket — JSON-RPC
2.0 with a 4-byte big-endian length prefix per frame, and a `vfs/auth` API-key
handshake instead of `initialize`:

```elixir
children = [
  {MyApp.MCP,
   transport:
     {:vfs_socket,
      socket_path: "/run/mcp/vfs.sock",
      auth: [verifier: {Noizu.MCP.Auth.ApiKeyVerifier, keys: [{key, claims_map}]}],
      # optional per-connection assigns (e.g. backend state), from the auth claims:
      context: {MyApp.MCP, :vfs_assigns}}}
]
```

The first frame on a connection must be `vfs/auth` with `{"api_key": "..."}`;
it is validated by the configured token verifier and the resulting claims are
bound to the connection's context (failed handshakes close the connection).
Operations `vfs/stat`, `vfs/list`, `vfs/read`, `vfs/write`, `vfs/create`,
`vfs/remove`, `vfs/search`, `vfs/xattr` run through the same feature layer as
MCP-native requests. The socket is created mode `0600`, stale socket files are
unlinked at startup and removed on shutdown. See
`Noizu.MCP.Transport.VFSSocket` for the full wire contract and
`Noizu.MCP.Transport.VFSClient` for a ready-made client:

```elixir
{:ok, client} = Noizu.MCP.Transport.VFSClient.connect("/run/mcp/vfs.sock")
{:ok, _} = Noizu.MCP.Transport.VFSClient.auth(client, key)
{:ok, %{"content" => content, "version" => v}} =
  Noizu.MCP.Transport.VFSClient.read(client, "/etc/dev/flag")
```

### WebSocket transport + live events (W1)

The TCP-addressable sibling of the socket transport: a bandit-hosted Plug that
upgrades `GET /vfs` into a WebSocket speaking the same `vfs/*` operations over
JSON text frames (envelope `v: 2`), plus subscribe/unsubscribe/ping and
server-pushed **change events**:

```elixir
children = [
  {Bandit,
   plug: {Noizu.MCP.Transport.VFSWS,
    server: MyApp.MCP,
    auth: [verifier: {Noizu.MCP.Auth.ApiKeyVerifier, keys: [{key, claims_map}]}],
    context: {MyApp.MCP, :vfs_assigns}},
   port: 4100}
]
```

Requests carry a bearer token on the upgrade (same verifier pipeline as the
Streamable HTTP plug; 401 before the socket exists) and then the same
`vfs/auth` first-frame handshake as the socket transport. After that, frames
are `{"v": 2, "id": 1, "method": "vfs/read", "params": {"path": "/a.txt"}}` →
`{"v": 2, "id": 1, "result": {"content": "...", "version": 3}}`.

### Change pubsub

Mutations are published through `Noizu.MCP.Server.VFSPubSub` (start it in your
supervision tree; the write path silently skips publishing when it is not
running). Over WS, connections subscribe with
`vfs/subscribe {"paths": ["/docs"], "depth": 1}` and receive metadata-only,
burst-coalesced (50 ms per {backend, path}) events for the watched subtrees:

```json
{"v": 2, "type": "vfs/event", "seq": 1, "op": "write", "path": "/docs/a.md",
 "version": 12, "by": "alice", "at": 1788241952601}
```

Semantics: subtree watches deliver on writes to the watched path **and any
descendant** (`depth` bounds how many levels below the watch path still match,
`:infinity` for unlimited); `seq` is per-connection monotonic; `by` is the
authenticated identity; events carry no content — pull with `vfs/read` and
compare `version` to skip your own echoes. `vfs/unsubscribe` stops delivery,
`vfs/ping` round-trips, and the server sends WebSocket pings every 30 s (drop
after two misses; `:keepalive_ms` overrides). Watch cap per connection is
10 000 → `-32047` (`:ewouldwatch`); dead connections are unwatched
automatically. The same API is callable in-process: `VFSPubSub.watch/3`,
`unwatch/2`, `watch_count/1`, and `publish/5` (invoked for you by the write
hook in `Features.VFS`). See `Noizu.MCP.Transport.VFSWS` and
`Noizu.MCP.Server.VFSPubSub`.

### Errno wire table

Both transports (and `mcp_fs_search`) map backend errnos through
`Noizu.MCP.Server.Features.VFS.errno_error/1`; the originating atom rides as
`error.data.errno_atom`:

| errno | code | wire error |
|-------|------|------------|
| `:enoent` | `-32002` | `resource_not_found` |
| `:eacces` | `-32040` | custom |
| `:eexist` | `-32041` | custom |
| `:erofs` | `-32042` | custom (read-only kill-switch) |
| `:eisdir` | `-32043` | custom |
| `:enotdir` | `-32044` | custom |
| `:enotempty` | `-32045` | custom |
| `:enosys` | `-32046` | custom (optional callback not implemented) |
| — | `-32047` | watch cap exceeded (`:ewouldwatch`, WS only) |
| `:eio` | `-32048` | custom (I/O error, e.g. malformed buffered writes) |

Anything else falls through to a plain internal error.

### mcp_fs_search

The MCP-tool face of the grep metaphor: register
`Noizu.MCP.Server.Tools.McpFsSearch` on a server and agents can search **every
registered backend at once** from any transport — no mounting required:

```elixir
defmodule MyApp.MCP do
  use Noizu.MCP.Server, name: "myapp", version: "1.0.0"

  vfs MyApp.VFS.PM          # first registration backs the vfs/* operations
  vfs MyApp.VFS.Wiki        # additional backends are searched too
  tool Noizu.MCP.Server.Tools.McpFsSearch
end
```

Arguments: `query` (required substring), `root` (subtree root, default `"/"`),
`backend` (optional filter on the full or short module name, case-insensitive —
an unknown name is a `-32002`, not an empty result), and `cursor`
(pagination). Backends without `search/3` are skipped; matches come back
merged in registration order, each tagged with its `backend`:

```elixir
%{"matches" => [%{path: "/docs/a.md", line: 1, text: "alpha",
                 backend: "MyApp.VFS.PM"}, ...], "nextCursor" => "..."}
```

Read-only by definition, so it keeps working under `vfs_readonly: true`.

### The /etc/dev control tree

`Noizu.MCP.VFS.Control` wraps an existing VFS backend and mounts a
introspection-and-control tree at `/etc/dev` — tools, runtime state, cache
management, and feature toggles, all through the ordinary filesystem
operations (so the FUSE mount, transports, and permission layers apply
unchanged):

```elixir
defmodule MyApp.MCP.FS do
  use Noizu.MCP.VFS.Control,
    server: MyApp.MCP,          # the MCP server module
    real: MyApp.VFS.Backend,    # your existing backend (omit for control-only)
    # optional gate hook — its verdict is final, destructive or not:
    tool_gate: {MyApp.Auth, :vfs_tool_gate, ["vfs"]},
    # optional extra toggles (get/set as {m, f, prefix_args}):
    toggles: [%{name: "motd", get: {Cfg, :motd, []}, set: {Cfg, :set_motd, []}}]
end
```

| Node | R | W | Notes |
|------|---|---|-------|
| `/etc/dev/tools/<tool>` | schema JSON | `{"args": {...}}` | invoke; result buffered per session, next read returns it |
| `/etc/dev/runtime/status` | JSON | – | server name/version, uptime, capabilities, transports, session count |
| `/etc/dev/runtime/sessions/` | ids | – | one JSON node per live session |
| `/etc/dev/cache/stats` | JSON | – | per-backend generations and entry counts |
| `/etc/dev/cache/flush` | hint | write | write bumps every cache generation, answers `ok` |
| `/etc/dev/config/<toggle>` | value | JSON value | `trace`, `cache_enabled` seeded; registry for more |
| *(every other path)* | | | delegated to `real:` unchanged |

Invocation safety, in order: the `tool_gate` hook (when set) decides; else a
`vfs_tool_allowlist` claim on the connection; else destructive tools
(`destructive_hint`) are refused with `:eacces` — fail closed. Writes are also
refused with `:erofs` server-wide when the server sets `vfs_readonly: true`.

Security notes: invoke goes through `server.handle_call_tool/3`, so authz/PDP
wrappers and tool middleware still apply; keep the VFS socket mode `0600` and
behind its `vfs/auth` handshake, and remember a FUSE mount of the control tree
is a local-privilege surface — mount it only for trusted users.

### Demo server

[`demo/vfs_demo_server`](demo/vfs_demo_server) is a small self-contained mix
app that seeds a static tree from `priv/seed/tree.yaml` and serves it over the
real `Noizu.MCP.Transport.VFSWS` transport — the reference implementation for
file-defining programs and the test fixture for the VFS/mounter stack
(`VfsDemoServer.Test.mutate/3` mutates the tree, `VfsDemoServer.TestServer`
boots an ephemeral-port instance for tests):

```sh
cd demo/vfs_demo_server
mix run --no-halt        # WS on :4000 (VFS_DEMO_PORT to override)
# in another terminal (the bearer token rides the WS upgrade request):
websocat --header "Authorization: Bearer demo-token" "ws://127.0.0.1:4000/vfs"
mix test                 # runs the demo's own suite against the real transport
```

It path-deps the parent library (`../..`), keeps its own `deps`/`_build`/
`mix.lock`, and is excluded from the hex package. The lib's `mix test` does
not recurse into it — run the demo suite with the `mix test` above from
`demo/vfs_demo_server`. Auth: single bearer token (env `VFS_DEMO_TOKEN`,
default `demo-token`), supplied on the WS upgrade request *and* confirmed by
the `vfs/auth` frame — the upgrade handshake is what gates the socket.

> Follow-up (not in this release): exporting a materialized mount over NFS
> (kernel `nfsd` on top of the mounter's real files) so non-local hosts and
> containers can share one live tree. The WS event stream already provides the
> live semantics; NFS export is packaging, not protocol.

### Mount daemon

[`daemon/mcp_mount`](daemon/mcp_mount) is the client side of the same protocol:
`mcp-mount` connects to a VFS WebSocket endpoint, materializes the tree as
**real local files** (grep/cat/tail -f/pipes just work), then keeps both sides
in sync — subscribed `vfs/event` changes apply to the files live, and a
filesystem watcher pushes local edits back as `vfs/write`/`vfs/create`
(conflicting edits are saved aside as `<path>.conflict-<ISO-timestamp>`).
`--ro` disables the watcher and never pushes. `.mcp-mount/manifest.json`
tracks versions; reconnects are a version-compare resync (no event log).

```sh
cd daemon/mcp_mount
mix escript.build
./mcp-mount --url ws://127.0.0.1:4000/vfs --token demo-token --mount ~/tmp/mcp [--ro]
mix test    # unit (FakeConn) + integration (in-repo bandit WS fixture)
```

| Flag | Meaning |
|---|---|
| `--url` | VFS WebSocket endpoint (`ws://`/`wss://`, path usually `/vfs`) |
| `--token` | bearer token (falls back to `MCP_MOUNT_TOKEN`); rides the WS upgrade request |
| `--mount` | local directory to materialize the tree into (created if missing) |
| `--ro` | read-only: no watcher, never pushes local edits |

It is a fully self-contained mix project (own `deps`/`_build`/`mix.lock`,
escript target) that speaks the v2 JSON wire protocol directly — it does not
link the parent library and is excluded from the hex package; the lib's
`mix test` does not recurse into it. Platform notes: on macOS an escript build
degrades to pull-only (`file_system`'s native `mac_listener` can't be embedded
in the archive; run from `mix run`/a release for full write-back); Linux
escripts have full write-back; Windows is planned. The intent is to possibly
break this out into its own signed-binary repo in the future.

## Consuming servers (client)

```elixir
children = [
  {Noizu.MCP.Client,
   name: MyApp.FS,
   transport: {:stdio, command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]},
   # or: transport: {:streamable_http, url: "https://api.example.com/mcp",
   #                 auth: {Noizu.MCP.Auth.Static, token: token}}
   handler: MyApp.MCPHandler}   # answers sampling/elicitation; see Noizu.MCP.Client.Handler
]

{:ok, tools}  = Noizu.MCP.Client.list_tools(MyApp.FS)
{:ok, result} = Noizu.MCP.Client.call_tool(MyApp.FS, "read_file", %{"path" => "/tmp/a.txt"},
                  timeout: 60_000, progress: fn p -> IO.inspect(p) end)
```

## Inspector

`mix mcp.client` launches a native HTML inspector (similar to the official
MCP Inspector) for exploring and exercising MCP servers interactively — tools
with auto-generated forms, resources, prompts, raw JSON-RPC history,
notifications, and a **Pending** tab for answering server-initiated sampling
and elicitation requests without writing any handler code.

```sh
# launch with no target and pick/switch servers inside the app
mix mcp.client

# in-process server module
mix mcp.client MyApp.MCP

# spawn an external stdio server
mix mcp.client --stdio "npx -y @modelcontextprotocol/server-everything"

# connect to a remote Streamable HTTP server
mix mcp.client --url http://localhost:4040/mcp --bearer TOKEN
```

Add `:bandit` and `:plug` (dev-only) to use it; `:req` is also required for
`--url` targets. See [guides/inspector.md](guides/inspector.md) for the full
option reference, tab tour, sampling/elicitation walkthrough, security notes,
and programmatic embedding via `Noizu.MCP.Inspector.start_link/1`.

## Testing your server

```elixir
defmodule MyApp.MCPTest do
  use ExUnit.Case, async: true
  import Noizu.MCP.Test

  setup do: %{client: connect(MyApp.MCP)}

  test "get_weather", %{client: client} do
    assert {:ok, result} = call_tool(client, "get_weather", %{"location" => "NYC"})
    assert result.structured["temperature"]
    assert_progress(client)
  end
end
```

## Escape hatch: no macros

Everything the DSL generates is an overridable callback:

```elixir
defmodule MyApp.RawMCP do
  use Noizu.MCP.Server, name: "raw", version: "1.0.0"

  @impl true
  def handle_list_tools(_cursor, _ctx),
    do: {:ok, [%Noizu.MCP.Types.Tool{name: "echo"}], nil}

  @impl true
  def handle_call_tool("echo", args, _ctx), do: {:ok, inspect(args)}
end
```

## Documentation

Guides on [hexdocs](https://hexdocs.pm/noizu_mcp): Getting Started ·
Tools & Schemas · Toolkits & Discovery · Resources & Prompts · the Handler
Context · Client · Streamable HTTP · stdio · Authentication · Testing ·
MCP Inspector — plus a cheatsheet.

## Examples

- [`examples/echo_stdio`](https://github.com/noizu-labs/noizu-mcp/tree/main/examples/echo_stdio)
  — minimal stdio server, ready for `claude mcp add`
- [`examples/no_dsl_server`](https://github.com/noizu-labs/noizu-mcp/tree/main/examples/no_dsl_server)
  — behaviour-only server (no macros), hand-written schemas and dynamic dispatch
- [`examples/http_kitchen_sink`](https://github.com/noizu-labs/noizu-mcp/tree/main/examples/http_kitchen_sink)
  — Streamable HTTP server on Bandit exercising the full feature surface
  (progress, cancellation, sampling, subscriptions, templates, completion,
  a toolkit module, hidden tools + the catalog discovery tool)
- [`examples/agent_client`](https://github.com/noizu-labs/noizu-mcp/tree/main/examples/agent_client)
  — client demo: spawns `echo_stdio` over stdio, lists and calls tools with
  progress, answers elicitations

## Development

```sh
mix test                 # unit + integration + spec conformance
mix test --include e2e   # also drive examples/echo_stdio as a real subprocess
```

## License

MIT
