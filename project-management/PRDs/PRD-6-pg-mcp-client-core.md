# PRD-6: pg_mcp Extension Core & Spike

**Series**: pg_mcp — MCP servers as Postgres structures (PRD-6 of 6, series 2 root)
**Repo**: `Portfolio/Libs/ai/elixir-mcp` — new subproject `pg/pg_mcp/` (Rust/pgrx). Elixir anchors below are relative to the lib root.
**Version policy**: no `mix.exs` bump in this PR. The single `0.4.0` bump lands in PRD-11 (`mix.exs:4` is `@version "0.3.0"` today). The Rust crate carries its own `Cargo.toml` version starting at `0.1.0`.
**Depends on**: nothing (series root). Gates PRD-9, PRD-11 and the Rust PRDs that follow.
**Date**: 2026-09-05 · **Author**: npl-prd-editor (Loom weave)
**Status**: Draft
**Design rules**: D1–D5 from series 1 apply where relevant (see §2)

---

## 1. Goal

Stand up a real PostgreSQL extension, `pg_mcp`, that can talk to a Noizu MCP server over Streamable HTTP from inside a Postgres backend, and prove — with an explicit go/no-go gate — that the whole approach is viable before any catalog or codegen work is committed.

Deliverables:

1. A pgrx skeleton subproject at `pg/pg_mcp/` producing `pg_mcp.so` + `pg_mcp.control` + versioned SQL, buildable for pg16/pg17/pg18.
2. A blocking Streamable HTTP JSON-RPC client: one MCP session per Postgres backend, `initialize` once, `Mcp-Session-Id` cached, re-initialize on 404/expired session, `Accept: application/json, text/event-stream` with a minimal SSE reader for the upgrade path.
3. Bearer credential sourcing from `USER MAPPING` (per ADR-004), never from server options.
4. Six SQL entry points: `mcp.call_tool/3`, `mcp.call_tool_text/3`, `mcp.get_prompt/3`, `mcp.read_resource/2`, `mcp.complete/4`, `mcp.refresh/1`.
5. FDW server-option and user-mapping-option validators.
6. A written spike report answering four go/no-go criteria (§7.5).

**Explicitly OUT of scope** (later PRDs): foreign tables and `tool_calls` (PRD-7), per-tool codegen and type mapping (PRD-8), the Elixir `sql/*` feature and Dataset DSL (PRD-9), image/CI packaging and the end-to-end harness (PRD-10).

---

## 2. Decision log applied to this PRD

| ADR / rule | How it binds this PRD |
|---|---|
| **ADR-001** real Postgres extension | The client lives inside a Postgres backend process. No Postgres wire emulation, no separate proxy daemon. Everything a user sees is reached through `CREATE EXTENSION pg_mcp`. |
| **ADR-002** pgrx 0.19 + `supabase-wrappers` as a library | Crate deps pinned to `pgrx = "0.19"` and `supabase-wrappers = "0.1.28"`. This PRD uses the crate only for option validation and the FDW handler/validator registration shape; the trait implementation itself arrives in PRD-7. Outbound HTTP is a blocking `ureq` client — no tokio runtime inside the backend. |
| **ADR-004** identity | The Bearer token comes from `USER MAPPING` options (`token`, or `token_secret` naming a row the extension reads), resolved through `pg_sys::GetUserMapping` for `GetUserId()`. Server options never carry a token. A missing mapping under `auth 'bearer'` is an error, not an anonymous call. |
| **ADR-005** FDW `mode auto\|generic\|sql` | The `mode` option is accepted and validated here; only `generic` semantics are exercised (the SQL entry points are mode-independent). `auto` probing is specified in PRD-9 §4.6. |
| **ADR-007** engine federation | The **primary** counterpart of this client is `Noizu.MCP.Engine` (PRD-11) — one foreign server, many upstreams attached as rows. The client is written against generic MCP Streamable HTTP, so it serves both, but the spike target and every later e2e is the engine. |
| **ADR-006** placement | `pg/pg_mcp/` sits beside the existing `daemon/mcp_mount/` escript subproject. The hex package `noizu_mcp` stays pure Elixir — `pg/` is excluded from `package.files`. |
| **D3** runtime-only resolution | No server URL, token or timeout is captured at extension build time. Every value is read from catalog options at call time. |
| **D5** fail-closed per table, fail-open per server | A failing MCP call raises a SQLSTATE for that statement only. It never poisons the backend's session cache in a way that breaks unrelated foreign servers; each foreign server gets its own session slot. |

---

## 3. Background

Noizu MCP servers today expose their surface over Streamable HTTP through `lib/noizu/mcp/transport/streamable_http/plug.ex`. That plug answers `application/json` on the fast path and commits to `text/event-stream` when a handler is slow: the decision is the `sse_commit_after` timer at `streamable_http/plug.ex:505`, whose default is set at `:112`, and the upgrade itself happens at `:489` on the first non-final message. It mints a session id at `:385`, returns it as `mcp-session-id` at `:431`, and requires it on subsequent requests at `:656-664` (a missing header is a 400). Authorization comes from the `:auth` option (`:102`). Per-request bearer claims reach handlers as `ctx.assigns[:auth_claims]` (`streamable_http/plug.ex:395-401`) and are re-resolved into a `%Noizu.MCP.Auth.Principal{}` (`lib/noizu/mcp/auth/principal.ex:24`) by the verifier chain (`lib/noizu/mcp/auth/token_verifier.ex`, `chain_verifier.ex`, `jwt_verifier.ex`, `api_key_verifier.ex`).

Nothing today lets a SQL client reach that surface. Research on 2026-09-05 found **no MCP foreign data wrapper in existence** — this is greenfield. The Noizu cluster runs `docker.io/noizu/timescaledb-ha-with-age:pg17.9-ts2.25.2-all-age1.7.0-r2` with citext, uuid-ossp, vector, cube, pg_trgm, earthdistance, pgcrypto, timescaledb and age installed, and **without** `wrappers`, `multicorn`, `http`, `plpython3u` or `postgres_fdw`. That absence is what forces a self-contained compiled extension (ADR-002) rather than a Wasm FDW guest or a plpgsql + `pgsql-http` shim.

The risk this PRD retires is concentrated in four unknowns: does a blocking HTTP client behave inside a Postgres backend, does the SSE upgrade path survive a synchronous reader, does `GetUserMapping` give us a usable per-role token, and is round-trip latency inside the budget that makes per-row invocation sane. PRD-7 through PRD-10 are all worthless if any of the four fails, so they are gated on §7.5.

---

## 4. Public surface

### 4.1 Subproject layout

```
pg/pg_mcp/
├── Cargo.toml                # pgrx 0.19, supabase-wrappers 0.1.28, ureq, serde_json
├── pg_mcp.control            # generated by pgrx; schema = mcp, relocatable = false
├── src/
│   ├── lib.rs                # extension_sql_file!, pg_module_magic!
│   ├── options.rs            # server / user-mapping option parsing + validators
│   ├── session.rs            # per-backend MCP session cache
│   ├── client.rs             # Streamable HTTP JSON-RPC client
│   ├── sse.rs                # minimal text/event-stream reader
│   ├── errors.rs             # MCP error → SQLSTATE mapping (shared with PRD-7)
│   └── api.rs                # #[pg_extern] SQL functions
└── sql/pg_mcp--0.1.0.sql     # generated
```

### 4.2 Foreign server options (validated)

```sql
CREATE SERVER npl
  FOREIGN DATA WRAPPER mcp_fdw
  OPTIONS (
    url                  'https://npl.noizu.com/mcp',   -- required
    mode                 'auto',        -- auto | generic | sql   (default 'auto')
    timeout_ms           '15000',       -- integer > 0            (default 15000)
    auth                 'bearer',      -- bearer | none          (default 'bearer')
    max_unqualified_reads '0',          -- integer >= 0           (default 0)
    audit_table          'mcp_audit.tool_calls'  -- optional, regclass-parseable
  );
```

| Option | Type | Default | Validation rule |
|---|---|---|---|
| `url` | text | — | required; must parse as an absolute `http`/`https` URL. `http` is rejected unless the host resolves to loopback. |
| `mode` | enum | `auto` | one of `auto`, `generic`, `sql`. |
| `timeout_ms` | int | `15000` | `1 <= n <= 600000`. Applied as both connect and read timeout. |
| `auth` | enum | `bearer` | `bearer` or `none`. `none` is rejected unless `url` host is loopback (ADR-004). |
| `max_unqualified_reads` | int | `0` | `>= 0`. `0` means an unqualified scan of a read-through table raises instead of fanning out. Consumed in PRD-7. |
| `audit_table` | text | none | must be a schema-qualified identifier pair; existence is checked lazily at first write, not at `CREATE SERVER`. |

### 4.3 User-mapping options (validated)

```sql
CREATE USER MAPPING FOR analyst SERVER npl
  OPTIONS (token 'eyJhbGciOi...');
-- or, keeping the secret out of pg_user_mappings:
CREATE USER MAPPING FOR analyst SERVER npl
  OPTIONS (token_secret 'mcp_secrets.npl_analyst');
```

| Option | Rule |
|---|---|
| `token` | Bearer credential, used verbatim as `Authorization: Bearer <token>`. Mutually exclusive with `token_secret`. |
| `token_secret` | `schema.table` holding one row `(role name primary key, token text)`; the extension reads the row for `current_user` with a `SPI` query under the table's own privileges. Mutually exclusive with `token`. |

> **Prefer `token_secret`. The inline `token` example above is the shape, not the recommendation.** ADR-004's redaction guarantee covers what *this extension* emits (§7.4 SEC-1), and it cannot cover what Postgres itself records about the statement that created the mapping. A `CREATE USER MAPPING … OPTIONS (token 'eyJ…')` is DDL text, so the literal lands in `pg_stat_activity` while it runs, in the server log under `log_statement = 'all'` or `'ddl'`, and in any `pg_dump` of the database. `token_secret` keeps the credential out of all three by naming a row instead of carrying a value. The runbook (PRD-10 §4.5 step 6) prescribes `token_secret` sourced from Infisical, and this PRD's guide text says the same.

Neither option is ever echoed in an error message, a log line, or a `RAISE` payload *by the extension*. Redaction is asserted in §7.4.

### 4.4 Session model

One `McpSession` per `(backend PID, foreign server OID, user OID)` triple, held in a backend-local `HashMap` reset by an `on_proc_exit` and by a transaction-abort callback that clears only in-flight state (the negotiated session survives rollback — MCP sessions are not transactional).

```rust
struct McpSession {
    url: String,
    session_id: Option<String>,   // Mcp-Session-Id
    protocol_version: String,     // from initialize result
    server_info: serde_json::Value,
    capabilities: serde_json::Value,
    next_id: i64,
    initialized_at: Instant,
}
```

Lifecycle, normative:

1. First call for the triple sends `initialize` (JSON-RPC 2.0, `protocolVersion` = the newest version the extension knows, `clientInfo` = `{"name":"pg_mcp","version":<crate version>}`), then the `notifications/initialized` notification.
2. `Mcp-Session-Id` from the initialize response is cached and sent on every later request.
3. On HTTP `404`, or a JSON-RPC error whose message indicates an unknown/expired session, the session is dropped and re-initialized **once**; a second failure surfaces as `08006`.
4. `mcp.refresh(server)` drops the cached session and any cached catalog for that server (catalog caching lands in PRD-7; in PRD-6 `refresh` drops the session only).
5. Every request sends `Accept: application/json, text/event-stream` and `MCP-Protocol-Version: <negotiated>`.

### 4.5 SSE reader

The plug commits to SSE when a handler is slow (`streamable_http/plug.ex:14`). The reader in `sse.rs` is deliberately minimal:

- Reads the response body line-by-line, accumulating `data:` lines per event, terminated by a blank line; ignores `event:`, `id:` and comment (`:`) lines except that `id:` is retained for a future `Last-Event-ID` resume.
- Parses each event payload as JSON-RPC. Returns on the first message whose `id` matches the request id.
- Enforces `timeout_ms` as a total deadline across the whole stream, not per read.
- On stream end without a matching id, raises `08006`.

No resume, no reconnect, no `Last-Event-ID` replay in this PRD — those are noted in §9.

### 4.6 SQL functions

```sql
-- Invoke a tool. Returns the full CallToolResult as jsonb.
-- on_error: 'raise' (default) turns isError = true into P0001; 'return' hands
-- the error result back as data. ADR-003 makes raising the default for
-- FUNCTIONS; TABLES (PRD-7 §4.7) do the opposite and always return a row.
CREATE FUNCTION mcp.call_tool(server text, tool text, args jsonb DEFAULT '{}'::jsonb,
                              on_error text DEFAULT 'raise')
  RETURNS jsonb VOLATILE;

-- Convenience: concatenated text content of a tool result. NULL if the result
-- carries no text content. Honors on_error identically.
CREATE FUNCTION mcp.call_tool_text(server text, tool text, args jsonb DEFAULT '{}'::jsonb,
                                   on_error text DEFAULT 'raise')
  RETURNS text VOLATILE;

-- prompts/get
CREATE FUNCTION mcp.get_prompt(server text, prompt text, args jsonb DEFAULT '{}'::jsonb)
  RETURNS jsonb STRICT VOLATILE;

-- resources/read
CREATE FUNCTION mcp.read_resource(server text, uri text)
  RETURNS jsonb STRICT VOLATILE;

-- completion/complete
CREATE FUNCTION mcp.complete(server text, ref jsonb, argument_name text, argument_value text)
  RETURNS jsonb STRICT VOLATILE;

-- Drop cached session (and, from PRD-7, cached catalog) for a foreign server.
CREATE FUNCTION mcp.refresh(server text)
  RETURNS boolean VOLATILE;

-- Programmatic equivalent of IMPORT FOREIGN SCHEMA (ADR-003), so import is
-- callable from a migration or a DO block. Implemented in PRD-7 §4.11;
-- declared here so the mcp.* function surface is settled in one place.
CREATE FUNCTION mcp.import(server text, schema text, opts jsonb DEFAULT '{}'::jsonb)
  RETURNS integer VOLATILE;
```

`server` is the **foreign server name**, resolved with `GetForeignServerByName`; an unknown name raises `42704`. All six are `VOLATILE` and `PARALLEL UNSAFE` — they perform network I/O and must not be pushed into parallel workers.

**The `on_error` split is the one place functions and tables deliberately disagree.** Per ADR-003, a *function* raises on `isError: true` by default, because a function call in an expression has no room to return an error flag alongside a value. A *table* never raises (PRD-7 §4.7), because a multi-row insert must survive one failing tool. `on_error => 'return'` opts a function into the table behavior, returning the `isError` payload as data. Both directions are reachable; only the defaults differ, and they differ for a reason worth stating in the guide.

### 4.7 Error mapping (subset used in PRD-6)

| Condition | SQLSTATE | Notes |
|---|---|---|
| JSON-RPC `-32602` invalid params | `22023` invalid_parameter_value | message carries the server's `error.message` |
| JSON-RPC `-32601` method not found | `0A000` feature_not_supported | |
| HTTP 401/403, or verifier rejection | `42501` insufficient_privilege | never synthesizes an anonymous retry |
| Connect / read timeout, DNS, TLS, malformed frame | `08006` connection_failure | |
| Unknown foreign server name | `42704` undefined_object | |
| Missing `USER MAPPING` under `auth 'bearer'` | `28000` invalid_authorization_specification | |
| `mcp.call_tool_text` on `isError` | `P0001` raise_exception | |

The full table (including per-table `is_error` row semantics) is normative in PRD-7 §4.7; `errors.rs` is written here and extended there.

---

## 5. Requirements

**FR-6.1** `pg/pg_mcp/` exists as a pgrx 0.19 crate building cleanly under `cargo pgrx test pg17` with no `unsafe` outside `session.rs` and the `GetUserMapping` call site.
**FR-6.2** The extension installs into schema `mcp` and is non-relocatable; `CREATE EXTENSION pg_mcp` succeeds on a stock pg17 with no other extension present.
**FR-6.3** A `mcp_fdw` foreign-data-wrapper handler + validator are registered. The validator enforces the §4.2 and §4.3 tables at `CREATE`/`ALTER SERVER` and `CREATE`/`ALTER USER MAPPING` time, raising `22023` with the offending option name.
**FR-6.4** Exactly one MCP session exists per `(backend, server OID, user OID)`; two calls in one session issue exactly one `initialize`.
**FR-6.5** `Mcp-Session-Id` is echoed on every non-initialize request when the server supplied one.
**FR-6.6** On HTTP 404 or expired-session error, the client re-initializes once and retries the original request once; a second failure raises `08006`.
**FR-6.7** Every request sends `Accept: application/json, text/event-stream`; a `text/event-stream` response is read to the first matching JSON-RPC id per §4.5.
**FR-6.8** Bearer token is resolved per §4.3 through `pg_sys::GetUserMapping` for `GetUserId()`. Under `auth 'bearer'` with no mapping the call raises `28000` and no request is sent.
**FR-6.9** `auth 'none'` is accepted only when `url`'s host is loopback; otherwise `CREATE SERVER` fails.
**FR-6.10** The seven functions in §4.6 exist with the stated signatures, volatility and parallel-safety. `mcp.import/3` is declared here and implemented in PRD-7 §4.11; calling it before then raises `0A000`.
**FR-6.16** `on_error` accepts `'raise'` (default) and `'return'`; any other value raises `22023`. Under `'raise'` an `isError` result becomes `P0001` carrying the tool's own text content; under `'return'` the result is returned as data.
**FR-6.11** Tokens never appear in error messages, `RAISE` payloads, `elog` output, or `EXPLAIN` output.
**FR-6.12** `timeout_ms` is honored as a total deadline; a hung server yields `08006` within `timeout_ms + 500ms`.
**FR-6.13** `mcp.refresh(server)` drops the session for the calling backend and returns `true`; on an unknown server name it raises `42704`.
**FR-6.14** All statements remain interruptible: a long SSE read responds to `pg_cancel_backend` within one read interval (the reader checks `CHECK_FOR_INTERRUPTS` between events).
**FR-6.15** A spike report is written to `pg/pg_mcp/SPIKE.md` answering §7.5 with measured numbers.

**Acceptance criteria**

**AC-6.1** Against a `Noizu.MCP.Fixtures.Server` booted on Bandit (pattern: `test/noizu/mcp/transport/streamable_http_test.exs:26-30`), `SELECT mcp.call_tool('t','echo','{"message":"hi"}')` returns the echo tool's `CallToolResult` as jsonb.
**AC-6.2** `SELECT mcp.call_tool_text('t','echo','{"message":"hi"}')` returns `hi`.
**AC-6.3** A tool returning `isError: true` raises `P0001` from both `call_tool` and `call_tool_text` at the default `on_error`, and returns the error payload as data from both under `on_error => 'return'`.
**AC-6.4** A slow tool (fixture `Noizu.MCP.Fixtures.Slow`) that forces the plug's SSE commit still returns the correct result through the SSE reader.
**AC-6.5** A user mapping carrying a token the server's verifier rejects raises `42501`, and the server-side `%Principal{}` for that request is `nil` — no anonymous principal is synthesized.
**AC-6.6** Two user mappings on the same foreign server, with different tokens, reach the server as different principals in the same Postgres cluster.
**AC-6.7** `SELECT mcp.get_prompt(...)`, `mcp.read_resource(...)` and `mcp.complete(...)` return payloads matching a direct MCP client call to the same server, field-for-field.
**AC-6.8** `pg_dump` of a database containing a `pg_mcp` server + mapping restores cleanly (options round-trip through the validator).
**AC-6.9** `cargo pgrx test` green on pg16, pg17, pg18.

---

## 6. Internal work checklist (with anchors)

| Step | File | Anchor / detail |
|---|---|---|
| 6.1 | `pg/pg_mcp/Cargo.toml` | new; pgrx 0.19, supabase-wrappers 0.1.28, ureq (blocking, rustls), serde_json, url |
| 6.2 | `pg/pg_mcp/src/lib.rs` | `pgrx::pg_module_magic!()`; `mcp` schema; `#[pg_extern]` re-exports |
| 6.3 | `pg/pg_mcp/src/options.rs` | §4.2/§4.3 tables; `#[pg_extern]` validator wired into the FDW validator entry point |
| 6.4 | `pg/pg_mcp/src/session.rs` | backend-local session map; `on_proc_exit` cleanup; `GetUserMapping` call site |
| 6.5 | `pg/pg_mcp/src/client.rs` | initialize / notifications-initialized / request; §4.4 step 3 retry-once |
| 6.6 | `pg/pg_mcp/src/sse.rs` | §4.5 minimal reader with `CHECK_FOR_INTERRUPTS` between events |
| 6.7 | `pg/pg_mcp/src/errors.rs` | §4.7 subset; extended by PRD-7 §4.7 |
| 6.8 | `pg/pg_mcp/src/api.rs` | the six functions in §4.6 |
| 6.9 | `pg/pg_mcp/SPIKE.md` | §7.5 report |
| 6.10 | `mix.exs` | add `pg` to the excluded paths so `pg/` never ships in the hex tarball (`mix.exs` `package/0`); no version change |
| 6.11 | `.gitignore` | `pg/pg_mcp/target/` |
| 6.12 | Elixir side | **no change**. `lib/noizu/mcp/transport/streamable_http/plug.ex` and the verifier chain are consumed as-is; the `sql/*` feature is PRD-9. |

---

## 7. Test plan

### 7.1 Rust unit tests (`cargo pgrx test`)

- `options_test` — every row of §4.2/§4.3 accepted and every violation rejected with the right message; `auth 'none'` + non-loopback rejected; `token` + `token_secret` together rejected.
- `sse_test` — hand-fed byte streams: single event, multi-line `data:`, interleaved comments, event for a different id followed by the right one, truncated stream, deadline exceeded.
- `errors_test` — the §4.7 table, driven from synthetic JSON-RPC error payloads.
- `session_test` — one initialize for N calls; 404 triggers exactly one re-initialize; second failure raises.

### 7.2 Integration (`cargo pgrx test pg17` against a stub HTTP server)

A tiny in-crate HTTP stub covers protocol shape without needing Elixir: initialize handshake, session-id echo, 404-expiry, SSE upgrade, 401.

### 7.3 Elixir-side integration

Deferred to PRD-10's `test/noizu/mcp/sql/pg_mcp_e2e_test.exs`, which is where a real `Fixtures.Server` and a real Postgres meet. PRD-6 asserts AC-6.1 through AC-6.7 by hand in the spike and re-asserts them automatically in PRD-10 §7.

### 7.4 Security tests

- **SEC-1 token redaction**: force every error path (bad URL, timeout, 401, malformed JSON) with a distinctive token value; assert that value appears in no message, log line or `EXPLAIN` output.
- **SEC-2 no anonymous synthesis** (ADR-004): a rejected token must not fall through to an unauthenticated retry. Asserted server-side in PRD-10 by checking the request never reaches a handler with a non-nil `%Principal{}`.
- **SEC-3 mapping isolation**: role A cannot read role B's token through any extension function; `token_secret` lookups run under the secret table's own privileges, so an unprivileged role gets `42501` from Postgres itself.
- **SEC-4 SSRF posture**: `url` is operator-supplied at `CREATE SERVER` time (superuser or `pg_create_foreign_server` privilege), not caller-supplied. Documented as the trust boundary; no per-call URL override exists anywhere in the series.

### 7.5 Go/no-go spike criteria (normative gate for PRD-7…10)

| # | Criterion | Pass condition | Result |
|---|---|---|---|
| **S1 handshake** | `initialize` + `notifications/initialized` + `tools/list` complete from inside a Postgres backend against a live Noizu MCP server | all three succeed; `Mcp-Session-Id` round-trips | _(fill in)_ |
| **S2 SSE** | A handler slow enough to force the plug's SSE commit still yields a correct result | correct result, no backend hang, cancelable | _(fill in)_ |
| **S3 auth → Principal** | A `USER MAPPING` token produces the expected `%Principal{subject, authenticator}` server-side, and a bad token produces `nil` principal + `42501` | both hold | _(fill in)_ |
| **S4 latency** | Median round-trip for a trivial tool, backend → server → backend, on the cluster network | **p50 < 25ms, p99 < 250ms** | _(fill in)_ |

If **S1** or **S3** fails the series stops. If **S2** fails, PRD-7's read-through tables narrow to JSON-fast-path servers only and the SSE work is re-scoped. If **S4** misses, PRD-8's per-row SELECT-invocation is downgraded to INSERT-only everywhere and the `invoke_on_select` option is dropped — the catalog work still proceeds.

---

## 8. Compat & rollback

- **Purely additive to the Elixir library.** No lib module changes, no behaviour changes, no version bump. Consumers on hex `noizu_mcp ~> 0.3` are unaffected by this PR.
- The hex tarball must not grow: `pg/` is excluded from `package.files` (step 6.10). A packaging test asserts this (PRD-10 §7).
- **Rollback**: delete `pg/pg_mcp/` and the two-line `mix.exs`/`.gitignore` edits. Nothing else in the repo references it until PRD-7.
- **Postgres-side rollback**: `DROP EXTENSION pg_mcp CASCADE` removes the schema, the FDW, and any dependent servers/mappings. No user data lives in the extension at this stage.
- **Risk watch**: a blocking HTTP client inside a backend holds no locks but does hold a backend slot for up to `timeout_ms`. Operators should keep `timeout_ms` well below `statement_timeout`. Documented in the PRD-10 runbook.

---

## 9. Open questions

1. **Q1 (blocking for §7.5 S4):** Which live MCP server is the spike target? PRD-11's engine is the primary path, and it adds a second hop (caller → engine → upstream), so the honest bar is measured through an engine with one upstream attached, not against a bare `Fixtures.Server`. Confirm the target: a locally booted engine, the NPL production endpoint, or a staging deployment. The latency bar only means something against real cluster networking, and S4's outcome governs PRD-8's SELECT-invocation.
2. **Q2:** `token_secret` table shape — the spec above assumes `(role name, token text)`. Should it instead accept an arbitrary `SELECT` expression, or read from a Vault/Infisical-backed FDW? Reading a plain table is the smallest thing that works; anything richer wants its own ADR.
3. **Q3:** SSE resume. `Last-Event-ID` replay is specified as out of scope. Confirm that a dropped stream mid-tool-call surfacing as `08006` (rather than resuming) is acceptable for 0.4.0.
4. **Q4:** Should `mcp.call_tool` be `PARALLEL RESTRICTED` rather than `PARALLEL UNSAFE`? Unsafe is the conservative choice and blocks parallel plans containing the call entirely; restricted would allow the leader to run it. Recommend unsafe for 0.4.0, revisit with measurements.
5. **Q5:** Protocol-version negotiation. The extension pins the newest version it knows and sends `MCP-Protocol-Version`. If a server negotiates down, should the extension refuse features it cannot express, or degrade silently? Recommend: record the negotiated version in the session and let PRD-7's catalog omit unsupported surfaces.
