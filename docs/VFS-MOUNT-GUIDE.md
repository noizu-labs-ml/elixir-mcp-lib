# VFS Mount Guide — zero to a mounted `~/wiki`

**Status**: canonical newcomer walkthrough · 2026-10-13 · targets `develop`
**Scope**: the full path from a bare macOS machine to a live, read-write mount of a
Docmost wiki at `~/wiki`, using only this document. Deeper references are linked at the
bottom ([§8](#8-pointers)); nothing earlier is required reading.

---

## 1. What this is

`mcp-mount` projects a remote MCP-VFS tree — here: a Docmost wiki served by the
`docmost-mcp` MCP server — as **real local files** in a directory you choose, and keeps
both sides in sync over a WebSocket: server changes land in your files live, and your
local edits (250 ms debounce) push back to the server. `cat`, `grep`, `tail -f`, editors,
pipes, and cron all work on wiki content as ordinary files.

**It is not a kernel FUSE mount.** The files are ordinary files in an ordinary directory;
there is no kernel extension, no macOS approval prompt, and **no FUSE runtime to
install**. (If you came here expecting to install macFUSE — you don't need it for this
flow; see [§2](#2-prerequisites-macos).)

| Piece | What it does | Where it comes from |
|---|---|---|
| `noizu_mcp` (hex) | VFS substrate: backend behaviour + DSL, generation-stamped cache, WebSocket transport, `/etc/dev` control tree | [hex.pm/packages/noizu_mcp](https://hex.pm/packages/noizu_mcp) — a server-side dependency, nothing you install |
| `docmost-mcp` server | Serves the wiki as a VFS tree at `ws://127.0.0.1:4700/vfs` | Built from the `docmost-mcp` repo (sibling checkout); full server recipe: the [VFS-RUNBOOK](#7-pointers) §2–3 |
| `mcp-mount` client | Connects to the endpoint, snapshots the tree to `~/wiki`, syncs both ways | **Built from this repo** (`daemon/mcp_mount`) — it is **not on hex**; there is no `mix install` or download shortcut |

## 2. Prerequisites (macOS)

| # | Requirement | Get it | Why |
|---|---|---|---|
| a | **FUSE runtime** | **None. Do not install one.** | `mcp-mount` is the *no-driver path*: it materializes real files and needs no FUSE/WinFsp (`docs/MCP-VFS-MOUNTING.md` §6). macFUSE / FUSE-T belong to the separate `mcp-fuse` **kernel** companion (a different binary, over a local unix socket) — not to this flow. Consequences: no kernel-extension approval in System Settings, no reboot, nothing to verify here. |
| b | **Xcode Command Line Tools** | `xcode-select --install` (then `cc --version` to confirm) | `mix deps.get` compiles the `file_system` watcher's native `mac_listener` binary — a C compiler is required. (Documented nowhere else before this guide.) |
| c | **Elixir + Erlang/OTP** | mise or asdf — commands below | The repo root `.tool-versions` pins `elixir 1.20.1-otp-29` / `erlang 29.0.2`. The client floor is **Elixir ≥ 1.18** (`daemon/mcp_mount/README.md`), so the pinned versions or anything newer work. |
| d | **git + repo access** | `git clone git@github.com:noizu-labs-ml/elixir-mcp-lib.git` | `noizu-labs-ml` is org-scoped: if the clone fails with `permission denied (publickey)`, you need an org invite + your SSH key registered on GitHub. |
| e | **A running `docmost-mcp` server + tokens** | Operator side — see below | The mount has nothing to connect to without it. |

Erlang/Elixir via mise (or asdf — both read `.tool-versions`; run inside the repo checkout):

```sh
mise install                            # full pinned toolchain (.tool-versions)
mise install erlang@29.0.2 elixir@1.20.1-otp-29   # …or just the two you need
eval "$(mise activate zsh)"             # or per-command: mise exec -- <cmd>
```

```sh
asdf plugin add erlang && asdf plugin add elixir
asdf install                            # reads .tool-versions
```

Server + tokens (operator convention; full recipe in VFS-RUNBOOK §3):

```sh
umask 077
mkdir -p ~/.config/docmost-mcp
openssl rand -hex 32 > ~/.config/docmost-mcp/mount-token   # authorizes the WS mount only
# ~/.config/docmost-mcp/api-key is your Docmost instance API key (from the Docmost UI),
# NOT locally generated — store it there by convention and never print it.
```

The server then starts with `DOCMOST_MCP_MOUNT_TOKEN="$(cat ~/.config/docmost-mcp/mount-token)"`
and `DOCMOST_MCP_MOUNT_PORT=4700` (the listener binds `127.0.0.1` only and exists only while
a token is configured). Verify it is up: `lsof -iTCP:4700 -sTCP:LISTEN`. Writes need
`DOCMOST_MCP_WRITES=1` and directory deletes need `DOCMOST_MCP_VFS_RMDIR=1` at boot.

## 3. Get + build the client

```sh
git clone git@github.com:noizu-labs-ml/elixir-mcp-lib.git
cd elixir-mcp-lib
git checkout develop

cd daemon/mcp_mount
rm -rf /tmp/mcp-mount-build            # NEVER build from a stale MIX_BUILD_ROOT (see below)
MIX_BUILD_ROOT=/tmp/mcp-mount-build mix deps.get
MIX_BUILD_ROOT=/tmp/mcp-mount-build mix escript.build
```

`MIX_BUILD_ROOT` keeps `_build` out of the checkout (shared checkouts stay
collision-free); `deps/` still lands in `daemon/mcp_mount/deps/` — which the run recipe
in §4 needs anyway, because that is where `mac_listener` gets built.

**Build-root hygiene (hard rule):** the escript embeds the Elixir stdlib beams it was
built against, so a `MIX_BUILD_ROOT` left over from a different elixir/OTP or dependency
set produces a daemon that boots, materializes the snapshot, then dies on the **first
watcher event** with stdlib/protocol undefs (seen live 2026-10-13:
`String.Chars.List`, `Inspect.Opts`, `Exception.blame`). `rm -rf` the build root before
every rebuild, or unset `MIX_BUILD_ROOT` entirely. The escript sanity-probes the
embedded runtime at boot and refuses to mount with a plain rebuild hint
(exit 78) if the beams are inconsistent.

Success looks like:

```text
Generated escript mcp-mount
```

```sh
ls -la mcp-mount                                        # the escript exists, is executable
file deps/file_system/priv/mac_listener                 # a Mach-O binary — note its arch
```

The `file_system` dep compiles `mac_listener` during `mix deps.get` for **the
interpreter's arch** (see the Rosetta row in §6). First build takes a few minutes.

## 4. Mount it

```sh
export FILESYSTEM_FSMAC_EXECUTABLE_FILE="$PWD/deps/file_system/priv/mac_listener"

./mcp-mount \
  --url ws://127.0.0.1:4700/vfs \
  --token-file ~/.config/docmost-mcp/mount-token \
  --mount ~/wiki > /tmp/mcp-mount.log 2>&1 &
```

- `FILESYSTEM_FSMAC_EXECUTABLE_FILE` is **required for write-back on macOS**: an escript
  cannot embed `mac_listener`, and without this variable the mount silently degrades to
  **pull-only** (server→local sync works; local edits are never pushed).
- `--deletes` is optional — opt in to pushing local deletions (§5.3). Without it, a local
  `rm` is a local-only no-op.
- `--ro` instead gives a read-only mount (no watcher, never pushes; `--deletes` + `--ro`
  logs a warning and has no effect). Flags are strict: `--url`, `--token-file`, `--mount`,
  `--ro`, `--deletes` — anything else prints usage and exits 64.
- Token resolution: `--token-file PATH` first, then the legacy `--token TOKEN` (works, but
  logs a warning — the value is visible to `ps`), then `$MCP_MOUNT_TOKEN`, then the default
  file `~/.config/docmost-mcp/mount-token` (trimmed; missing/empty ⇒ exit 78 with a plain
  error). Passing both `--token` and `--token-file` is a usage error (exit 64).

**First-mount expectations:** no macOS permission dialogs — no kernel extension is
involved, and `~/wiki` is not a TCC-protected location. If you see an approval prompt, it
belongs to something else you installed (macFUSE for another tool, perhaps).

A healthy boot log (`/tmp/mcp-mount.log`):

```text
mcp-mount: ws://127.0.0.1:4700/vfs -> /Users/you/wiki
mcp-mount[mcp-mount]: connected (was authing)
mcp-mount[mcp-mount]: live (N files, ro=false)
```

If you instead see `watcher unavailable (mount stays pull-only)`, fix the env var and
restart (§6).

**Verify:**

```sh
ls ~/wiki                          # one directory per Docmost space + README.md (server-generated)
grep " live " /tmp/mcp-mount.log   # live (N files, ro=false) after the snapshot
```

**Caps.** The `vfs/auth` handshake result carries a `caps` list — a current `docmost-mcp`
server advertises `["move", "rmdir"]`. Caps gate optional operations: `move` lets a local
`mv` pair into one `vfs/move` RPC (§5.2); `rmdir` gates `--deletes` directory removals
(§5.3). The CLI does not print caps — observe them via behavior, or run a direct VFS
client against the endpoint. An older server with no caps degrades safely: moves/deletes
report unsupported and park instead of misbehaving.

**Process tree** while running (`ps -ef | grep -E 'mcp-mount|mac_listener'`):

```text
mcp-mount (escript → BEAM VM)
├── mac_listener        # file_system port program — the filesystem watcher (write-back)
└── erl_child_setup     # BEAM helper for port subprocesses
```

Unmount: `Ctrl-C` / kill the foreground process (or `pkill -f mcp-mount`). The files stay
on disk; the next mount diff-resyncs against `.mcp-mount/manifest.json`.

## 5. Everyday use

### 5.1 Writes toggle

The server's writes gate (`DOCMOST_MCP_WRITES`) can be flipped without a restart:
`~/wiki/etc/dev/config/writes` is the **one writable `/etc` node** — edit it to contain
`true` or `false` and the mount pushes it back as a `vfs/write`; the gate re-evaluates
immediately. Every other `/etc/**` path is read-only (local edits are a no-op; the
watcher never queues them).

### 5.2 Move

`mv ~/wiki/engineering/foo.md ~/wiki/engineering/bar.md` just works: when the server
advertises the `move` cap, the rename+edit is paired into a single `vfs/move` RPC and the
server retitles/re-parents the page, fanning out events so the local tree re-paths
without a full resync.

### 5.3 Deletes (`--deletes` mounts only)

All deletes are **soft deletes** — recoverable in Docmost's trash.

- **Files**: `rm` pushes `vfs/remove` after a short double-confirm window (an editor's
  atomic save — remove+recreate inside the window — aborts the delete).
- **Page directories** use a marker handshake. Author the marker **inside** the
  directory, then remove the directory:

  ```sh
  cat > ~/wiki/engineering/notes/.confirm-delete <<'EOF'
  {"confirm_delete": "/engineering/notes", "ts": "2026-10-13T12:00:00Z"}
  EOF
  rm ~/wiki/engineering/notes
  ```

  The marker must be **fresh (±5 minutes)**, must name the directory it sits in, and
  binds to the page the directory resolves to *now* — a rename or a new page claiming the
  path invalidates it. It is consumed on success, retained on failure (retry without
  re-authoring), and lives in server memory only — a server restart between authoring
  and `rm` drops it (`eperm`; re-author).
- **Refusals park** instead of retrying: `eperm` (missing/stale marker), `eacces`
  (server `DOCMOST_MCP_VFS_RMDIR` off or writes gate off), `enotempty` (remove child
  `.md` files first — deletes decompose bottom-up, no cascade). Spaces (root-level
  dirs) are never deletable via the mount.

### 5.4 Conflicts and parked paths

If the server moved ahead of your local edit, your version is saved aside as
`<path>.conflict-<ISO-timestamp>` and the server copy is re-pulled — reconcile by hand;
conflict files are never pushed. A path that keeps failing (or staying unconfirmed) is
attempted 4 times, then **parked** with a warning; it re-arms only when you edit the
file again. `.mcp-mount/` is local bookkeeping — never edit, never pushed.

### 5.5 Updating the client

The client is **not on hex** — updates are always git + rebuild + restart:

```sh
cd /path/to/elixir-mcp-lib && git pull origin develop
cd daemon/mcp_mount
rm -rf /tmp/mcp-mount-build      # never reuse a stale MIX_BUILD_ROOT (see build-root hygiene above)
MIX_BUILD_ROOT=/tmp/mcp-mount-build mix deps.get && MIX_BUILD_ROOT=/tmp/mcp-mount-build mix escript.build
pkill -f mcp-mount      # then re-run the §4 recipe (same manifest → fast diff resync)
```

A server restart bumps every version (boot-epoch stamping), so the first sync after one
re-pulls the full tree once — expected, not a bug.

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| You expected a macOS approval prompt / installed macFUSE for this | None is needed — `mcp-mount` is not kernel FUSE. Uninstalling macFUSE is optional; it is unrelated to this flow. (Only the `mcp-fuse` kernel companion uses it.) |
| Mount lists files but local edits never propagate | Pull-only degrade: `watcher unavailable (mount stays pull-only)` in the log. Set `FILESYSTEM_FSMAC_EXECUTABLE_FILE` (§4) and restart `mcp-mount`. |
| `deps/file_system/priv/mac_listener` missing after `mix deps.get` | The native watcher did not compile — usually no Xcode CLT (§2b). `xcode-select --install`, then re-run `mix deps.get`. |
| Arch mismatch (Rosetta) | `mac_listener` is built for the building interpreter's arch; `file` it and compare with `file $(which erl)`'s arch. If `mcp-mount` runs under Rosetta, rebuild the deps under an x86_64 toolchain so the watcher binary matches — a mismatching `mac_listener` fails to spawn and the mount degrades to pull-only. |
| Files/checkout vanish mid-session under `~/Work` | `~/Work` is an automount that can drop. Keep the repo clone and the mount point off it (`~/wiki` is safe); recover the mount with `sudo /usr/local/bin/fstab-remount` and restart `mcp-mount`. |
| Dir delete fails `eperm` though `--deletes` is on | Stale marker: `.confirm-delete` is ±5 minutes, must name the current dir, and dies with a server restart. Re-author it at the current path (§5.3). |
| `eacces` on deletes / writes | Server opt-ins: `DOCMOST_MCP_VFS_RMDIR=1` (dir deletes) and `DOCMOST_MCP_WRITES=1` (all mutations) — or flip the gate at runtime via `etc/dev/config/writes` (§5.1). |
| Port 4700 busy | `lsof -iTCP:4700 -sTCP:LISTEN` — a stale or second server holds it. Kill it or start the server on another `DOCMOST_MCP_MOUNT_PORT` and point `--url` at the same port. |
| HTTP 401 before any socket traffic | Wrong/missing mount token — the WS upgrade bearer check failed. Compare `~/.config/docmost-mcp/mount-token` with the server's `DOCMOST_MCP_MOUNT_TOKEN`. |
| Error `-32001` right after connect | The first frame must be `vfs/auth` with the same token; a mismatch closes the connection. Same check as above. |
| Optional demo server (`demo/vfs_demo_server`) won't compile — `yamerl` errors | `yamerl` is a **demo-server** dependency only; `mcp-mount` does not use it. After an OTP switch its cached build can go stale — wipe and recompile fresh: `rm -rf demo/vfs_demo_server/deps demo/vfs_demo_server/_build`, then `mix deps.get && mix compile` in that dir. |
| `mcp-mount` exits immediately, usage + exit 64 | Strict flags only: `--url --token-file --mount --ro --deletes` (legacy `--token` still accepted) — no `--transport`, no `--write`, no positional target. |
| `mcp-mount` exits with 78 and a "token file" message | The token file (`--token-file` or the default `~/.config/docmost-mcp/mount-token`) is missing or trims to empty — mint one (`openssl rand -hex 32 > ~/.config/docmost-mcp/mount-token`) and remount. |
| Docmost web edits don't show up in the mount | Live mounts see VFS events only; web-side changes surface at the next reconnect/resync. Restart `mcp-mount` to force a diff resync (and reconcile before writing — mount writes replace page content wholesale). |
| Full re-pull after a server restart | Expected: versions are boot-epoch-stamped; one full re-pull per server restart. |

## 7. Restarting the local stack (server + mount)

Server (docmost-mcp) and client (`mcp-mount`) are independent processes. Start the **server first**; the client retries its connection (~30 s) if the server is briefly down, so a client already running through a server restart heals itself. Secret values live in `~/.config/docmost-mcp/` (`api-key`, `mount-token`) and are only ever read via command substitution — never paste them into shells, logs, or transcripts.

### 7.1 Server (docmost-mcp)

The server reads **exactly three** env vars (`config/runtime.exs`): `DOCMOST_API_KEY`, `DOCMOST_MCP_MOUNT_TOKEN`, `DOCMOST_MCP_VFS_RMDIR`. Launch through the `tail -f /dev/null |` feeder — the stdio transport shuts the whole app down when stdin closes, so a bare `nohup` start dies seconds after boot:

```bash
T=~/.config/docmost-mcp
tail -f /dev/null | nohup sh -c 'cd /path/to/Projects/docmost-mcp && direnv exec . env DOCMOST_API_KEY="$(cat '"$T"'/api-key)" DOCMOST_MCP_MOUNT_TOKEN="$(cat '"$T"'/mount-token)" DOCMOST_MCP_VFS_RMDIR=1 mix run --no-halt' >> /tmp/docmost-mcp-server.log 2>&1 &
disown
```

Traps (each cost a failed start on 2026-10-13):

- **`direnv exec .` is load-bearing** — a bare asdf `mix` resolves whatever Erlang/OTP is globally selected (it picked OTP 29 and began recompiling the whole tree); the repo runs on the `.tool-versions` pin (elixir 1.18.4-otp-28).
- **Missing `DOCMOST_API_KEY`** ⇒ boot "succeeds" but every VFS snapshot/list GenServer crashes with `** (RuntimeError) DOCMOST_API_KEY is required`.
- Healthy boot line: `Running Noizu.MCP.Transport.VFSWS with Bandit ... at 127.0.0.1:4700 (http)`.
- A server restart bumps the boot epoch ⇒ the mount does **one full re-pull** (expected; §6).
- Stop: `ps -axo pid,ppid,command | grep "[m]ix run --no-halt"`, then `kill <beam-pid>` (the feeder shell can linger harmlessly; kill it too for tidiness).

### 7.2 Client (mcp-mount)

```bash
T=~/.config/docmost-mcp
cd /path/to/Projects/elixir-mcp/daemon/mcp_mount   # the checkout the escript was built from (§3)
FILESYSTEM_FSMAC_EXECUTABLE_FILE="$PWD/deps/file_system/priv/mac_listener" \
  nohup ./mcp-mount --url ws://127.0.0.1:4700/vfs \
    --token-file "$T/mount-token" --mount ~/wiki --deletes \
    >> /tmp/mcp-mount.log 2>&1 &
disown; echo $! > "$T/mount.pid"
```

Verify: the log shows `live (N files, ro=false)`; `ps ax | grep '[p]riv/mac_listener'` finds the watcher (absent ⇒ pull-only degrade, §6); `ls ~/wiki` lists the spaces.

- Build the escript from a **fresh `MIX_BUILD_ROOT`** (§3): a stale-beam escript boots normally, then dies on the first watcher event.
- The client reads the token from `~/.config/docmost-mcp/mount-token` (`--token-file`): the token **does not appear in `ps` output** — `mcp-mount` argv is no longer secret-bearing. The legacy `--token TOKEN` form still works for back-compat but logs a warning (`token passed via argv is visible to ps — use --token-file`).

## 8. Pointers

| Doc | Covers |
|---|---|
| [`MCP-VFS-MOUNTING.md`](MCP-VFS-MOUNTING.md) | Operator reference for `mcp-mount`: full option surface, mount commands, backend choices (DB-backed, directory-backed), the **kernel** `mcp-fuse` companion (Linux FUSE3, macFUSE/FUSE-T, WinFsp), and the resources/prompts content bridge |
| [`MCP-VFS-GROUP-MOUNTS.md`](MCP-VFS-GROUP-MOUNTS.md) | Design of record: how each MCP group exposes its content through the mounting stack |
| `daemon/mcp_mount/README.md` | Client internals: write-back safety rules, deletes state machine, `Conn` behaviour/transports |
| `Projects/docmost-mcp/docs/VFS-RUNBOOK.md` (monorepo sibling checkout) | Server-side runbook: env vars, token minting, starting the mount listener, `.meta` sharing/permissions, page CRUD, full troubleshooting matrix |
| [hex.pm/packages/noizu_mcp](https://hex.pm/packages/noizu_mcp) · [hexdocs.pm/noizu_mcp](https://hexdocs.pm/noizu_mcp/) | The server-side VFS substrate (`noizu_mcp` hex package) |
