# Engine federation — design notes (ADR-007 / PRD-11)

`Noizu.MCP.Engine` is the reference `sql/*` server and the primary counterpart
of `pg_mcp`: an MCP server whose content is other MCP servers. This note is
the design record; `guides/engine.md` is the operator story.

## Shape

The engine is a plain `use Noizu.MCP.Server` module. It registers:

- the `servers` **dataset** (`Noizu.MCP.Engine.Servers`) — the upstream
  registry, writable through the ordinary Dataset behaviour
  (`insert/2`, `update/3`, `delete/2`);
- three **tools** (`engine.attach`, `engine.detach`, `engine.refresh`) that are
  thin wrappers over the same dataset callbacks — one implementation, called by
  both the SQL path and the tool path (D1);
- a **toolset implementation** that folds per-upstream layers into the one
  resolution path.

There is no engine-specific storage, registry or listing API anywhere.

## Layering: federation is just another layer

The engine's toolset protocol functions compose a
`%Noizu.MCP.Toolset.Custom{}` whose base is the engine's spec set: local
registrations plus every READY upstream's namespaced catalog, read per request
from live session state (D3). Per upstream the engine contributes exactly one
`%Noizu.MCP.Toolset.Context.Layer{}` at **weight 100** under
`{:upstream, name}`.

The bands are the series-1 defaults and nothing about federation is special:

| Weight | Layer | Effect |
|---|---|---|
| — | base specs (incl. federated catalog) | the surface |
| 100 | `{:upstream, name}` per ready upstream | federation provenance, folded by `Merge.fold/2` like any layer |
| 200 | persisted grants/negotiations | an operator's `:set_name`/`:set_description`/… of a federated tool WINS |
| 300 | ACL | denied federated tools are invisible and uncallable |

One deviation from the PRD sketch, recorded deliberately: the PRD §4.4 example
shows upstream tools entering as `:add` override ops. The 0.3.0 override
vocabulary is closed and has no `:add` — introducing a spec is the base
surface's job. Federated tools therefore enter as base specs (runtime-read,
AP-P14-compliant) and the weight-100 layers ride the fold for provenance,
versioning and ordering. Behaviorally identical: overrides and ACL apply to
federated tools with no federation-specific precedence code.

## The `servers` registry

Ordinary dataset semantics: `scan/3` merges persisted rows with live session
state and honors no quals (the registry is small; the caller re-checks per the
one-directional contract). Rows persist through the configured
`Noizu.MCP.Persistence` provider under the `"engine_servers"` store key — a
fourth record kind in the SHARED codec (AP-8), not a new storage layer. Only
operator columns persist; the derived columns (`status`, `status_detail`,
`last_seen`, `tool_count`, `protocol_version`, `server_info`) are live session
state, never written.

Validation exists to stop foreseeable mistakes:

- `name` must match `^[a-z][a-z0-9_]{0,30}$` (it becomes the namespace
  prefix); `engine` is reserved (it would collide with the engine's own
  tools);
- `transport` is `stdio` or `http`, with `command`/`url` mutual exclusion;
- `auth_ref` must be a reference (`env:`, `secret:`, `infisical:`,
  `passthrough`) — a credential-shaped value is rejected at insert with an
  explanatory message that does not echo the value (AP-P13).

## Sessions

One `Noizu.MCP.Engine.Session` per enabled upstream, started under the engine
tree's existing `DynamicSupervisor`. Each session resolves `auth_ref` at
connect time (never at insert), starts a `Noizu.MCP.Client` with
`on_notification: self()`, handshakes within `:connect_timeout_ms`, lists
tools/prompts/resources (plus `sql/schema` when the upstream advertises
`experimental.sql`), and publishes the catalog.

Failure posture (D5, fail-open per server):

- connect failures, transport death and re-list failures set `status = :error`
  with a redacted detail, empty the layer, and schedule a reconnect after
  exponential backoff with jitter, reset on a successful handshake;
- the session traps exits: a client's abnormal death is data, not death;
- a permanently unreachable upstream retries at `max_ms` forever — one idle
  process, never a crash, never a downed engine.

Refresh triggers: upstream `notifications/{tools,prompts,resources}/list_changed`
(mirrored through `:on_notification`), a periodic `:refresh_interval_ms`
backstop, and `engine.refresh`. A re-list that changes the tool layer has the
engine emit its own downstream `notifications/tools/list_changed`.

## Existence hiding

The registry filters rows on the SAME ACL that governs federated tools: a
row is hidden when the provider denies the tool-kind resource whose id is the
upstream's name. A principal denied `github.*` sees none of its tools and no
row for it — the registry cannot enumerate what one may not use (AP-P17). A
denied (or absent) tool resolves to the identical `invalid_params` shape
(AP-P16); the ACL layer at 300 runs inside the ordinary composition, so the
property holds with no federation-specific code.

## Pass-through

`auth_ref = 'passthrough'` forwards the caller's credential instead of a
stored one. Stated trade-offs (ADR-007's headline weakens per row):

- the engine does not inspect or re-sign the token; it forwards it raw
  (`Authorization` header for http, `MCP_PASSTHROUGH_TOKEN` env for stdio);
- invocation uses a per-principal session, idle-evicted after
  `passthrough_idle_ms` — a connection multiplier under many principals
  (PRD-11 Q4 recommends refusing pass-through for stdio for exactly this
  reason; the library allows it and the guide documents the cost);
- a pass-through row keeps a credential-free CATALOG session so its tools can
  be advertised at all; that session never proxies a call — the engine refuses
  a caller with no credential before any session or upstream request.

The caller's credential is taken from the principal per the documented
convention: `principal.metadata[:raw_token]`, then a `"token"` claim, then the
subject. Hosts that hold the raw bearer should place it there in their
principal mapping.

## Operational profile (the real cost of ADR-007)

The engine is a long-running component: N upstream connections, N supervised
sessions, credentials in memory. Every federated call is two hops
(caller → engine → upstream); `tools/list` is catalog-cached in session state
(one hop). `servers.status` is the health surface. A deployable engine app
with its own chart/image is a follow-up outside this repo.

## Test architecture

The suite drives REAL stdio fixture upstreams (`test/support/stdio_upstream.py`,
a dependency-free MCP responder): attach-to-ready, spawn failure, kill and
reconnect, notification-driven refresh, pass-through token delivery, and the
shared conformance battery (`test/support/engine_conformance_case.ex`) — the
three properties any engine deployment must hold.
