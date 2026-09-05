# lib/noizu/mcp/auth/ — Authentication & Authorization

```
auth/
├── server/                            # OAuth 2.1 authorization-server facade for MCP hosts
│   ├── cimd/
│   │   └── req_fetcher.ex             # Default CIMD fetcher over :req
│   ├── store/
│   │   ├── ecto.ex                    # Postgres store adapter (raw SQL)
│   │   └── ets.ex                     # In-memory store adapter
│   ├── upstream/
│   │   ├── host_session.ex            # Default upstream: reuse the host app's session
│   │   └── oidc.ex                    # Optional upstream: run an OIDC flow internally
│   ├── api_key_token_plug.ex          # Trade host API key for short-lived audience-bound token
│   ├── authorize_plug.ex              # Authorization endpoint + consent screen
│   ├── cimd.ex                        # Client-ID Metadata Documents: client_id as https URL
│   ├── client.ex                      # OAuth client of this server + admission validation
│   ├── config.ex                      # Validated config struct for the auth-server facade
│   ├── consent.ex                     # Consent policy and default consent screen
│   ├── errors.ex                      # OAuth error codes and rendering
│   ├── jwks_plug.ex                   # JWKS document (GET /oauth/jwks, RS256 only)
│   ├── metadata_plug.ex               # RFC 8414 authorization-server metadata
│   ├── params.ex                      # Parameter extraction for OAuth endpoints
│   ├── pkce.ex                        # PKCE (RFC 7636), S256 only
│   ├── plug_support.ex                # Shared plumbing for authorization-server endpoints
│   ├── redirect_uri.ex                # Redirect-URI validation and matching
│   ├── registration_plug.ex           # RFC 7591 dynamic client registration
│   ├── revoke_plug.ex                 # Token revocation (RFC 7009)
│   ├── router.ex                      # One forward for the whole authorization server
│   ├── secret.ex                      # Secret generation, hashing, constant-time comparison
│   ├── ssrf.ex                        # SSRF guards for server fetches of client-supplied URLs
│   ├── store.ex                       # Persistence contract for the auth-server facade
│   ├── token_plug.ex                  # Token endpoint (POST /oauth/token, two grants)
│   ├── tokens.ex                      # Mints access/refresh tokens and authorization codes
│   └── upstream.ex                    # Upstream-authentication configuration
├── api_key_verifier.ex                # Accepts a raw API key presented as bearer token
├── chain_verifier.ex                  # Tries verifiers in order, takes first success
├── client_strategy.ex                 # Client-side authorization strategy for Streamable HTTP
├── compound_jwt_verifier.ex           # Compound JWT verifier for dual-auth tokens
├── jwt_verifier.ex                    # Audience-checking JWT verifier for an MCP mount
├── oauth.ex                           # OAuth 2.1 client strategy (RFC 9728 discovery onward)
├── principal.ex                       # Typed request identity: who the caller is (PRD-2)
├── protected_resource_metadata_plug.ex  # Serves RFC 9728 protected-resource metadata
├── resource.ex                        # Canonical resource identifiers (RFC 8707/9728)
├── static.ex                          # Fixed bearer-token auth strategy
├── token_verifier.ex                  # Server-side bearer-token verification for Streamable HTTP
└── www_authenticate.ex                # Parse/format WWW-Authenticate challenges (RFC 9110)
```
