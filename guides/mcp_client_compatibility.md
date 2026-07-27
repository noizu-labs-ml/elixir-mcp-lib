# MCP client compatibility

What each real client will and will not do, verified against the MCP
specification revision **2025-11-25** and current client documentation. The
differences are not cosmetic: three of the entries below are the reason
`Noizu.MCP.Auth.Server` exists at all.

> #### This is a snapshot {: .warning}
>
> Client auth behaviour changes without notice and without a version bump you can
> detect. Treat the table as "what we saw", not as a contract, and re-check the
> manual assertions at the end of this guide after any client update.

## The matrix

| Client | Static bearer | OAuth + DCR | OAuth + CIMD | Pre-registered `client_id` |
|---|---|---|---|---|
| **claude.ai / Claude Desktop connectors** | org-admin beta only, shared org-wide | yes | yes | yes (Advanced settings) |
| **Claude Code** (`claude mcp add`) | yes (`--header`) | yes | yes | yes |
| **OpenAI Codex** (`codex mcp add`) | yes (`bearer_token_env_var`, `http_headers`) | yes (`--oauth-client-id`) | — | yes |
| **ChatGPT developer mode** | — | yes | — | yes |
| **MCP Inspector** | yes | yes | yes | yes |

### claude.ai and Claude Desktop

Custom connectors take a URL and run discovery. Points that decide whether it
works at all:

- **A static bearer header is an org-admin beta**, and the header is shared across
  the whole organization — one credential for every member. Not a per-user
  solution; do not design around it.
- Claude offers **CIMD only when the metadata document advertises *both***
  `client_id_metadata_document_supported: true` **and** `"none"` in
  `token_endpoint_auth_methods_supported`. With one of the two missing it falls
  back to dynamic registration silently — which looks like "CIMD doesn't work"
  rather than "the document is short a field".
- The **only** redirect URI to allow is
  `https://claude.ai/api/mcp/auth_callback`.
- `authorization_servers` in the protected-resource metadata must have **exactly
  one** entry. Claude reads `[0]` and does not fall back to `[1]`.
- The `resource` in that document must **byte-match** the URL the user typed. Not
  a trailing-slash variant, not a different case in the path.
- A **401 is required** to start the flow. A server that answers `200` with a
  JSON-RPC error, or `403`, does not trigger discovery — the connector just fails.
- Discovery happens in a **browser context**, so CORS is load-bearing: without
  `Access-Control-Allow-Origin` on the well-known documents, and
  `Access-Control-Expose-Headers: WWW-Authenticate` on the 401, the client cannot
  read the challenge and can never begin OAuth. This failure is completely silent
  on the server.
- Claude's egress range is **`160.79.104.0/21`**. It must reach both the MCP host
  *and* the authorization-server host — which for a path-based mount is the same
  host, one of the reasons to prefer that layout.

### Claude Code

```bash
# OAuth: opens a browser, no key to paste
claude mcp add --transport http trl https://app.therobotlearns.com/mcp

# Static bearer
claude mcp add --transport http trl https://app.therobotlearns.com/mcp \
  --header "Authorization: Bearer $TOKEN"

# stdio, no auth at all — best for local development
claude mcp add trl-learning -- mix trl.mcp.stdio --domain learning
```

> #### A rejected header does not fall back to OAuth {: .error}
>
> If you pass `--header "Authorization: Bearer …"` and the server rejects it,
> Claude Code **fails the connection**. It does not notice the 401 challenge and
> start OAuth instead. So a stale token in a config file presents as "the server
> is broken", and the fix (remove the header) is not one the error message
> suggests. Prefer OAuth unless the caller is headless.

Claude Code binds an **ephemeral loopback port** for its callback, so the port it
registers is never the port it returns on.
`Noizu.MCP.Auth.Server.RedirectURI` matches loopback URIs **port-agnostically** for
exactly this reason; a server doing exact matching rejects every callback.
Register `http://localhost/callback` and `http://127.0.0.1/callback`.

### OpenAI Codex

`~/.codex/config.toml`:

```toml
[mcp_servers.trl]
url = "https://app.therobotlearns.com/mcp"
bearer_token_env_var = "TRL_MCP_TOKEN"

[mcp_servers.trl.http_headers]
"X-Whatever" = "value"
```

or OAuth:

```bash
codex mcp add --url https://app.therobotlearns.com/mcp \
  --oauth-client-id <client_id> --oauth-resource https://app.therobotlearns.com/mcp
```

`--oauth-client-id` means Codex does **not** dynamically register — create a
`:preconfigured` client for it. `--oauth-resource` is the RFC 8707 indicator, and
it must be one of your configured `resources:` or the token request is
`invalid_target`.

### ChatGPT developer mode

Takes a URL and runs OAuth with dynamic registration. No static-header path.

## Path-based mounts, and why

Both of our apps mount at `https://<existing-host>/mcp*` rather than on a new
subdomain:

- Zero DNS, zero TLS, zero terraform. `api.therobotlearns.com` does not exist and
  `api.therobotknows.com` has its own TLS history.
- The MCP host and the authorization server are the same origin, so Claude's
  egress range reaches both by construction.
- The issuer stays an **origin with no path**, which collapses the RFC 8414
  path-insertion/suffix ambiguity to one URL.

The cost is that each mount needs its own protected-resource metadata document at
an RFC 9728 path-inserted URL —
`/.well-known/oauth-protected-resource/mcp/learning` describes
`https://host/mcp/learning`. `ProtectedResourceMetadataPlug`'s `resources:` map
answers all of them from one forward.

## Session handling

`Mcp-Session-Id` lives in a per-node ETS table. Two consequences:

- **`strategy: Recreate`, `replicas: 1`, autoscaling off.** A rolling update
  briefly runs two pods and splits requests across two independent session
  tables. Sticky routing on `Mcp-Session-Id` is *not available* — nginx-ingress
  affinity is cookie-based and cannot hash an arbitrary header.
- A restart costs a **session, not a request**: the plug answers `404` for an
  unknown session and a conformant client transparently re-initializes.

## Ingress requirements for SSE

Mandatory, not tuning — without the first two the stream simply stops working:

```yaml
nginx.ingress.kubernetes.io/proxy-buffering: "off"       # else the SSE stream buffers and the client hangs
nginx.ingress.kubernetes.io/proxy-read-timeout: "86400"  # else nginx kills the GET stream at 60s
nginx.ingress.kubernetes.io/proxy-send-timeout: "86400"
nginx.ingress.kubernetes.io/proxy-body-size: "10m"       # bounds bulk-authoring tool calls
```

## Two Phoenix traps

1. **Do not forward through an `:api` pipeline that has `plug :accepts, ["json"]`.**
   The SSE `GET` sends `Accept: text/event-stream` and Phoenix answers `406`.
   Forward from a bare `scope`. (`Plug.Parsers` is *not* the problem — the
   transport tolerates an already-parsed body.)
2. **Forward order is load-bearing.** The transport plug requires
   `path_info == []` after the forward, so domain mounts must precede the
   aggregator or `/mcp/learning` 404s:

   ```elixir
   forward "/mcp/workspace", …   # specific first
   forward "/mcp/learning", …
   forward "/mcp", …             # aggregator last
   ```

## Manual assertions before calling a mount healthy

Each one catches a specific failure above.

```bash
# 1. resource byte-matches the mount URL
curl -i https://host/.well-known/oauth-protected-resource/mcp/learning

# 2. 401 + challenge. 404 = forward order; 200 = auth not wired
curl -i -X POST https://host/mcp/learning

# 3. the stream stays open past 60s and arrives unbuffered
curl -i https://host/mcp/learning -H 'Accept: text/event-stream' \
     -H 'Authorization: Bearer …'

# 4. preflight echoes the requested header, and exposes www-authenticate
curl -i -X OPTIONS https://host/mcp \
     -H 'Origin: https://claude.ai' \
     -H 'Access-Control-Request-Headers: mcp-session-id'

# 5. the fields Claude gates on
curl -s https://host/.well-known/oauth-authorization-server | jq \
  '{code_challenge_methods_supported, token_endpoint_auth_methods_supported,
    client_id_metadata_document_supported, registration_endpoint,
    authorization_response_iss_parameter_supported}'
```

And one that is not an HTTP check: the server process must be **alive, not merely
routed**. A server module left out of `application.ex` compiles, routes, and is
dead, with no error anywhere.

```bash
kubectl exec … -- bin/my_app rpc 'Process.whereis(MyApp.Domains.Learning.MCP)'
```
