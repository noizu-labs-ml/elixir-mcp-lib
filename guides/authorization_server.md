# Authorization Server (OAuth 2.1 facade)

`noizu_mcp` ships an OAuth 2.1 **authorization server facade** under
`Noizu.MCP.Auth.Server`. It exists because of a gap that has no other fix:

- Claude Desktop and claude.ai connectors will authenticate to an MCP server with
  OAuth + **dynamic client registration** (RFC 7591), OAuth + a **client-id
  metadata document** (CIMD), or a pre-registered `client_id`.
- **Authentik does not support RFC 7591** (goauthentik/authentik#8751, open since
  February 2024).

So an app whose IdP is Authentik cannot be an MCP OAuth server by pointing at its
IdP. This facade sits in front of the IdP you already have: it owns the OAuth
client registry, consent, authorization codes and token issuance, and delegates
*authenticating the human* to the host's existing login. The IdP never sees an MCP
client.

> #### What this is not {: .warning}
>
> This is not a general-purpose identity provider. It has no user database, no
> password handling, no account recovery, no SSO surface of its own. It issues
> tokens for MCP mounts on **one** host, for subjects that host has already
> authenticated. If you want an IdP, run an IdP.

## Mounting it

```elixir
# lib/my_app_web/mcp_config.ex — values resolved at RUNTIME, see the footgun below
def as_opts do
  Noizu.MCP.Auth.Server.config(
    issuer: issuer(),                                # origin, NO path
    store: {Noizu.MCP.Auth.Server.Store.Ecto, repo: MyApp.Repo},
    signing: {:hs256, {MyApp.MCPAuth, :secret}},
    scopes_supported: ["mcp"],
    resources: [
      [resource: issuer() <> "/mcp", name: "MyApp"],
      [resource: issuer() <> "/mcp/learning", name: "MyApp Learning"]
    ],
    dcr: [enabled: true, allowed_redirect_hosts: ["claude.ai"]],
    cimd: [enabled: true],
    upstream: {Noizu.MCP.Auth.Server.Upstream.HostSession,
               current_subject: {MyApp.Auth.MCPBridge, :current_subject},
               login_url:       {MyApp.Auth.MCPBridge, :login_url}},
    api_keys: [validator: {MyApp.MCPKeys, :verify}],
    rate_limit: {MyApp.RateLimit, :mcp_oauth}
  )
end
```

```elixir
# router.ex
scope "/" do
  forward "/.well-known/oauth-authorization-server",
          Noizu.MCP.Auth.Server.MetadataPlug, MCPConfig.as_opts()
  forward "/.well-known/openid-configuration",
          Noizu.MCP.Auth.Server.MetadataPlug, MCPConfig.as_opts()
  forward "/.well-known/oauth-protected-resource",
          Noizu.MCP.Auth.ProtectedResourceMetadataPlug, MCPConfig.prm_opts()
end

scope "/oauth" do
  pipe_through :browser_session          # session YES, require_authenticated NO
  forward "/", Noizu.MCP.Auth.Server.Router, MCPConfig.as_opts()
end

scope "/api/mcp" do
  pipe_through [:api, :rate_limited_auth]   # MUST skip protect_from_forgery
  forward "/token", Noizu.MCP.Auth.Server.ApiKeyTokenPlug, MCPConfig.as_opts()
end
```

Two pipeline requirements, and what each looks like when you miss it:

- `/oauth/authorize` and `/oauth/consent` need a **session** but must **not**
  require an authenticated user. With `require_authenticated` in the pipeline the
  flow can never reach the login redirect that would authenticate one, and the
  user sees a 401 loop.
- `/oauth/token`, `/register` and `/revoke` are called by machines with no cookie.
  If `protect_from_forgery` covers them, every token exchange fails with
  `InvalidCSRFTokenError` — *after* the browser leg succeeded, so it presents as a
  token bug rather than a routing one.

> #### Resolve configuration at runtime {: .error}
>
> `forward` evaluates its options at **compile time**. Reading `System.get_env`
> there bakes build-time values into the release, and a prod `issuer` or
> `resource` that disagrees with the protected-resource metadata makes **every
> client refuse to authenticate**. Put the values in `config/runtime.exs` and have
> `MCPConfig` read app env *inside* the functions. `Auth.Server.config/1` raises
> on an issuer with a path or a resource outside it, which catches the common
> half of this at boot.

## The flow

```
Claude                         Your app (AS facade)              Your IdP
  |                                   |                             |
  |-- GET /.well-known/… ------------>|  metadata: S256, "none", CIMD
  |-- POST /oauth/register ---------->|  a client row (or CIMD fetch)
  |-- GET /oauth/authorize ---------->|
  |                                   |-- not logged in? redirect -->|
  |                                   |<-- session established ------|
  |                                   |  consent screen (CSRF-protected)
  |<-- 302 ?code=…&state=…&iss=… -----|
  |-- POST /oauth/token ------------->|  atomic single-use code + PKCE
  |<-- access_token + refresh_token --|  aud = ONE mount, ≤15 min
  |-- POST /mcp/learning ------------>|  JWTVerifier checks aud exactly
```

## Store

`Noizu.MCP.Auth.Server.Store` is a behaviour with two shipped adapters:

| | |
|---|---|
| `Store.ETS` | In-memory, single node. Development, and single-replica deployments that can afford to lose OAuth state on restart (the cost is a re-login). Mutations run through a GenServer, which is what makes single-use redemption atomic. |
| `Store.Ecto` | Postgres, **raw SQL, zero Ecto schemas**. The library owns no tables — `priv/liquibase/noizu_mcp_oauth.yaml` is a template you copy into your own changelog directory. |

Adapters receive **raw** codes and tokens and must hash them (SHA-256, via
`Secret.token_hash/1`) before persisting or comparing. Hashing never lives in the
caller: a caller that forgot would write plaintext and no adapter could tell.

`take_authorization_code/2` and `rotate_refresh_token/3` must be genuinely atomic
*and* must distinguish "never existed" from "already used" — the second is a
replay, and a replay revokes the whole refresh family. Run
`Noizu.MCP.Auth.Server.StoreConformanceCase` against any adapter you write; two of
its tests race 20 concurrent redemptions of one credential, which is where a
plausible-looking adapter fails.

### Host tables

Copy `priv/liquibase/noizu_mcp_oauth.yaml`, renumber the changeSet ids, set
`author:`, add the include to your master changelog. Tables:
`mcp_oauth_clients`, `mcp_oauth_login_states`, `mcp_oauth_authorization_codes`,
`mcp_oauth_refresh_tokens`, `mcp_oauth_consents`, and optionally
`mcp_oauth_access_tokens` (only with `track_access_tokens: true`).

`subject` is plain `text`, not a foreign key — the library cannot assume you have
a `users` table or that its key is a uuid. An optional FK changeSet ships
commented out.

Nothing sweeps expired rows on its own. Run `purge_expired/2` yourself; a 15-minute
Oban job is the shape both of our apps use.

## Consent is not optional

Any client can register itself and then send an already-logged-in user to
`/oauth/authorize`. Without consent the server would issue that client a token on
the strength of the user's session alone — the user's own cookie authorizing a
stranger. That is the confused-deputy problem the MCP specification calls out.

So consent is **mandatory for every `:registered` and `:cimd` client**;
`consent: [enabled: false]` affects only `:preconfigured` clients, which an
operator created deliberately. Consent is remembered per `{subject, client_id}`,
is CSRF-protected, and **re-prompts when the requested scope broadens**.

Replace the built-in screen with `consent: [renderer: {MyAppWeb.MCPConsent, :render}]`;
the renderer gets `(conn, assigns)` with `:client`, `:scope`, `:resource`,
`:csrf_token`, `:action`, `:login_state`, `:subject`. If you render your own,
**escape the client name and the scope strings** — a self-registered client
chooses both, and they land on your origin.

## Upstream: who is the human?

`Upstream.HostSession` (the default) asks the host two questions:

```elixir
defmodule MyApp.Auth.MCPBridge do
  # (conn) -> {:ok, subject} | {:ok, %{subject: …}} | :none
  def current_subject(conn) do
    case conn.assigns[:current_user] do
      %{id: id} -> {:ok, to_string(id)}
      _ -> :none
    end
  end

  # (conn, return_to) -> where to send someone who needs to log in
  def login_url(_conn, return_to),
    do: "/sso/oidc?return_to=" <> URI.encode_www_form(return_to)
end
```

`return_to` is the authorization endpoint carrying only a login-state key, so no
scope, PKCE challenge or client `state` ends up in your access logs. **Validate it
same-origin** in your SSO controller anyway: the login screen is exactly where
someone will try an open redirect. The URL this module builds is always
same-origin with the issuer, so a same-origin check never rejects a legitimate one.

`Upstream.OIDC` is the fallback for a host with no session of its own. It
deliberately does **not** send the RFC 8707 `resource` parameter upstream:
Authentik's support is unconfirmed, and the upstream token is read for its `sub`
and discarded, so there is no audience to narrow.

## Security properties, and where each lives

| Property | Where |
|---|---|
| PKCE S256 mandatory for every client, no `plain` | `PKCE`, `AuthorizePlug.check_pkce/1` |
| `aud` is one canonical URI, exact-matched | `Tokens`, `Auth.JWTVerifier`, `Auth.Resource` |
| RFC 8707 `resource` may narrow, never widen | `Server.resolve_resource/2`, `TokenPlug` |
| **No token passthrough** | `Tokens` takes no inbound token; `no_passthrough_test.exs` |
| Consent before any IdP redirect or code, CSRF-protected, re-prompt on broadening | `Consent`, `AuthorizePlug` |
| Open-redirect discipline: unresolved client or bad `redirect_uri` → rendered 400 | `AuthorizePlug.start/3`, `PlugSupport.error_page/2` |
| SSRF guards on the CIMD fetch | `SSRF`, `CIMD` |
| Constant-time compares; nothing secret stored plaintext | `Secret`, the store adapters |
| Atomic single-use codes; refresh rotation with family revocation on replay | `Store` contract, both adapters, `TokenPlug` |
| Header-injection-safe `WWW-Authenticate` | `Auth.WWWAuthenticate.escape_quoted/1` |
| `error_description` never reflects input | `Errors` |
| `cache-control: no-store` on token/register/revoke | `PlugSupport.json/3` |
| Alg allowlist from config only | `JWTVerifier`, `Tokens` |
| Rate-limit hooks on `/register` and the API-key endpoint | `Server.rate_limit/3` |
| Access-token TTL ≤ 15 min (clamped) | `Server.config/1` |
| `iss` on every authorization response (RFC 9207) | `AuthorizePlug`, `PlugSupport.error_redirect/4` |

Deliberately out of scope: RFC 7592 client management
(`registration_access_token` and its CRUD — nothing in the MCP client ecosystem
uses it, and it is one more credential to leak), RS256 key rotation procedure, and
clustering `Store.ETS`.

## Headless callers

A cron job cannot open a browser. Two options:

1. **`ApiKeyTokenPlug`** — `POST /api/mcp/token` with your API key returns a
   short-lived, audience-bound access token and **no** refresh token (the key is
   already the long-lived credential). Best with several mounts: the key is
   presented once, and what travels to each mount is a token bound to that mount.
2. **`Auth.ApiKeyVerifier` in a `ChainVerifier`** on the mount itself — simpler
   for a single mount, at the cost of a long-lived key in every request log.

## Testing your integration

### Running the library's own suite

Two batteries are opt-in, and a plain `mix test` runs **neither**: the
`Store.Ecto` conformance battery needs a database, and every `:e2e` suite is
excluded by default because it spawns subprocesses and a real listener. This is
the only command that verifies the whole library:

```bash
cd libs/elixir-mcp
MCP_OAUTH_TEST_DATABASE_URL="postgres://USER:PASS@127.0.0.1:5432/noizu_mcp_test" \
  mix test --include e2e --include slow
```

| Flag / variable | Without it |
|---|---|
| `MCP_OAUTH_TEST_DATABASE_URL` | The entire `Store.Ecto` adapter is unverified |
| `--include e2e` | The end-to-end OAuth flow and the stdio transport are unverified |
| `--include slow` | Expiry tests (which sleep) do not run |

A run missing either of the first two **fails on purpose**, with a
`Noizu.MCP.CoverageGateTest` failure naming what did not execute. That gate
exists because it was once possible for a `Store.Ecto` that had never performed a
single `INSERT` to sit behind a green suite: the skipped run and the real run
reported the same passing count, in the same words. If you genuinely want a
partial run — a fast single-file loop, a machine with no Postgres — set
`MCP_SKIP_FULL_COVERAGE=1`. It still prints the banner; it just stops failing.

Read the skip and exclude counts, not only the passing one.

### Verifying a live mount

Before calling a mount healthy, each of these catches a specific failure:

```bash
# resource byte-matches the mount URL
curl -i https://host/.well-known/oauth-protected-resource/mcp/learning

# 401 + a challenge. 404 = router order wrong; 200 = auth not wired
curl -i -X POST https://host/mcp/learning

# the fields Claude gates on
curl -s https://host/.well-known/oauth-authorization-server | jq \
  '{code_challenge_methods_supported, token_endpoint_auth_methods_supported,
    client_id_metadata_document_supported, registration_endpoint}'
```

See [MCP client compatibility](mcp_client_compatibility.md) for what each real
client needs.
