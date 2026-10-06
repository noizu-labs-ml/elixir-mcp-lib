# Threat Model Summary

Library, not a deployment — no perimeter of its own. Assets: the host's MCP
tool surface, credentials in transit/at rest, and data reachable via VFS
mounts, Engine upstreams, and `mcp_sync` databases. Boundaries: LLM client ↔
transports · host ↔ library seams · server ↔ upstream MCPs (Engine) ·
library ↔ local desktop (mount daemons, Inspector) · app roles ↔ PostgreSQL
(sync) · Hex ↔ consumers.

Register: 15 entries — 10 mitigated, 3 partial, 1 open-by-design, 1 host-audit.

- T-001 High/Spoofing — unauthenticated tool access: verifiers + OAuth AS
  facade (PKCE S256-only, ≤900s tokens); wiring is host responsibility.
- T-002 High/Spoofing — token replay: atomic code redemption, refresh-family
  revocation, JTI SETNX guard.
- T-003 High/Info-disclosure — credentials at rest: hash-only convention
  (SHA-256 / Argon2-PBKDF2), no plaintext columns.
- T-004 High/Elevation — tool bypass: single toolset path, unbypassable ACL
  chokepoint (`filter_entries/4`).
- T-005 Medium/Info-disclosure — ACL oracle: silent denials, identical error
  for hidden vs absent tools.
- T-006 Medium/Elevation — no ACL provider wired: inert `:allow` default,
  open by design (host responsibility).
- T-007 Medium/Tampering — sync races: DB-owned CAS, fencing tokens, outbox
  leases, FORCE RLS + SECURITY DEFINER.
- T-008 Medium/Elevation — sync principal from request params: contract
  mitigated; enforcement is host code — audit new Sources.
- T-009 Low/Info-disclosure — Inspector: 127.0.0.1 + random bearer + Origin
  check; residual = local machine trust.
- T-010 Medium/Spoofing — VFS mount daemons: `vfs/auth` API-key handshake;
  unix-socket exposure rides on filesystem permissions (operator).
- T-011 Medium/DoS — task-per-request cancellation, bounded EventStore ring,
  no JSON-RPC batching; plug-level limits are host responsibility.
- T-012 Medium/Tampering — supply chain: locked deps, feature-gated optional
  deps, 2FA Hex publish; no artifact signing.
- T-013 Low/Info-disclosure — crash dumps/logs carry frames: gitignored
  locally; host storage hygiene.
- T-014 Medium/Spoofing — Engine upstream impersonation: `auth_ref`
  indirection; upstream transport authenticity is host config.
- T-015 Low/Repudiation — agent lifecycle disputes: append-only audit events,
  revoked keys kept.

Residual risk accepted: anti-oracle trades debuggability; local-desktop tools
assume a trusted machine; experimental surfaces (`sql/*`, sync v1) have short
field history — treat upstream-derived data as untrusted at the host boundary.
