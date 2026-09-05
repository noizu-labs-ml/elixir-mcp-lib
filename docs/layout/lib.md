# lib/ — Source Code

```
lib/noizu/
├── mcp/
│   ├── acl/
│   │   ├── provider.ex                # Authorization policy seam (PRD-2) — lib owns no policy
│   │   ├── providers/deny_all.ex      # Built-in `:deny_all` provider — denies everything
│   │   ├── providers/disabled.ex      # Built-in `:disabled` provider — allows everything
│   │   └── resource.ex                # Object of an authorization decision (PRD-2)
│   ├── auth/                          # Strategies, verifiers, OAuth 2.1 server → [layout/auth.md](auth.md)
│   ├── client/
│   │   ├── handler.ex                 # Callbacks for server-initiated MCP traffic (client side)
│   │   └── telemetry.ex               # Telemetry events emitted by Noizu.MCP.Client
│   ├── eval/
│   │   ├── harness.ex                 # Core of the description-tuning eval harness
│   │   ├── judge.ex                   # Behaviour: grade one rubric criterion against a transcript
│   │   ├── judge/stub.ex              # Deterministic no-LLM judge for tests/CI
│   │   ├── runner.ex                  # Behaviour: execute an eval prompt against a target
│   │   ├── runner/stub.ex             # Deterministic no-LLM runner for tests/CI
│   │   └── spec.ex                    # Compiled eval spec attached to a tool
│   ├── inspector/
│   │   ├── handler.ex                 # Client handler for inspector (sampling, server-initiated traffic)
│   │   ├── plug.ex                    # HTTP surface serving the single-page inspector UI
│   │   ├── session.ex                 # One inspector session owning a client to the target server
│   │   └── tap_transport.ex           # Transport decorator capturing traffic for the inspector
│   ├── migration/
│   │   └── runner.ex                  # Host migration entry (Oban shape): apply/revert lib tables
│   ├── migrations/
│   │   └── v1_toolsets.ex             # Shipped v1 change set: lib-owned Postgres tables
│   ├── persistence/
│   │   ├── disabled.ex                # `:disabled` provider — every call is a no-op
│   │   ├── ecto.ex                    # Postgres persistence provider over lib-owned tables
│   │   ├── memory.ex                  # Default provider — one lazily-created public ETS table
│   │   └── ping.ex                    # D4 boot-gate child checked by the server supervisor
│   ├── protocol/
│   │   ├── methods.ex                 # Compile-time registry of MCP methods and kinds
│   │   └── version.ex                 # Protocol version negotiation
│   ├── server/
│   │   ├── features/
│   │   │   ├── completion.ex          # completion/complete glue: parse ref, route to owner
│   │   │   ├── pagination.ex          # Opaque offset cursors for list endpoints
│   │   │   ├── prompts.ex             # Prompts feature plumbing behind generated macros
│   │   │   ├── resources.ex           # Resources feature plumbing behind generated macros
│   │   │   ├── tools.ex               # Tools feature plumbing behind generated macros
│   │   │   └── vfs.ex                 # VFS feature plumbing behind `vfs/*` extension ops
│   │   ├── tool/
│   │   │   ├── fields.ex              # Compile-time machinery for tool schemas
│   │   │   └── spec.ex                # Normalized runtime descriptor for one registered tool
│   │   ├── tools/
│   │   │   ├── catalog.ex             # Built-in catalog discovery tool
│   │   │   └── mcp_fs_search.ex       # Virtual grep over registered VFS backends
│   │   ├── event_store.ex             # Buffer for Streamable HTTP messages with no live stream
│   │   ├── prompt.ex                  # Define an MCP prompt as a module
│   │   ├── resource.ex                # Define an MCP resource as a module
│   │   ├── resource_template.ex       # Define an MCP resource template (RFC 6570) as a module
│   │   ├── session.ex                 # GenServer owning protocol state per MCP session
│   │   ├── supervisor.ex              # Supervision tree for one logical MCP server
│   │   ├── tool.ex                    # Define an MCP tool as a module
│   │   ├── toolkit.ex                 # Define several tools in one module via `@mcp` annotations
│   │   ├── vfs.ex                     # Derives vfs/vfs_write capability flags from backends
│   │   └── vfs_pubsub.ex              # Per-path change pubsub for VFS backends, subtree watches
│   ├── toolset/
│   │   ├── behaviour.ex               # Protocol + behaviour duality for toolsets
│   │   ├── cache.ex                   # Optional ETS memoization of composed custom-toolset catalogs
│   │   ├── context.ex                 # One opinion-set batch in the composition context pass
│   │   ├── custom.ex                  # Declarative per-caller toolset: base surface + include/exclude
│   │   ├── merge.ex                   # The one weighted merge engine folding opinions into specs
│   │   ├── override.ex                # One entry in the closed override vocabulary
│   │   ├── overrides.ex               # Pure override materializer applying override ops
│   │   ├── ref.ex                     # Reference wrapper pointing at a toolset module
│   │   ├── static.ex                  # Wrapper over already-expanded tool specs
│   │   └── validator.ex               # One structural problem found materializing overrides
│   ├── transport/
│   │   ├── streamable_http/
│   │   │   ├── client.ex              # Streamable HTTP client transport (Req-based)
│   │   │   ├── plug.ex                # Streamable HTTP server Plug — single MCP endpoint
│   │   │   └── sink.ex                # Routes outbound messages to SSE streams/pollers
│   │   ├── sse.ex                     # Minimal Server-Sent Events codec for Streamable HTTP
│   │   ├── stdio.ex                   # Stdio server transport (newline-delimited JSON-RPC)
│   │   ├── stdio_client.ex            # Stdio client transport; spawns a server subprocess
│   │   ├── test.ex                    # In-memory server transport for tests
│   │   ├── test_client.ex             # In-memory client transport connecting client to server
│   │   ├── vfs_client.ex              # Elixir client for the unix-socket VFS transport
│   │   ├── vfs_socket.ex              # Unix-domain-socket VFS transport (length-prefixed JSON-RPC)
│   │   └── vfs_ws.ex                  # WebSocket VFS transport Plug (GET /vfs upgrade)
│   ├── types/
│   │   ├── content.ex                 # Content blocks: text/image/audio/resource link/embedded
│   │   ├── implementation.ex          # clientInfo/serverInfo identity structs
│   │   ├── prompt.ex                  # Prompt definition advertised by prompts/list
│   │   ├── prompt_message.ex          # One message in a prompts/get result
│   │   ├── resource.ex                # Resource definition from resources/list
│   │   ├── resource_contents.ex       # Read-resource contents (text or binary)
│   │   ├── resource_template.ex       # Resource template (RFC 6570 URI template)
│   │   ├── root.ex                    # Filesystem root exposed by client (roots/list)
│   │   ├── tool.ex                    # Tool definition from tools/list
│   │   └── tool_result.ex             # tools/call result: content + optional structured content
│   ├── acl.ex                         # Authorization decision protocol (PRD-2): subject/action/resource
│   ├── client.ex                      # Client behaviour and macros
│   ├── ctx.ex                         # Request context (metadata, progress)
│   ├── description.ex                 # Tailored description: one string per render context
│   ├── error.ex                       # Structured error types
│   ├── eval.ex                        # Inline `@eval` annotations for description tuning
│   ├── inspector.ex                   # Noizu.MCP.Inspector supervisor
│   ├── json_rpc.ex                    # JSON-RPC 2.0 message handling
│   ├── migrations.ex                  # One applied-in-order migration unit (PRD-4), ledger naming
│   ├── peer.ex                        # Sans-IO session core (server sessions + client)
│   ├── permission.ex                  # Persisted per-caller policy record (PRD-4)
│   ├── persistence.ex                 # Persistence contract for lib-owned toolset state (PRD-4)
│   ├── render_ctx.ex                  # Render context threaded through description render sites
│   ├── schema.ex                      # JSV schema loading and validation
│   ├── server.ex                      # Server behaviour and macros
│   ├── store.ex                       # Host write facade: provider write → version bump (PRD-4)
│   ├── test.ex                        # Test helpers and assertions
│   ├── toolset.ex                     # Single toolset resolution path for list/call/catalog
│   ├── transport.ex                   # Transport behaviour
│   ├── uri_template.ex                # RFC 6570 URI template expansion
│   └── vfs.ex                         # Virtual filesystem behaviour for MCP servers
└── mcp.ex                             # Top-level Noizu.MCP module
```
