# Authentication / Authorization Controls

Detail for T-001…T-006, T-014. Architecture: [../arch/auth.md](../arch/auth.md),
[../arch/authorization.md](../arch/authorization.md).

## Token verification (T-001)

- Server-side bearer validation via `Auth.TokenVerifier` family; chain and
  compound-JWT verifiers cover audience/issuer checks.
- `Auth.Server` AS facade: access tokens TTL-capped at 900s; optional
  `track_access_tokens` buys immediate revocation for a store read per request
  (documented trade-off, T-003-adjacent).
- PKCE is S256-only — enforced by DB CHECK as well as code (defense in depth).
- Client registry accepts RFC 7591 dynamic registration and CIMD; public
  clients (`auth method none`) carry NULL `secret_hash` by design.

## Replay resistance (T-002)

- Auth codes: redemption is `UPDATE … WHERE used_at IS NULL RETURNING *` — a
  second redemption is detected, and revokes the whole `refresh_family_id`.
- Refresh rotation: self-FK chain + family reuse-detection; `family_expires_at`
  is an absolute ceiling rotation cannot extend.
- Login states keyed by SHA-256 of the state value — a leaked row does not
  yield a usable state parameter.
- Agent assertions: session nonce consumed atomically (single UPDATE);
  `jti_hash` claimed via `INSERT … ON CONFLICT DO NOTHING RETURNING` (SETNX shape).

## Authorization chokepoint (T-004, T-005)

- Every tool-surface consumer flows through the Toolset protocol; the ACL
  check (`filter_entries/4`) sits inside the behaviour, so feature shims and
  custom toolsets cannot bypass it.
- Weighted merge: static base → weight-200 persisted grants/negotiations
  (adjust/extend, never hide) → weight-300 ACL visibility gating.
- Anti-oracle: denials are silent; a hidden tool resolves to the identical
  error as an absent one; consent-gated tools stay listed but invoke to one
  honest `:forbidden`.

## Known gaps

- **T-006 (open by design)**: no `ACL.Provider` configured ⇒ inert `:allow`.
  Back-compat default; hosts must wire a policy for any exposed surface.
- **T-014 (partial)**: Engine upstream authenticity depends on the host's
  transport config (TLS, endpoint validation). `auth_ref` keeps stored
  credentials out of the registry table itself; `passthrough` deliberately
  forwards the caller's credential — only to upstreams the host trusts with it.
