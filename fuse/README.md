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
make fuse-build        # from repo root; host binary at bin/mcp-fuse
make fuse-cross        # linux/amd64 linux/arm64 darwin/arm64 windows/amd64 windows/arm64
# or directly:
cd fuse && go build -o ../bin/mcp-fuse .
```

Prebuilt companions are attached to GitHub Releases as
`mcp-fuse-{os}-{arch}[.exe]` (linux amd64/arm64, darwin arm64, windows
amd64/arm64). The `noizu_mcp` Hex archive remains Elixir-only; the Go
binary is never packed into Hex.

Windows release binaries are built with `CGO_ENABLED=0` (cgofuse **nocgo**):
WinFsp is demand-loaded at mount time, so compiling does not require WinFsp
headers. The `windows-11-arm` GitHub-hosted runner is used for arm64; if that
job fails to schedule, the release still ships windows amd64.

## Mount prerequisites

* **macOS** — [macFUSE](https://osxfuse.github.io/) or
  [fuse-t](https://www.fuse-t.app/) must be installed.
* **Linux** — FUSE 3 (`fusermount3`) must be available.
* **Windows** — [WinFsp](https://winfsp.dev/) must be installed at runtime.
  The binary does not link WinFsp at compile time (`CGO_ENABLED=0`); the
  driver is loaded when `mcp-fuse` mounts. Use `--server unix:/path` (Windows
  10+ AF_UNIX). Remote NPL browse over `wss://` should use `mcp-mount`
  (no kernel driver), not `mcp-fuse`.

## Usage

```bash
export MCP_VFS_TOKEN=<key>     # or pass --apikey

# read-only
bin/mcp-fuse --server unix:/run/mcp/vfs.sock --mount /Volumes/mcp --ro

# read-write (server node.writable still gates per-file writes)
bin/mcp-fuse --server unix:/run/mcp/vfs.sock --mount /Volumes/mcp

# unmount: Ctrl-C (SIGINT/SIGTERM trigger graceful unmount), or
fusermount -u /Volumes/mcp        # macOS: diskutil unmount /Volumes/mcp
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
