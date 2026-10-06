# OAuth 2.1 AS tables (template)

Source of truth: `priv/liquibase/noizu_mcp_oauth.yaml`. TEMPLATE — the host
copies it into its own changelog (renumber ids, set author) and applies via
Liquibase; the library ships but never applies it. Backs
`Noizu.MCP.Auth.Server`. `subject` is plain `text` (no FK to a users table);
optional `subject_fk` changeSets at the bottom of the changelog add the FK when
the host wants cascade deletes. Every hash column is SHA-256 hex `char(64)`
except `secret_hash` (PBKDF2 string).

## mcp_oauth_clients

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| client_id | text | No | — | PK (text: CIMD ids are https URLs) |
| client_id_kind | varchar(20) | No | `registered` | CHECK registered/cimd/preconfigured |
| client_name | text | Yes | — | |
| secret_hash | text | Yes | — | PBKDF2 string; NULL = public client (`none`) |
| token_endpoint_auth_method | varchar(32) | No | `none` | CHECK none/client_secret_post/client_secret_basic |
| redirect_uris | jsonb | No | `'[]'` | |
| grant_types | jsonb | No | `["authorization_code","refresh_token"]` | |
| response_types | jsonb | No | `["code"]` | |
| scope | text | Yes | — | |
| upstream_client_ref | text | Yes | — | Pointer at host's own caller record (never an IdP token) |
| logo_uri / client_uri / policy_uri / tos_uri | text | Yes | — | Client metadata |
| software_id / software_version | text | Yes | — | |
| cimd_fetched_at / cimd_etag / cimd_expires_at | timestamptz / text | Yes | — | CIMD cache bookkeeping |
| metadata | jsonb | No | `'{}'` | |
| disabled_at | timestamptz | Yes | — | |
| inserted_at / updated_at | timestamptz | No | now() | |

**Indexes**: `idx_mcp_oauth_clients_kind (client_id_kind) WHERE disabled_at IS NULL`;
`idx_mcp_oauth_clients_cimd_expiry (cimd_expires_at) WHERE client_id_kind = 'cimd'`

## mcp_oauth_login_states

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| state_hash | char(64) | No | — | PK — SHA-256 of state value |
| payload | jsonb | No | `'{}'` | Pending auth request + consent CSRF + decision |
| expires_at | timestamptz | No | — | |
| inserted_at / updated_at | timestamptz | No | now() | |

**Index**: `idx_mcp_oauth_login_states_expiry (expires_at)`

## mcp_oauth_authorization_codes

Single-use; redemption is `UPDATE … WHERE used_at IS NULL RETURNING *` — a
second redemption is a replay and revokes `refresh_family_id` in full. Rows are
kept after use until purged.

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| code_hash | char(64) | No | — | PK |
| client_id | text | No | — | FK → mcp_oauth_clients ON DELETE CASCADE |
| subject | text | No | — | |
| redirect_uri | text | No | — | |
| scope | text | No | `''` | |
| resource | text | Yes | — | |
| code_challenge | text | No | — | PKCE (S256-only, CHECK + code) |
| code_challenge_method | varchar(10) | No | `S256` | CHECK `= 'S256'` |
| nonce | text | Yes | — | |
| refresh_family_id | uuid | Yes | — | Family revocation pointer |
| upstream_ref | jsonb | Yes | — | |
| expires_at | timestamptz | No | — | |
| used_at | timestamptz | Yes | — | Atomic redemption marker |
| inserted_at | timestamptz | No | now() | |

**Indexes**: `idx_mcp_oauth_codes_expiry (expires_at)`;
`idx_mcp_oauth_codes_family (refresh_family_id) WHERE refresh_family_id IS NOT NULL`

## mcp_oauth_refresh_tokens

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| id | uuid | No | gen_random_uuid() | PK |
| token_hash | char(64) | No | — | UNIQUE |
| client_id | text | No | — | FK → clients ON DELETE CASCADE |
| subject | text | No | — | |
| scope | text | No | `''` | |
| resource | text | Yes | — | |
| family_id | uuid | No | — | Rotation family (reuse-detection unit) |
| rotated_to | uuid | Yes | — | Self-FK — rotation chain |
| rotated_at / revoked_at | timestamptz | Yes | — | |
| expires_at | timestamptz | No | — | |
| family_expires_at | timestamptz | Yes | — | Absolute ceiling rotation cannot extend |
| inserted_at | timestamptz | No | now() | |

**Indexes**: `idx_mcp_oauth_refresh_family (family_id)`;
`idx_mcp_oauth_refresh_subject (subject, client_id) WHERE revoked_at IS NULL`;
`idx_mcp_oauth_refresh_expiry (expires_at)`

## mcp_oauth_consents

**Constraint**: `uq_mcp_oauth_consents_subject_client UNIQUE (subject, client_id)`

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| id | uuid | No | gen_random_uuid() | PK |
| subject | text | No | — | |
| client_id | text | No | — | FK → clients ON DELETE CASCADE |
| scope | text | No | `''` | Granted-so-far scope (re-prompt boundary) |
| resource | text | Yes | — | |
| granted_at | timestamptz | No | now() | |
| expires_at | timestamptz | Yes | — | |

## mcp_oauth_access_tokens (OPTIONAL)

Only needed with `track_access_tokens: true` (immediate revocation at the cost
of a store read per request). Without it, access tokens are valid until expiry
(TTL capped at 15 minutes).

| Column | Type | Nullable | Default | Description |
|--------|------|----------|---------|-------------|
| jti_hash | char(64) | No | — | PK |
| client_id | text | No | — | FK → clients ON DELETE CASCADE |
| subject | text | No | — | |
| scope | text | No | `''` | |
| resource | text | Yes | — | |
| family_id | uuid | Yes | — | |
| expires_at | timestamptz | No | — | |
| revoked_at | timestamptz | Yes | — | |
| inserted_at | timestamptz | No | now() | |

**Indexes**: `idx_mcp_oauth_access_tokens_expiry (expires_at)`;
`idx_mcp_oauth_access_tokens_family (family_id) WHERE family_id IS NOT NULL`
