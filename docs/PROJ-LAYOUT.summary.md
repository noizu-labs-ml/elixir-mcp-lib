# Project Layout Summary

```
noizu-mcp/
├── lib/noizu/
│   ├── mcp/
│   │   ├── acl/ + acl.ex           # Authorization protocol + policy seam (PRD-2)
│   │   ├── auth/                   # Auth strategies (bearer/static, OAuth 2.0), plugs
│   │   ├── client/ + client.ex     # MCP client + server-initiated callbacks
│   │   ├── eval/ + eval.ex         # @eval description-tuning harness
│   │   ├── inspector/ + inspector.ex  # Browser inspector (session, plug, tap transport)
│   │   ├── migration/ + migrations.ex + migrations/  # Host migrations + v1 change set (PRD-4)
│   │   ├── persistence/ + persistence.ex  # Persistence contract + providers (PRD-4)
│   │   ├── protocol/               # Compile-time MCP method registry
│   │   ├── server/ + server.ex     # Server DSL, sessions, stream buffers, features
│   │   ├── toolset/ + toolset.ex   # Toolset resolution (tools/list, tools/call)
│   │   ├── transport/ + transport.ex  # stdio, SSE codec, streamable HTTP, test
│   │   ├── types/                  # Content blocks + shared MCP types
│   │   ├── vfs/ + vfs.ex           # Virtual filesystem behaviour + TTL cache
│   │   ├── ctx.ex / render_ctx.ex / description.ex  # Request + render contexts
│   │   ├── error.ex / json_rpc.ex / schema.ex / uri_template.ex  # Primitives
│   │   ├── permission.ex / store.ex  # Persisted policy + host write facade (PRD-4)
│   │   ├── peer.ex                 # Sans-IO session core (server + client)
│   │   └── test.ex                 # In-memory test helpers
│   └── mcp.ex                      # Top-level module
├── lib/mix/tasks/                  # mix mcp.client, mix mcp.eval
├── test/                           # Mirrors lib (acl…transport) + support fixtures
├── priv/                           # spec/ JSON Schema, inspector UI, liquibase/
├── docs/                           # arch/, 01–09 topical, specs/, PROJ-* docs
├── guides/                         # 13 ExDoc guides
├── cheatsheets/                    # mcp.cheatmd
├── examples/                       # echo_stdio, agent_client, http_kitchen_sink, no_dsl_server
├── daemon/mcp_mount/               # Companion mount daemon (separate mix app)
├── demo/vfs_demo_server/           # VFS demo server (separate mix app)
├── mix.exs                         # noizu_mcp 0.3.0
└── README.md
```
