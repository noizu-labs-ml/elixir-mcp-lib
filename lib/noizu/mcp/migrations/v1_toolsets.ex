if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Noizu.MCP.Migrations.V1Toolsets do
    @moduledoc """
    The shipped v1 change set (PRD-4 §4.6): the lib-owned Postgres tables —
    `noizu_mcp_toolsets`, `noizu_mcp_toolset_grants`,
    `noizu_mcp_toolset_negotiations` and their `noizu_mcp_store_versions`
    counters. Raw-SQL DDL; `if not exists` guards make re-runs idempotent (the
    Runner's ledger skips applied sets anyway — the guards cover a crashed
    pre-ledger half-apply and hand-run psql).

    Ownership (decision 2): these tables serve lib-default and non-NPL
    consumers. The ONLY reader is `Noizu.MCP.Persistence.Ecto` (AP-11); NPL
    never migrates `mcp_custom_scopes`/`toolset_config` data into them.

    `noizu_mcp_schema_versions` is deliberately NOT here — the Runner creates
    its own ledger before applying sets (bootstrap-first ordering).
    """

    alias Noizu.MCP.Migrations.ChangeSet

    @doc "The v1 change set (`\"v1_toolsets\"`, version 1)."
    # ⟦𓎝𓉔𓄿𓈖𓎼𓅱⟧ change_set :: The v1 change set.
    @spec change_set() :: ChangeSet.t()
    def change_set do
      %ChangeSet{
        name: "v1_toolsets",
        version: 1,
        up: &__MODULE__.up/2,
        down: &__MODULE__.down/2,
        note:
          "lib-owned toolset/toolset_grant/toolset_negotiation tables + store version counters"
      }
    end

    @doc false
    def up(repo, _opts) do
      Enum.each(up_statements(), fn sql -> repo.query!(sql, []) end)
      :ok
    end

    @doc false
    def down(repo, _opts) do
      # Reverse order; indexes drop with their tables but drop them
      # explicitly so a partially hand-migrated schema cleans up too.
      Enum.each(down_statements(), fn sql -> repo.query!(sql, []) end)
      :ok
    end

    # §4.6 DDL, verbatim.
    def up_statements do
      [
        """
        create table if not exists noizu_mcp_toolsets (
          slug text primary key,
          title text, description text,
          base text not null,
          immutable boolean not null default false,
          include jsonb, exclude jsonb not null default '[]'::jsonb,
          tools jsonb not null default '{}'::jsonb,
          metadata jsonb not null default '{}'::jsonb,
          inserted_at timestamptz not null default now(),
          updated_at timestamptz not null default now()
        )
        """,
        """
        create table if not exists noizu_mcp_toolset_grants (
          id text primary key,
          toolset_slug text not null,
          authenticator text not null,
          subject text not null,
          effect text not null check (effect in ('allow','deny')),
          scopes jsonb not null default '[]'::jsonb,
          tool_overrides jsonb not null default '{}'::jsonb,
          expires_at timestamptz,
          metadata jsonb not null default '{}'::jsonb,
          inserted_at timestamptz not null default now()
        )
        """,
        """
        create index if not exists noizu_mcp_grants_lookup_idx
          on noizu_mcp_toolset_grants (toolset_slug, authenticator, subject)
        """,
        """
        create table if not exists noizu_mcp_toolset_negotiations (
          id text primary key,
          toolset_slug text not null,
          authenticator text not null,
          tool text not null,
          required_scopes jsonb not null default '[]'::jsonb,
          granted boolean not null default false,
          metadata_overrides jsonb not null default '{}'::jsonb,
          expires_at timestamptz,
          metadata jsonb not null default '{}'::jsonb,
          inserted_at timestamptz not null default now()
        )
        """,
        """
        create index if not exists noizu_mcp_negotiations_lookup_idx
          on noizu_mcp_toolset_negotiations (toolset_slug, authenticator, tool)
        """,
        """
        create table if not exists noizu_mcp_store_versions (
          store_key text primary key,
          version bigint not null default 0,
          bumped_at timestamptz not null default now()
        )
        """
      ]
    end

    def down_statements do
      [
        "drop table if exists noizu_mcp_store_versions",
        "drop index if exists noizu_mcp_negotiations_lookup_idx",
        "drop table if exists noizu_mcp_toolset_negotiations",
        "drop index if exists noizu_mcp_grants_lookup_idx",
        "drop table if exists noizu_mcp_toolset_grants",
        "drop table if exists noizu_mcp_toolsets"
      ]
    end
  end
end
