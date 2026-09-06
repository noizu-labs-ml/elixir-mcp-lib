---
id: ADR-008
title: "A standalone Go FUSE companion with bounded, explicit filesystem semantics"
status: accepted
date: 2026-09-06
---

# ADR-008: Standalone Go FUSE companion

## Context

The Elixir VFS already exposes a length-framed JSON-RPC protocol over a local
unix socket. `daemon/mcp_mount` materializes that tree over WebSocket, but it is
not a kernel filesystem. A FUSE client provides ordinary local file access for
programs that cannot speak MCP.

FUSE also creates semantic obligations that the VFS protocol does not cover.
The wire API overwrites whole files and has no chmod, chown, timestamp, rename,
or symlink operation. Buffering unbounded full-file writes would permit a local
truncate or sparse write to exhaust the daemon before the server can reject it.

## Decision

- Add `fuse/mcp-fuse`, a Go/go-fuse v2 companion speaking the canonical
  `Noizu.MCP.Transport.VFSSocket` contract.
- Keep it a separately built source artifact. The `noizu_mcp` Hex archive
  remains Elixir-only; no prebuilt FUSE binary is published by this decision.
- Expose the remote root through the actual root `InodeEmbedder`, and preserve
  per-handle write/truncate call order. Successful `fsync` starts a new batch;
  later writes must not be discarded.
- Support full-file reads, create, unlink, write, `O_TRUNC`, and size changes.
  Unsupported metadata mutations return `EOPNOTSUPP`, never false success.
- Default buffered file size to 8 MiB (`--max-file-size` configurable) and
  reject over-limit growth with `EFBIG` before allocation. Independently cap
  JSON frame bodies at the VFSSocket default of 16 MiB.
- Pin repository/CI development to Go 1.25.8 while retaining `go 1.22` module
  compatibility. CI runs format, vet, unit, race, and Linux build checks. A
  kernel-mount smoke runs when Linux CI exposes `/dev/fuse`.

## Acceptance

Accepted by the maintainer on 2026-09-06. The maintainer also approved the
one-time sequencing exception for this pre-existing feature: ADR-008 and
PRD-12 may land with the implementation in PR #15 instead of through an
earlier docs-only PR.

## Consequences

Positive:

- Ordinary filesystem clients get predictable read/write/truncate behavior.
- Local callers cannot request unbounded daemon allocations through offsets or
  truncation.
- Hex consumers do not inherit a platform-specific binary payload.

Negative / risks:

- Writes remain full-content, last-writer-wins operations; large files are not
  a fit until the VFS protocol gains ranged I/O or streaming.
- Operators must install FUSE and build/distribute the companion separately.
- Hosted CI without `/dev/fuse` can compile and unit-test the boundary but
  cannot perform the kernel mount smoke; release validation needs a capable
  Linux runner or a documented manual run.

## Alternatives considered

- Extend `daemon/mcp_mount` into a FUSE implementation: rejected because its
  materialized-sync model and WebSocket lifecycle solve a different problem.
- Include binaries in Hex: rejected because Hex is the Elixir library release
  and FUSE artifacts are OS/architecture-specific.
- Report success for unsupported metadata operations: rejected because it
  misleads callers and can cause silent state divergence.

## References

- `lib/noizu/mcp/transport/vfs_client.ex`
- `lib/noizu/mcp/transport/vfs_socket.ex`
- `fuse/README.md`
- `project-management/PRDs/PRD-12-mcp-fuse-companion.md`
