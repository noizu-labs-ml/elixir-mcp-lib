# The Engine — attach an MCP server with a row insert

`Noizu.MCP.Engine` is an MCP server whose content is other MCP servers
(PRD-11, ADR-007). Install it once, point `pg_mcp` at it once, and every
subsequent upstream — stdio-only servers included — is attached with a
`servers` row.

## Quick start (embedded)

```elixir
# 1. Mount the engine behind the ordinary Streamable HTTP plug
plug Noizu.MCP.Transport.StreamableHTTP.Plug, server: Noizu.MCP.Engine

# 2. (optional) seed static upstreams at boot — they become ordinary rows
Noizu.MCP.Engine.seed_static()
# with: Application.put_env(:noizu_mcp, :engine, static_servers: [
#   %{"name" => "github", "transport" => "stdio",
#     "command" => "npx -y @modelcontextprotocol/server-github",
#     "auth_ref" => "env:GITHUB_TOKEN"}
# ])
```

Or run standalone:

```
mix mcp.engine --port 4040 --attach 'github=stdio:npx -y @modelcontextprotocol/server-github'
```

## Attaching an upstream

Any of these — all the SAME code path (one implementation, D1):

```sql
INSERT INTO engine.servers (name, transport, command, auth_ref, enabled)
VALUES ('github', 'stdio', 'npx -y @modelcontextprotocol/server-github', 'env:GITHUB_TOKEN', true);
-- via sql/modify, or the FDW's foreign table
```

```
tools/call engine.attach {"name": "github", "transport": "stdio",
                          "command": "npx -y ...", "auth_ref": "env:GITHUB_TOKEN"}
```

Within the connect timeout the upstream's tools appear in the engine's
`tools/list` as `github.<tool>`, its status reads `ready` in the `servers`
relation, and `SELECT * FROM mcp.generate_functions('engine', 'github')`
produces its SQL functions.

Detach: `engine.detach` or `DELETE FROM engine.servers WHERE name = 'github'`.
Refresh: `engine.refresh` (re-lists; upstream `list_changed` notifications and
a periodic backstop do this automatically).

## Credentials are references, never values

`auth_ref` accepts exactly four forms:

| Form | Resolved at connect time by |
|---|---|
| `env:VAR` | the process environment |
| `secret:<name>` | the configured `{module, function}` resolver |
| `infisical:<path>/<KEY>` | the same resolver (naming convention) |
| `passthrough` | the caller's own token (see below) |

Anything else — anything that looks like a pasted credential — is rejected at
insert with an explanation. The rejection never echoes the rejected value.
Configure the resolver:

```elixir
Application.put_env(:noizu_mcp, :engine,
  secret_resolver: {MyApp.Secrets, :resolve}  # ("secret:name" -> {:ok, value})
)
```

A row can be created before its secret exists; resolution happens at connect
time and on every reconnect, and a failure shows up as
`status = 'error'` with a detail that names the REFERENCE only.

## Pass-through (opt-in)

`auth_ref = 'passthrough'` forwards the CALLER's credential to the upstream
instead of a stored one. It is off by default and costs session pooling: the
engine keeps a short-lived per-principal session (idle-evicted after
`passthrough_idle_ms`, default 60s). For stdio upstreams the credential rides
in `MCP_PASSTHROUGH_TOKEN`; for http it is the `Authorization: Bearer` header.
A caller with no credential is refused before any upstream request. The
trade-off is stated in `docs/arch/engine.md`: the upstream gets the caller's
real identity, and the engine is no longer the only holder of upstream
credentials.

## ACL

Configure a `Noizu.MCP.ACL.Provider` (runtime):

```elixir
Application.put_env(:noizu_mcp, :engine, acl: MyApp.Policy)
```

Policies are written at either granularity against the PREFIXED names:

- whole upstream — deny every tool id starting `github.` … and the upstream's
  registry id `github`, which also hides its `servers` row: a principal that
  cannot use an upstream cannot enumerate it;
- single tool — deny `github.delete_repo`.

A denied tool returns exactly the error an absent tool returns.

## The SQL story

One `CREATE SERVER` points at the engine; one `USER MAPPING` per role; then:

```sql
IMPORT FOREIGN SCHEMA mcp FROM SERVER engine INTO public
  OPTIONS (per_tool 'true', all_upstreams 'true');
```

yields one schema per enabled upstream plus the engine's own — `all_upstreams`
is required and defaults to false, so a later attach cannot silently change
what a re-import produces. Attaching an MCP afterwards:

```sql
INSERT INTO engine.servers (name, transport, command, auth_ref, enabled)
VALUES ('github', 'stdio', 'npx -y @modelcontextprotocol/server-github', 'env:GITHUB_TOKEN', true);
SELECT mcp.refresh('engine');
SELECT * FROM mcp.generate_functions('engine', 'github');
```

Upstreams that advertise `experimental.sql` have their own relations
re-exported as `<server>.<relation>` through the engine's `sql/schema`, and
`sql/scan` on one proxies to that upstream.

## Configuration

All options are runtime (`:noizu_mcp, :engine`) — see
`Noizu.MCP.Engine.Config`: `:persistence`, `:store_key`, `:acl`,
`:static_servers`, `:connect_timeout_ms`, `:backoff`, `:refresh_interval_ms`,
`:passthrough_idle_ms`, `:secret_resolver`.

## Persistence note (Ecto)

With `--persistence ecto --repo MyApp.Repo` (or `persistence:
{Noizu.MCP.Persistence.Ecto, repo: MyApp.Repo}`), the `servers` registry lives
in `noizu_mcp_engine_servers`. Deployments predating PRD-11 should re-run
`Noizu.MCP.Migration.Runner.up/3` once (idempotent) to create the table.

## Health and failure

`servers.status` is the health surface: `connecting`, `ready`, `error` (with a
redacted `status_detail`), `disconnected`, `disabled`. A down upstream
contributes NO tools and never fails `tools/list`; every other upstream keeps
serving. A permanently unreachable upstream retries in the background forever
(exponential backoff with jitter, capped at `max_ms`).
