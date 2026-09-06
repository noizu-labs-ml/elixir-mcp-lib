# Project Layout

```
noizu-mcp/
├── lib/                        # Source code → [layout/lib.md](layout/lib.md)
│   ├── mix/tasks/              #   Mix tasks (mcp.client, mcp.engine, mcp.eval)
│   └── noizu/
│       ├── mcp/                #   MCP protocol implementation
│       └── mcp.ex              #   Top-level module
├── test/                       # Test suites (mirror lib/noizu/mcp subdirs)
│   ├── noizu/mcp/              #   Per-area suites: acl, auth, engine, eval, inspector,
│   │                           #   migrations, persistence, server, sql, store, toolset,
│   │                           #   transport + flat e2e/conformance files
│   ├── mix/tasks/              #   Mix task suites
│   ├── support/                #   Fixtures (acl, as, auth, custom, engine, oauth, persistence,
│   │                           #   persistence_db, pg_e2e, server, sql, vfs), conformance
│   │                           #   cases, stdio upstream helper
│   └── test_helper.exs         #   ExUnit config
├── priv/                       # Runtime assets
│   ├── spec/2025-11-25/        #   Official MCP JSON Schema
│   ├── inspector/              #   Inspector browser UI (vanilla ES modules, no build step)
│   └── liquibase/              #   OAuth schema change set (noizu_mcp_oauth.yaml)
├── docs/                       # Documentation → [layout/docs.md](layout/docs.md)
│   ├── arch/                   #   Architecture docs (12: auth … vfs)
│   ├── adrs/                   #   Decision records (ADR-001…008 + INDEX)
│   ├── 01–09-*.md              #   Topical guides, spec changelogs, draft-spec notes
│   └── specs/                  #   MCP spec snapshots (2025-03-26 → draft)
├── guides/                     # ExDoc guides (15: getting_started, engine, postgres,
│                               #   testing, handler_context, …)
├── cheatsheets/                # ExDoc cheatsheet (mcp.cheatmd)
├── examples/                   # Example applications (own mix apps)
│   ├── echo_stdio/             #   Minimal stdio MCP server
│   ├── agent_client/           #   Agent-based MCP client
│   ├── http_kitchen_sink/      #   Full-featured HTTP server (auth, OAuth)
│   └── no_dsl_server/          #   Server without DSL macros
├── daemon/                     # Companion applications
│   └── mcp_mount/              #   mcp-mount daemon (separate mix app, own README)
├── demo/                       # Demo applications
│   └── vfs_demo_server/        #   VFS demo server (separate mix app)
├── fuse/                       # Go FUSE daemon: exposes MCP VFS as a local mount
│   ├── main.go / fs.go         #   Entry point + filesystem implementation
│   ├── client.go / cache.go    #   Unix-socket client + entry cache
│   └── *_test.go, fusetest.sh  #   Tests (Linux-only mount tests) + test harness
├── pg/                         # Postgres extension track (pg_mcp)
│   ├── pg_mcp/                 #   Rust/pgrx extension (src/, sql/, spike/, SPIKE.md)
│   └── docker/                 #   E2E compose + smoke SQL + install image
├── project-management/         # PRD series (INDEX.md, PRD-1…12)
├── .github/workflows/          # CI: fuse.yml (Go daemon), pg_mcp.yml (Rust extension)
├── AGENT.md, AGENTS.md,        # Agent guidance (kept aligned)
│   CLAUDE.md
├── .dialyzer_ignore.exs        # Dialyzer warning suppressions
├── .formatter.exs              # Elixir formatter config
├── .gitignore
├── .tool-versions              # Toolchain pinning (elixir 1.20.1-otp-29, erlang 29.0.2)
├── Makefile                    # Repo tasks
├── CHANGELOG.md                # Release history
├── LICENSE                     # Project license
├── mix.exs                     # Project definition and dependencies (noizu_mcp)
├── mix.lock                    # Locked dependency versions
└── README.md                   # Start here
```

## Key Files

| File | Purpose |
|------|---------|
| `lib/noizu/mcp.ex` | Top-level `Noizu.MCP` module |
| `lib/noizu/mcp/server.ex` | `Noizu.MCP.Server` — server behaviour and DSL |
| `lib/noizu/mcp/client.ex` | `Noizu.MCP.Client` — client behaviour + server-initiated callbacks |
| `lib/noizu/mcp/peer.ex` | Sans-IO session core shared by server sessions and client |
| `lib/noizu/mcp/engine.ex` + `engine/` | Federation engine: mount upstream MCPs behind one surface (attach/detach/refresh) |
| `lib/noizu/mcp/sql/` | SQL feature over the pg_mcp extension (schema, quals, types) |
| `lib/noizu/mcp/transport.ex` | Transport behaviours (stdio, SSE, streamable HTTP, test, VFS) |
| `lib/noizu/mcp/json_rpc.ex` | JSON-RPC 2.0 encode/decode |
| `lib/noizu/mcp/schema.ex` | JSON Schema 2020-12 validation (JSV) against the MCP spec |
| `lib/noizu/mcp/acl.ex` | Authorization protocol + policy seam (PRD-2; lib owns no policy) |
| `lib/noizu/mcp/auth/` | Auth strategies (bearer/static, OAuth 2.1), token verification, plugs |
| `lib/noizu/mcp/persistence.ex` | Persistence contract + providers incl. `:disabled` (PRD-4) |
| `lib/noizu/mcp/store.ex` | Host write facade: provider write → version bump (PRD-4) |
| `lib/noizu/mcp/permission.ex` | Persisted per-caller policy records (PRD-4) |
| `lib/noizu/mcp/migrations.ex` + `migrations/` | Host migration units + shipped v1 Postgres change set |
| `lib/noizu/mcp/vfs.ex` | Virtual filesystem behaviour + TTL cache |
| `lib/noizu/mcp/toolset.ex` | Toolset resolution path (`tools/list`, `tools/call`) |
| `lib/noizu/mcp/description.ex` + `render_ctx.ex` | Per-render-context tool descriptions |
| `lib/noizu/mcp/eval.ex` | `@eval` description-tuning harness |
| `lib/noizu/mcp/inspector.ex` | `Noizu.MCP.Inspector` supervisor (Registry + DynamicSupervisor + Bandit) |
| `lib/mix/tasks/mcp.client.ex` | `mix mcp.client` Mix task |
| `lib/mix/tasks/mcp.engine.ex` | `mix mcp.engine` Mix task |
| `lib/mix/tasks/mcp.eval.ex` | `mix mcp.eval` eval harness Mix task |
| `priv/spec/2025-11-25/schema.json` | Official MCP JSON Schema |
| `priv/liquibase/noizu_mcp_oauth.yaml` | OAuth tables change set (Liquibase owns schema) |
| `daemon/mcp_mount/` | Companion mount daemon (separate mix app) |
| `fuse/README.md` | Go FUSE daemon build/run notes |
| `pg/pg_mcp/SPIKE.md` | pg_mcp extension spike notes |
| `test/support/fixture_server.ex` | Reusable test server for all test suites |
