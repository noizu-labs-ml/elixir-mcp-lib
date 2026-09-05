# pg_mcp install runbook (operators)

Install the `pg_mcp` extension onto the cluster's Postgres, point it at a
`Noizu.MCP.Engine`, and attach MCP servers as rows (PRD-10 §4.5, ADR-007's
install-once story). Rollback is at the end.

This is the cluster path. For local development, `pg/docker/README.md` has
the one-liner (`docker compose` + `PG_MCP_URL mix test --only pg_mcp`).

## 1. Build or pull the layered image

The extension ships as an image layer on the pinned TimescaleDB base
(ADR-006: image layering, not hex, not PGXN):

```bash
# production profile — layers pg_mcp.so + control/SQL onto the Noizu base:
docker build -f pg/docker/Dockerfile .
```

or pull the published tag
(`noizu/timescaledb-ha-with-age-mcp:<base>-mcp<ext version>-r<rev>`, pushed by
CI on `pg_mcp-v*` tags). CI runs the §7.5 smoke test — `CREATE EXTENSION
pg_mcp` plus every pre-existing base extension — on every build and against
the production base nightly.

## 2. Roll the image (schedule a failover)

Bump the image in the monorepo — `terraform/kubernetes/modules/timescaledb/
variables.tf` `image` default (or the per-deployment override) — to the new
`-mcp` tag, then `terragrunt apply` in `terraform/kubernetes`.

**This is an image roll: expect a pod restart, which for a TimescaleDB HA
deployment means a failover. Schedule accordingly.** This is the single most
operationally significant step in the series, and it belongs to a routine
image bump, not to anything pg_mcp does.

Databases that never run `CREATE EXTENSION pg_mcp` are unaffected (D5:
fail-open per server; the extension is not in `shared_preload_libraries`).

## 3. Deploy the engine

The engine (`Noizu.MCP.Engine`, PRD-11) is what Postgres points at. Either
embed it in a host app behind the Streamable HTTP plug
(`plug Noizu.MCP.Transport.StreamableHTTP.Plug, server: Noizu.MCP.Engine`,
with an auth verifier) or run it standalone (`mix mcp.engine --port 4040`).
It must be reachable from the Postgres pods over plain HTTP loopback or
HTTPS — the extension refuses plaintext http to non-loopback hosts (SEC-4),
so in-cluster use means an in-cluster engine URL over https, or a sidecar
loopback.

## 4. Per database: enable the extension

Requires superuser (or `pg_create_foreign_server` plus `CREATE` on the target
schema):

```sql
CREATE EXTENSION pg_mcp;
```

## 5. One foreign server, for the engine

```sql
CREATE SERVER engine FOREIGN DATA WRAPPER mcp_fdw
  OPTIONS (url 'https://engine.internal/mcp', timeout_ms '20000');
```

**One** server for the engine — that is the install-once claim. Generic mode
(pointing a server directly at a single MCP server) remains available as the
fallback, but the engine is the intended path.

## 6. One USER MAPPING per role

```sql
CREATE USER MAPPING FOR app_role SERVER engine
  OPTIONS (token_secret 'mcp_secrets.npl');   -- reference, never a literal
```

Tokens are sourced from Infisical through the existing secrets flow
(`dc`/`secrets-mcp`), never typed into a migration. The token maps to a
principal server-side; the engine's ACL decides what that principal sees
(two mappings → two tool sets, per ADR-004).

## 7. Import

```sql
CREATE SCHEMA mcp;
SELECT mcp.import('engine', 'mcp', '{"all_upstreams": true}');
-- optionally the per-tool objects (typed tables/functions/views):
SELECT * FROM mcp.generate_functions('engine', 'mcp', '{"per_upstream_schema": true}');
```

One schema per attached upstream plus the engine's own slice is created;
`all_upstreams` is required and defaults to false, so a later attach cannot
silently change what a re-import produces. Note: `all_upstreams` derives
schemas from EVERY prefixed `tools/list` name, including the engine's own
`engine.attach`/`detach`/`refresh` — so do not name the target schema
`engine` (that name becomes the engine-local tools' slice).

## 8. Attach MCP servers as rows, thereafter

```
tools/call engine.attach  {"name": "github", "transport": "stdio",
                           "command": "...", "auth_ref": "secret:github"}
-- then:
SELECT mcp.refresh('engine');
SELECT * FROM mcp.generate_functions('engine', 'github');
```

`auth_ref` holds a **reference** (`env:VAR`, `secret:<name>`,
`infisical:<path>/<KEY>`, or `passthrough`) — resolved at connect time by the
engine, never a pasted credential. Detach is `engine.detach`. The SQL-level
`engine.servers` dataset rides the engine's `sql/modify` MCP methods (it is
deliberately outside the frozen ten-table FDW registry).

## 9. Check the DDL into Liquibase

Steps 4–7's DDL goes into a Liquibase changelog per the monorepo convention
(Liquibase owns schema). Generated per-tool objects are DDL and must not be
hand-run in production — regeneration belongs to `mcp.generate_functions`,
which drops and recreates only what it recorded in `mcp.generated`. Step 8's
attach is data, not schema, and belongs wherever the operator keeps
configuration. Which changelog target owns the pg_mcp DDL (each consuming
app's, or a new shared one) is a monorepo decision tracked under PRD-10 §9
Q6.

## Rollback

```sql
DROP EXTENSION pg_mcp CASCADE;   -- per database, drops foreign servers/tables
```

then revert the Terraform `image` value and `terragrunt apply` (another
failover). Local audit tables (`tool_calls` log) survive deliberately.
A database that keeps `pg_mcp` objects after the image rolls back will fail
on extension object access until the image returns — `DROP EXTENSION CASCADE`
first avoids that, at the cost of the foreign servers and tables.
