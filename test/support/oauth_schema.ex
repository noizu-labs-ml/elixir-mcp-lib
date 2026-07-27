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
  )

  def tables, do: @tables

  def drop_sql, do: "DROP TABLE IF EXISTS #{Enum.join(@tables, ", ")} CASCADE"

  def truncate_sql, do: "TRUNCATE #{Enum.join(@tables, ", ")}"

  def create_sql do
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
        subject text NOT NULL,
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
        subject text NOT NULL,
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
        subject text NOT NULL,
        client_id text NOT NULL REFERENCES mcp_oauth_clients(client_id) ON DELETE CASCADE,
        scope text NOT NULL DEFAULT '',
        resource text,
        granted_at timestamptz NOT NULL DEFAULT now(),
        expires_at timestamptz,
        CONSTRAINT uq_mcp_oauth_consents_subject_client UNIQUE (subject, client_id)
      )
      """,
      access_tokens_sql()
    ]
  end

  @doc """
  The optional access-tokens table on its own.

  Broken out so a test can drop it and put it back — hosts running
  `track_access_tokens: false` are told the table is optional, and
  `purge_expired/2` must not name it in that case.
  """
  def access_tokens_sql do
    """
    CREATE TABLE mcp_oauth_access_tokens (
      jti_hash char(64) PRIMARY KEY,
      client_id text NOT NULL REFERENCES mcp_oauth_clients(client_id) ON DELETE CASCADE,
      subject text NOT NULL,
      scope text NOT NULL DEFAULT '',
      resource text,
      family_id uuid,
      expires_at timestamptz NOT NULL,
      revoked_at timestamptz,
      inserted_at timestamptz NOT NULL DEFAULT now()
    )
    """
  end
end
