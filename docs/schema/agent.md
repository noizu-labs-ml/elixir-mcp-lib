# Agent auth tables (template)

Source of truth: `priv/liquibase/noizu_mcp_agent.yaml`. TEMPLATE — applied
independently of the OAuth changelog and sharing no tables with it; all six
tables are optional as a group (they back the agent block of
`Noizu.MCP.Auth.Server.Store`, which `Store.supports?/2` lets a caller skip).
`purge_expired/2` tolerates their absence (undefined-table during the sweep =
zero rows, not a crash).

`id`, `handle`, `fingerprint`, `public_key` are PUBLIC identifiers; every other
hash column holds SHA-256 hex (64 chars). `password_hash` /
`recovery_hashes` hold caller-hashed Argon2/PBKDF2 strings.

## mcp_agent_accounts

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| id | text | No | — | PK — public identifier |
| handle | text | No | — | Case-insensitively unique (functional index, no citext) |
| kind | varchar(10) | No | `agent` | CHECK agent/human |
| status | varchar(10) | No | `pending` | CHECK pending/approved/rejected/suspended |
| display_name | text | Yes | — | |
| profile | jsonb | No | `'{}'` | |
| revocation_epoch | integer | No | 0 | |
| status_reason | text | Yes | — | |
| approved_at | timestamptz | Yes | — | |
| approved_by | text | Yes | — | |
| inserted_at / updated_at | timestamptz | No | now() | |

**Indexes**: `uq_mcp_agent_accounts_handle_ci UNIQUE (lower(handle))`;
`idx_mcp_agent_accounts_status (status)`

## mcp_agent_account_keys

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| fingerprint | text | No | — | PK — RFC 8037 JWK thumbprint, globally unique |
| account_id | text | No | — | FK → accounts ON DELETE CASCADE |
| public_key | bytea | No | — | |
| alg | varchar(10) | No | `ed25519` | CHECK `= 'ed25519'` |
| label | text | Yes | — | |
| added_via | text | Yes | — | |
| added_at | timestamptz | No | now() | |
| revoked_at | timestamptz | Yes | — | Revoked keys are kept, never deleted |
| revoked_by | text | Yes | — | |

**Index**: `idx_mcp_agent_account_keys_account (account_id)`

## mcp_agent_credentials

One row per account (1:1). No email column, no reset flow — recovery codes are
the only way back into a human account.

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| account_id | text | No | — | PK + FK → accounts ON DELETE CASCADE |
| password_hash | text | No | — | Caller-hashed Argon2/PBKDF2 |
| recovery_hashes | jsonb | No | `'[]'` | Caller-hashed recovery codes |
| inserted_at / updated_at | timestamptz | No | now() | |

## mcp_agent_sessions

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| id_hash | char(64) | No | — | PK — hashed credential (unlike accounts.id) |
| nonce_hash | char(64) | No | — | Hashed nonce |
| level | varchar(10) | No | `anonymous` | CHECK anonymous/agent/human |
| account_id | text | Yes | — | FK → accounts ON DELETE CASCADE |
| key_fingerprint | text | Yes | — | |
| public_key | bytea | Yes | — | |
| client | jsonb | No | `'{}'` | |
| ip_hash | text | Yes | — | |
| issued_at | timestamptz | No | now() | |
| expires_at | timestamptz | No | — | |
| consumed_at | timestamptz | Yes | — | Atomic consume marker |
| revoked_at | timestamptz | Yes | — | |

**Index**: `idx_mcp_agent_sessions_expiry (expires_at)`

## mcp_agent_assertion_jti

SETNX-shaped replay guard: `claim_assertion_jti/3` = `INSERT … ON CONFLICT
(jti_hash) DO NOTHING RETURNING jti_hash` — a returned row is the first claim.

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| jti_hash | char(64) | No | — | PK |
| expires_at | timestamptz | No | — | |
| inserted_at | timestamptz | No | now() | |

**Index**: `idx_mcp_agent_assertion_jti_expiry (expires_at)`

## mcp_agent_account_events

Append-only audit log — no update path is exposed by the adapter.

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| id | uuid | No | gen_random_uuid() | PK |
| account_id | text | No | — | FK → accounts ON DELETE CASCADE |
| event | jsonb | No | — | |
| inserted_at | timestamptz | No | now() | |

**Index**: `idx_mcp_agent_account_events_account (account_id, inserted_at DESC)`
