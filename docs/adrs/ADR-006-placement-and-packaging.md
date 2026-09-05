---
id: ADR-006
title: "pg_mcp lives in pg/pg_mcp inside elixir-mcp; hex package stays pure Elixir; shipped by image layering"
status: proposed
date: 2026-09-05
---

# ADR-006: Repository placement, release trains and packaging

> Implements ADR-001/002. Normative build/CI detail in PRD-10.

## Context

elixir-mcp is a hex library (`noizu_mcp`, consumers pin `~> 0.1.x`–`0.3.x`) with one existing
non-Elixir subproject, the `mcp-mount` escript under `daemon/mcp_mount/`. `pg_mcp` is a Rust
extension with its own build (cargo pgrx), its own versioning (`pg_mcp--x.y.sql`), and a
deployment target that is a **custom Postgres image** (`noizu/timescaledb-ha-with-age`,
PG 17.9, TimescaleDB, Apache AGE) whose build source is not in this workspace. The cluster
runs plain Terraform Deployments, not an operator, so there is no ImageVolume/extension-image
mechanism to lean on.

## Decision

- **Placement:** `pg/pg_mcp/` (Cargo project) and `pg/docker/` inside this repo, following
  the `daemon/mcp_mount/` precedent. Rationale: the extension's contract (the `sql/*` methods,
  the projection of elixir-mcp's tool DSL) co-evolves with the library and its e2e tests
  reuse the library's fixtures. It is self-contained so it can be extracted to its own repo
  later without history surgery.
- **Hex package unchanged:** `mix.exs` `files:` excludes `pg/`; `noizu_mcp` remains pure
  Elixir with no Rust or NIF dependency. The `sql/*` feature (ADR-005) and the Engine
  (ADR-007, `lib/noizu/mcp/engine/`, `mix mcp.engine`) ship in `noizu_mcp` **0.4.0**; the
  extension has an independent semver starting at `0.1.0`.
- **Packaging:** CI runs `cargo pgrx package` for PG 16/17/18 and publishes artifacts; a
  Dockerfile in `pg/docker/` layers the `.so`, control and SQL files onto the production image,
  producing a `-mcp` tagged image that Terraform's `timescaledb` module then references.
  Local development uses a stock `postgres:17` image with the same layering.
- **Later distribution options** (not now): Wasm FDW build for hosts with `wrappers`;
  PGXN/Trunk publication.

## Consequences

Positive
- One PR series, one review surface, shared fixtures and CI.
- Consumers of the hex package are untouched; Rust is only needed by people building the
  extension.

Negative / risks
- The repo's CI matrix grows (Rust + Postgres containers); keep it in a separate workflow that
  triggers on `pg/**` paths.
- The base image's build source lives outside this workspace — an open question for PRD-10 is
  whether to layer onto the published image (proposed) or fold `pg_mcp` into that image's
  own build.

## Alternatives considered
- Separate repository now — cleaner ownership but slows the co-evolution during the first
  series; revisit once the `sql/*` contract is frozen.
- CloudNativePG ImageVolume extension images — not applicable; no operator in the cluster.
- Ship only via PGXN/Trunk — does not put the extension into the running cluster image.

## References
- `daemon/mcp_mount/` (precedent) · monorepo `terraform/kubernetes/modules/timescaledb/` · `docs/arch/deployment.md` (monorepo) · pgrx packaging docs
