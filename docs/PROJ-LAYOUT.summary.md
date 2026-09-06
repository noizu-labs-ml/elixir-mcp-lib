# Project Layout Summary

```
noizu-mcp/
├── lib/noizu/
│   ├── mcp/
│   │   ├── acl/ + acl.ex           # Authorization protocol + policy seam (PRD-2)
│   │   ├── auth/                   # Auth strategies (bearer/static, OAuth 2.1), plugs
│   │   ├── client/ + client.ex     # MCP client + server-initiated callbacks
│   │   ├── engine/ + engine.ex     # Federation: mount upstream MCPs (attach/detach/refresh)
│   │   ├── eval/ + eval.ex         # @eval description-tuning harness
│   │   ├── inspector/ + inspector.ex  # Browser inspector (session, plug, tap transport)
│   │   ├── migration/ + migrations.ex + migrations/  # Host migrations + v1 change set (PRD-4)
│   │   ├── persistence/ + persistence.ex  # Persistence contract + providers (PRD-4)
│   │   ├── protocol/               # Compile-time MCP method registry
│   │   ├── server/ + server.ex     # Server DSL, sessions, features (incl. sql, vfs)
│   │   ├── sql/                    # SQL feature over pg_mcp (schema, quals, types)
│   │   ├── toolset/ + toolset.ex   # Toolset resolution (tools/list, tools/call)
│   │   ├── transport/ + transport.ex  # stdio, SSE codec, streamable HTTP, test, VFS transports
│   │   ├── types/                  # Content blocks + shared MCP types
│   │   ├── vfs/ + vfs.ex           # Virtual filesystem behaviour + TTL cache
│   │   ├── ctx.ex / render_ctx.ex / description.ex  # Request + render contexts
│   │   ├── error.ex / json_rpc.ex / schema.ex / uri_template.ex  # Primitives
│   │   ├── peer.ex                 # Sans-IO session core (server + client)
│   │   ├── permission.ex / store.ex  # Persisted policy + host write facade (PRD-4)
│   │   └── test.ex                 # In-memory test helpers
│   └── mcp.ex                      # Top-level module
├── lib/mix/tasks/                  # mix mcp.client, mix mcp.engine, mix mcp.eval
├── test/                           # Mirrors lib (acl…transport) + support fixtures
├── priv/                           # spec/ JSON Schema, inspector UI, liquibase/
├── docs/                           # arch/ (12), adrs/, 01–09 topical, specs/, PROJ-* docs
├── guides/                         # 15 ExDoc guides
├── cheatsheets/                    # mcp.cheatmd
├── examples/                       # echo_stdio, agent_client, http_kitchen_sink, no_dsl_server
├── daemon/mcp_mount/               # Companion mount daemon (separate mix app)
├── demo/vfs_demo_server/           # VFS demo server (separate mix app)
├── fuse/                           # Go FUSE daemon: MCP VFS as a local filesystem mount
├── pg/                             # pg_mcp Rust/pgrx extension + docker e2e/smoke
├── project-management/PRDs/        # PRD series (INDEX + PRD-1…12)
├── .github/workflows/              # CI: fuse.yml, pg_mcp.yml
├── mix.exs                         # noizu_mcp package
└── README.md
```
