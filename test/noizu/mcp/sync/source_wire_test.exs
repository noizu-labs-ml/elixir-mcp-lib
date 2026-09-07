defmodule Noizu.MCP.Sync.SourceWireTest do
  use ExUnit.Case, async: false
  import Noizu.MCP.Test
  alias Noizu.MCP.Test.SyncDB, as: DB
  alias Noizu.MCP.Test.{SyncCacheRepo, SyncSourceRepo, SyncAppRepo}
  alias Noizu.MCP.Sync.{Protocol, RevisionedDataset, Store, Worker}

  defmodule SourceServer do
    use Noizu.MCP.Server, name: "sync-pg-wire", version: "1", sync: true
    @impl true
    def handle_sync(method, params, %{auth: %{subject: "wire-user"}}),
      do:
        Protocol.dispatch(
          {RevisionedDataset, Application.fetch_env!(:noizu_mcp, :sync_wire_source)},
          method,
          params
        )

    def handle_sync(_, _, _), do: {:error, Protocol.error("permission_denied")}
  end

  defmodule CommitBarrier do
    @behaviour Noizu.MCP.Sync.Source
    for method <- [:capabilities, :snapshot, :changes, :operation] do
      @impl true
      def unquote(method)(params, state),
        do: apply(RevisionedDataset, unquote(method), [params, state])
    end

    @impl true
    def mutate(params, state) do
      result = RevisionedDataset.mutate(params, state)
      send(state.owner, {:source_committed, self(), result})

      receive do
        :release -> result
      end
    end
  end

  defmodule DeniedLookup do
    def capabilities(params, state), do: RevisionedDataset.capabilities(params, state)
    def operation(_params, _state), do: {:error, Protocol.error("permission_denied")}
    def mutate(_, _), do: raise("an unauthorized lookup must not mutate")
  end

  defmodule EndlessSnapshot do
    def snapshot(params, state) do
      index = String.to_integer(params["snapshotCursor"] || "0")

      {:ok,
       %{
         "snapshotId" => "bounded",
         "changeCursor" => "sync:#{state.binding_id}:0",
         "rows" => [],
         "nextCursor" => to_string(index + 1)
       }}
    end
  end

  setup_all do
    {cache_url, source_url} = DB.urls()
    DB.install!(cache_url)
    DB.install!(source_url)
    admin = start_supervised!(DB.connection_spec(cache_url, nil, :wire_cache_admin))
    source_admin = start_supervised!(DB.connection_spec(source_url, nil, :wire_source_admin))
    DB.bootstrap_roles!(admin)
    start_supervised!(DB.repo_spec(cache_url, "sync_test_worker", SyncCacheRepo))
    start_supervised!(DB.repo_spec(cache_url, "sync_test_a", SyncAppRepo))
    start_supervised!(DB.repo_spec(source_url, "sync_test_a", SyncSourceRepo))
    {:ok, admin: admin, source_admin: source_admin}
  end

  setup context do
    binding = Ecto.UUID.generate()

    for conn <- [context.admin, context.source_admin],
        do: DB.binding!(conn, binding, "sync_test_a", binding)

    state = %{repo: SyncSourceRepo, binding_id: binding, relation: "notes"}

    opts = [
      store_repo: SyncCacheRepo,
      binding_id: binding,
      source: {RevisionedDataset, state},
      timeout: 1000
    ]

    Application.put_env(:noizu_mcp, :sync_wire_source, state)
    on_exit(fn -> Application.delete_env(:noizu_mcp, :sync_wire_source) end)
    {:ok, binding: binding, state: state, opts: opts, key: %{"id" => "wire"}}
  end

  test "real MCP source and SQL local cache preserve both edits on CAS conflict", context do
    client = connect(SourceServer)

    request = %{
      "relation" => "notes",
      "key" => context.key,
      "operationId" => Ecto.UUID.generate(),
      "operation" => "create",
      "precondition" => %{"absent" => true},
      "value" => %{"title" => "source"}
    }

    assert {:error, %{"data" => %{"syncCode" => "permission_denied"}}} =
             request(client, "sync/mutate", request)

    assert {:ok, created} =
             request(client, "sync/mutate", request, claims: %{"sub" => "wire-user"})

    assert {:ok, _} = Worker.snapshot(context.opts)

    assert {:ok, %{"localRevision" => 2}} =
             Store.put(SyncAppRepo, context.binding, context.key, %{"title" => "sql"}, 1)

    external = %{
      request
      | "operationId" => Ecto.UUID.generate(),
        "operation" => "update",
        "precondition" => %{"revision" => created["revision"]},
        "value" => %{"title" => "mcp"}
    }

    assert {:ok, _} = request(client, "sync/mutate", external, claims: %{"sub" => "wire-user"})

    assert {:ok, %{"state" => "conflict", "conflictId" => conflict}} =
             Worker.run_once(context.opts)

    assert {:ok, %{"value" => %{"title" => "sql"}, "revision" => revision}} =
             Store.query(
               SyncAppRepo,
               "SELECT jsonb_build_object('value',payload,'revision',local_revision) FROM mcp_sync.records WHERE binding_id=$1::text::uuid",
               [context.binding]
             )

    assert {:ok, _} = Worker.pull_once(context.opts)

    assert {:ok, %{"resolved" => true}} =
             Store.resolve(SyncAppRepo, conflict, "accept_remote", revision)

    assert {:ok, %{"title" => "mcp"}} =
             Store.query(
               SyncAppRepo,
               "SELECT payload FROM mcp_sync.records WHERE binding_id=$1::text::uuid",
               [context.binding]
             )
  end

  test "killing a worker after source commit cancels its callback and replay has one effect",
       context do
    assert {:ok, _} =
             Store.put(SyncAppRepo, context.binding, context.key, %{"title" => "once"}, 0)

    source = {CommitBarrier, Map.put(context.state, :owner, self())}
    opts = Keyword.merge(context.opts, source: source, timeout: 10_000)
    worker = spawn(fn -> Worker.run_once(opts) end)
    assert_receive {:source_committed, callback, {:ok, committed}}, 5000
    monitor = Process.monitor(callback)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^callback, _}, 1000

    DB.query!(
      context.admin,
      "UPDATE mcp_sync.outbox SET lease_until=clock_timestamp()-interval '1 second' WHERE binding_id=$1::text::uuid",
      [context.binding]
    )

    assert {:ok, %{"applied" => true}} = Worker.run_once(context.opts)

    assert {:ok, remembered} =
             RevisionedDataset.operation(
               %{"relation" => "notes", "operationId" => committed["operationId"]},
               context.state
             )

    assert remembered == committed

    assert DB.scalar!(
             context.source_admin,
             "SELECT counter FROM mcp_sync.source_heads WHERE binding_id=$1::text::uuid",
             [context.binding]
           ) == 1
  end

  test "empty unique snapshot pages are bounded and do not replace published records", context do
    opts =
      Keyword.merge(context.opts, source: {EndlessSnapshot, context.state}, max_snapshot_pages: 2)

    assert {:error, %{data: %{"syncCode" => "snapshot_limit_exceeded"}}} = Worker.snapshot(opts)
    assert {:ok, nil} = Store.checkpoint(SyncCacheRepo, context.binding)
  end

  test "snapshot byte budget preserves an already published generation", context do
    params = %{
      "relation" => "notes",
      "key" => context.key,
      "operationId" => Ecto.UUID.generate(),
      "operation" => "create",
      "precondition" => %{"absent" => true},
      "value" => %{"title" => "preserved"}
    }

    assert {:ok, _} = RevisionedDataset.mutate(params, context.state)
    assert {:ok, _} = Worker.snapshot(context.opts)
    assert {:ok, before} = Store.checkpoint(SyncCacheRepo, context.binding)

    assert {:error, %{data: %{"syncCode" => "snapshot_limit_exceeded"}}} =
             Worker.snapshot(Keyword.put(context.opts, :max_snapshot_bytes, 10))

    assert {:ok, ^before} = Store.checkpoint(SyncCacheRepo, context.binding)

    assert {:ok, %{"title" => "preserved"}} =
             Store.query(
               SyncAppRepo,
               "SELECT payload FROM mcp_sync.records WHERE binding_id=$1::text::uuid",
               [context.binding]
             )
  end

  test "unauthorized ambiguous operation lookup pauses without replay until explicit resume",
       context do
    assert {:ok, _} =
             Store.put(SyncAppRepo, context.binding, context.key, %{"title" => "queued"}, 0)

    assert {:ok, operation} = Store.claim(SyncCacheRepo, context.binding, 30)

    assert {:ok, _} =
             Store.fail(
               SyncCacheRepo,
               operation["operationId"],
               operation["fencingToken"],
               "unknown"
             )

    DB.query!(
      context.admin,
      "UPDATE mcp_sync.outbox SET next_attempt_at=clock_timestamp() WHERE binding_id=$1::text::uuid",
      [context.binding]
    )

    opts = Keyword.put(context.opts, :source, {DeniedLookup, context.state})
    assert {:ok, %{"state" => "unknown"}} = Worker.run_once(opts)
    assert {:ok, %{"status" => "paused_auth"}} = Store.checkpoint(SyncCacheRepo, context.binding)
    assert {:error, %{data: %{"syncCode" => "permission_denied"}}} = Worker.run_once(opts)

    assert DB.scalar!(
             context.source_admin,
             "SELECT count(*) FROM mcp_sync.source_operations WHERE binding_id=$1::text::uuid",
             [context.binding]
           ) == 0

    assert {:ok, %{"resumed" => true}} = Store.resume(SyncCacheRepo, context.binding)
    assert {:ok, %{"status" => "ready"}} = Store.checkpoint(SyncCacheRepo, context.binding)
  end
end
