# SPIKE — PRD-6 §7.5 go/no-go report

**Date**: 2026-09-05 · **Runner**: `pg/pg_mcp/spike/run.sh` · **Verdict: GO**

> **Status note (PRD-7.E):** the 38/38 probe count below was PRD-6's scope.
> The runner now executes **158 probes** across every test schema — PRD-7's
> catalog (A), read-through (B), tool_calls (C) and import (D) tracks plus
> the PRD-7.E integration battery in `src/e2e.rs` (anti-patterns §7.4,
> performance §7.5, AC-7.8/7.10/7.11, engine-convention AC-7.13/7.14) —
> verified green on **pg18 and pg17**. The S4 latency figure here is the
> PRD-6 baseline; PRD-7.E re-asserts the budget automatically (`perf_*`
> probes, 100 × 250ms ceiling) and PRD-10 re-measures against a live engine
> on cluster networking.

Extension `pg_mcp 0.1.0` (pgrx 0.19.2, PostgreSQL 18.4, aarch64-darwin) against
`Noizu.MCP.Fixtures.Server` on Bandit 1.12, loopback, `MIX_ENV=test`. Two
listeners: one open (`auth 'none'`), one bearer (`ApiKeyVerifier`, two static
keys). Reproduce with `pg/pg_mcp/spike/run.sh`; per-check transcript in
`spike/RESULTS.md`.

| # | Criterion | Result | Measured |
|---|---|---|---|
| **S1 handshake** | initialize + notifications/initialized + tools/call from inside a backend | **PASS** | first SQL call completes the handshake; `mcp-session-id` round-trips (`hasSessionId=true`); exactly **1** initialize across N calls (FR-6.4) |
| **S2 SSE** | slow handler forces the plug's SSE commit; synchronous reader survives | **PASS** | `Fixtures.Slow` (1500ms) with `sse_commit_after=200ms` → correct result `done` through the SSE reader, no hang |
| **S3 auth → Principal** | valid token → expected `%Principal`; bad token → nil principal + `42501` | **PASS** | `whoami` returns `sub=spike_a` from the USER MAPPING token; wrong token raises `42501` before any handler runs; two roles on one server reach the server as `spike_a` and `spike_b` (AC-6.6) |
| **S4 latency** | p50 < 25ms, p99 < 250ms | **PASS (loopback)** | **p50 = 0.19ms, p99 = 0.22ms** over 60 `mcp.call_tool_text` echo calls, keep-alive reused |

Caveats, stated:

* **S1c**: `tools/list` is not on the PRD-6 SQL surface (the PRD-6 functions
  don't expose it; `mcp.import` lands in PRD-7). The handshake and a
  `tools/call` exercise the identical JSON-RPC/session path, so no open risk is
  left — but the literal `tools/list` from SQL is re-checked in PRD-7.
* **S4** is measured on loopback, not cluster networking (§9 Q1 remains open —
  the honest S4 re-measure happens against the PRD-11 engine).
* **S3b** server-side `%Principal` nil: the rejected token never reaches a
  handler (401 at the plug); the direct `%Principal == nil` assertion is
  pinned for PRD-10's e2e per §7.3.

AC hand-assertions (§7.3, re-asserted automatically in PRD-10):

| AC | Result |
|---|---|
| AC-6.1 `call_tool` echo → `CallToolResult` jsonb | PASS |
| AC-6.2 `call_tool_text` → `hi` | PASS |
| AC-6.3 `isError` → `P0001` both functions at default; payload as data under `'return'` | PASS |
| AC-6.4 slow tool through SSE reader | PASS (= S2) |
| AC-6.5 rejected token → `42501` | PASS (= S3b) |
| AC-6.6 two mappings, two principals, one cluster | PASS (= S3c) |
| AC-6.7 `get_prompt`/`read_resource`/`complete` match expected payloads | PASS |
| AC-6.8 `pg_dump` → restore → options re-validate → `mcp.version()` | PASS |

FR-6.12: black-hole loopback listener, `timeout_ms '1000'` → `08006` after
**1031ms** wall clock (budget: 1500ms). FR-6.13: `mcp.refresh` returns `true`
and drops the cached session.

## Gate consequences (§7.5)

* S1 + S3 pass → **the series proceeds** to PRD-7…10 as specified.
* S2 passes → PRD-7 read-through tables keep the SSE path as specified.
* S4 passes with two orders of magnitude of headroom on loopback; PRD-8's
  SELECT-invocation stays on the table pending the cluster-network re-measure.

## Environment notes

* The pgrx-tests framework wrapper misbehaved on this machine (probes report
  "does not exist" despite a clean `CREATE EXTENSION`), so `run-tests.sh`
  performs the identical build → replay → probe flow explicitly: **38/38
  probes pass** on pg18. `cargo pgrx test pg16/pg17` untested — no local
  pg16/pg17 servers (AC-6.9 is pg18-verified only).
* `supabase-wrappers` is deliberately absent (ADR-002 deviation, documented in
  `pg/README.md`).
