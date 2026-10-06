# Threat Model — Summary

Digest of `docs/THREAT-MODEL.md`. Keep in sync after register changes.

## Posture

Library (`noizu_mcp` v0.4.2) embedded by hosts; jewels = auth-primitive
correctness (verifiers, OAuth server, ACL), VFS backend confinement (host FS /
SQL escape = host compromise), artifact pipeline (manual hex publish;
mcp-mount/mcp-fuse/pg_mcp via GitHub Releases + DockerHub). Library vulns
amplify into every host. Boundaries: client → transport · credential →
verifier · server → VFS backend · library → upstream IdP · CI → artifacts ·
loopback daemon trust. Host obligations (stores, secrets, TLS, throttling)
stated explicitly, never implied.

## Register Counts

**13 mitigated · 2 open · 2 partial · 2 accepted** (T-001…T-019).

- Mitigated: forged tokens (RS256-strict, constant-time ApiKey), PKCE/DCR
  redirect allowlist, OIDC SSRF confinement, VFS.File traversal+symlink
  confinement (incl. children/2 lstat), parameterized SQL in VFS.Database,
  fail-closed ACL, bounded atomization, constant-time Basic compares,
  scope-claim extraction via JWTVerifier.scopes/1, content-prefix routing
  gate, scheme-aware WWW-Authenticate, bare-`*` containment.
- Open: T-013 Password login-form CSRF · T-016 fuse.yml floating action tags.
- Partial: T-015 no Elixir CI → workflow added in epic (closes on merge;
  pg battery gains a per-PR Postgres service) · T-017 no CODEOWNERS/branch
  protection (manual hex publish = human gate).
- Accepted: T-018 local api_key/loopback trust · T-019 host obligations.

## Residual Risk

T-009–T-012 fixes staged on `epic.content-crud-auth` — flip to mitigated only
when the post-fix suite is green; they gate the epic merge. T-015 (add an
Elixir test workflow) is the cheapest high-leverage closure. Register is the
tracker — no tickets filed.
