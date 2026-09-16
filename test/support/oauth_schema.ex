defmodule Noizu.MCP.Auth.Server.TestSchema do
  @moduledoc false
  # DDL for the DB-gated `Store.Ecto` conformance run.
  #
  # This mirrors `priv/liquibase/noizu_mcp_oauth.yaml`. It is a second copy, which
  # is a real risk — `oauth_liquibase_template_test.exs` compares the table and
  # column sets of the two so drift fails a test rather than surfacing as a
  # confusing SQL error months later.
  #
  # `gen_random_uuid()` needs pgcrypto on PostgreSQL < 13; on 13+ it is built in.

  @tables ~w(
    mcp_oauth_access_tokens mcp_oauth_consents mcp_oauth_refresh_tokens
    mcp_oauth_authorization_codes mcp_oauth_login_states mcp_oauth_clients
    mcp_agent_accounts mcp_agent_account_keys mcp_agent_credentials
    mcp_agent_sessions mcp_agent_assertion_jti mcp_agent_account_events
  )

  def tables, do: @tables

  def drop_sql, do: "DROP TABLE IF EXISTS #{Enum.join(@tables, ", ")} CASCADE"

  def truncate_sql, do: "TRUNCATE #{Enum.join(@tables, ", ")}"

  @doc """
  DDL with a `text` subject column.

  Hosts differ on this: the library treats `subject` as opaque text (it may be an
  email), but an app whose users table is keyed by uuid will have declared the
  column `uuid`, and `Store.Ecto` is told which via `subject_type:`. Both shapes
  are exercised — `create_sql/1` builds either — because a uuid subject column is
  precisely where the adapter used to fail, with "expected a binary of 16 bytes".
  """
  def create_sql, do: create_sql(:text)

  def create_sql(subject_type) when subject_type in [:text, :uuid] do
    subject = subject_column(subject_type)

    [
      """
      CREATE TABLE mcp_oauth_clients (
        client_id text PRIMARY KEY,
        client_id_kind varchar(20) NOT NULL DEFAULT 'registered'
          CHECK (client_id_kind IN ('registered','cimd','preconfigured')),
        client_name text,
        secret_hash text,
        token_endpoint_auth_method varchar(32) NOT NULL DEFAULT 'none'
          CHECK (token_endpoint_auth_method IN ('none','client_secret_post','client_secret_basic')),
        redirect_uris jsonb NOT NULL DEFAULT '[]'::jsonb,
        grant_types jsonb NOT NULL DEFAULT '["authorization_code","refresh_token"]'::jsonb,
        response_types jsonb NOT NULL DEFAULT '["code"]'::jsonb,
        scope text,
        upstream_client_ref text,
        logo_uri text,
        client_uri text,
        policy_uri text,
        tos_uri text,
        software_id text,
        software_version text,
        cimd_fetched_at timestamptz,
        cimd_etag text,
        cimd_expires_at timestamptz,
        metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
        disabled_at timestamptz,
        inserted_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now()
      )
      """,
      """
      CREATE TABLE mcp_oauth_login_states (
        state_hash char(64) PRIMARY KEY,
        payload jsonb NOT NULL DEFAULT '{}'::jsonb,
        expires_at timestamptz NOT NULL,
        inserted_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now()
      )
      """,
      """
      CREATE TABLE mcp_oauth_authorization_codes (
        code_hash char(64) PRIMARY KEY,
        client_id text NOT NULL REFERENCES mcp_oauth_clients(client_id) ON DELETE CASCADE,
        subject #{subject} NOT NULL,
        redirect_uri text NOT NULL,
        scope text NOT NULL DEFAULT '',
        resource text,
        code_challenge text NOT NULL,
        code_challenge_method varchar(10) NOT NULL DEFAULT 'S256'
          CHECK (code_challenge_method = 'S256'),
        nonce text,
        refresh_family_id uuid,
        upstream_ref jsonb,
        expires_at timestamptz NOT NULL,
        used_at timestamptz,
        inserted_at timestamptz NOT NULL DEFAULT now()
      )
      """,
      """
      CREATE TABLE mcp_oauth_refresh_tokens (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        token_hash char(64) NOT NULL UNIQUE,
        client_id text NOT NULL REFERENCES mcp_oauth_clients(client_id) ON DELETE CASCADE,
        subject #{subject} NOT NULL,
        scope text NOT NULL DEFAULT '',
        resource text,
        family_id uuid NOT NULL,
        rotated_to uuid REFERENCES mcp_oauth_refresh_tokens(id) ON DELETE SET NULL,
        rotated_at timestamptz,
        revoked_at timestamptz,
        expires_at timestamptz NOT NULL,
        family_expires_at timestamptz,
        inserted_at timestamptz NOT NULL DEFAULT now()
      )
      """,
      """
      CREATE TABLE mcp_oauth_consents (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        subject #{subject} NOT NULL,
        client_id text NOT NULL REFERENCES mcp_oauth_clients(client_id) ON DELETE CASCADE,
        scope text NOT NULL DEFAULT '',
        resource text,
        granted_at timestamptz NOT NULL DEFAULT now(),
        expires_at timestamptz,
        CONSTRAINT uq_mcp_oauth_consents_subject_client UNIQUE (subject, client_id)
      )
      """,
      access_tokens_sql(subject_type)
    ] ++ agent_tables_sql()
  end

  defp subject_column(:text), do: "text"
  defp subject_column(:uuid), do: "uuid"

  @doc """
  The optional access-tokens table on its own.

  Broken out so a test can drop it and put it back — hosts running
  `track_access_tokens: false` are told the table is optional, and
  `purge_expired/2` must not name it in that case.
  """
  def access_tokens_sql, do: access_tokens_sql(:text)

  def access_tokens_sql(subject_type) when subject_type in [:text, :uuid] do
    subject = subject_column(subject_type)

    """
    CREATE TABLE mcp_oauth_access_tokens (
      jti_hash char(64) PRIMARY KEY,
      client_id text NOT NULL REFERENCES mcp_oauth_clients(client_id) ON DELETE CASCADE,
      subject #{subject} NOT NULL,
      scope text NOT NULL DEFAULT '',
      resource text,
      family_id uuid,
      expires_at timestamptz NOT NULL,
      revoked_at timestamptz,
      inserted_at timestamptz NOT NULL DEFAULT now()
    )
    """
  end

  @doc """
  The agent-block tables (anonymous keypair / human-credential auth), as a
  list — mirrors the `noizu-mcp-agent-*` changeSets in `noizu_mcp_oauth.yaml`.
  Broken out from `create_sql/1` the same way `access_tokens_sql/1` is, in
  case a test ever needs to create the OAuth tables without these, or vice
  versa.
  """
  def agent_tables_sql do
    [
      """
      CREATE TABLE mcp_agent_accounts (
        id text PRIMARY KEY,
        handle text NOT NULL,
        kind varchar(10) NOT NULL DEFAULT 'agent'
          CHECK (kind IN ('agent','human')),
        status varchar(10) NOT NULL DEFAULT 'pending'
          CHECK (status IN ('pending','approved','rejected','suspended')),
        display_name text,
        profile jsonb NOT NULL DEFAULT '{}'::jsonb,
        revocation_epoch integer NOT NULL DEFAULT 0,
        status_reason text,
        approved_at timestamptz,
        approved_by text,
        inserted_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now()
      )
      """,
      """
      CREATE TABLE mcp_agent_account_keys (
        fingerprint text PRIMARY KEY,
        account_id text NOT NULL REFERENCES mcp_agent_accounts(id) ON DELETE CASCADE,
        public_key bytea NOT NULL,
        alg varchar(10) NOT NULL DEFAULT 'ed25519' CHECK (alg = 'ed25519'),
        label text,
        added_via text,
        added_at timestamptz NOT NULL DEFAULT now(),
        revoked_at timestamptz,
        revoked_by text
      )
      """,
      """
      CREATE TABLE mcp_agent_credentials (
        account_id text PRIMARY KEY REFERENCES mcp_agent_accounts(id) ON DELETE CASCADE,
        password_hash text NOT NULL,
        recovery_hashes jsonb NOT NULL DEFAULT '[]'::jsonb,
        inserted_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now()
      )
      """,
      """
      CREATE TABLE mcp_agent_sessions (
        id_hash char(64) PRIMARY KEY,
        nonce_hash char(64) NOT NULL,
        level varchar(10) NOT NULL DEFAULT 'anonymous'
          CHECK (level IN ('anonymous','agent','human')),
        account_id text REFERENCES mcp_agent_accounts(id) ON DELETE CASCADE,
        key_fingerprint text,
        public_key bytea,
        client jsonb NOT NULL DEFAULT '{}'::jsonb,
        ip_hash text,
        issued_at timestamptz NOT NULL DEFAULT now(),
        expires_at timestamptz NOT NULL,
        consumed_at timestamptz,
        revoked_at timestamptz
      )
      """,
      """
      CREATE TABLE mcp_agent_assertion_jti (
        jti_hash char(64) PRIMARY KEY,
        expires_at timestamptz NOT NULL,
        inserted_at timestamptz NOT NULL DEFAULT now()
      )
      """,
      """
      CREATE TABLE mcp_agent_account_events (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        account_id text NOT NULL REFERENCES mcp_agent_accounts(id) ON DELETE CASCADE,
        event jsonb NOT NULL,
        inserted_at timestamptz NOT NULL DEFAULT now()
      )
      """
    ]
  end
end
