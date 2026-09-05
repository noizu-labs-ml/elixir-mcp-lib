# pg_mcp — call MCP servers from SQL

`pg_mcp` is a PostgreSQL extension (PRD-6 of the pg_mcp series) that lets a SQL
statement talk to any MCP Streamable HTTP server — including the `Noizu.MCP`
plug and the PRD-11 `Noizu.MCP.Engine` — from inside a backend:

```sql
CREATE EXTENSION pg_mcp;

CREATE SERVER npl FOREIGN DATA WRAPPER mcp_fdw
  OPTIONS (url 'https://npl.noizu.com/mcp', timeout_ms '15000');

CREATE USER MAPPING FOR CURRENT_USER SERVER npl
  OPTIONS (token_secret 'mcp_secrets.npl');   -- preferred over inline `token`

SELECT mcp.call_tool_text('npl', 'echo', jsonb_build_object('message', 'hi'));
```

## Layout

```
pg/pg_mcp/
├── Cargo.toml / pg_mcp.control / sql/pg_mcp--0.1.0.sql   (generated)
├── src/{lib,api,client,session,options,errors,sse}.rs
├── run-tests.sh            deterministic pg test runner (38 probes)
└── spike/                  PRD-6 §7.5 go/no-go spike harness + report
```

## Build & test

Requirements: `cargo` (rust-toolchain.toml pins 1.98.1), `cargo-pgrx 0.19.2`
(`cargo install --locked cargo-pgrx@0.19.2`), PostgreSQL 18 dev files
(`pg_config` on PATH; pg16/pg17 feature flags exist but pg18 is what we test).

```bash
cargo pgrx init --pg18 $(which pg_config)   # once
cargo pgrx install -c $(which pg_config)    # install into the server
cargo pgrx test pg18                        # pgrx framework runner
./run-tests.sh                              # deterministic runner (see note)
```

**Note on `cargo pgrx test`:** the underlying pgrx-tests framework misbehaves
on some machines — its `CREATE EXTENSION` step and its probe queries end up
against different state, so every probe reports "does not exist" even though
the extension installs perfectly. `run-tests.sh` performs the identical flow
explicitly (build → generate SQL → throwaway cluster → replay → run every
`tests.*` probe) and is the runner we trust. PostgreSQL's macOS linker also
needs `-Wl,-undefined,dynamic_lookup`, which `.cargo/config.toml` supplies
(cargo-pgrx's own template default).

## Surface (PRD-6 §4.6)

| Function | Notes |
|---|---|
| `mcp.call_tool(server, tool, args := '{}', on_error := 'raise')` | full `CallToolResult` as jsonb; `isError` → `P0001` by default, data under `'return'` |
| `mcp.call_tool_text(server, tool, args, on_error)` | concatenated text content; NULL if none |
| `mcp.get_prompt(server, prompt, args)` / `mcp.read_resource(server, uri)` / `mcp.complete(server, ref, name, value)` | STRICT |
| `mcp.refresh(server)` | drops this backend's cached MCP session, returns true |
| `mcp.import(server, schema, opts)` | declared only; implemented in PRD-7 (raises `0A000`) |

One MCP session per `(backend, server OID, user OID)`: `initialize` once, the
`Mcp-Session-Id` echoed on every request, one silent re-initialize if the
server 404s or reports an expired session. `timeout_ms` is a total deadline
per exchange (connect + read, default 15s); every statement stays cancelable.

Foreign tables, read-through catalogs and `tool_calls` are PRD-7+. The
`mcp_fdw` wrapper exists so `CREATE SERVER` / `CREATE USER MAPPING` validate
their options; planning against a foreign table raises `0A000` today.

## Security posture

* Bearer tokens come only from `USER MAPPING` options (`token`, or the
  preferred `token_secret 'schema.table'` row lookup). Server options never
  carry a token, and no option value is ever echoed into an error (SEC-1).
* `auth 'none'` is accepted only for loopback URLs; plaintext `http` likewise.
* `token_secret` lookups run as the calling role (SEC-3): Postgres's own
  grants decide readability.
* `url` is operator-supplied at `CREATE SERVER` time (superuser or
  `pg_create_foreign_server`); there is no per-call URL override (SEC-4).

## ADR-002 deviation (recorded)

ADR-002 names `supabase-wrappers` 0.1.28 as a library dependency alongside
pgrx 0.19. That combination does not exist: `supabase-wrappers` 0.1.28 pins
`pgrx = "=0.16.1"` **exactly** and pulls tokio, contradicting ADR-002's own
"pgrx 0.19" and "no tokio inside the backend" clauses (0.16.1 also predates
PostgreSQL 18). PRD-6's scope needs none of the crate's scaffolding, so the
crate is built on plain pgrx 0.19.2. PRD-7 must decide: accept the ADR-002
risk note (plain pgrx FDW) or re-spec the framework. Filed for the ADR owner;
not silently ignored.
