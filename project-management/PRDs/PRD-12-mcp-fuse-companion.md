# PRD-12: Kernel FUSE companion readiness

**Series**: mcp-fuse companion

**Repo**: `Portfolio/Libs/ai/elixir-mcp` — `fuse/`, build/docs, and scoped CI

**Architecture source**: ADR-008 (**accepted 2026-09-06**)

**Date**: 2026-09-06
**Status**: Ready for review

## 1. Goal

Provide a reviewable standalone FUSE client for the unix-socket VFS without
changing the Elixir or Hex public surface, and prove that normal filesystem
write/truncate sequences do not silently lose data.

## 2. Requirements

- **FR-12.1 Root dispatch:** the `InodeEmbedder` passed to `fs.NewNodeFS`
  implements getattr, lookup, readdir, create, unlink, and setattr for `/`.
- **FR-12.2 Ordered handles:** writes and truncates are applied in call order.
  A successful flush clears its batch; a later write starts another flushable
  batch. Reads on the same handle include pending operations.
- **FR-12.3 Truncate:** `O_TRUNC` with no subsequent write persists an empty
  file. Handle-based and path-based size changes shrink or zero-extend.
- **FR-12.4 Honest support:** chmod, chown, timestamps, rename, links, and
  other unsupported mutations return an explicit unsupported/read-only errno.
- **FR-12.5 Bounds:** reject file growth above the configured maximum with
  `EFBIG` before allocation; reject JSON bodies above the transport frame cap.
- **FR-12.6 Cache:** create and unlink invalidate the containing directory
  listing while successful writes retain fresh attribute/content entries.
- **FR-12.7 Distribution:** pin the development Go version and document that
  the binary is built/distributed separately from the Elixir-only Hex archive.
- **FR-12.8 CI:** enforce gofmt, vet, unit tests, race tests, and Linux build.
  Attempt the kernel mount smoke whenever `/dev/fuse` is exposed.

## 3. Acceptance criteria

- **AC-12.1:** a root `Readdir`/`Lookup` test traverses the real root
  `InodeEmbedder`, not a detached child helper.
- **AC-12.2:** write → fsync → write → release produces both writes and two
  server write calls.
- **AC-12.3:** overlapping writes retain invocation order.
- **AC-12.4:** `O_RDONLY|O_TRUNC` still enforces read-only mount and node
  writability; denied opens issue no write RPC.
- **AC-12.5:** `O_TRUNC` without data writes empty content on release.
- **AC-12.6:** path and handle truncation update content and reported size;
  unsupported metadata returns `EOPNOTSUPP`.
- **AC-12.7:** oversized offset writes/truncates return `EFBIG` without the
  requested allocation.
- **AC-12.8:** `go test`, `go test -race`, `go vet`, gofmt, and Linux build pass.
- **AC-12.9:** on a FUSE-capable Linux host, the mounted root lists and reads a
  file served by the in-process unix-socket fixture.

## 4. Compatibility and rollback

The daemon is additive and outside the Hex file list. Removing `fuse/`, its
workflow, and its root Make target fully rolls it back without changing any
Elixir module or wire method. The 8 MiB default is operator-adjustable; the
16 MiB frame cap matches `VFSSocket`'s default.

## 5. Acceptance record

The maintainer accepted ADR-008 on 2026-09-06 and approved landing these
architecture documents with the pre-existing implementation in PR #15. The
PR's Linux CI ran `TestMountedRootIntegration` through `/dev/fuse` successfully,
recording AC-12.9. The architecture and mount-validation gates are satisfied.
