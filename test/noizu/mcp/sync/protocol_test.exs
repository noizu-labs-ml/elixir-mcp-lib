defmodule Noizu.MCP.Sync.ProtocolTest do
  use ExUnit.Case, async: true
  alias Noizu.MCP.Sync.{Protocol, RevisionedDataset}

  test "mutations require explicit CAS and reject caller identity fields" do
    request = %{
      "relation" => "notes",
      "key" => %{"id" => "one"},
      "operationId" => "id",
      "operation" => "update",
      "precondition" => %{"revision" => "opaque"},
      "value" => %{"title" => "local"}
    }

    assert :ok = Protocol.validate("sync/mutate", request)

    for invalid <- [
          Map.delete(request, "precondition"),
          Map.put(request, "binding_id", "other"),
          Map.put(request, "skip_hooks", true),
          Map.put(request, "precondition", %{"revision" => "opaque", "absent" => true}),
          Map.put(request, "precondition", %{"revision" => ""}),
          Map.put(request, "operation", "insert")
        ] do
      assert {:error, %{data: %{"syncCode" => "invalid_request"}}} =
               Protocol.validate("sync/mutate", invalid)
    end

    assert :ok =
             Protocol.validate("sync/mutate", %{
               request
               | "operation" => "create",
                 "precondition" => %{"absent" => true}
             })
  end

  test "only explicit full consistency enables writes" do
    caps = %{
      "version" => 1,
      "snapshot" => "consistent",
      "changes" => true,
      "conditionalWrites" => true,
      "idempotency" => true,
      "idempotencyRetentionSeconds" => 60,
      "changeRetentionSeconds" => 60
    }

    assert :ok = Protocol.writable(caps)

    for field <-
          ~w(snapshot changes conditionalWrites idempotency idempotencyRetentionSeconds changeRetentionSeconds) do
      assert {:error, %{data: %{"syncCode" => "unsupported_consistency"}}} =
               Protocol.writable(Map.delete(caps, field))
    end
  end

  test "source relation and binding are trusted state, never caller-selected" do
    assert {:error, %{data: %{"syncCode" => "permission_denied"}}} =
             RevisionedDataset.capabilities(%{"relation" => "other"}, %{
               repo: UnusedRepo,
               binding_id: "trusted",
               relation: "notes"
             })
  end

  test "method and pagination bounds fail closed" do
    assert {:error, %{code: -32601}} = Protocol.validate("sync/run_sql", %{"relation" => "notes"})

    assert {:error, _} =
             Protocol.validate("sync/snapshot", %{"relation" => "notes", "limit" => 501})

    assert {:error, _} = Protocol.validate("sync/changes", %{"relation" => "notes"})

    assert {:error, _} =
             Protocol.validate("sync/operation", %{"relation" => "notes", "operationId" => ""})
  end
end
