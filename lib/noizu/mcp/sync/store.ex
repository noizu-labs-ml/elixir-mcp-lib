if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Noizu.MCP.Sync.Store do
    @moduledoc """
    Parameterized SQL facade over the host-owned `mcp_sync` Liquibase schema.
    Every call is one short database transaction. No adapter performs remote
    I/O while a record lock is held. Use a restricted app Repo for put/remove
    and a separately authorized worker Repo for queue/apply operations.
    """
    alias Noizu.MCP.Sync.Protocol

    def put(repo, binding, key, payload, expected),
      do:
        query(repo, "SELECT mcp_sync.put($1::text::uuid,$2::jsonb,$3::jsonb,$4::bigint)", [
          binding,
          key,
          payload,
          expected
        ])

    def remove(repo, binding, key, expected),
      do:
        query(repo, "SELECT mcp_sync.remove($1::text::uuid,$2::jsonb,$3::bigint)", [
          binding,
          key,
          expected
        ])

    def resolve(repo, conflict, strategy, expected),
      do:
        query(repo, "SELECT mcp_sync.resolve($1::text::uuid,$2::text,$3::bigint)", [
          conflict,
          strategy,
          expected
        ])

    def claim(repo, binding, lease_seconds),
      do:
        query(repo, "SELECT mcp_sync.claim_outbox($1::text::uuid,$2::int)", [
          binding,
          lease_seconds
        ])

    def ack(repo, operation, fence, result),
      do:
        query(repo, "SELECT mcp_sync.ack_outbox($1::text::uuid,$2::bigint,$3::jsonb)", [
          operation,
          fence,
          result
        ])

    def fail(repo, operation, fence, code, evidence \\ %{}),
      do:
        query(repo, "SELECT mcp_sync.fail_outbox($1::text::uuid,$2::bigint,$3::text,$4::jsonb)", [
          operation,
          fence,
          code,
          evidence
        ])

    def apply_changes(repo, binding, events, cursor),
      do:
        query(repo, "SELECT mcp_sync.apply_changes($1::text::uuid,$2::jsonb,$3::text)", [
          binding,
          events,
          cursor
        ])

    def publish_snapshot(repo, binding, rows, cursor, snapshot),
      do:
        query(
          repo,
          "SELECT mcp_sync.publish_snapshot($1::text::uuid,$2::jsonb,$3::text,$4::text)",
          [binding, rows, cursor, snapshot]
        )

    def pause(repo, binding, reason),
      do: query(repo, "SELECT mcp_sync.pause_binding($1::text::uuid,$2::text)", [binding, reason])

    def resume(repo, binding),
      do: query(repo, "SELECT mcp_sync.resume_binding($1::text::uuid)", [binding])

    def checkpoint(repo, binding),
      do:
        query(
          repo,
          "SELECT jsonb_build_object('cursor',source_cursor,'status',status) FROM mcp_sync.checkpoints WHERE binding_id=$1::text::uuid",
          [binding]
        )

    @doc "Executes a fixed SQL statement and redacts database errors at the wire boundary."
    def query(repo, sql, params) do
      case Ecto.Adapters.SQL.query(repo, sql, params, log: false) do
        {:ok, %{rows: [[result]]}} -> {:ok, result}
        {:ok, %{rows: []}} -> {:ok, nil}
        {:error, error} -> {:error, database_error(error)}
      end
    end

    defp database_error(%{postgres: postgres}) when is_map(postgres) do
      message = Map.get(postgres, :message, "")

      code =
        Enum.find(
          ~w(revision_conflict idempotency_mismatch resnapshot_required unsupported_consistency permission_denied invalid_request pending_operation blocked reconciliation_required snapshot_limit_exceeded),
          &String.contains?(message, &1)
        ) ||
          case Map.get(postgres, :code) do
            :serialization_failure -> "revision_conflict"
            :insufficient_privilege -> "permission_denied"
            :object_not_in_prerequisite_state -> "pending_operation"
            _ -> "storage_error"
          end

      evidence =
        case Map.get(postgres, :detail) do
          detail when is_binary(detail) ->
            case Jason.decode(detail) do
              {:ok, decoded} when is_map(decoded) ->
                Map.take(decoded, ~w(current revision value deleted key eventId))

              _ ->
                %{}
            end

          _ ->
            %{}
        end

      Protocol.error(code, evidence)
    end

    defp database_error(_), do: Protocol.error("storage_error")
  end
end
