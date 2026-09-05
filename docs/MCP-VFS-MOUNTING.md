# MCP-VFS Mounting — Options & Commands

**Status**: operator reference · 2026-09-05 · companion to [`MCP-VFS-GROUP-MOUNTS.md`](MCP-VFS-GROUP-MOUNTS.md) (design of record)
**Tool**: `mcp-mount` escript — `Portfolio/Libs/ai/elixir-mcp/daemon/mcp_mount` (`McpMount.CLI`)
**Behavior**: materializes a remote MCP-VFS tree as **real local files**, keeps them live over
`vfs/subscribe` (WS), pushes local edits back (250 ms debounce), syncs on reconnect by manifest
version-diff. Runs in the **foreground** until killed; the mounted directory remains as plain
files afterward (a later remount resyncs by version, deletions included).

---

## 1. Build

```bash
cd /Users/keithbrings/Work/Space/Noizu/Portfolio/Libs/ai/elixir-mcp/daemon/mcp_mount
MIX_ENV=prod mix escript.build          # → ./mcp-mount (escript, -noshell)
```

## 2. Options (full surface — OptionParser `strict:`)

| Flag | Required | Meaning |
|---|---|---|
| `--url ws(s)://host/vfs` | ✔ | VFSWS endpoint of the target host (`GET /vfs` upgrade; `wss://` for TLS) |
| `--token TOKEN` | ✔* | Principal credential — an NPL **MCP JWT** (mint: `POST /api/mcp/token {"key": "<api-key>"}`) or an OAuth-delegated bearer. *Or set `MCP_MOUNT_TOKEN` (env fallback; env wins only if the flag is absent) |
| `--mount DIR` | ✔ | Local directory to materialize into (created/updated in place) |
| `--ro` | — | Read-only mount: full snapshot + live sync, **never pushes** local edits (no watcher) |

Strict parsing — unknown/misspelled flags print usage and exit `64`. The first protocol frame is
`vfs/auth` with the token; every operation then runs under that principal's identity (group-set
gating applies: an excluded group is absent from the tree, a disabled tool is unwritable).

## 3. Mount commands

```bash
# stage — read-write (your key's scope defines what materializes)
mcp-mount --url wss://tobor-stage.noizu.com/vfs \
          --token "$STAGE_MCP_JWT" \
          --mount ~/mnt/tobor-stage

# prod — read-only safety mount
mcp-mount --url wss://tobor.locker/vfs \
          --token "$PROD_MCP_JWT" \
          --mount ~/mnt/tobor --ro

# token via env (keeps it out of shell history / ps)
MCP_MOUNT_TOKEN="$JWT" mcp-mount --url wss://tobor-stage.noizu.com/vfs --mount ~/mnt/tobor-stage
```

**Unmount**: `Ctrl-C` / `kill` the foreground process (or `pkill -f mcp-mount`). No daemon remains;
`DIR/.mcp-mount/manifest.json` records the last synced versions — the next mount with the same
token diff-resyncs (server-side deletions are mirrored locally).

## 4. What you get in the mounted directory

```
~/mnt/tobor-stage/
├── etc/dev/tools/<tool>          # write {"args": {...}} to invoke; read = last result (per-connection)
│   …                             # + runtime/, cache/, config/ control nodes
└── tobor/{org}/…                 # per the group-mount design:
    ├── wiki/{space}/{page}.md    # natural-file groups: edit + save = pushed update
    ├── tickets/{KEY}/record.json # entity-dirs: record.json is the canonical write target
    ├── chat/{room}/messages/{ts}-{seq}.json   # append-log: each message is a NEW file
    ├── notifications/{me}/{id}.json           # fswatch this dir for inbound notifications
    └── …                         # full topology: MCP-VFS-GROUP-MOUNTS.md §1–2
```

- New files you create locally are pushed as `vfs/create`; edits as `vfs/write` (debounced 250 ms).
- If the server moved ahead of your edit, your version is saved aside as `<path>.conflict-<ISO-ts>`
  and the server copy is re-pulled. `.mcp-mount/` and `*.conflict-*` are never pushed.
- File modes: `0755` for executable-flagged nodes, else `0644`. 16 MB max per file frame.
- Read-only groups (unicode, github mirror, markdown, `_npl`, `_meta`) reject writes with `EROFS`-
  class errors; excluded groups are not present at all.

## 5. Availability

| Endpoint | VFS state |
|---|---|
| Local dev / CI | `daemon/mcp_mount/test` ships an in-repo WS fixture server; the lib's transport suite mounts against it today |
| `wss://tobor-stage.noizu.com/vfs` | **pending design Wave 0** — NPL serves no VFS backend yet (`MCP-VFS-GROUP-MOUNTS.md` §0.4: greenfield); this is the first deliverable of implementation Wave 0 (Router backend + VFSWS on `fs.{host}`) |
| `wss://tobor.locker/vfs` | follows stage after flip-train validation |

The `--include/--exclude/--max-files` narrowing flags are **design asks (D1), not implemented** —
until then, bound what materializes by mounting with a scope-narrowed credential (the narrowed
tool-set plane defines the visible tree).
