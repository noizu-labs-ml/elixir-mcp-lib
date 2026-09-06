# PRD-11: `Noizu.MCP.Engine` — Upstream Federation

**Series**: pg_mcp — MCP servers as Postgres structures (PRD-11 of 6)
**Repo**: `Portfolio/Libs/ai/elixir-mcp` (Elixir library). All anchors relative to the lib root.
**Version policy**: **this PRD carries the single `0.4.0` bump** for series 2. `mix.exs:4` is `@version "0.3.0"` today. CHANGELOG entry and user-run hex publish land here; the Rust PRDs that follow touch no library code.
**Depends on**: PRD-9 (`sql/*` methods and the Dataset behaviour — the engine's registry *is* a dataset). Independent of the Rust side; PRD-7, 8 and 10 consume it.
**Date**: 2026-09-05 · **Author**: npl-prd-editor (Loom weave)
**Status**: Draft

---

## 1. Goal

Make "connect another MCP server" a row in a table rather than a deployment.

`Noizu.MCP.Engine` is an MCP server whose content is other MCP servers. An operator installs the extension once, points Postgres at the engine once, and every subsequent MCP server — including stdio-only ones, and ones on private networks Postgres cannot reach — is attached with an `INSERT`.

Deliverables:

1. `Noizu.MCP.Engine` — a `use Noizu.MCP.Server` server module federating upstreams.
2. A writable dataset `servers` backed by the existing `Persistence` providers, holding credentials **by reference only**.
3. Supervised upstream client sessions with backoff and health status.
4. Namespaced projection of upstream tools, prompts, resources and `sql/*` relations as `<server>.<name>`, one Toolset layer per upstream.
5. ACL applied per principal, over upstreams and over individual tools.
6. Optional per-upstream token pass-through.
7. `engine.attach`, `engine.detach`, `engine.refresh` tools.
8. `mix mcp.engine` for standalone operation; embedded operation via the existing Streamable HTTP plug.
9. Conformance tests, `guides/engine.md`, `docs/arch/engine.md`, CHANGELOG, and the `0.4.0` bump.

**Explicitly OUT of scope**: a deployable engine application with its own chart and image (a follow-up outside this repo, per ADR-007); the Rust side's consumption of per-upstream schemas (PRD-7 §4.11, PRD-8 §4.6, PRD-10 §4.3).

---

## 2. Decision log applied to this PRD

| ADR / rule | How it binds this PRD |
|---|---|
| **ADR-007** engine federation | This PRD *is* ADR-007. One extension, one foreign server, MCPs attached as rows. The engine holds every upstream connection; Postgres never speaks to an upstream directly. |
| **ADR-005** `sql/*` + Dataset DSL | The upstream registry is an ordinary `Noizu.MCP.Server.Dataset` (PRD-9 §4.1) named `servers`, implementing `insert/2`, `update/3` and `delete/2`. Attaching over SQL is `sql/modify`; there is no bespoke registry protocol. |
| **ADR-004** identity | The caller's token identifies them **to the engine**. The engine holds upstream credentials by reference and decides, through its ACL provider, which upstreams and tools each `%Principal{}` sees. Pass-through of the caller's token to an upstream is opt-in per upstream and off by default. A nil principal stays anonymous and is never synthesized. |
| **ADR-003** SQL projection model | Namespacing is `<server>.<name>`. Names exceeding Postgres identifier limits fall back to the hashed-suffix rule in PRD-8 §4.5 — the engine emits the long name and the extension truncates, so the two never disagree about which tool a table means. |
| **D1 one resolver** | Federated tools enter through the `Toolset` protocol as one `%Context.Layer{}` per upstream (`lib/noizu/mcp/toolset/context.ex:17`). There is no second listing path and no parallel tool registry. `tools/list` on the engine is the ordinary behaviour default over a composed toolset. |
| **D2 effective materialization** | Upstream layers fold through the existing merge engine (`lib/noizu/mcp/toolset/merge.ex:44`), so operator overrides and ACL apply to federated tools exactly as to local ones. |
| **D3 runtime-only resolution** | Upstream rows are read at call time from the persistence provider. No upstream is captured at compile time. Static config seeds rows; it does not bypass them. |
| **D4 explicit participation** | An upstream federates because a row says so. No discovery, no scanning, no probing of a network range. |
| **D5 fail-closed per set, fail-open per server** | A down upstream contributes **no** tools and sets `status = 'error'`; the engine and every healthy upstream keep serving. A single upstream's failure never fails `tools/list`. |

---

## 3. Background

ADR-001 through 006 make any single Streamable HTTP MCP server queryable from SQL. The cost is per-server: a `CREATE SERVER`, a `USER MAPPING`, an `IMPORT FOREIGN SCHEMA`, and a network path from the Postgres pod to that server. Three things fall outside that: stdio servers, which have no URL at all; servers on networks Postgres cannot reach; and servers whose auth is an OAuth flow rather than a static bearer. It also makes attaching an MCP a DBA task with a credential landing in a Postgres catalog.

The library already holds the missing half. `Noizu.MCP.Client` (`lib/noizu/mcp/client.ex:60`) is a GenServer client with `await_ready/2` (`:75`), `list_tools/2` (`:170`), `call_tool/4` (`:158`), and — critically for refresh — an `:on_notification` option (`client.ex:35`, wired at `:388`, mirrored at `:917-919`) that forwards every upstream notification to a pid. It runs over `Noizu.MCP.Transport.Stdio.Client` (`lib/noizu/mcp/transport/stdio_client.ex:1`) and `Noizu.MCP.Transport.StreamableHTTP.Client` (`transport/streamable_http/client.ex:2`), both driven by the sans-IO `Noizu.MCP.Peer` state machine (`lib/noizu/mcp/peer.ex:53`).

The composition machinery is likewise present. `%Toolset.Custom{}` (`lib/noizu/mcp/toolset/custom.ex:61`) composes a base with weighted layers through `compose/3` (`:97`); `Toolset.Context` supplies `layers/3` (`context.ex:59`) returning `%Layer{id, weight, ops}` (`context.ex:17`); `Merge.fold/1` (`merge.ex:44`) resolves them. Series 1 established the weight bands: persisted layers at 200, ACL at 300. Federation slots in **below** both, at weight 100, which is what makes an operator's override of a federated tool win and ACL filter it — for free, with no federation-specific code.

Persistence is a solved problem too: `Noizu.MCP.Persistence` (`lib/noizu/mcp/persistence.ex:62-86`) declares `put/4`, `get/3`, `list/3`, `delete/3`, `version/2` and `ping/1`, with Memory, Ecto and Disabled providers. The `servers` registry needs exactly those six operations and no new storage layer.

So the engine is not new machinery. It is a server module that wires a client pool into a toolset layer and exposes the pool's membership as a dataset. That is the whole idea, and it is why ADR-007 places it in the library rather than in a new product.

---

## 4. Public surface

### 4.1 `lib/noizu/mcp/engine.ex` — the server

```elixir
defmodule Noizu.MCP.Engine do
  use Noizu.MCP.Server,
    name: "noizu-mcp-engine",
    version: Mix.Project.config()[:version],
    sql: true,
    acl: Application.compile_env(:noizu_mcp, [:engine, :acl], nil)

  dataset Noizu.MCP.Engine.Servers, name: "servers"

  tool Noizu.MCP.Engine.Tools.Attach
  tool Noizu.MCP.Engine.Tools.Detach
  tool Noizu.MCP.Engine.Tools.Refresh
end
```

Options read at runtime (D3) from `:noizu_mcp, :engine`:

| Key | Meaning | Default |
|---|---|---|
| `:persistence` | provider module for the `servers` store | app-env default |
| `:store_key` | persistence store key | `:engine_servers` |
| `:acl` | ACL provider (series-1 PRD-2) | `nil` |
| `:static_servers` | list of upstream maps seeded at boot | `[]` |
| `:connect_timeout_ms` | per-upstream handshake budget | `10_000` |
| `:backoff` | `{initial_ms, max_ms, jitter}` | `{1_000, 60_000, 0.2}` |
| `:refresh_interval_ms` | periodic catalog re-list per upstream | `300_000` |

### 4.2 The `servers` dataset — `lib/noizu/mcp/engine/servers.ex`

Implements `Noizu.MCP.Server.Dataset` (PRD-9 §4.1) including all three optional write callbacks.

| Column | `SQL.Types` | Writable | Meaning |
|---|---|---|---|
| `name` | `:text` | insert only | primary key; the namespace prefix. Must match `^[a-z][a-z0-9_]{0,30}$`. |
| `transport` | `{:enum, ["stdio","http"]}` | yes | |
| `command` | `:text` | yes | stdio only; the argv, shell-split. NULL for http. |
| `url` | `:text` | yes | http only. NULL for stdio. |
| `auth_ref` | `:text` | yes | **a reference**, never a credential: `secret:<name>`, `infisical:<path>/<KEY>`, `env:<VAR>`, or `passthrough`. |
| `enabled` | `:boolean` | yes | |
| `status` | `{:enum, ["disconnected","connecting","ready","error","disabled"]}` | no | derived from the supervised session |
| `status_detail` | `:text` | no | last error message, redacted |
| `last_seen` | `:timestamptz` | no | last successful request |
| `tool_count` | `:bigint` | no | tools in the current layer |
| `protocol_version` | `:text` | no | negotiated with the upstream |
| `server_info` | `:jsonb` | no | upstream `serverInfo` |

**`auth_ref` is a reference and nothing else.** A value that looks like a credential — anything not matching one of the four documented forms — is rejected at insert with `invalid_params`. This is the one validation in the engine that exists purely to stop a foreseeable mistake: a person pasting a bearer token into a SQL `INSERT` where it lands in `pg_stat_activity`, the query log, and the persistence store. The error message says so.

`auth_ref = 'passthrough'` means the caller's own token is forwarded to that upstream (§4.6).

Write semantics:

- **`insert/2`** validates the row, persists it, and — if `enabled` — asks the supervisor to start a session. Returns the row with derived columns populated (`status` will be `connecting`). A duplicate `name` returns `invalid_params`.
- **`update/3`** persists changes and restarts the session when any of `transport`, `command`, `url`, `auth_ref` or `enabled` changed. Attempting to write a derived column returns `invalid_params` naming it.
- **`delete/2`** stops the session, drops the layer, and removes the row. Returns the count deleted.
- **`scan/3`** merges persisted rows with live session state; a row whose session is not running reads `status = 'disconnected'`. It honors no quals and lets Postgres re-check, per PRD-9 §4.1's one-directional contract — the registry is small enough that pushdown buys nothing.

### 4.3 Session supervision — `lib/noizu/mcp/engine/supervisor.ex`, `session.ex`

A `DynamicSupervisor` holding one `Noizu.MCP.Engine.Session` GenServer per enabled upstream. Each session:

1. Resolves `auth_ref` to a credential at connect time, through `lib/noizu/mcp/engine/credentials.ex` (§4.7).
2. Starts a `Noizu.MCP.Client` (`client.ex:60`) over the right transport, passing `on_notification: self()` (`client.ex:35`).
3. `await_ready/2` (`client.ex:75`) within `connect_timeout_ms`, then lists tools, prompts, resources and — when the upstream advertises `experimental.sql` — `sql/schema`.
4. Publishes the resulting layer and sets `status = 'ready'`, `last_seen`.
5. On any failure: `status = 'error'`, `status_detail` set to a **redacted** message, layer emptied, reconnect after backoff.

Backoff is exponential with jitter from `{initial_ms, max_ms, jitter}`, reset on a successful handshake. A session never crashes its supervisor on a connection error — a permanently unreachable upstream retries at `max_ms` forever and costs one idle process. Only a programming error crashes, and the supervisor's restart intensity then applies normally.

**Refresh triggers**: an upstream `notifications/tools/list_changed`, `prompts/list_changed` or `resources/list_changed` arriving through `on_notification` re-lists that surface immediately; `refresh_interval_ms` re-lists periodically as a backstop; `engine.refresh` forces one. After any re-list that changed the layer, the engine emits its own `notifications/tools/list_changed` downstream, so a connected `pg_mcp` sees the change through PRD-7 §4.10.

### 4.4 Federation into the Toolset — `lib/noizu/mcp/engine/toolset.ex`

Implements `Noizu.MCP.Toolset.Context` (`lib/noizu/mcp/toolset/context.ex:59`), returning one `%Layer{}` (`context.ex:17`) per ready upstream:

```elixir
%Noizu.MCP.Toolset.Context.Layer{
  id: {:upstream, "github"},
  weight: 100,
  ops: [ %Override{slot: {:tool, "github.create_issue"}, op: :add, ...}, ... ]
}
```

Normative rules:

- **Weight 100**, below persisted (200) and ACL (300). Operator overrides win over federated definitions; ACL filters them. No federation-specific precedence logic exists.
- **Namespacing**: every upstream tool `t` becomes `<server>.<t>`. Prompts and resources are namespaced the same way; resource URIs get a `mcp+engine://<server>/` prefix so they stay globally unique and reversible.
- **Collisions** across upstreams are impossible by construction, since the prefix is the primary key of `servers`. A collision between a federated name and an engine-local tool (`engine.attach`) is prevented by reserving the `engine` prefix: a `servers` row named `engine` is rejected at insert.
- **Dispatch**: `invoke/5` on a federated entry splits the prefix, finds the session, and calls `Client.call_tool/4` (`client.ex:158`) with the caller's `%Ctx{}` carried as request metadata. The upstream's `CallToolResult` is returned unmodified, `isError` included.
- **A down upstream contributes an empty layer** (D5). It does not error, and it does not remove the other upstreams' tools.
- Federated `sql/*` relations from an upstream advertising `experimental.sql` are re-exported by the engine's own `sql/schema` as `<server>.<relation>`, and `sql/scan` on one proxies to that upstream's `sql/scan`.

### 4.5 ACL

The engine's ACL provider (series-1 PRD-2) receives entries whose names carry the upstream prefix, so a policy can be written at either granularity:

- Whole upstream: deny every entry matching `github.*`.
- Single tool: deny `github.delete_repo`.

Two rules are normative. A principal denied an upstream sees none of its tools **and** no row for it in `servers` — the registry dataset filters on the same ACL, so the existence of an upstream is not leaked to someone who cannot use it. And a denied tool returns the same `invalid_params` an absent tool returns, preserving series 1's no-discovery-oracle property (AP-3, AP-P4).

### 4.6 Token pass-through

`auth_ref = 'passthrough'` forwards the caller's bearer token to that upstream instead of a stored credential. It is off unless explicitly set, and it carries three constraints:

1. The engine does not inspect or re-sign the token; it forwards the raw credential.
2. A pass-through upstream cannot use a pooled session, because the session is per-caller. The engine keeps a short-lived per-principal session, evicted after `passthrough_idle_ms` (default 60s).
3. A caller with no token calling a pass-through upstream gets `42501`-equivalent `forbidden`, not an anonymous upstream call.

The trade-off is stated plainly in `docs/arch/engine.md`: pass-through gives the upstream the caller's real identity, at the cost of session pooling and of the engine no longer being the only holder of upstream credentials.

### 4.7 Credential resolution — `lib/noizu/mcp/engine/credentials.ex`

| `auth_ref` form | Resolution |
|---|---|
| `env:VAR` | `System.get_env("VAR")` |
| `secret:<name>` | a configured `{module, function}` resolver, so a host wires its own secret store |
| `infisical:<path>/<KEY>` | the `secret:` resolver with an Infisical-shaped argument; the library ships no Infisical client |
| `passthrough` | §4.6 |

A reference that fails to resolve sets `status = 'error'` with `status_detail = "auth_ref could not be resolved"` — the reference name is included, the resolved value never is. Resolution happens at connect time and on refresh, never at insert time, so a row can be created before its secret exists.

### 4.8 Engine tools

| Tool | Arguments | Behavior |
|---|---|---|
| `engine.attach` | `name`, `transport`, `command`/`url`, `auth_ref`, `enabled` | same path as `servers` insert — one implementation, called by both |
| `engine.detach` | `name` | same path as `servers` delete |
| `engine.refresh` | `name` (optional; all when absent) | forces a re-list; returns per-upstream status |

These exist so an MCP client with no SQL can manage the engine. They are thin wrappers over the dataset callbacks, not a second implementation (D1).

### 4.9 Deployment

**Embedded**: mount `Noizu.MCP.Engine` behind the existing Streamable HTTP plug, exactly as any other server:

```elixir
plug Noizu.MCP.Transport.StreamableHTTP.Plug, server: Noizu.MCP.Engine, auth: my_verifier
```

**Standalone**: `mix mcp.engine`, following the option style already established by `mix mcp.client` (`lib/mix/tasks/mcp.client.ex:20-25`):

```
mix mcp.engine --port 4040 --persistence ecto --repo MyApp.Repo
mix mcp.engine --attach 'github=stdio:npx -y @modelcontextprotocol/server-github'
```

| Option | Meaning |
|---|---|
| `--port PORT` | Bandit listener port (default 4040) |
| `--persistence memory\|ecto` | provider (default memory) |
| `--repo MODULE` | Ecto repo when `--persistence ecto` |
| `--attach SPEC` | repeatable; `name=stdio:CMD` or `name=http:URL` |
| `--no-auth` | bind loopback-only with no verifier, for local use |

`--no-auth` binds to `127.0.0.1` and refuses any other bind address, mirroring the `auth 'none'` loopback rule in PRD-6 §4.2.

### 4.10 What Postgres sees

One `CREATE SERVER` pointing at the engine, one `USER MAPPING` per role, and:

```sql
IMPORT FOREIGN SCHEMA mcp FROM SERVER engine INTO public
  OPTIONS (per_tool 'true', all_upstreams 'true');
```

yields one schema per enabled upstream plus the engine's own — the mechanics are PRD-7 §4.11 and PRD-8 §4.6, driven by the `<server>.<name>` namespacing above. **`all_upstreams` is required here and defaults to `false`** (PRD-7 FR-7.19): without it the import produces a single schema whose tool names carry the `<upstream>.` prefix inline. The opt-in is deliberate, so that a later `INSERT INTO engine.servers` cannot silently change what a re-import produces (§9 Q1). Attaching an MCP afterwards is:

```sql
INSERT INTO engine.servers (name, transport, command, auth_ref, enabled)
VALUES ('github', 'stdio', 'npx -y @modelcontextprotocol/server-github', 'env:GITHUB_TOKEN', true);
SELECT mcp.refresh('engine');
SELECT * FROM mcp.generate_functions('engine', 'github');
```

---

## 5. Requirements

**FR-11.1** `Noizu.MCP.Engine` is a `use Noizu.MCP.Server` module registering the `servers` dataset and the three engine tools.
**FR-11.2** The `servers` dataset implements `columns/0`, `info/0`, `scan/3`, `insert/2`, `update/3` and `delete/2` with the §4.2 columns.
**FR-11.3** Rows persist through the configured `Persistence` provider using only `put/4`, `get/3`, `list/3`, `delete/3` and `version/2` (`lib/noizu/mcp/persistence.ex:62-79`); the engine adds no storage layer.
**FR-11.4** `auth_ref` accepts only `env:`, `secret:`, `infisical:` and `passthrough` forms; anything else is rejected at insert with a message explaining that credentials must not be inlined.
**FR-11.5** A resolved credential never appears in a row, a log line, a `status_detail`, a telemetry payload, or an error message.
**FR-11.6** One supervised session per enabled upstream, with exponential backoff and jitter per `:backoff`, reset on successful handshake.
**FR-11.7** A failed or unreachable upstream sets `status = 'error'` and contributes an empty layer; the engine's `tools/list` still returns every healthy upstream's tools (D5).
**FR-11.8** Upstream tools, prompts and resources are namespaced `<server>.<name>`; resource URIs are prefixed `mcp+engine://<server>/`.
**FR-11.9** Each ready upstream contributes exactly one `%Context.Layer{}` at weight 100, folded by the existing merge engine.
**FR-11.10** A `servers` row named `engine` is rejected; the prefix is reserved.
**FR-11.11** `invoke/5` on a federated tool proxies to `Client.call_tool/4` and returns the upstream result unmodified, `isError` included.
**FR-11.12** Upstream `list_changed` notifications, received via `:on_notification` (`lib/noizu/mcp/client.ex:35`), re-list that surface and, when the layer changed, emit the engine's own downstream `list_changed`.
**FR-11.13** `refresh_interval_ms` re-lists periodically; `engine.refresh` forces one.
**FR-11.14** ACL applies to federated entries by prefixed name; a principal denied an upstream sees neither its tools nor its `servers` row.
**FR-11.15** A denied tool returns the same error an absent tool returns.
**FR-11.16** `auth_ref = 'passthrough'` forwards the caller's token, uses a per-principal session evicted after `passthrough_idle_ms`, and refuses a caller with no token.
**FR-11.17** `engine.attach`, `engine.detach` and `engine.refresh` call the same code paths as the dataset callbacks.
**FR-11.18** `mix mcp.engine` runs the engine on Bandit with the §4.9 options; `--no-auth` binds loopback-only.
**FR-11.19** An upstream advertising `experimental.sql` has its relations re-exported as `<server>.<relation>` through the engine's `sql/schema`, and `sql/scan` proxies.
**FR-11.20** `mix.exs` `@version` becomes `"0.4.0"`; CHANGELOG gains a `0.4.0` section covering PRD-6, 9 and 11.
**FR-11.21** Docs: `guides/engine.md` (operator: attach, credentials, deployment, the SQL story) and `docs/arch/engine.md` (design: layering, weights, pass-through trade-off, failure semantics).

**Acceptance criteria**

**AC-11.1** With two stdio fixture upstreams attached, `tools/list` on the engine equals the union of both upstreams' `tools/list`, every name prefixed, no duplicates, no omissions.
**AC-11.2** `sql/scan` on `servers` returns one row per attached upstream with live `status` and `tool_count`.
**AC-11.3** `sql/modify` insert on `servers` attaches a stdio fixture server; within the connect timeout its tools appear in `tools/list` and its `status` reads `ready`.
**AC-11.4** `sql/modify` delete removes the row, stops the session, and removes its tools from `tools/list`.
**AC-11.5** Attaching a deliberately broken upstream sets `status = 'error'`, leaves every other upstream's tools intact, and does not fail `tools/list`.
**AC-11.6** Killing a ready upstream mid-session flips `status` to `error` and back to `ready` after it returns, with no operator action.
**AC-11.7** `tools/call` on `github.create_issue` reaches the upstream's handler and returns its result byte-identically, including an `isError` result.
**AC-11.8** An upstream emitting `notifications/tools/list_changed` causes the engine to re-list and emit its own downstream notification.
**AC-11.9** An `auth_ref` containing a raw token is rejected at insert with the explanatory message; nothing is persisted.
**AC-11.10** With a resolver returning a distinctive secret, that value appears in no row, log, telemetry event or error across every failure path.
**AC-11.11** Two principals with different ACLs see different `tools/list` and different `servers` row sets over the same engine.
**AC-11.12** A pass-through upstream receives the caller's token; a caller with no token gets `forbidden` and the upstream receives no request.
**AC-11.13** An operator override of a federated tool wins over the upstream definition, and ACL still filters the overridden tool — asserted without any federation-specific precedence code.
**AC-11.14** `mix mcp.engine --attach 'x=stdio:...'` serves that upstream's tools over Streamable HTTP; `--no-auth` refuses a non-loopback bind.
**AC-11.15** `mix test` fully green; `mix format --check-formatted`, `mix credo`, `mix dialyzer` clean; no new warnings.
**AC-11.16** `mix.exs` reports `0.4.0`; `mix hex.build` succeeds and the tarball contains no `pg/` path.

---

## 6. Internal work checklist (with anchors)

| Step | File | Anchor / detail |
|---|---|---|
| 11.1 | `lib/noizu/mcp/engine.ex` | new; §4.1 server module, `sql: true` (PRD-9 §4.6), `acl:` (series-1 PRD-2) |
| 11.2 | `lib/noizu/mcp/engine/servers.ex` | new; dataset per PRD-9 §4.1; persistence via `lib/noizu/mcp/persistence.ex:62-79` |
| 11.3 | `lib/noizu/mcp/engine/supervisor.ex` | new; `DynamicSupervisor` over sessions |
| 11.4 | `lib/noizu/mcp/engine/session.ex` | new; wraps `Noizu.MCP.Client.start_link/1` (`client.ex:60`), `await_ready/2` (`:75`), `on_notification: self()` (`:35`, wired `:388`, mirrored `:917-919`) |
| 11.5 | `lib/noizu/mcp/engine/toolset.ex` | new; `Toolset.Context` impl (`toolset/context.ex:59`) emitting `%Layer{}` (`context.ex:17`) at weight 100, folded by `merge.ex:44` |
| 11.6 | `lib/noizu/mcp/engine/credentials.ex` | new; §4.7 resolution + redaction |
| 11.7 | `lib/noizu/mcp/engine/tools/{attach,detach,refresh}.ex` | new; thin wrappers over the dataset callbacks |
| 11.8 | `lib/mix/tasks/mcp.engine.ex` | new; option style from `lib/mix/tasks/mcp.client.ex:20-25` |
| 11.9 | `test/support/fixture_engine.ex` | new; stdio fixture upstreams, a broken upstream, a two-principal ACL, a secret resolver |
| 11.10 | `lib/noizu/mcp/test.ex` | reuse PRD-9's `sql_scan/3`/`sql_modify/3` helpers; add `attach_upstream/2` |
| 11.11 | `guides/engine.md`, `docs/arch/engine.md`, `README.md`, `CHANGELOG.md` | FR-11.21, FR-11.20 |
| 11.12 | `mix.exs` | `@version` `0.3.0` → `0.4.0` (`mix.exs:4`); confirm `pg` excluded from `package.files` (PRD-6 step 6.10) |
| 11.13 | Transports | **no change.** `transport/stdio_client.ex:1` (`Noizu.MCP.Transport.Stdio.Client`) and `transport/streamable_http/client.ex:2` are consumed as-is. |

---

## 7. Test plan

New tests under `test/noizu/mcp/engine/`:

- **`servers_dataset_test.exs`** — columns, insert/update/delete round trips, duplicate name, reserved `engine` name, derived-column write rejection, `auth_ref` validation (AC-11.9), persistence provider interaction asserted against Memory and the Ecto fixture (`test/support/fixture_persistence_db.ex`).
- **`session_test.exs`** — connect, ready, backoff schedule (asserted on the computed delays, not by sleeping), reset on success, error status and redaction, reconnect after an upstream returns (AC-11.6).
- **`federation_test.exs`** — union property (AC-11.1), namespacing, empty layer for a down upstream (AC-11.5), proxied `tools/call` including `isError` (AC-11.7), notification-driven refresh (AC-11.8).
- **`layering_test.exs`** — weight-100 placement: an operator override at 200 wins, ACL at 300 filters, with no federation-specific code in the path (AC-11.13).
- **`acl_test.exs`** — two principals, two tool sets, two `servers` row sets (AC-11.11); denied tool error equals absent tool error (FR-11.15).
- **`passthrough_test.exs`** — token forwarded, per-principal session, idle eviction, tokenless caller refused with no upstream request (AC-11.12).
- **`mix_task_test.exs`** — `--attach` parsing, `--no-auth` loopback enforcement (AC-11.14).

### 7.5 Conformance suite

`test/support/engine_conformance_case.ex`, following `persistence_conformance_case.ex` and `store_conformance_case.ex` in `test/support/`, and composing with PRD-9's `sql_conformance_case.ex`. It asserts the three properties any engine deployment must hold: federated `tools/list` equals the union of upstream lists, `sql/scan` over `servers` agrees with the live session states, and an insert attaches a real stdio fixture server end to end.

### 7.6 Anti-pattern regression tests

- **AP-P13 (credential in a row):** no code path writes a resolved credential into the `servers` store, a log, a telemetry payload or an error. Asserted by driving every failure path with a distinctive secret and grepping every captured output (AC-11.10).
- **AP-P14 (parallel registry):** federated tools reach `tools/list` only through the Toolset layer. Asserted by mutating an upstream's tool set and confirming the engine's list follows without any cache-clearing call, and structurally by there being no engine-owned tool map outside the layer.
- **AP-P15 (one upstream fails all):** a broken upstream never removes a healthy upstream's tools or fails `tools/list` (D5, AC-11.5).
- **AP-P16 (federation bypasses ACL):** every federated entry passes through the same ACL layer as a local tool. Asserted by a principal denied `github.*` receiving the absent-tool error on a direct `tools/call`, not a successful proxy.
- **AP-P17 (upstream existence oracle):** a principal denied an upstream sees no `servers` row for it, so the registry cannot be used to enumerate what one may not use.

---

## 8. Compat & rollback

- **Additive to the library.** The engine is new modules plus one new Mix task. No existing module changes shape; no callback, `__mcp__/1` key or wire response is altered. A host that never references `Noizu.MCP.Engine` is unaffected, and the engine's own dependencies (client, peer, transports, persistence, toolset) are all already present.
- **`0.4.0` is a minor bump.** Consumers pinning `~> 0.3` do not pick it up; the CHANGELOG recommends `~> 0.4` and lists PRD-6, 9 and 11's surfaces.
- **Publish**: user-run `mix hex.publish` with 2FA, per the series-1 standing rule. Agents never publish and never touch hex keys. Tag `v0.4.0`.
- **Rollback**: revert the PR. The only persisted artifact is the `servers` store; a rollback leaves those rows orphaned in whatever provider held them, harmless and re-readable if the engine returns. No migration, no wire-format change for any other server.
- **Risk watch — the engine is a new long-running component.** It holds N upstream connections, N supervised processes, and credentials in memory. That is a materially different operational profile from a library, and it is the real cost of ADR-007's convenience. `docs/arch/engine.md` says so and `servers.status` is the health surface.
- **Risk watch — two hops.** Every federated call is caller → engine → upstream. PRD-6 §7.5 S4's latency budget applies to the *first* hop only; the engine adds a second. The engine's catalog caching keeps `tools/list` to one hop, but `tools/call` is unavoidably two. If S4 was marginal, federated per-row invocation is worse than direct.
- **Risk watch — pass-through weakens the credential story.** ADR-007's headline is that the engine holds upstream credentials. `passthrough` opts out of that per upstream, and defeats session pooling. It is off by default and documented as an exception.

---

## 9. Open questions

1. **Q1 (blocking PRD-7/8's import shape):** Does `IMPORT FOREIGN SCHEMA` against the engine create one Postgres schema per upstream automatically, or does the operator import each upstream's schema explicitly by name? Automatic is the "install once" promise; explicit is far more predictable, since an attach would otherwise silently change what a re-import produces. Recommend explicit `LIMIT TO`-style selection with an `all_upstreams 'true'` opt-in.
2. **Q2 (blocking):** Where does the engine actually run in the Noizu cluster? ADR-007 defers "a dedicated deployable app" to a follow-up outside this repo, which leaves the primary path with no deployment target. Embedded in an existing host app, or standalone via `mix mcp.engine` in a container someone must build?
3. **Q3:** The `secret:` resolver is a `{module, function}` the host wires. Should the library ship an Infisical resolver given the monorepo already standardizes on Infisical, or does that dependency belong outside a general-purpose library? Recommend outside; the `infisical:` prefix is then just a naming convention the host's resolver interprets.
4. **Q4:** Pass-through sessions are per-principal and idle-evicted. Under many concurrent principals against one pass-through upstream this is a connection multiplier. Should pass-through be capped, or refused for stdio upstreams entirely (where a session means a spawned OS process)? Recommend refusing pass-through for stdio.
5. **Q5:** `servers.status` is derived, not persisted. A restarted engine reports `disconnected` for everything until sessions establish. Confirm that is right rather than persisting last-known status, which would be stale and misleading.
6. **Q6:** Namespacing uses `.` (`github.create_issue`). Series 1 left dotted-name canonicalization host-side (PRD-1 Q4, NPL's `ToolNames.canonical/1`). Confirm `.` does not collide with any host's existing dotted convention, and that PRD-8 §4.5's identifier derivation turns `github.create_issue` into `github_create_issue` or a per-upstream schema plus `create_issue` — these are different SQL shapes and Q1 decides which.
7. ~~**Q7:** ADR-007 named the stdio client `Transport.StdioClient`.~~ **Resolved 2026-09-05** — ADR-007 now reads `Noizu.MCP.Transport.Stdio.Client`, matching `lib/noizu/mcp/transport/stdio_client.ex:1`. No open question remains.
