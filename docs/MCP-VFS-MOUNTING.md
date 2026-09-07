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
| `--token TOKEN` | — | Principal credential — an NPL **MCP JWT** (mint: `POST /api/mcp/token {"key": "<api-key>"}`) or an OAuth-delegated bearer. Optional; empty token is allowed. The first protocol frame is still `vfs/auth`. Empty token is accepted when the server has `auth: nil` or optional auth. *Or set `MCP_MOUNT_TOKEN` (env fallback; env wins only if the flag is absent) |
| `--mount DIR` | ✔ | Local directory to materialize into (created/updated in place) |
| `--ro` | — | Read-only mount: full snapshot + live sync, **never pushes** local edits (no watcher) |

Strict parsing — unknown/misspelled flags print usage and exit `64`. The first protocol frame is
always `vfs/auth` (empty token included); every operation then runs under that principal's identity
(group-set gating applies: an excluded group is absent from the tree, a disabled tool is unwritable).

## 3. Mount commands

```bash
# no-driver path (works without FUSE; preferred for remote wss://)
mcp-mount --url wss://tobor-stage.noizu.com/vfs --mount ~/mnt/tobor-stage

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

---

## 6. Kernel mount (`mcp-fuse`) vs no-driver path (`mcp-mount`)

`mcp-mount` is the **no-driver path**: it materializes real local files over WebSocket and
does not need FUSE/WinFsp. Prefer it for remote `wss://` (NPL browse, laptops that should
not install a kernel driver). `mcp-fuse` is the kernel filesystem over a **local** unix
socket (`unix:/path`); it needs a FUSE runtime (Linux FUSE 3, macFUSE/fuse-t, or WinFsp).

Prebuilt `mcp-fuse` companions ship on GitHub Releases (Hex stays Elixir-only):

| Artifact | Runner / notes |
|---|---|
| [mcp-fuse-linux-amd64](https://github.com/noizu-labs/noizu-mcp/releases/latest/download/mcp-fuse-linux-amd64) | linux amd64 |
| [mcp-fuse-linux-arm64](https://github.com/noizu-labs/noizu-mcp/releases/latest/download/mcp-fuse-linux-arm64) | linux arm64 (`ubuntu-24.04-arm`) |
| [mcp-fuse-darwin-arm64](https://github.com/noizu-labs/noizu-mcp/releases/latest/download/mcp-fuse-darwin-arm64) | darwin arm64 (`macos-14`) |
| [mcp-fuse-windows-amd64.exe](https://github.com/noizu-labs/noizu-mcp/releases/latest/download/mcp-fuse-windows-amd64.exe) | windows amd64, `CGO_ENABLED=0` (WinFsp demand-loaded) |
| [mcp-fuse-windows-arm64.exe](https://github.com/noizu-labs/noizu-mcp/releases/latest/download/mcp-fuse-windows-arm64.exe) | windows arm64 (`windows-11-arm`); if that runner cannot schedule, amd64 still ships |

```bash
# no-driver (preferred for remote wss://)
mcp-mount --url wss://tobor-stage.noizu.com/vfs --mount ~/mnt/tobor-stage

# kernel FUSE (local unix socket)
mcp-fuse --server unix:/run/mcp/vfs.sock --mount /Volumes/mcp --ro
```
