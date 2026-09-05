# docs/ — Documentation

```
docs/
├── arch/
│   ├── auth.md                     # Authentication strategies + OAuth AS facade
│   ├── authorization.md            # ACL protocol + policy seam (PRD-2)
│   ├── client.md                   # Client architecture
│   ├── peer.md                     # Peer sans-IO state machine
│   ├── persistence.md              # Persistence providers, Store facade, migrations (PRD-4)
│   ├── request-lifecycle.md        # Request handling flow
│   ├── supervision.md              # Supervision tree design
│   ├── toolsets.md                 # Toolset resolution + weighted merge (PRD-1/3)
│   ├── transports.md               # Transport layer design
│   └── vfs.md                      # Virtual filesystem + /etc/dev control tree
├── layout/
│   ├── auth.md                     # lib/noizu/mcp/auth/ breakdown (strategies + OAuth server)
│   ├── lib.md                      # lib/ source code breakdown
│   └── docs.md                     # This file
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
├── PROJ-ARCH.md                    # Architecture documentation
├── PROJ-ARCH.summary.md            # Architecture summary
├── PROJ-LAYOUT.md                  # Project layout (this doc set)
└── PROJ-LAYOUT.summary.md          # Layout summary
```
