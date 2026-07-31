# Authentication (OAuth 2.1)

MCP's authorization model (HTTP transports only): the MCP server is an OAuth
2.1 **resource server**; tokens are issued by an authorization server
discovered via RFC 9728 protected-resource metadata. `noizu_mcp` implements
both halves of that — enforcement on the server, the full flow on the client.

> #### The authorization server {: .info}
>
> Until 0.1.5 this guide said the library never implements an authorization
> server. As of 0.1.5 it does: `Noizu.MCP.Auth.Server` is an OAuth 2.1 **AS
> facade**, because the alternative was worse. Claude Desktop and claude.ai
> accept OAuth+DCR (RFC 7591), OAuth+CIMD, or a pre-registered `client_id` — and
> Authentik, the IdP behind these apps, has not supported DCR since the request
> was filed in 2024. The facade delegates *end-user authentication* to the host's
> existing IdP login and owns only the OAuth client, code and token semantics.
>
> See [Authorization Server](authorization_server.md) to mount it, and
> [MCP client compatibility](mcp_client_compatibility.md) for what each real
> client needs. This guide stays about the **resource server** half — enforcing
> tokens on your MCP mounts — which is what you need whether the tokens come from
> the facade or from an IdP that can already do the job.

## Server side: enforcing tokens

The quickest correct mount uses the built-in audience-checking verifier:

```elixir
resource = "https://app.example.com/mcp/learning"

forward "/mcp/learning", Noizu.MCP.Transport.StreamableHTTP.Plug,
  server: MyApp.Learning.MCP,
  origins: :mcp_clients,
  cors: true,
  auth: [
    verifier: {Noizu.MCP.Auth.JWTVerifier, [
      resource: resource,           # `aud` must match this exactly
      issuer: "https://app.example.com",
      secret: {MyApp.MCPAuth, :secret},
      algorithms: ["HS256"],        # from config, never from the token header
      scopes: ["mcp"]
    ]},
    resource_metadata: :derive,
    scope: "mcp"
  ]
```

`resource` is the whole point: a token minted for `https://app.example.com/mcp`
is **rejected** here, and a token minted here is rejected at `/mcp`. Audience
binding per mount is what keeps one mount from acting as a confused deputy for
its neighbour, so give every mount its own canonical URI and never share one.

`Noizu.MCP.Auth.Resource` is the comparison used: byte-exact, normalizing only
scheme/host case and the default port. `…/mcp` and `…/mcp/` are different
resources, deliberately.

### Accepting API keys alongside OAuth tokens

Headless callers cannot run a browser flow. `Noizu.MCP.Auth.ChainVerifier` tries
verifiers in order and takes the first success, so one mount serves both:

```elixir
auth: [
  verifier: {Noizu.MCP.Auth.ChainVerifier, [
    verifiers: [
      {Noizu.MCP.Auth.JWTVerifier, [resource: resource, secret: {MyApp.MCPAuth, :secret}]},
      {Noizu.MCP.Auth.ApiKeyVerifier, [
        resource: resource,
        prefix: "mcp_live_",
        validator: {MyApp.MCPKeys, :verify}   # your table, your hash comparison
      ]}
    ]
  ]},
  resource_metadata: :derive
]
```

Order the chain cheapest-first. When every link rejects, the client gets one
uniform `invalid_token` — a chain that reported *which* link rejected would tell
an attacker their string parsed as a JWT.

### Browser clients: CORS is not optional

claude.ai drives MCP from a browser context. Without `cors: true` the preflight
fails; and without the `Access-Control-Expose-Headers` it sets, the browser
cannot read `WWW-Authenticate` **at all**, so the client never learns where the
authorization server is and OAuth never starts. This failure is silent on the
server. `origins: :mcp_clients` allows the known browser MCP hosts plus
localhost and keeps the DNS-rebinding guard intact.

### A custom verifier

Implement `Noizu.MCP.Auth.TokenVerifier` and hand it to the plug:

```elixir
defmodule MyApp.MCPTokenVerifier do
  @behaviour Noizu.MCP.Auth.TokenVerifier

  @impl true
  def verify(token, _conn_info, _opts) do
    case MyApp.Auth.verify_jwt(token) do
      # IMPORTANT: validate audience (RFC 8707) — the token must be *for this server*
      {:ok, %{"aud" => "https://api.example.com/mcp"} = claims} ->
        if "mcp" in String.split(claims["scope"] || "", " "),
          do: {:ok, claims},
          else: {:error, :insufficient_scope, %{scope: "mcp"}}

      _ ->
        {:error, :invalid_token}
    end
  end
end

forward "/mcp", Noizu.MCP.Transport.StreamableHTTP.Plug,
  server: MyApp.MCP,
  auth: [
    verifier: {MyApp.MCPTokenVerifier, []},
    resource_metadata: "https://api.example.com/.well-known/oauth-protected-resource"
  ]
```

The plug then:

- rejects a request with **no** credential with **401** + a
  `WWW-Authenticate: Bearer` challenge carrying `resource_metadata` (how clients
  bootstrap discovery) and, when configured, `scope`. Per RFC 6750 §3.1 that
  challenge carries **no** `error` — nothing has failed yet
- rejects an invalid token with **401** and `error="invalid_token"`
- rejects `{:error, :insufficient_scope, %{scope: ...}}` with **403** and a
  `scope` hint (how clients know to step up)
- on success exposes the claims to every handler as
  `ctx.assigns.auth_claims`

One adjacent caution: hiding tools from `tools/list` (`hidden: true`, see
[Toolkits, Categories & Hidden Tools](toolkits_and_discovery.md)) is
presentation, not authorization — hidden tools remain callable by name.
Enforce real permissions here (token scopes, `ctx.assigns.auth_claims`
checks inside handlers), never via listing visibility.

Serve the RFC 9728 document next to it:

```elixir
forward "/.well-known/oauth-protected-resource", Noizu.MCP.Auth.ProtectedResourceMetadataPlug,
  resource: "https://api.example.com/mcp",
  authorization_servers: ["https://auth.example.com"],
  scopes_supported: ["mcp"]
```

With more than one mount, one forward answers them all — each path-inserted
suffix with its **own** `resource`, because a client that discovers the wrong
`resource` asks for a token with the wrong audience and is refused by the mount
it was trying to reach:

```elixir
forward "/.well-known/oauth-protected-resource", Noizu.MCP.Auth.ProtectedResourceMetadataPlug,
  authorization_servers: ["https://app.example.com"],   # exactly one: Claude reads [0]
  scopes_supported: ["mcp"],
  bearer_methods_supported: ["header"],
  default_resource: "/mcp",
  resources: %{
    "/mcp" => [resource: "https://app.example.com/mcp"],
    "/mcp/learning" => [resource: "https://app.example.com/mcp/learning"],
    "/mcp/workspace" => [resource: "https://app.example.com/mcp/workspace"]
  }
```

Each `resource` must **byte-match** the URL the user typed into their client. An
unknown suffix answers 404 rather than some other mount's document.

> #### Resolve these at runtime {: .warning}
>
> `forward` evaluates its options at **compile time**. Reading `System.get_env`
> there bakes build-time values into the release, and a prod `resource` that
> disagrees with the PRM document makes every client refuse to authenticate.
> Put the values in `config/runtime.exs` and reach them through the
> `{module, function}` / `{module, function, args}` forms of
> `auth[:resource_metadata]`, or `:derive`.

## Client side

### Static tokens

For machine-to-machine setups where you already hold a credential:

```elixir
transport: {:streamable_http,
  url: "https://api.example.com/mcp",
  auth: {Noizu.MCP.Auth.Static, token: System.fetch_env!("MCP_TOKEN")}}
```

### Full OAuth 2.1 flow

`Noizu.MCP.Auth.OAuth` runs the whole chain on the first 401:
`WWW-Authenticate` → RFC 9728 resource metadata (falling back to the
default well-known path on the MCP origin) → RFC 8414 / OIDC authorization
server discovery → PKCE (S256) authorization request with `state` and the
RFC 8707 `resource` indicator → code exchange → automatic refresh and
scope step-up on later 401/403s.

One thing cannot live in a library: putting the authorization URL in front
of a human. You supply that as the `authorize_user` callback:

```elixir
transport: {:streamable_http,
  url: "https://api.example.com/mcp",
  auth: {Noizu.MCP.Auth.OAuth,
    client_id: "my-client",
    redirect_uri: "http://localhost:8914/callback",
    scope: "mcp",
    authorize_user: &MyApp.OAuthBrowser.run/1}}
```

`authorize_user` receives the fully-built authorization URL and must return
`{:ok, %{"code" => code, "state" => state}}` — typically by opening the
browser and catching the redirect on a loopback listener (the
`redirect_uri` above). Return `{:error, reason}` to abort.

> #### Validate this seam early {: .tip}
>
> `authorize_user` is the API most likely to evolve before 1.0. If you wire
> it into a real product, please report friction.

### Custom strategies

Anything token-shaped can implement `Noizu.MCP.Auth.ClientStrategy`:
`init/1` (receives your opts plus `:mcp_url`), `headers/1` (returns headers
+ updated state), and `handle_unauthorized/3` (parse the challenge, refresh
or re-acquire, return `{:retry, state}` or `{:error, reason, state}`). The
transport retries a request at most twice after `{:retry, _}`.
