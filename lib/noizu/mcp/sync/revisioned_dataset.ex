if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Noizu.MCP.Sync.RevisionedDataset do
    @moduledoc """
    Controlled PostgreSQL Source with durable revisions, idempotency and snapshots.
    State is `%{repo: MySourceRepo, binding_id: uuid, relation: "notes"}` and MUST
    be resolved by the host from the authenticated principal. A caller may choose
    a relation name, never a database binding or credential. Direct base-table
    mutation is denied; SQL clients use the same source_mutate function.
    """
    @behaviour Noizu.MCP.Sync.Source
    alias Noizu.MCP.Sync.{Protocol, Store}

    @impl true
    def capabilities(params, state), do: call(state, params, "source_capabilities", [], [])
    @impl true
    def snapshot(params, state),
      do:
        call(state, params, "source_snapshot", ["text", "int"], [
          params["snapshotCursor"],
          params["limit"] || 500
        ])

    @impl true
    def changes(params, state),
      do:
        call(state, params, "source_changes", ["text", "int"], [
          params["cursor"],
          params["limit"] || 500
        ])

    @impl true
    def mutate(params, state), do: call(state, params, "source_mutate", ["jsonb"], [params])
    @impl true
    def operation(params, state),
      do: call(state, params, "source_operation", ["text"], [params["operationId"]])

    defp call(
           %{repo: repo, binding_id: binding, relation: relation},
           %{"relation" => relation},
           name,
           types,
           values
         ) do
      arguments = [
        "$1::text::uuid"
        | Enum.with_index(types, 2) |> Enum.map(fn {type, index} -> "$#{index}::#{type}" end)
      ]

      Store.query(repo, "SELECT mcp_sync.#{name}(#{Enum.join(arguments, ",")})", [
        binding | values
      ])
    end

    defp call(_, _, _, _, _), do: {:error, Protocol.error("permission_denied")}
  end
end
