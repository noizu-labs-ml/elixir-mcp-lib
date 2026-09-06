# MCP-VFS Group Mounts — Design of Record

**Status**: DRAFT for owner review · 2026-09-05
**Operator reference**: [`MCP-VFS-MOUNTING.md`](MCP-VFS-MOUNTING.md) — build, flags, mount commands
**Scope**: how each NPL MCP group (`NoizuPromptLingua.MCPServers` catalog, ~22 entries) exposes
its content and interaction through the MCP-FUSE/VFS mounting stack (noizu_mcp 0.2.0 `Noizu.MCP.VFS`
+ `daemon/mcp_mount`).
**Grounded in**: the real VFS callback surface in `Portfolio/Libs/ai/elixir-mcp` and the real tool
surface in `Portfolio/Apps/AI/NoizuPromptLingo/backend`. Every op↔file mapping below names actual
tool modules; every mechanism cites the actual lib module. Nothing here is invented API —
unbuilt pieces are explicitly labeled **[feature ask]**.

---

## 0. Ground truth — the VFS contract we are designing against

### 0.1 Backend behaviour — `Noizu.MCP.VFS`

A backend is any module `use Noizu.MCP.VFS` implementing:

| Callback | Required | Contract |
|---|---|---|
| `stat/2` | yes | `%Noizu.MCP.VFS{}` node (`type: :dir \| :file \| :control`, `size`, `mtime`, `version`, `writable`, `executable`, `xattrs`) or `{:error, errno}` |
| `list/3` | yes | children of a dir, paginated: `{:ok, entries, next_cursor}` |
| `read/2` | yes | `{:ok, content, version}` |
| `write/3` | opt | whole-file overwrite (default `:enosys`) |
| `create/3` | opt | new file (binary) or dir (`:dir`); default `:enosys` |
| `remove/2` | opt | file or **empty** dir (`:enotempty` guard); default `:enosys` |
| `search/3` | opt | grep-style line matches under a root, paginated; default `:enosys` |
| `xattr/2` | opt | extended-attribute map; default `{:ok, %{}}` |

Errnos are plain atoms — `:enoent, :eacces, :eexist, :erofs, :eisdir, :enotdir, :enosys, :enotempty`
— mapped on the wire by `Noizu.MCP.Server.Features.VFS.errno_error/1`
(`eacces → -32040, eexist → -32041, erofs → -32042, eisdir → -32043, enotdir → -32044,
enotempty → -32045, enosys → -32046, eio → -32048`; `enoent → -32002 resource_not_found`).
`Noizu.MCP.Server.VFS.capabilities/1` derives the server's `vfs` / `vfs_write` capability flags
from which callbacks the backend implemented.

**Notable absences**: no `append`; no `rename`/`move`/`copy`; `write/3` takes **no expected-version
parameter** (no server-side CAS); content is a binary shipped inside JSON text frames (UTF-8
assumed); one backend per server — `vfs/*` operations address only the **first** registration
(`Noizu.MCP.Server.Features.VFS.with_backend/2`), while the `mcp_fs_search` tool
(`Noizu.MCP.Server.Tools.McpFsSearch`) fans out to **all** registrations.

### 0.2 Dispatch, cache, liveness

- `Noizu.MCP.Server.Features.VFS` — cache-aware wrappers over the backend; the server-level ops
  `vfs_stat / vfs_list / vfs_read / vfs_write / vfs_create / vfs_remove / vfs_search / vfs_xattr`.
  Versions served to clients are stamped `node.version + Noizu.MCP.VFS.Cache.generation(backend)`;
  every successful `write/create/remove` bumps the generation first. `vfs_read` accepts an
  `expected_version` that is compared against the *cached* read version (a freshness check, not a
  write CAS).
- `Noizu.MCP.VFS.Cache` — per-backend `:persistent_term` `{generation, entries}`, TTL
  `:noizu_mcp, :vfs_cache_ttl_ms` (default 60 s), kill switch `:vfs_cache_enabled`. **Cache keys are
  `{backend, kind, path}` — identity-blind.** A backend that varies results by `ctx` (per-principal
  views) can cross-contaminate caches across principals. The `Noizu.MCP.VFS.Control` moduledoc
  already flags a `__mcp_vfs__(:cacheable)` opt-out as "the clean long-term fix … flagged upstream".
- `Noizu.MCP.Server.VFSPubSub` — subtree watches over `{backend, path}` keys:
  `watch(backend, paths, depth: n | :infinity)`, metadata-only events
  `%{backend, op, path, version, seq, by, at}` delivered as `{:vfs_event, event}`, 50 ms burst
  coalescing (final version wins), ancestor-or-equal dispatch, 10 000 watches per subscriber
  (`:ewouldwatch`). **Publishing happens only from the `Features.VFS` write/create/remove wrappers.**
  Mutations performed outside the VFS (a `tools/call` on the MCP surface, the web UI, another agent)
  do **not** publish — consumers fall back to the 60 s TTL and the mounter's reconnect diff-resync.
- `Noizu.MCP.VFS.Control` — the `/etc/dev` control & introspection tree, composed into a backend by
  delegation ("the generated module *is* the backend the server registers" — the composition
  precedent our router follows). Node table: `/etc/dev/tools/<tool>` (read = tool-definition JSON,
  or the buffered result of the last invocation for **this connection**; write = one JSON line
  `{"args": {...}}` → `server.handle_call_tool/3`), `/etc/dev/runtime/{status,sessions/<id>}`,
  `/etc/dev/cache/{stats,flush}`, `/etc/dev/config/<toggle>`. Invocation gating, in order:
  `tool_gate: {m,f}` hook → `ctx.assigns[:auth_claims]["vfs_tool_allowlist"]` → tools annotated
  `destructive_hint: true` fail closed (`:eacces`) → allow. Server opt `vfs_readonly: true` turns
  every write (control tree included) into `:erofs`.
- Transports: `Noizu.MCP.Transport.VFSSocket` (unix socket, `packet: 4` length-prefixed JSON-RPC,
  mode 0600, **first frame must be `vfs/auth {"api_key": ...}`**, max frame 16 MB);
  `Noizu.MCP.Transport.VFSWS` (bandit Plug upgrading `GET /vfs`, optional Bearer verifier on the
  upgrade, `v: 2` envelope, `vfs/auth | vfs/stat | … | vfs/subscribe {"paths": [...], "depth":
  n|"infinity"} | vfs/unsubscribe | vfs/ping`, server-pushed `vfs/event` frames, 30 s WS pings,
  watch-cap excess → `-32047`); `Noizu.MCP.Transport.VFSClient` (Elixir reference client).
  Auth binds the principal's claims to the connection `Ctx` (`assigns.auth_claims` plus any
  `context: {Mod, :fun}` assigns) and **every subsequent operation runs under that identity** —
  backends receive `ctx` in every callback.

### 0.3 The mounter — `daemon/mcp_mount`

`McpMount.Mounter` materializes a remote VFS as **real local files** (not FUSE):

- Snapshot = recursive `vfs/list` walk (`walk/1`, cursor-pagination aware) then
  `Task.async_stream` stat+read per file (`max_concurrency: 8`); every non-`:dir` node — control
  nodes included — becomes a local file. `.mcp-mount/manifest.json` (`McpMount.Manifest`) records
  `{path → {version, mode, size}}`; reconnects are a version-diff resync (deletions mirrored).
- Live = `vfs/subscribe {"/", :infinity}`; `write|create` events pull via `vfs/read`, `remove`
  deletes locally; self-echo detected by manifest-version match. Local file edits are debounced
  250 ms and pushed back (`vfs/create` for locally new files, `vfs/write` when the server version
  still matches the manifest); if the server moved ahead, the local edit is saved aside as
  `<path>.conflict-<ISO-ts>` and the server version re-pulled. `--ro` mounts never push.
  Modes: `executable: true` → 0755, else 0644. `.mcp-mount/` and `*.conflict-*` are never pushed.
- Transport is the `McpMount.Conn` behaviour (production `McpMount.WSConn`, mint-based);
  CLI: `--url ws(s)://host/vfs --token T --mount DIR [--ro]`.

Consequences that shape this design: (1) whatever we put in the tree *will* be materialized
locally — subtrees are cheap, monsters are not; (2) append-log semantics must be expressed as
**per-entry create-new files** (a `tail`ed `messages.log` would push whole-file overwrites back);
(3) control-file conventions work today — an `/etc/dev/tools/<tool>` node materializes as an
editable local file whose edit is pushed as the invoking `vfs/write`, with the result consumed by
the next read; (4) the daemon walks and subscribes to *everything* the principal can see —
group gating must therefore be server-side and authoritative, with daemon-side filters as
bandwidth hygiene.

### 0.4 The NPL group catalog

`NoizuPromptLingua.MCPServers` (`mcp_servers.ex`) is the source of truth: `root` at `<host>/mcp`,
21 groups at `<id>.<host>/mcp` (`custom_url/2` serves scopes at `<host>/custom/<slug>/mcp`).
Server modules: `NoizuPromptLingua.MCP.{Organizations, Projects, Sessions, Clients}` and
`NoizuPromptLingua.Domains.<Domain>.MCP` (17 domains). `clients` is served on root only (not in the
public customizable catalog). Every group server registers its domain tools **plus the five
Discovery tools** (`Tools.{ToolSummary, ToolSearch, ToolDefinition, ToolCall, ToolHelp}`) and an
`Overview` tool; root additionally registers `Tools.{NPLLoad, NPLSpec, McpOverview}` and
`MCP.Keys.Tools.*`.

Access narrowing already exists and is the model to mirror:
`NoizuPromptLingua.MCP.EffectiveToolset.resolve/4` cascades scope config (`%{"groups" => ...}` from
`NoizuPromptLingua.MCPCustomScopes`, kinds `custom | all_in_one | core_variant`) → client
`toolset_config` → per-user ACL final override, producing per-tool
`%{enabled:, visible:, name_override:, description_override:, expires_at:}`.
`NoizuPromptLingua.MCP.Toolsets.Profiles` defines the 5 capability profiles
(`full, agent-ops, pm-dev, content, comms`) as a compile-validated `@profile_groups` registry.
`NoizuPromptLingua.MCP.Server` routes `handle_call_tool/3` through `MCP.Dispatch`
(ToolGuard + PDP) and filters listings through EffectiveToolset.

**NPL has no VFS backend today** — everything in §2 is greenfield on the NPL side, riding the lib
as-is plus the feature asks in §6.

---

## 1. Namespace layout

### 1.1 Mount root schema

```
<mount-dir>/                       ← local materialization by mcp-mount
├── etc/dev/…                      ← lib control tree (composed at "/"), see §3.6
└── tobor/
    ├── {org-slug}/                ← one subtree per organization the principal can see
    │   ├── org.json               ← this org's own record   (Organizations group)
    │   ├── _meta/                 ← discovery plane for THIS principal, see §3.6
    │   ├── wiki/{space}/{page}.md           ← natural-file groups
    │   ├── artifacts/{artifact}/…
    │   ├── instructions/{name}/…
    │   ├── unicode/…
    │   ├── projects/{slug}/…                ← entity-dir groups
    │   ├── tickets/{KEY}/…
    │   ├── customers/…  market/…  campaigns/…
    │   ├── personas/{slug}/…
    │   ├── sessions/{id}/…
    │   ├── chat/{room}/…                    ← append-log groups
    │   ├── notifications/{recipient}/…
    │   ├── memory/{agent}/…
    │   ├── pubsub/{channel}/…
    │   ├── github/{owner}/{repo}/…          ← control/query + mirror groups
    │   ├── browser/…  markdown/…
    │   └── clients/{id}/…                   ← internal, root-plane keyed principals only
    └── orgs/                      ← (super-mount only) cross-org listing, see §3.7
```

Rationale:

- **Org as the first segment** mirrors the org-scoped gateway URLs (chatrooms at `/app/{org}/…`,
  `{group}.{host}/mcp` endpoints) and gives every group subtree a clean authz boundary: one
  membership check at `{org}` covers everything beneath it.
- **`readdir /tobor` = `OrganizationList`** for the mounting principal — the org listing *is* the
  mount root; `OrganizationCreate` = create a new `{org-slug}/org.json`. The namespace and the tool
  surface coincide by construction.
- Path segments follow NPL entity identity rules: **stable keys only**. Org/project slugs; ticket
  human keys (`PREFIX-NNN`, immutable by design); UUIDs rendered `{type}-{short8}` where no slug
  exists (rooms, sessions, personas without slugs); display names live in `record.json`/index
  files, never in the path. Synthesized file names use filesystem-safe timestamps
  (`2026-09-05T12-00-01Z-{short8}` — no colons). Renames of slugs are out of scope (no rename
  primitive; treat as create-new + remove-old, documented per group).

### 1.2 One VFS endpoint, one composed router backend

The lib's one-backend-per-`vfs/*` rule (§0.1) plus the mounter's one-endpoint-per-mount model
settle the topology: NPL registers **one composed backend**,
`NoizuPromptLingua.MCP.VFS.Router`, on a VFS-capable server (recommend a dedicated `fs.{host}`
server so the mount principal needs no tool keys at all), exposed over `Noizu.MCP.Transport.VFSWS`
at `/vfs` (bandit child) with the same verifier pipeline NPL already uses
(`mcp/dual_token_verifier.ex`, API key or OAuth token). The Router:

1. `use Noizu.MCP.VFS.Control, server: …, real: NoizuPromptLingua.MCP.VFS.Root` — inherits the
   entire `/etc/dev` tree (the `Control` composition precedent: delegation, not overlay);
2. dispatches every non-control path by prefix to per-group backend modules
   (`NoizuPromptLingua.MCP.VFS.{Wiki, Tickets, Chat, …}`), each `use Noizu.MCP.VFS` and each
   independently conformance-testable;
3. because `mcp_fs_search` fans over *all* registrations, registering only the Router keeps search
   unified; per-group backends can additionally be registered search-only if we ever want
   backend-filtered search.

### 1.3 Authentication → per-principal view

`vfs/auth` (socket) or Bearer on the WS upgrade (or in-band `vfs/auth` for token rotation) binds
the principal's claims — the same key/OAuth identity the MCP surface uses. The Router resolves the
principal's **effective group set once per connection** (EffectiveToolset cascade against the
key's scope/client, memoized like `mcp/toolset_cache.ex`, invalidated by
`MCP.Server.notify_toolset_changed/0`) and that set gates visibility:

| Principal state | VFS behavior |
|---|---|
| group in effective set, tools visible | subtree served normally |
| group included but tool `disabled` | node listed, `writable: false`; mutating ops → `:eacces` |
| group excluded (scope doesn't include it) | **`:enoent` for the entire subtree** — mirrors `visible: false` (no existence leak) |
| user-level ACL `deny` on a tool | node hidden from listings; control-file invoke → `:eacces` |
| `vfs_readonly: true` server kill-switch | every write → `:erofs` (lib behavior) |

Group-set membership is therefore **checked at mount time** (the sync only ever sees gated paths)
and re-checkable per operation (the `ctx` rides every callback). A mount credential is just an NPL
key/OAuth token; issuing a scope-narrowed key yields a scope-narrowed mount. Per-principal *content*
filtering (e.g. only tickets you watch) is a per-backend concern, deferred — §6 Q4.

### 1.4 Daemon-side filtering (hygiene, not security)

**[feature ask D1]** `mcp-mount --include /tobor/{org}/tickets --include /tobor/{org}/chat`
(+ `--exclude`, `--max-files`): restrict the snapshot walk, event application, and watcher to
prefixes. The server-side gates of §1.3 are authoritative; these keep a `content`-profile principal
from materializing 50 000 ticket dirs they are *allowed* but don't want.

---

## 2. Per-group design

Conventions used in every block:

- **`record.json`** — the canonical, whole-entity JSON document: one read = one consistent
  snapshot; versioned by the cache generation. Field files, where shown, are ergonomic projections;
  the canonical doc is the merge target.
- **Error mapping** is the lib's, uniformly: unknown id/path → `ENOENT`; authz/visibility →
  `EACCES` (hidden) or `ENOENT` (excluded group); read-only group/kill-switch → `EROFS`; collision
  → `EEXIST`; malformed control write → `EIO`; structural → `EISDIR/ENOTDIR/ENOTEMPTY`.
- **Liveness classes**: `live` = mutation routed through the VFS (write-back or `/etc/dev`
  invoke) → generation bump + pubsub event, mounters see it in ≤50 ms; `ttl` = out-of-band
  mutation (web UI, plain `tools/call` on the MCP surface) → visible after the 60 s cache TTL /
  next resync; `hooked` = domain code additionally calls `VFSPubSub.publish/5` on its write paths
  (**[feature ask L1]**, §6 Q5) → live without routing through VFS.
- **Destructive/side-effecting actions** that must not look like file edits go through
  `/etc/dev/tools/<Tool>` control writes — uniformly, so the ToolGuard + PDP path in
  `MCP.Dispatch` applies untouched. Group-local control files are used only where they read
  naturally and are called out explicitly.

Unless marked otherwise every group is **read-write**; read-only groups set `writable: false` and
omit the mutating callbacks (the lib then advertises no `vfs_write` for that subtree — enforced by
`:enosys` defaults, surfaced as `EROFS`-class behavior).

### 2.1 Wiki — `Domains.Wiki.MCP` · natural-file

Paths: `/tobor/{org}/wiki/{space}/_space.json`, `/tobor/{org}/wiki/{space}/{page}.md`,
`…/{page}.comments/{id}.json`, `…/{page}.assets/{filename}`, `…/reactions.json`

| Tool | File op |
|---|---|
| `Wiki.Tools.SpaceList` | readdir `/wiki` |
| `SpaceGet` / `SpaceUpdate` | read / write `{space}/_space.json` |
| `SpaceCreate` | create `{space}/` (+`_space.json`) |
| `SpaceDelete` | remove — `ENOTEMPTY` while pages exist; force-delete via `/etc/dev` control write |
| `PageList` | readdir `{space}/` |
| `PageGet` / `PageCreate` / `PageUpdate` / `PageDelete` | read / create / write / unlink `{space}/{page}.md` (metadata in front-matter + xattrs) |
| `CommentList` / `CommentCreate` / `CommentDelete` | readdir / create / unlink `{page}.comments/` |
| `AttachmentList` / `AttachmentCreate` / `AttachmentDelete` | readdir / create / unlink `{page}.assets/` — binaries per §3.3 |
| `ReactionList` / `ReactionAdd` / `ReactionRemove` | read / write / write `reactions.json` |

Class: **natural-file** — the page content *is* the file; this is the flagship of the whole
feature. Writes: `PageUpdate` = whole-file overwrite; concurrent edits surface through the
daemon's stat-then-push check → `.conflict-*` save-aside (§0.3). Search: implement `search/3`
over page bodies (`mcp_fs_search` gets wiki for free). Liveness: `live` on VFS writes, `ttl`
otherwise. Default: read-write.

### 2.2 Artifacts — `Domains.Artifacts.MCP` · natural-file + immutable revisions

Paths: `/tobor/{org}/artifacts/{artifact}/record.json`, `…/revs/v{n}.{ext}`, `…/current.txt`

| Tool | File op |
|---|---|
| `ArtifactList` | readdir `/artifacts` |
| `ArtifactCreate` | create dir + `record.json` + `revs/v1.{ext}` |
| `ArtifactGet` | read `record.json` (or `current.txt` → revision content) |
| `ArtifactAddRevision` | **create-only** `revs/v{n+1}.{ext}` (server rejects overwrite of an existing revision with `EEXIST` — immutability without new primitives) |
| `ArtifactListRevisions` | readdir `revs/` (sorted; `current.txt` names the active revision) |
| `ArtifactGetBinary` | **[feature ask B1]** — binary retrieval blocked on §3.3 |

Class: **natural-file** with append-only revision semantics (create-new files — exactly the
primitive the daemon/model already has). Default: read-write (adding revisions), revisions
themselves immutable.

### 2.3 Instructions — `Domains.Instructions.MCP` · natural-file + version pointer

Paths: `/tobor/{org}/instructions/{name}/versions/v{n}.md`, `…/active` (pointer file),
`…/record.json`

| Tool | File op |
|---|---|
| `InstructionList` | readdir `/instructions` |
| `InstructionCreate` | create dir + `versions/v1.md`, `active` = `v1` |
| `InstructionGet` | read content of the revision named by `active` |
| `InstructionUpdate` | create `versions/v{n+1}.md` (new immutable version) |
| `InstructionVersions` | readdir `versions/` |
| `InstructionSetActiveVersion` | write `active` (one-line pointer) |
| `InstructionRender` | `/etc/dev` control write (`params` in args) — rendered text comes back as the buffered result read |
| `InstructionDelete` | remove dir (`ENOTEMPTY` unless all versions removed) |

Class: **natural-file**; render is a **control/query** action. Default: read-write.

### 2.4 Unicode Codex — `Domains.UnicodeCodex.MCP` · natural reference + query

Paths: `/tobor/{org}/unicode/special-usages/{slug}.md`, `/tobor/{org}/unicode/{plane}/{U+XXXX}.json`

| Tool | File op |
|---|---|
| `UnicodeCodex.Tools.SpecialUsageList` | readdir `special-usages/` |
| `SpecialUsageGet` | read the markdown doc |
| `UnicodeCodex.Tools.Get` | read `{plane}/{U+XXXX}.json` (generated static reference tree) |
| `Search` / `Related` | `search/3` over the reference tree; `Related` via `/etc/dev` control write |

Class: **natural-file** (static reference content) + query. Default: **read-only**. Cheap wave-1
filler — the tree is generated content.

### 2.5 Organizations — `MCP.Organizations` · entity-dir

Paths: `/tobor/{org}/org.json`; super-mount `/tobor/orgs/{slug}/record.json` (§3.7)

| Tool | File op |
|---|---|
| `OrganizationList` | readdir `/tobor` (orgs visible to the principal) |
| `OrganizationGet` | read `org.json` |
| `OrganizationUpdate` | write `org.json` (canonical doc merge) |
| `OrganizationCreate` | create `{new-slug}/org.json` (create-dir + file) |

Class: **entity-dir**. Default: read-write for org admins, read-only otherwise (writable flag per
principal role). Slug is the stable key; rename = out of scope.

### 2.6 Projects — `MCP.Projects` · entity-dir

Paths: `/tobor/{org}/projects/{slug}/record.json`

| Tool | File op |
|---|---|
| `ProjectList` | readdir `/projects` |
| `ProjectGet` / `ProjectUpdate` | read / write `record.json` |
| `ProjectCreate` | create `{slug}/record.json` |

Class: **entity-dir**. Read-write. Group-scoped detail: `_meta` per project for membership/profile
data stays a `record.json` field, not a subtree (avoid explosion).

### 2.7 Sessions — `MCP.Sessions` · entity-dir + log

Paths: `/tobor/{org}/sessions/{session-id}/record.json`, `…/manifest.json`, `…/log/` (append)

| Tool | File op |
|---|---|
| `SessionList` | readdir `/sessions` |
| `SessionCreate` | create dir + `record.json` |
| `SessionGet` | read `record.json` |
| `SessionUpdate` | write `record.json` |
| `Sessions.Tools.Manifest` | read `manifest.json` (rendered from `MCP.Session_Manifest`) |
| `SessionArchive` | control write via `/etc/dev` (state transition, not a content edit) |

Class: **entity-dir** with an append-only activity log (`log/{ts}-{id}.json` entries — same
convention as chat). Read-write.

### 2.8 Tickets — `Domains.Tickets.MCP` · entity-dir (the big one)

Paths: `/tobor/{org}/tickets/{KEY}/…` (KEY = immutable human key `PREFIX-NNN`),
`/tobor/{org}/tickets/_queues/{queue}.json`, `/tickets/_queues/{queue}.feed.log`,
`/tickets/_types/{type}.json`, `/tickets/_fields/{field}.json`

| Tool | File op |
|---|---|
| `TicketList` | readdir `/tickets` (paged via `list/3` cursor; see §3.4) |
| `TicketGet` | read `{KEY}/record.json` |
| `TicketCreate` | create `{KEY}/` + `record.json` (server assigns the key; the created node's path is returned in the node map / xattrs) |
| `TicketUpdate` | write `record.json` (or a `fields/{name}.json` projection — canonical doc is merge target) |
| `TicketComment` | create `{KEY}/comments/{ts}-{id}.json` |
| `TicketFeed` | read `{KEY}/feed.log/` entries (readdir) |
| `TicketWatch` | write `{KEY}/watchers.json` |
| `TicketAttach` | create `{KEY}/attachments/{filename}` (binary per §3.3) |
| `TicketLink/Unlink` | write `{KEY}/links.json` |
| `TicketLinkEntity/UnlinkEntity` | write `{KEY}/links.json` (typed entries) |
| `QueueCreate/Get/List` | create / read / readdir `_queues/` |
| `QueueFeed` | readdir `_queues/{queue}.feed.log/` |
| `DefinitionCreate/Get/Update/Delete` | create / read / write / unlink `_types/{type}.json` |
| `FieldDefinitionCreate/Update/Delete` | create / write / unlink `_fields/{field}.json` |

Class: **entity-dir**, human-keyed (tickets already have immutable `PREFIX-NNN` keys — the cleanest
entity mapping in the catalog). `record.json` = one-read consistent snapshot; field-file writes are
documented as projections with last-write-wins + `.conflict-*` semantics. Status transitions ride
`TicketUpdate` (plain field edits) — no special-casing. Ticket **deletion is not in the tool
surface and stays unexposed** (see §3.5). Read-write. Liveness: `ttl` for UI-driven edits unless
hooked (**L1**).

### 2.9 Chat — `Domains.Chat.MCP` · append-log

Paths: `/tobor/{org}/chat/rooms.json` (index), `/tobor/{org}/chat/{room}/record.json`,
`…/messages/{ts}-{seq}.json`, `…/messages/{msg-id}.replies/{ts}-{seq}.json`, `…/members/{member}.json`,
`…/events/{ts}-{id}.json`, `…/attachments/{filename}`, `…/reactions.json`, `…/pinned.json`

| Tool | File op |
|---|---|
| `ListRooms` | readdir `/chat` (+ `rooms.json` index with unread counts) |
| `CreateRoom` | create `{room}/record.json` |
| `GetRoom` | read `record.json` |
| `DeleteRoom` | remove — `ENOTEMPTY` guard; force via `/etc/dev` |
| `SendMessage` | **create** `messages/{ts}-{seq}.json` — append expressed as create-new (no append primitive; §6 Q2) |
| `ListMessages` | readdir `messages/` (sorted, cursor-paginated) |
| `Chat.Tools.CreateEvent` / `ListEvents` | create / readdir `events/` |
| `AddMember` / `ListMembers` | create / readdir `members/` |
| `JoinRoom` / `LeaveRoom` / `MuteRoom` | create / remove / write own `members/{me}.json` flags |
| `ChatReact` | write `reactions.json` |
| `PinMessage` / `HighlightMessage` | write `pinned.json` / message-meta field |
| `ChatAttach` | create `attachments/{filename}` |
| `ScheduleMessage` | create `scheduled/{send-at}-{id}.json` (server sends + moves to `messages/` on due) |
| `ForwardReplies` | `/etc/dev` control write |
| `DM` | create `dm/{member-pair-key}/…` (same room shape) |
| `AttachWiki` | write `record.json` wiki-link field |
| `Chat.Tools.Notifications` / `NotificationClear` | read / clear own `notifications/` entries (→ §2.17) |

Class: **append-log**, per-message files. This is deliberate: one `messages.log` would (a) require
the missing append primitive and (b) make every `tail -f` consumer push whole-file overwrites back.
Per-message create events give the daemon exactly one materialization per message and let plain
`ls messages/ | tail` do what `tail -f` would have. Read-write.

### 2.10 Notifications — `Domains.Notifications.MCP` · append-log + subscribe

Paths: `/tobor/{org}/notifications/{recipient}/{notif-id}.json`, `…/{notif-id}.meta.json`

| Tool | File op |
|---|---|
| `Notify` | **create** `{recipient}/{id}.json` (cross-recipient create, ToolGuard-gated) |
| `Notifications.Tools.Get` / `Poll` | read / readdir (unread filter via meta files or `?unread` index dir) |
| `MarkRead` / `MarkSeen` / `Ack` | write the notification's `read/seen/acked` fields (meta file or in-doc) |
| `Clear` | `/etc/dev` control write (bulk destructive) |
| `Watch` | **native**: `vfs/subscribe {"/tobor/{org}/notifications/{me}", depth: 1}` — the tool becomes redundant under a mount |
| `FollowUp` / `Share` | `/etc/dev` control write |

Class: **append-log + stream**. This is the headline mount UX: `fswatch ~/m/tobor/{org}/notifications/me/`
fires on every incoming notification with zero new machinery — `VFSPubSub` ancestor dispatch
already fans a create event to the directory watcher, and the daemon materializes the file. Read:
everyone their own subtree only (per-principal filtering in the backend, enforced by path).
Read-write (mark-read), create-gated (Notify).

### 2.11 PubSub — `Domains.PubSub.MCP` · stream/subscribe

Paths: `/tobor/{org}/pubsub/{channel}/pointer.json`, `…/messages/{ts}-{seq}.json` (ring buffer)

| Tool | File op |
|---|---|
| `PubSub.Tools.Publish` | create `messages/{ts}-{seq}.json` |
| `FetchChannel` | readdir `{channel}/messages/` |
| `FetchAll` | readdir `/pubsub` |
| `Follow` / `Unfollow` | native `vfs/subscribe`/`unsubscribe` over `{channel}` |
| `PubSub.Tools.Ack` | consume `pointer.json` (advance pointer / remove unread marker) |

Class: **stream/subscribe** — a channel *is* a watched directory. Ring-buffer retention: server
prunes beyond `max-N` messages (emits `remove` events; mirrors cleanly). Read-write (publish
gated by ToolGuard).

### 2.12 Memory — `Domains.Memory.MCP` · journal + semantic query

Paths: `/tobor/{org}/memory/agents/{call-sign}.json`, `/tobor/{org}/memory/{agent}/journal/{id}.json`,
`…/{id}.links.json`, `…/_query` (control)

| Tool | File op |
|---|---|
| `AgentRegister` / `AgentList` | create / readdir `agents/` |
| `Remember` | create `journal/{id}.json` (content + context + reflection + mood) |
| `Memory.Tools.Reinforce` / `Denforce` | write `journal/{id}.json` weight field |
| `MemoryAssociations` | read `{id}.links.json` |
| `Recall` / `RecallByEmotion` | **control/query-file**: write `{"query": …}` / mood vector to `_query` → read ranked results (semantic search is not readdir) |

Class: **append-log** journal + **control/query** for recall. The `_query` node is the canonical
example of the write-request/read-result pattern. Read-write (journal), query nodes read-only
after write-consume.

### 2.13 Personas — `Domains.Personas.MCP` · entity-dir + journal

Paths: `/tobor/{org}/personas/{slug}/record.json`, `…/journal/{ts}-{id}.md`,
`…/knowledge/{id}.json`

| Tool | File op |
|---|---|
| `PersonaList` | readdir `/personas` |
| `PersonaGet` / `PersonaCreate` / `PersonaUpdate` / `PersonaDelete` | read / create / write / remove `record.json` (+dir) |
| `JournalAdd` / `JournalList` | create / readdir `journal/` |
| `KnowledgeAdd` / `KnowledgeGet` / `KnowledgeUpdate` / `KnowledgeList` / `KnowledgeDelete` | create / read / write / readdir / unlink `knowledge/` |

Class: **entity-dir** with natural-file journal entries. Read-write.

### 2.14 Customers — `Domains.Customers.MCP` · entity-dir

Paths: `/tobor/{org}/customers/personas/{id}/record.json`, `/tobor/{org}/customers/segments/{id}/record.json`,
`…/personas/{id}/tickets.json`

| Tool | File op |
|---|---|
| `Customers.Tools.PersonaList/Get/Create/Update` | readdir / read / create / write |
| `PersonaDraft` | `/etc/dev` control write (generation op) |
| `PersonaLinkTicket` / `PersonaUnlinkTicket` | write `tickets.json` |
| `SegmentList/Get/Create/Update` | readdir / read / create / write under `segments/` |

Class: **entity-dir**. Read-write.

### 2.15 Market — `Domains.Market.MCP` · entity-dir + jobs

Paths: `/tobor/{org}/market/competitors/{id}/record.json`, `…/keywords/{id}/record.json`,
`…/reports/{id}/record.json` + `…/report.md`

| Tool | File op |
|---|---|
| `CompetitorList/Get/Create/Update`, `KeywordList/Get/Create/Update`, `ReportList/Get/Create` | readdir / read / create / write per subtree |
| `KeywordResearch`, `ReportGenerate` | long-running → **job-dir convention** (§3.8) or `/etc/dev` sync control write for short ops |

Class: **entity-dir** + job-backed generation. Read-write.

### 2.16 Campaigns — `Domains.Campaigns.MCP` · entity-dir + jobs + natural landing content

Paths: `/tobor/{org}/campaigns/campaigns/{id}/record.json`, `…/ad-groups/{id}/record.json`,
`…/ad-copy/{id}/record.json`, `…/landing-pages/{id}/{record.json, content.html}`,
`…/domain-names/{id}/record.json`

| Tool | File op |
|---|---|
| `Campaign*/AdGroup*/DomainName*` CRUD | entity-dir ops per subtree |
| `AdCopyCreate/Get/List` | entity-dir ops |
| `AdCopyGenerate` | job-dir / control write |
| `AdCopyApprove` / `AdCopyReject` | write `{id}/verdict` (one-line control-ish file, ToolGuard-checked) |
| `LandingPage*` CRUD | entity-dir ops |
| `LandingPageGenerate` | job-dir; result lands as **natural file** `content.html` |

Class: **entity-dir**; landing-page content is the one natural-file payoff (edit `content.html`
locally, daemon pushes the update). Read-write.

### 2.17 Review — `Domains.Review.MCP` · natural overlays

Paths: `/tobor/{org}/review/{review-id}/record.json`, `…/overlay.md`, `…/comments/{ts}-{id}.json`,
`…/attached.json`

| Tool | File op |
|---|---|
| `ReviewCreate` / `ReviewGet` | create / read `record.json` |
| `ReviewOverlay` | write `overlay.md` (the reviewable diff/annotation doc — natural-file) |
| `ReviewComment` | create `comments/…` |
| `ReviewAttach` | write `attached.json` (artifact links) |
| `ReviewComplete` | control write (state transition) |
| `ReviewCompile` | control write; compiled output buffered-read (or job-dir if slow) |

Class: **natural-file** overlays + entity shell. Read-write.

### 2.18 Assets — `Domains.Assets.MCP` · entity-dir + lifecycle + blobs

Paths: `/tobor/{org}/assets/{asset}/record.json`, `…/outputs/{output-id}/record.json`,
`…/history.log/`, `…/actions/` (control)

| Tool | File op |
|---|---|
| `AssetList` / `AssetGet` / `AssetCreate` / `AssetUpdate` | entity-dir ops |
| `AssetGenerate` / `AssetRegenerate` | job-dir / control write (media generation) |
| `AssetSetActive` / `AssetPublish` / `AssetArchive` / `AssetRequestReview` | control writes (lifecycle transitions — never plain field edits) |
| `AssetOutputs` | readdir `outputs/` |
| `AssetOutputAccept` / `AssetOutputReject` | write `outputs/{id}/verdict` |
| `AssetHistory` | readdir `history.log/` |

Class: **entity-dir** + lifecycle controls; the media binaries themselves are **[feature ask B1]**
— metadata mounts now, blobs later. Read-write via controls only (content files read-only).

### 2.19 GitHub — `Domains.Github.MCP` · read-mostly mirror + controls

Paths: `/tobor/{org}/github/{owner}/{repo}/branches/{name}.json`, `…/pulls/{n}.json`,
`…/pulls/{n}.comments/`, `…/issues/{n}.json`, `…/issues/{n}.comments/`

| Tool | File op |
|---|---|
| `RepoList` | readdir `/github` (org-linked repos) |
| `BranchList` / `BranchGet` | readdir / read `branches/` |
| `BranchCreate` | create `branches/{name}.json` |
| `PullList` / `PullGet` | readdir / read `pulls/` |
| `PullCreate` | create `pulls/{n}.json` (server assigns `n`) |
| `PullMerge` | **control write only** (destructive; confirm-gated) |
| `PullComment` | create `pulls/{n}.comments/{ts}.json` |
| `IssueList` / `IssueGet` / `IssueCreate` / `IssueComment` | mirror pattern as pulls |

Class: **entity-mirror** (upstream is GitHub; local tree is a projected cache). Liveness: `ttl`
only unless a webhook→publish bridge exists (**L1b**, optional). Default: read; create/comment
where mapped; `PullMerge` never a file write.

### 2.20 Markdown — `Domains.Markdown.MCP` · control/query

Paths: `/tobor/{org}/markdown/convert/` (query dir: write `request.json`, read `result.md`)

| Tool | File op |
|---|---|
| `Markdown.Tools.Convert` | write `convert/request.json` `{"url"|"html", …}` → read `convert/result.md` |
| `Markdown.Tools.View` | same, with heading filter/collapse params |

Class: **control/query-file**, stateless and fast — sync write + buffered read suffices (no
job-dir needed). Read-only group otherwise. Note: requests are per-connection buffered (the
`Control.take_buffer` pattern) — each mount connection sees only its own results.

### 2.21 Browser — `Domains.Browser.MCP` · control/query + job-dirs

Paths: `/tobor/{org}/browser/session/{id}/url` (write-to-navigate), `…/state.json`,
`…/screenshots/{ts}.png`, `…/jobs/{job-id}/{request.json, status, result}`

| Tool | File op |
|---|---|
| `Browser.Tools.Navigate` | write `url` (one-line) — the purest write-to-command in the tree |
| `Browser.Tools.GetState` | read `state.json` |
| `Screenshot` | control write → read `screenshots/{ts}.png` (**B1** binary caveat) |
| `Click` / `Fill` | job-dir request (selector/text) → poll `status` → read `result` |
| `RecordStart` / `RecordStop` | control flags; recordings under `recordings/` (**B1**) |

Class: **control/query-file** with async job-dirs for anything that can outlat a sync round-trip.
Gated hard: the Playwright controller runs on the *user's machine* — only principals whose key
carries the browser grant see this subtree at all (group gate), and every op is ToolGuard-checked.
Read-only subtree; all interaction via control files.

### 2.22 Clients (internal) — `MCP.Clients` · entity-dir

Paths: `/tobor/{org}/clients/{client-id}/record.json`. Same CRUD mapping as projects; exposed only
to root-plane/admin principals (the group is not in the public customizable catalog). Read-write
for admins.

### 2.23 Root plane — discovery, NPL, keys

- **Discovery tools** map to `_meta` + `/etc/dev`: `ToolSummary`/`ToolSearch`/`ToolDefinition`/
  `ToolHelp` are about the *tool* plane — they stay MCP-native; the file plane's equivalent is
  `_meta/toolsets.json` (this principal's effective narrowed set) + the `/etc/dev/tools/` listing
  (which *is* the visible tool inventory — see caveat §3.6). `ToolCall` → `/etc/dev/tools/<tool>`
  write-to-invoke, exactly.
- **Group `Overview` tools** → read `/tobor/{org}/{group}/overview.md` (rendered from each group's
  Overview tool — every group has one).
- **NPLLoad / NPLSpec** → natural files under `/tobor/_npl/`: `conventions/{section}.yaml`
  (the `conventions/*.yaml` source of truth, read-only) and `spec.md` (rendered full spec).
  NPL syntax is files; this is the most literal mapping in the catalog and costs almost nothing.
- **Keys (`MCP.Keys.Tools.KeyCreate`, revoke family)** → `/etc/dev` control writes only.
  **Key revocation is never file-exposed** — no path in the tree maps to it (§3.5).

---

## 3. Cross-cutting decisions

### 3.1 Read-only vs read-write defaults

Read-only by default: `unicode`, `github` (mirror), `markdown` (query), `_npl`, `_meta`.
Read-write: everything else, with *content* vs *control* split — lifecycle transitions
(archive/publish/merge/revoke), generation ops (`*Generate`, `PersonaDraft`, `KeywordResearch`),
and bulk destructive ops (`Clear`) are **always** control-file or `/etc/dev` operations, never
plain content edits. This keeps ToolGuard/PDP enforcement points uniform and makes
`vfs_readonly: true` a true panic button.

### 3.2 Pagination over readdir

`list/3` is cursor-paginated natively and the daemon's `walk` honors `nextCursor`, so
protocol-level pagination is solved. The real constraint is **materialization volume**: the daemon
snapshots everything visible. Mitigations, in order: (1) scope-narrowed keys (§1.3) — the `pm-dev`
principal never sees `market/`; (2) **[D1]** daemon `--include/--exclude/--max-files`; (3) for the
two monster collections (tickets, chat history, notifications), top-level dirs list a bounded
*window* (active/recent, e.g. 500 entries) plus `_all/` subtrees that carry the full cursor-paginated
set for consumers that deliberately opt in — the window keeps default syncs bounded while `mcp_fs_search`
and `vfs/search` still reach everything server-side.

### 3.3 Binary content

The wire is JSON text frames; `vfs_read` returns raw content — non-UTF-8 payloads break encoding
today. Decisions: (1) **metadata now** — assets/artifacts/browser recordings mount as `record.json`
+ out-refs (URLs to CDN/media endpoints), fully functional without binaries; (2) wiki/asset
attachments that are text (svg, csv, md) mount directly; (3) true binary pass-through is
**[feature ask B1]**: an `encoding: "base64"` convention (xattr `{"encoding": "base64"}` +
daemon decode) or a dedicated blob op — owner's call, §6 Q3. Until then, no image/PDF bytes
cross the VFS.

### 3.4 Consistent snapshots for entity-dirs

The rule that makes entity-dirs safe: **`record.json` is the only canonical write target**; it is
one file, one read, one version. Field-file projections (tickets `fields/`, message meta) are
documented as read-mostly conveniences; when writable, they are read-modify-write merges into the
canonical doc with last-write-wins, and the daemon's conflict path (stat-then-push + `.conflict-*`
save-aside) is the UX for lost races. There is no server-side write CAS today (`write/3` carries no
expected version — §0.1); the race window is the daemon's debounce, not zero
(**[feature ask W1]**: optional `expected_version` on `vfs_write` for true optimistic concurrency).

### 3.5 What must NOT be file-exposed

A file write should never be able to do something a shell one-liner shouldn't do casually.
Explicitly **not mapped to any path**:

- `Key_Revoke` / key lifecycle beyond create (control-only, `/etc/dev/tools/…`, `destructive_hint`
  fail-closed per §0.2);
- org/project/space **deletes with cascades** (force-deletes go through `/etc/dev` control writes
  where the tool exists; plain `remove/2` only removes what `ENOTEMPTY`-guards make safe);
- `PullMerge`, `AssetPublish/Archive`, `ReviewComplete`, `NotificationClear`, session archive —
  state transitions ride control writes, never content edits;
- ticket/campaign deletion (absent from the tool surface — stays absent);
- everything under `/etc/dev/config/` except documented toggles.

### 3.6 The discovery plane and `/etc/dev`

`/etc/dev` (composed by `Noizu.MCP.VFS.Control`) is the meta plane, unchanged:
`tools/` (write-to-invoke), `runtime/`, `cache/`, `config/`. NPL additions live in
`/tobor/{org}/_meta/`: `whoami.json` (resolved claims + effective group set),
`toolsets.json` (EffectiveToolset output for this principal — the *narrowed plane made visible*),
`groups/{group}.json` descriptors. Per-group `overview.md` nodes carry the Overview tools.

**Known gap to flag**: `Control.tool_specs/1` reads the server's *static* `__mcp__(:tools)`
registrations, not the per-principal filtered listing NPL computes in `handle_list_tools/2`
(EffectiveToolset). Under a narrowed key, `/etc/dev/tools/` would over-expose tool nodes (invocation
still passes ToolGuard — writes fail `:eacces` — but the *listing* lies). **[feature ask C1]**:
let `VFS.Control` consult a server-provided visibility hook (NPL supplies its EffectiveToolset
filter) so the control tree agrees with the MCP surface.

### 3.7 Multi-org

**Recommendation: one mount per org** — one `mcp-mount` process per org-scoped key. Isolation is
total (a compromised mount dir sees one org), manifests stay small, and `--include` filters stay
simple. The **super-mount** (`/tobor/` listing all visible orgs via `readdir /tobor`, `orgs/`
cross-org index) works with zero schema changes — paths already carry `{org}` — and is the right
default for platform-admin principals. Both modes are the same backend; only the credential's org
visibility differs.

### 3.8 Long-running ops: the job-dir convention

Browser actions, media generation, report/research/compile ops don't fit sync control writes.
Convention (pure VFS, no new primitives): `…/jobs/{job-id}/` with `request.json` (create),
`status` (read; `queued|running|done|error`), `result` (read when done). Server-side job runner
writes status/result through `Features.VFS` so pubsub events announce completion — a consumer
subscribes to the jobs dir and watches `status` files appear/change. Cost: a small
`NoizuPromptLingua.MCP.VFS.Jobs` GenServer + per-group runner shims (**wave 4**).

### 3.9 Rate & size limits

16 MB max frame (`VFSSocket` default) is the practical per-file ceiling; WS frames should adopt the
same cap explicitly. Design ceiling: files ≤ 16 MB; larger content = blob-ref (**B1**) or chunked
files. Daemon write-back debounce (250 ms) is the effective rate limit per path; pubsub coalescing
(50 ms) bounds event storms. `search/3` and `list/3` cursors keep result sets bounded. Recommended
server-side guards: per-connection op rate limit on control writes (ToolGuard already meters the
domain side) and a max-tree-size refuse on snapshot (`ENOSPC`-style `Noizu.MCP.Error`) — **[D1]**
companion.

---

## 4. Implementation phasing

Each group backend is `use Noizu.MCP.VFS` + a context module it already trusts; every backend is
individually exercisable against the conformance battery pattern (`use Noizu.MCP.VFS.Conformance`,
as referenced by the behaviour docs). Effort: S ≈ days, M ≈ a week, L ≈ multi-week including the
jobs/controls work.

**Wave 0 — substrate (L).** `MCP.VFS.Router` (Control-composed, prefix dispatch, claims →
effective group set, `_meta`, `overview.md`), VFS-capable server + `VFSWS` transport on
`fs.{host}`, auth wiring (`dual_token_verifier`), conformance harness per backend.
*Unblocks everything; no group content yet.*

**Wave 1 — natural-file groups (M+S each).** `wiki` (L — the flagship, comments/attachments/
reactions), `artifacts` (M — revisions), `instructions` (S), `unicode` (S), `_npl` (S).
Delivers the demo: edit a wiki page in any editor, daemon syncs.

**Wave 2 — entity-dirs (M each).** `organizations`, `projects`, `sessions`, `tickets` (L —
largest surface: comments/queues/types/fields/links), `customers`, `market`, `campaigns`.
Pattern is uniform (`record.json` CRUD + projections); the router gains the entity-dir support
helpers (key validation, windowed listings, `record.json` merge helpers).

**Wave 3 — logs & streams (M each).** `chat` (L — richest append-log: rooms/threads/members/
reactions/scheduled), `notifications` (M — the fswatch demo; needs per-recipient path filtering),
`pubsub` (M — ring-buffer retention), `memory` (M — journal + `_query` control node),
personas journal/knowledge (S, rides wave-2 personas CRUD).

**Wave 4 — control/query + blobs + mirror (M–L).** `browser` (L — job-dirs, session state),
`markdown` (S — sync query files), `github` (M — mirror + controls), `assets`/`artifacts` binary
pass-through (gated on **B1**), `Jobs` runner (M), review compile (S).

Daemon work (**D1** filters/caps) lands alongside wave 1; **C1** (control-tree visibility) and
**L1** (domain publish hooks) are lib/app asks that can land independently but before wave 3 is
considered "live" rather than "ttl".

---

## 5. Open questions for the owner

1. **Endpoint topology** — single `fs.{host}` VFS server with the composed Router (recommended),
   or a VFS surface on every group subdomain? Single keeps authz, caching and mounting coherent;
   per-group multiplies credentials and daemon processes for no gain we can name.
2. **Append primitive** — standardize per-entry create-new files (this doc's assumption, works
   today) or add `vfs/append` to the lib for true log semantics (`messages.log`, `feed.log` as
   single files)? Per-entry is strictly more daemon-friendly; append mainly helps non-mount MCP
   clients.
3. **Binary contract [B1]** — base64 encoding convention (xattr + daemon decode), a dedicated
   `vfs/blob` operation, or content-addressed blob refs with out-of-band fetch? Determines whether
   assets/artifacts/browser recordings ever mount as real bytes.
4. **Per-principal depth** — beyond group gating, do we filter content within a group by
   principal (only watched tickets, only own notifications) inside the backends? If yes, the
   identity-blind `VFS.Cache` becomes a correctness issue, not just a leak — per-principal keying
   or the `__mcp_vfs__(:cacheable)` opt-out becomes a wave-0 lib ask.
5. **Liveness investment** — is `ttl` (60 s) acceptable for out-of-band mutations (web UI edits,
   plain `tools/call`), or do we require domain write paths to call `VFSPubSub.publish/5`
   (**L1**) for the groups agents mount concurrently with the UI (tickets, chat, notifications)?
   L1 is cheap per group but touches every domain's write path.

## 6. VFS feature asks (gaps found while grounding)

| ID | Gap | Where it bites | Ask |
|---|---|---|---|
| D1 | Daemon has no include/exclude/caps — it materializes the entire visible tree | monster orgs, `content`-profile mounts | `--include/--exclude/--max-files` in `McpMount.Mounter` walk + event filter |
| B1 | Wire is UTF-8 JSON text; `vfs_read` has no encoding notion; no blob op | assets, artifacts (`ArtifactGetBinary`), browser screenshots/recordings, attachments | `encoding: "base64"` convention or `vfs/blob` fetch |
| W1 | `write/3` takes no expected version — no server-side CAS (daemon does stat-then-push, TOCTOU window) | every concurrent-edit group | optional `expected_version` on `vfs_write` → `:eexist`/conflict errno on mismatch |
| C1 | `VFS.Control` lists *static* registrations, not the server's dynamic per-principal tool visibility | `/etc/dev/tools/` over-exposes under narrowed keys | server-supplied visibility hook in `Noizu.MCP.VFS.Control` |
| L1 | Only `Features.VFS` write/create/remove publish events; out-of-band domain writes are TTL-invisible | live mounts over UI-active groups | domain-side `VFSPubSub.publish/5` hooks (NPL-side, listed here for completeness) |
| A1 | No append mode (`write` = whole-file overwrite) | log-shaped groups (chat, notifications, memory journal) | per-entry files now (design choice); `vfs/append` as a later lib op if needed |
| P1 | Cache keys are `{backend, kind, path}` — identity-blind; per-principal backends cross-contaminate | §1.3 per-principal views, §6 Q4 | per-identity key suffix or `__mcp_vfs__(:cacheable)` opt-out (already "flagged upstream" in `Control`'s moduledoc) |
| J1 | No async-job primitive; control writes are sync + buffered-once per connection | browser, generation ops | job-dir convention (pure VFS, §3.8) — lib work optional (job helper in `Control`-style composition) |
| R1 | No rename/move/copy; no symlink concept | slug renames, `current` pointers in artifacts/instructions | pointer-file convention (chosen); `vfs/rename` only if a real need emerges |
| S1 | `vfs/subscribe` delivers metadata-only events with no ACL re-check on the *event* (path names leak to any watch holder; re-reads are authz-checked) | cross-principal mounts | optional per-watch visibility filter — acceptable to defer; watches are same-connection and group-gated at auth |

---

## Appendix A — group → class → default → wave summary

| Group | Module | Class | Default | Wave |
|---|---|---|---|---|
| wiki | `Domains.Wiki.MCP` | natural-file | rw | 1 |
| artifacts | `Domains.Artifacts.MCP` | natural-file + revisions | rw | 1 (+B1 in 4) |
| instructions | `Domains.Instructions.MCP` | natural-file + pointer | rw | 1 |
| unicode | `Domains.UnicodeCodex.MCP` | natural reference + query | ro | 1 |
| organizations | `MCP.Organizations` | entity-dir | rw (admins) | 2 |
| projects | `MCP.Projects` | entity-dir | rw | 2 |
| sessions | `MCP.Sessions` | entity-dir + log | rw | 2 |
| tickets | `Domains.Tickets.MCP` | entity-dir | rw | 2 |
| customers | `Domains.Customers.MCP` | entity-dir | rw | 2 |
| market | `Domains.Market.MCP` | entity-dir + jobs | rw | 2 (+jobs 4) |
| campaigns | `Domains.Campaigns.MCP` | entity-dir + jobs + natural | rw | 2 (+jobs 4) |
| clients | `MCP.Clients` | entity-dir | rw (admins) | 2 |
| chat | `Domains.Chat.MCP` | append-log | rw | 3 |
| notifications | `Domains.Notifications.MCP` | append-log + stream | rw | 3 |
| pubsub | `Domains.PubSub.MCP` | stream/subscribe | rw | 3 |
| memory | `Domains.Memory.MCP` | journal + query | rw | 3 |
| personas | `Domains.Personas.MCP` | entity-dir + journal | rw | 2/3 |
| review | `Domains.Review.MCP` | natural overlays | rw | 2 |
| assets | `Domains.Assets.MCP` | entity-dir + lifecycle | rw via controls | 2 (+B1 4) |
| github | `Domains.Github.MCP` | mirror + controls | ro/create | 4 |
| markdown | `Domains.Markdown.MCP` | control/query | ro | 4 |
| browser | `Domains.Browser.MCP` | control/query + jobs | ro + gated | 4 |
| root plane | `NoizuPromptLingua.MCP` (root) | meta + natural (`_npl`) | ro + controls | 0/1 |
