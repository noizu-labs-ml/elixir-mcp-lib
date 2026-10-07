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

## 7. Linux

`mcp-mount` is platform-neutral userland sync — no kernel FUSE involved. On Linux it needs
Erlang/Elixir installed (build the escript as above); the `file_system` watcher uses inotify,
so write-back works out of the box (the escript pull-only degradation is macOS-only — see
`daemon/mcp_mount/README.md` "Platform notes").

For a **kernel** FUSE mount of the VFS use the companion `mcp-fuse` daemon
(`fuse/README.md` §Linux notes): install `fuse3` (`fusermount3` on `PATH`), then

```bash
export MCP_VFS_TOKEN=<key>
bin/mcp-fuse --server unix:/run/mcp/vfs.sock --mount /mnt/mcp
fusermount3 -u /mnt/mcp    # or Ctrl-C for graceful unmount
```

Linux binaries (`mcp-fuse-linux-amd64` / `-arm64`, statically linked) build via
`make fuse-build-linux` and are uploaded as CI artifacts on every `fuse/**` change.

## 8. Database-backed mounts

A mount can be served straight out of Postgres with `Noizu.MCP.VFS.Database`
— a raw-SQL backend (no Ecto schemas) over a single table:

```elixir
defmodule MyApp.MCP.DBFS do
  use Noizu.MCP.VFS.Database,
    repo: MyApp.Repo,
    table: "noizu_mcp_vfs_nodes",   # default
    read_only: false                # true => writes are :erofs
end
```

Apply the shipped Liquibase template
(`priv/liquibase/noizu_mcp_vfs.yaml` — copy it into your changelog directory
and add the include) before mounting, and seed the root row:

```sql
INSERT INTO noizu_mcp_vfs_nodes (path, parent_path, type)
VALUES ('/', NULL, 'dir') ON CONFLICT (path) DO NOTHING;
```

Files are rows (`data` BYTEA), directories are explicit rows (empty dirs
persist), and `version` is a real monotonic counter bumped on every write —
so FUSE/cache clients see fresh content immediately. Register the backend as
a VFS mount like any other (see `Noizu.MCP.Server` / `MCP-VFS-GROUP-MOUNTS.md`);
the mount commands in §3 above work unchanged against it.

## 9. Directory-backed mounts (`Noizu.MCP.VFS.File`)

For a mount that IS a directory on the host filesystem, use the shipped
`Noizu.MCP.VFS.File` backend — registration opts are the mount definition:

```elixir
use Noizu.MCP.Server, name: "my-files", version: "1.0.0"

vfs Noizu.MCP.VFS.File,
  root: "/srv/files",        # required — the served directory
  read_only: false,          # true => write/create/remove answer :erofs
  mime_types: %{".wasm" => "application/wasm"}  # ext -> mime overrides
```

Confinement is the backend's job, not the operator's: every path is
lexically checked against `root` (a `..` that climbs out reads as
`:enoent`, like any path that does not exist inside the tree), then
resolved component-wise through symlinks — any link that lands outside the
mount is `:eacces`, links that stay inside are followed. The root's own
ancestry is taken as given, so a symlinked root directory is fine.

Operator notes:

* stat versions derive from `{mtime, size}`: a same-sized same-mtime
  external edit is invisible to the version (writes through the backend
  always bump strictly). Treat versions as advisory for out-of-band edits.
* The server advertises `vfs_write` only when a registered backend is
  write-capable; a `read_only: true` registration never gets it, and its
  mutators stay runtime-gated (`:erofs`) rather than vanishing.
* Registration opts reach the backend per-request through
  `ctx.assigns[:vfs_opts]`; a bare backend call without them falls back to
  `Application.get_env(:noizu_mcp, Noizu.MCP.VFS.File, [])` — set `root:`
  there only if you call the backend directly without a server.

## 10. CRUD resources & prompts (`content/1,2`)

A `content` registration is a `vfs` mount plus a bridge into the resources
and prompts surfaces: the files are CRUDable through the existing `vfs/*`
tooling *and* advertise as live MCP resources and prompts. Add, edit, and
remove components by writing files — no recompile, no redeploy.

```elixir
use Noizu.MCP.Server, name: "my-app", version: "1.0.0"

resource MyApp.MCP.StaticAbout          # static registrations merge in front
prompt MyApp.MCP.StaticCodeReview

content {Noizu.MCP.VFS.File, root: "/srv/content"},
  resources: "/resources",              # files → resources (uri_scheme://rel)
  prompts: "/prompts",                  # JSON files → prompts
  uri_scheme: "content",                # default; resource URIs read back
  write_scope: "content:write"          # mutating vfs/* ops require this scope
```

Prefixes are optional — declare only what you expose; at least one is
required (compile-time error otherwise). Mechanics:

* `/resources/**` files advertise on `resources/list` as
  `<uri_scheme>://<path-under-prefix>` (e.g. `/resources/guide.md` →
  `content://guide.md`); `resources/read` reads off the backend
  (cache-aware, like any VFS read). Mime comes from the backend's
  `mime_type/2` when it has one, else an extension map; the description is
  the first paragraph of text content (or a `description` xattr).
* `/prompts/**` files are JSON prompt definitions — `{"name",
  "description", "arguments": [...], "messages": [{"role", "content"}]}` —
  the same shape the static prompt DSL produces. `prompts/get` substitutes
  `{{argument}}` placeholders from the request's string-keyed arguments and
  reports missing required arguments as `invalid_params`. Files that fail
  to parse are skipped on `prompts/list` (one broken file must not hide
  the others) and surface the error on `prompts/get`.
* Successful `vfs/write`, `vfs/create`, and `vfs/remove` under a content
  prefix fan out `notify_resource_updated/1` (resources prefix) and
  `notify_changed/1` (`:resources` / `:prompts`), so subscribed sessions
  and list caches invalidate exactly like static component changes.
* `write_scope:` gates the three mutators on content prefixes: the
  caller's claims (`ctx.assigns.auth_claims` — the same plumbing the JWT
  verifier fills) must hold the scope, exact or trailing-`*` glob; missing
  scope is `:eacces`. Reads stay under the existing auth.
* Every `content` registration joins `__mcp__(:vfs)`, so the mount is
  CRUDable through `vfs/*` and the mounters of §§3–9 — path routing picks
  the content mount whose prefix covers the request, else the first `vfs`
  registration (unchanged first-wins behavior).
