# docs/ — Documentation

```
docs/
├── arch/
│   ├── auth.md                     # Authentication strategies + OAuth AS facade
│   ├── authorization.md            # ACL protocol + policy seam (PRD-2)
│   ├── client.md                   # Client architecture
│   ├── engine.md                   # Engine federation architecture
│   ├── peer.md                     # Peer sans-IO state machine
│   ├── persistence.md              # Persistence providers, Store facade, migrations (PRD-4)
│   ├── request-lifecycle.md        # Request handling flow
│   ├── sql.md                      # SQL feature + pg_mcp extension
│   ├── supervision.md              # Supervision tree design
│   ├── toolsets.md                 # Toolset resolution + weighted merge (PRD-1/3)
│   ├── transports.md               # Transport layer design
│   ├── vfs.md                      # Virtual filesystem + /etc/dev control tree
│   └── sync.md                     # Dataset synchronization, sync/version 1 (ADR-009/PRD-13)
├── layout/
│   ├── auth.md                     # lib/noizu/mcp/auth/ breakdown (strategies + OAuth server)
│   ├── lib.md                      # lib/ source code breakdown
│   └── docs.md                     # This file
├── adrs/                           # Decision records (ADR-001…009 + INDEX.md)
├── specs/                          # MCP specification references
│   ├── 2025-03-26/                 #   Initial spec (15 files)
│   ├── 2025-06-18/                 #   Added auth, elicitation (22 files)
│   ├── 2025-11-25/                 #   Added tasks, schema (22 files)
│   └── draft/                      #   Upcoming spec (31 files)
├── 01-overview.md                  # Library overview and concepts
├── 02-transports.md                # Transport layer guide
├── 03-tools.md                     # Tool definition and handling
├── 04-resources.md                 # Resource serving guide
├── 05-prompts-sampling-roots.md    # Prompts, sampling, roots
├── 06-lifecycle-and-jsonrpc.md     # Connection lifecycle and JSON-RPC
├── 07-changelog-2025-06-18.md      # Changes in MCP spec 2025-06-18
├── 08-changelog-2025-11-25.md      # Changes in MCP spec 2025-11-25
├── 09-draft-2026-07-28-rc.md       # Draft spec notes
├── MCP-VFS-GROUP-MOUNTS.md         # VFS group-mount design notes
├── MCP-VFS-MOUNTING.md             # VFS mounting design notes
├── pg-mcp-install.md               # pg_mcp Postgres extension install guide
├── PROJ-ARCH.md                    # Architecture documentation
├── PROJ-ARCH.summary.md            # Architecture summary
├── PROJ-LAYOUT.md                  # Project layout (this doc set)
├── PROJ-LAYOUT.summary.md          # Layout summary
├── PROJ-SCHEMA.md                  # Data schema reference (ERDs + inventory)
├── PROJ-SCHEMA.summary.md          # Schema quick-reference (Mermaid only)
├── THREAT-MODEL.md                 # Threat model (surface, STRIDE register)
├── THREAT-MODEL.summary.md         # Threat model quick-reference
├── schema/                         # Per-domain schema detail
│   ├── toolsets.md                 #   Lib-owned v1_toolsets tables
│   ├── oauth.md                    #   OAuth 2.1 AS tables
│   ├── agent.md                    #   Agent auth tables
│   └── sync.md                     #   mcp_sync schema (ADR-009/PRD-13)
└── threats/                        # Threat model detail
    ├── attack-surface.md           #   Ingress/egress/store enumeration
    ├── authn-authz.md              #   Auth + ACL control detail
    ├── sync-and-stores.md          #   Store + synchronization controls
    ├── local-surface.md            #   VFS mounts, Inspector, transport DoS
    └── supply-chain.md             #   Hex package, shipped SQL, CI
```
