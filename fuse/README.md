# mcp-fuse

Companion Go FUSE daemon for the `Noizu.MCP` VFS: mounts a remote MCP VFS
tree (served over the unix-socket JSON-RPC transport) as a local filesystem.

The wire protocol is owned by the Elixir library — see the moduledoc of
`lib/noizu/mcp/transport/vfs_client.ex` in this repo for the canonical
contract (framing, handshake, methods, errno codes).

## Build

Requirements: Go 1.22+. Repository development and CI pin Go 1.25.8 in
`.tool-versions` and `.github/workflows/fuse.yml`.

```bash
make fuse-build        # from repo root; binary at bin/mcp-fuse
make fuse-build-linux  # cross-compiled: bin/mcp-fuse-linux-{amd64,arm64}
# or directly:
cd fuse && go build -o ../bin/mcp-fuse .
```

`mcp-fuse` is a standalone source-built companion executable. It is
deliberately not included in the `noizu_mcp` Hex archive, which remains an
Elixir-only package; build or distribute the Go binary separately.

## Mount prerequisites

* **macOS** — [macFUSE](https://osxfuse.github.io/) or
  [fuse-t](https://www.fuse-t.app/) must be installed.
* **Linux** — FUSE 3 runtime must be available. On Debian/Ubuntu:
  `sudo apt-get install fuse3`; on Fedora/RHEL: `sudo dnf install fuse3`.
  `fusermount3` must be on `PATH`, and unprivileged mounts require either
  `user_allow_other`-free default policy (fine for single-user mounts) or
  membership in the `fuse` group on some distributions. Verify with
  `fusermount3 --version`.

The daemon itself is platform-neutral Go (pure-Go FUSE via
`hanwen/go-fuse`; no CGO), so Linux binaries are plain cross-compiles —
`make fuse-build-linux` produces statically linked `linux/amd64` and
`linux/arm64` binaries. CI builds and uploads both as artifacts
(`mcp-fuse-linux`) on every `fuse/**` change.

## Usage

```bash
export MCP_VFS_TOKEN=<key>     # or pass --apikey

# read-only
bin/mcp-fuse --server unix:/run/mcp/vfs.sock --mount /Volumes/mcp --ro

# read-write (server node.writable still gates per-file writes)
bin/mcp-fuse --server unix:/run/mcp/vfs.sock --mount /Volumes/mcp

# unmount: Ctrl-C (SIGINT/SIGTERM trigger graceful unmount), or
fusermount3 -u /mnt/mcp            # Linux
diskutil unmount /Volumes/mcp      # macOS
```

### Flags

| Flag | Default | Meaning |
|------|---------|---------|
| `--server` | (required) | `unix:/path/to.sock` |
| `--mount` | (required) | mountpoint path |
| `--apikey` | `$MCP_VFS_TOKEN` | auth key for `vfs/auth` |
| `--ro` | off | read-only mount (writes → `EROFS`) |
| `--cache-ttl-attr` | `1s` | attribute cache TTL |
| `--cache-ttl-entry` | `2s` | directory-entry cache TTL |
| `--rpc-timeout` | `5s` | per-request timeout (→ `ESTALE`) |
| `--max-file-size` | `8388608` | maximum buffered file size (→ `EFBIG`) |
| `--debug` | off | verbose FUSE + RPC logging |

## Behaviour

* **Caching** — attributes 1s TTL, directory listings 2s TTL, file content
  keyed by the server's node `version`, so server-side writes invalidate
  stale content naturally. Writes through the mount update the cache from
  the write ack.
* **Reads** — `Getattr`/`Lookup` → `vfs/stat`, `Readdir` loops the
  `vfs/list` cursor until the directory is exhausted, `Read` → `vfs/read`.
* **Writes** — buffered per open handle and flushed on close/`fsync` as a
  full-content `vfs/write` (read-modify-write, last-writer-wins). Version
  and authorization failures surface through the server's errno mapping.
  `echo x > file`
  and appends work; `O_TRUNC` skips the read-back.
* **Not supported** — `Mkdir`/`Rmdir`/`Rename`/symlinks and metadata changes
  (`chmod`, `chown`, timestamps) return
  `ENOSYS`/`EROFS` (the VFS protocol has no rename); `vfs/create` only
  backs file creation in this mount (directory creation is not implemented);
  `vfs/search` and
  `vfs/xattr` are not exposed through the mount.
* **Errno mapping** — server `data.errno_atom` wins, then the JSON-RPC
  code (`-32002`→`ENOENT`, `-32040`→`EACCES`, `-32041`→`EEXIST`,
  `-32042`→`EROFS`, `-32043`→`EISDIR`, `-32044`→`ENOTDIR`,
  `-32045`→`ENOTEMPTY`, `-32046`→`ENOSYS`), else `EIO`.
* **Resilience** — one mutex-serialized connection per mount; transport
  failures trigger reconnect + re-auth with backoff; timeouts surface
  `ESTALE`.

## Manual smoke test

```bash
fuse/fusetest.sh /path/to/vfs.sock /Volumes/mcp <key>
```

## Tests

```bash
cd fuse && go test .     # fake in-process unix-socket VFS server
go test -race . && go vet . && gofmt -l .
```

On Linux with FUSE available, the opt-in kernel mount smoke is:

```bash
MCP_FUSE_MOUNT_TEST=1 go test -run TestMountedRootIntegration -v .
```

CI runs this automatically whenever the hosted runner exposes `/dev/fuse`;
otherwise it is skipped (GitHub-hosted Ubuntu runners currently do not).

## Linux notes

* **Kernel mounts** (`mcp-fuse`) — the same binary semantics as macOS; the
  kernel-side differences (fusermount3 unmount helper, `/dev/fuse`) are
  handled by `hanwen/go-fuse` + the OS FUSE 3 runtime. There is no
  Linux-specific code path in this daemon; `mount_linux_test.go` covers the
  kernel-mount smoke when `/dev/fuse` is present.
* **Boot persistence** — a minimal systemd unit (adjust paths/key):

  ```ini
  # /etc/systemd/system/mcp-fuse.service
  [Unit]
  Description=MCP VFS FUSE mount
  After=network-online.target

  [Service]
  Environment=MCP_VFS_TOKEN=<key>
  ExecStart=/usr/local/bin/mcp-fuse --server unix:/run/mcp/vfs.sock --mount /mnt/mcp
  ExecStop=/bin/fusermount3 -u /mnt/mcp
  Restart=on-failure

  [Install]
  WantedBy=multi-user.target
  ```

  (`systemctl daemon-reload && systemctl enable --now mcp-fuse`; the mount
  target directory must exist.) fstab helpers are not supported — the mount
  is driven by this daemon, not mount(8).
* **`mcp-mount` (escript)** — needs Erlang/Elixir installed; it is fully
  platform-neutral (userland sync, no kernel FUSE involved). The
  `file_system` watcher uses inotify on Linux, so write-back works without
  the macOS escript `mac_listener` caveat.
