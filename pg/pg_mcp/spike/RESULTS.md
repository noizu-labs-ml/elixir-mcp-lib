# Spike results — PRD-6 §7.5

Verdict: **GO** (S1–S4 all pass). Full report with measured numbers and
caveats: [`../SPIKE.md`](../SPIKE.md).

| Check | Result | Key number |
|---|---|---|
| S1 handshake | PASS | 1 initialize across N calls; session id round-trips |
| S2 SSE | PASS | slow tool (1500ms vs 200ms commit) read correctly |
| S3 auth → Principal | PASS | `sub=spike_a`; bad token → `42501`; two roles, two principals |
| S4 latency (loopback) | PASS | p50 0.19ms, p99 0.22ms |
| FR-6.12 timeout | PASS | `08006` in 1031ms @ 1000ms budget |
| AC-6.1…6.8 | PASS | incl. pg_dump/restore round-trip |
| Unit probes (`run-tests.sh`, pg18) | 38/38 | `cargo pgrx test` framework note in `../README.md` |

Reproduce: `pg/pg_mcp/spike/run.sh` (boots the Elixir fixture servers, builds
the extension, creates + drops a throwaway `pg_mcp_spike` database).
