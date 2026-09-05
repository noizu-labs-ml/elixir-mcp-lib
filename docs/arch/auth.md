# Authentication

## Overview

Authentication spans three layers: **client-side strategies** (how an MCP client acquires and refreshes credentials), **server-side verifiers** (how a transport validates presented tokens), and the **authorization-server facade** (a full OAuth 2.1 AS hosts can mount in front of their IdP).

## ClientStrategy behaviour

```elixir
@callback init(opts :: keyword()) :: {:ok, state}
@callback authenticate(req :: Req.Request.t(), state) :: {:ok, Req.Request.t(), state}
@callback handle_unauthorized(resp, req, state) :: {:retry, Req.Request.t(), state} | {:error, term()}
```

Transports call `authenticate/2` before every request and `handle_unauthorized/3` on 401 responses.

## OAuth (`Auth.OAuth`)

Full OAuth 2.1 authorization-code flow with PKCE (S256):

1. **Discovery** — RFC 9728 protected-resource metadata → RFC 8414 authorization-server metadata
2. **Authorization** — Builds the authorization URL with PKCE challenge and RFC 8707 `resource` parameter; delegates to the user's `:authorize_user` callback to drive the user-agent
3. **Token exchange** — Exchanges the authorization code for access/refresh tokens
4. **Refresh** — Automatic token refresh on expiry or 401; `insufficient_scope` triggers step-up re-authorization

Requires `Req` as an optional dependency.

## Static (`Auth.Static`)

Injects a fixed bearer token header. Suitable for API keys or pre-provisioned tokens.

## Server-side verification

A verifier family validates presented credentials on the server:

- `TokenVerifier` — server-side bearer-token verification for Streamable HTTP
- `ApiKeyVerifier` — accepts a raw API key presented as a bearer token
- `ChainVerifier` — tries verifiers in order, takes the first success
- `JwtVerifier` — audience-checking JWT verification for an MCP mount
- `CompoundJwtVerifier` — compound JWT verifier for dual-auth tokens

Supporting pieces: `Principal` (typed request identity — the ACL subject), `ProtectedResourceMetadataPlug` (RFC 9728 metadata), `WWWAuthenticate` (RFC 9110 challenge parse/format), and `Resource` (canonical RFC 8707/9728 resource identifiers).

## Authorization-server facade (`Auth.Server`)

An OAuth 2.1 authorization server **facade in front of an existing IdP**: the facade owns the MCP client registry (RFC 7591 dynamic registration + CIMD client_id-as-URL), consent, authorization codes, and token issuance — the IdP never sees an MCP client and no upstream token passes through. Authenticating the human delegates to an **upstream**: `Upstream.HostSession` (reuse the host app's session, default) or `Upstream.OIDC` (run an OIDC flow internally).

Mounted via plugs: `MetadataPlug` (RFC 8414 well-known docs), `Server.Router` (one forward for `/oauth/*` — authorize, token, register, revoke, JWKS), and optional `ApiKeyTokenPlug` (trade a host API key for a short-lived audience-bound access token).

Invariants: config is validated at boot (raise on misconfiguration — silent failures would surface as inexplicable client refusals); issuer is an origin with no path; access tokens are TTL-capped at 900s (no revocation path without a token table); RFC 8707 `resource` requests check against an audience allowlist; consent is mandatory for DCR/CIMD clients. SSRF guards protect server fetches of client-supplied URLs (CIMD). Backing stores: `Server.Store.Ecto` (Postgres, raw SQL — tables in `priv/liquibase/`) or `Server.Store.ETS` (in-memory).
