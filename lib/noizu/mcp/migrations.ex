defmodule Noizu.MCP.Migrations.ChangeSet do
  @moduledoc """
  One applied-in-order migration unit (PRD-4 §4.6): `name` is the ledger
  primary key, `version` is strictly increasing across the host's `change_sets/0`
  list, and `up`/`down` are `(repo, opts) -> result` thunks — raw SQL inside;
  `Noizu.MCP.Migration.Runner` wraps each set in a Postgres transaction and
  records the row in `noizu_mcp_schema_versions` on success.

  `down` is optional — a `to:`/rollback past a set without one is
  `{:error, {:no_down, name}}`, never a silent skip. `note` is host-facing
  documentation (what the set exists for, who to ask).
  """

  @enforce_keys [:name, :version, :up]
  defstruct [:name, :version, :up, :down, note: nil]

  @type t :: %__MODULE__{
          name: String.t(),
          version: integer(),
          up: (repo :: module(), opts :: keyword() -> term()),
          down: (repo :: module(), opts :: keyword() -> term()) | nil,
          note: String.t() | nil
        }
end

defmodule Noizu.MCP.Migrations do
  @moduledoc """
  The migrations contract (PRD-4 §4.6) — Oban shape: ONE host migration file
  delegates to `Noizu.MCP.Migration.Runner` with this module (or the host's
  own extension of it):

      defmodule MyApp.Repo.Migrations.NoizuMcpToolsets do
        use Ecto.Migration

        def up,
          do: Noizu.MCP.Migration.Runner.up(MyApp.Repo, Noizu.MCP.Migrations, to: :latest)

        def down,
          do: Noizu.MCP.Migration.Runner.down(MyApp.Repo, Noizu.MCP.Migrations, to: 0)
      end

  A host adds its OWN lib-related sets by implementing `change_sets/0` on its
  module (lib sets first, host versions strictly increasing after):

      def change_sets,
        do: [Noizu.MCP.Migrations.V1Toolsets.change_set() | my_sets()]

  This module is ALSO the shipped default registry: `change_sets/0` here
  returns exactly the lib-owned sets (`V1Toolsets`). The Runner owns the
  `noizu_mcp_schema_versions` ledger and creates it before applying anything —
  bootstrap-first ordering, so no change set ever references it in its own DDL.
  """

  @callback change_sets() :: [Noizu.MCP.Migrations.ChangeSet.t()]

  @doc "The shipped lib-owned change sets, in apply order."
  # ⟦𓎝𓉔𓄿𓈖𓎼𓅱⟧ change_sets :: The shipped lib-owned change sets, in apply order.
  @spec change_sets() :: [Noizu.MCP.Migrations.ChangeSet.t()]
  def change_sets, do: [Noizu.MCP.Migrations.V1Toolsets.change_set()]
end
