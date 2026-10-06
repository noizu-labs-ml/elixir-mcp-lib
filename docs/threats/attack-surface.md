# Attack Surface Enumeration

Full ingress/egress/store inventory backing the [THREAT-MODEL.md](../THREAT-MODEL.md)
diagram. Component locations: [../PROJ-LAYOUT.md](../PROJ-LAYOUT.md).

## Ingress (things that talk to a noizu_mcp server)

| Entry | Boundary crossing | Auth mechanism | Notes |
|---|---|---|---|
| Stdio transport | Local subprocess ↔ host process | Process ownership | Newline-delimited JSON-RPC; no auth (local trust) |
| Streamable HTTP Plug | Public internet ↔ server (via host router) | Token verifiers (`TokenVerifier`, `ApiKeyVerifier`, `ChainVerifier`, `Jwt*`); `Auth.Server` facade | POST/GET/DELETE + SSE; `Mcp-Session-Id`; TLS is host/edge responsibility |
| VFS unix socket | Local machine ↔ server | `vfs/auth` API-key handshake (verifier-configured) before any other method | Length-prefixed JSON-RPC; `-32001` on failed auth |
| VFS WebSocket (`GET /vfs`) | Browser/local ↔ server | Same `vfs/auth` path | Plug upgrade |
| OAuth AS endpoints | Browser ↔ host app | PKCE S256-only codes, hashed state, consent records | RFC 7591 DCR + CIMD client registry |
| Engine upstream callbacks | Upstream MCP ↔ Engine session | Upstream's own auth; `auth_ref` indirection or `passthrough` | One session per upstream, backoff reconnect |
| Agent keypair assertion | Client ↔ server | Ed25519 signature over hashed session id+nonce; JTI replay guard | `mcp_agent_*` tables |
| Sync worker | `mcp_sync_worker` PG role ↔ source/cache DBs | FORCE RLS + SECURITY DEFINER guards, `app_role` binding check | No network inside SQL; short transactions |

## Egress

| Exit | Destination | Credential involved |
|---|---|---|
| Client transports (Stdio.Client, StreamableHTTP.Client, VFS.Client) | MCP servers | `Auth.ClientStrategy` (OAuth 2.1 PKCE / static bearer) |
| Engine sessions | Upstream MCP servers | Stored `auth_ref` or caller's credential (passthrough) |
| Sync.RemoteSource | Upstream MCP server | Host-owned authenticated `Client` session (one per principal) |
| OAuth client strategy | IdP token/discovery endpoints | Client secret / PKCE verifier |

## Stores

| Store | Secret shape | At-rest protection |
|---|---|---|
| `mcp_oauth_*` tables | SHA-256 hashes (64 chars); PBKDF2 `secret_hash` | No plaintext columns; rows purged on expiry |
| `mcp_agent_*` tables | Public ids plaintext; hashes elsewhere; Argon2/PBKDF2 passwords | Revoked keys kept; append-only events |
| `mcp_sync.*` tables | `credential_ref` indirection only | RLS + role separation; no tokens stored |
| ETS persistence (default) | Toolset/grant metadata | In-memory only; no credentials |
| `:persistent_term` caches | Schemas, persistence resolution, VFS TTL cache | Derived, non-secret data |

## Explicitly out of scope (library)

TLS termination, ingress rate limiting, secret storage backend, host login
flow, socket directory permissions. The library supplies verification
mechanisms; deploying them behind a real perimeter is the host's job.
