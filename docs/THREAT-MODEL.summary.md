# Threat Model — Summary

Digest of `docs/THREAT-MODEL.md`. Keep in sync after register changes.

## Posture

Library (`noizu_mcp` v0.4.2) embedded by hosts; jewels = auth-primitive
correctness (verifiers, OAuth server, ACL), VFS backend confinement (host FS /
SQL escape = host compromise), artifact pipeline (manual hex publish;
mcp-mount/mcp-fuse/pg_mcp via GitHub Releases + DockerHub). Library vulns
amplify into every host. Boundaries: client → transport · credential →
verifier · server → VFS backend · library → upstream IdP · server → Engine
upstreams · server → mcp_sync (RLS) · CI → artifacts · loopback daemon trust ·
Inspector (127.0.0.1). Host obligations (stores, secrets, TLS, throttling)
stated explicitly, never implied.

## Register Counts

**22 mitigated · 2 open · 1 open-by-design · 5 partial · 2 accepted · 1 host-audit**
(T-001…T-033). PR #31's merge resolution dropped the 2026-10-07 fleet-sweep
entries; restored as T-020…T-033 (mount-daemon entry folded into T-018).

- Mitigated: forged tokens (RS256-strict, constant-time ApiKey), PKCE/DCR
  redirect allowlist, OIDC SSRF confinement, VFS.File traversal+symlink
  confinement (incl. children/2 lstat), parameterized SQL in VFS.Database,
  fail-closed ACL, bounded atomization, constant-time Basic compares,
  scope-claim extraction via JWTVerifier.scopes/1, content-prefix routing
  gate, scheme-aware WWW-Authenticate, bare-`*` containment; restored sweep:
  server-surface auth (T-020), OAuth replay resistance (T-021), hashes-at-rest
  (T-022), toolset authorization chokepoint (T-023), ACL anti-oracle (T-024),
  mcp_sync in-database correctness — CAS/fencing/RLS (T-026), Inspector
  loopback controls (T-028), transport DoS posture (T-029), agent-key
  append-only lifecycle (T-033).
- Open: T-013 Password login-form CSRF · T-016 fuse.yml floating action tags ·
  T-025 no-ACL-provider inert `:allow` (open by design, documented).
- Partial: T-015 no Elixir CI → workflow added in epic (closes on merge;
  pg battery gains a per-PR Postgres service) · T-017 no CODEOWNERS/branch
  protection (manual hex publish = human gate) · T-030 supply chain (locked
  deps, 2FA publish, reviewed SQL templates; no artifact signing) · T-031
  crash-dump/log hygiene (host obligation) · T-032 Engine upstream
  authenticity (host transport config; `auth_ref`/`passthrough`).
- Accepted: T-018 local api_key/loopback + socket-permission trust (mount
  daemons) · T-019 host obligations. Host-audit: T-027 Sync.Source principal
  binding.

## Residual Risk

T-009–T-012 fixes staged on `epic.content-crud-auth` — flip to mitigated only
when the post-fix suite is green; they gate the epic merge. T-015 (add an
Elixir test workflow) is the cheapest high-leverage closure. Restored-sweep
residuals: silent ACL denials vs debuggability (T-024), shared-machine
exposure of mount daemons/Inspector (T-018/T-028), short field history of
`sql/*` + `mcp_sync` v1 (T-026/T-027). Register is the tracker — no tickets
filed.
