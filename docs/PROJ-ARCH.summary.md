# Architecture Summary

Noizu MCP is an Elixir MCP (Model Context Protocol) library using JSON-RPC 2.0. Provides both server and client implementations sharing a common sans-IO state machine (Peer). On top of the protocol core sits a frozen 0.3.0 extension architecture: toolsets, ACL authorization, persistence, a virtual filesystem, per-render-context descriptions with an eval harness, and an OAuth 2.1 authorization-server facade.

**Server DSL** — `use Noizu.MCP.Server` + `tool/resource/prompt` macros define servers. Capabilities auto-derived at compile time (incl. `vfs_write` from backend implementation). Behaviour callbacks available as escape hatch. Compile-time validation of `acl:`/`persistence:`/`providers:` opts.

**Client** — `Noizu.MCP.Client` GenServer wrapping Peer in client role. Manages transport lifecycle, handshake queuing, and server-initiated request dispatch (sampling, elicitation). Capabilities derived from Handler callbacks.

**Session** — One GenServer per connected client (server side). Delegates protocol state to Peer, spawns handler tasks via Task.Supervisor. Handles cancellation, progress, logging, resource subscriptions.

**Peer** — Pure state machine (no I/O). Ingests JSON-RPC messages, returns effects. Manages handshake, request tracking, cancellation. Shared between server and client roles.

**Toolsets (D1)** — Single resolution path (`catalog/resolve/invoke/permissions`) for `tools/list`, `tools/call`, and the catalog tool. Implementations materialize the effective surface (post-override) before validation/wire rendering. Explicit participants only (no `@derive`, fail-closed `Any` impl); a broken toolset disables itself, not the server (D5). Custom toolsets compose via include/exclude + closed-vocabulary overrides through a weighted merge (`Merge.fold/2`): static base → weight-200 persisted Grant/Negotiation layers (adjust/extend, never hide) → weight-300 ACL visibility gating. Anti-oracle: hidden tools resolve to the identical error as absent ones.

**Authorization (PRD-2)** — Binary-verdict `ACL.check/5 → :allow | :deny` over a host-implemented `ACL.Provider` seam; lib owns no policy. No provider ⇒ inert `:allow` (zero-change back-compat). Enforcement chokepoint `filter_entries/4` cannot be bypassed. ACL denials are silent; unsatisfied consent negotiations keep tools visible but `callable: false` — invoking is the one honest `:forbidden`. Subjects are `%Auth.Principal{}`.

**Persistence (PRD-4)** — Provider contract over three lib-owned stores (`toolsets`, `toolset_grants`, `toolset_negotiations`). Providers: Memory (ETS, default), Ecto (Postgres), Disabled (a no-layers policy). Lazy per-call selection (D3). `Store` write facade: put → version bump → per-toolset cache invalidate → best-effort notify fan-out (D5, never raises after a successful write). Boot gate (`Persistence.Ping`) fails server boot when an external provider is unreachable or tables are missing (D4).

**Migrations** — Lib tables ship as raw-SQL change sets (`%ChangeSet{}` thunks) applied by an Oban-shaped `Migration.Runner` the host delegates to from one Ecto migration. Ledger `noizu_mcp_schema_versions` bootstraps first; per-set transactions; missing `down` is an explicit error.

**Transports** — Three core pairs: Stdio/Stdio.Client (subprocess stdin/stdout), StreamableHTTP.Plug/StreamableHTTP.Client (POST/GET/DELETE + SSE, Req-based), Test/Test.Client (in-process); plus VFS transports (unix socket, WebSocket `GET /vfs`, Elixir client). SSE codec shared. EventStore backs Last-Event-ID resumability and buffers messages emitted while no stream is live — disconnect-surviving chunks replay on reconnect.

**Auth** — Client-side: `ClientStrategy` behaviour with OAuth 2.1 (PKCE, RFC 9728 discovery, refresh) and Static implementations. Server-side: token verifiers (bearer, API-key, chain, audience-JWT, compound JWT) and `Auth.Server` — an OAuth 2.1 authorization-server facade in front of the host IdP (RFC 7591 DCR + CIMD client registry, consent, token issuance; upstream human auth via host session or internal OIDC; access tokens TTL-capped at 900s).

**Descriptions & Eval** — Verbosity-variant description lists with named variants, `verbosity_map:`, and model/provider `runners:` (compile-time validated, nearest-level gap-fill 0–9). `RenderCtx` threads knobs through render sites. Inline `@eval` specs grade rendered descriptions via `mix noizu.mcp.eval` (pluggable Runner/Judge; deterministic stubs for CI).

**VFS** — Behaviour exposing backends as node trees with errno-mapped errors and version-stamped nodes; `:persistent_term` TTL cache generation-keyed per backend; `/etc/dev` control tree composed into every backend (tools/runtime/cache/config nodes). `daemon/mcp_mount` escript mounts a server as local files over WebSocket with bidirectional sync, conflict save-aside, and version-diff reconnect resync.

**Feature modules** — Tools, Resources, Prompts, Completion, VFS. Dispatch registered components, validate inputs via JSV schema, call user callbacks.

**Supervision** — Server module → Supervisor with Registry, TaskSupervisor, DynamicSupervisor (sessions), EventStore, persistence children (conditional boot gate), transport (stdio/vfs_socket). One persistence resolution per server at boot, stashed in `:persistent_term`. Client is a standalone GenServer.

**Inspector** — `Noizu.MCP.Inspector` supervisor (launched via `mix mcp.client`): Registry + DynamicSupervisor for sessions + Bandit on 127.0.0.1. Each session owns a `Noizu.MCP.Client` wrapped in `TapTransport` (mirrors frames for History tab); `Inspector.Handler` parks sampling/elicitation for browser responses (Pending tab). REST + SSE bridge with 500-event ring buffer. Random bearer token + localhost Origin check per run.

**Key decisions** — Sans-IO peer for testability; shared peer for both roles; task-per-request for responsiveness; macro DSL with behaviour escape hatch; persistent_term schema cache; EventStore for SSE resumability + disconnect survival; fail-closed ACL/persistence seams (inert when unconfigured); single toolset resolution path with anti-oracle error identity; lazy reads + best-effort write fan-out; fail-to-boot on broken persistence; 0.3.0 interface freeze (ADR + 0.4.0 to change).
