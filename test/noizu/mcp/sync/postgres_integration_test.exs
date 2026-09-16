defmodule Noizu.MCP.Sync.PostgresIntegrationTest do
  use ExUnit.Case, async: false
  alias Noizu.MCP.Test.SyncDB, as: DB
  alias Noizu.MCP.Sync.{Store, Worker, RevisionedDataset}
  alias Noizu.MCP.Test.{SyncCacheRepo, SyncSourceRepo, SyncAppRepo}

  setup_all do
    {cache_url, source_url} = DB.urls()
    DB.install!(cache_url)
    DB.install!(source_url)
    admin = start_supervised!(DB.connection_spec(cache_url, nil, :sync_admin_cache))
    source_admin = start_supervised!(DB.connection_spec(source_url, nil, :sync_admin_source))
    DB.bootstrap_roles!(admin)

    start_supervised!(DB.repo_spec(cache_url, "sync_test_worker", SyncCacheRepo))
    start_supervised!(DB.repo_spec(cache_url, "sync_test_a", SyncAppRepo))
    start_supervised!(DB.repo_spec(source_url, "sync_test_a", SyncSourceRepo))

    connections = %{
      admin: admin,
      source_admin: source_admin,
      app: start_supervised!(DB.connection_spec(cache_url, "sync_test_a", :sync_app)),
      app2: start_supervised!(DB.connection_spec(cache_url, "sync_test_a", :sync_app2)),
      other: start_supervised!(DB.connection_spec(cache_url, "sync_test_b", :sync_other)),
      worker: start_supervised!(DB.connection_spec(cache_url, "sync_test_worker", :sync_worker)),
      source: start_supervised!(DB.connection_spec(source_url, "sync_test_a", :sync_source)),
      source2: start_supervised!(DB.connection_spec(source_url, "sync_test_a", :sync_source2)),
      source3: start_supervised!(DB.connection_spec(source_url, "sync_test_a", :sync_source3))
    }

    {:ok, connections}
  end

  setup context do
    for conn <- [context.admin, context.source_admin],
        do: DB.query!(conn, "TRUNCATE mcp_sync.bindings CASCADE")

    binding = Ecto.UUID.generate()
    other_binding = Ecto.UUID.generate()

    for conn <- [context.admin, context.source_admin] do
      DB.binding!(conn, binding, "sync_test_a")
      DB.binding!(conn, other_binding, "sync_test_b", "b")
    end

    {:ok, binding: binding, other_binding: other_binding, key: %{"id" => "one"}}
  end

  defp publish(context, value \\ %{"title" => "remote"}, revision \\ "r1") do
    rows = [
      %{
        "key" => context.key,
        "revision" => revision,
        "value" => value,
        "deleted" => false,
        "eventId" => "0"
      }
    ]

    DB.scalar!(
      context.worker,
      "SELECT mcp_sync.publish_snapshot($1::text::uuid,$2::jsonb,$3::text,'initial')",
      [context.binding, rows, "sync:#{context.binding}:0"]
    )
  end

  defp put(context, value, revision) do
    DB.scalar!(
      context.app,
      "SELECT mcp_sync.put($1::text::uuid,$2::jsonb,$3::jsonb,$4::bigint)",
      [context.binding, context.key, value, revision]
    )
  end

  defp record(context) do
    DB.scalar!(
      context.admin,
      """
      SELECT jsonb_build_object('payload',payload,'localRevision',local_revision,'state',state,'sourceRevision',source_revision)
      FROM mcp_sync.records WHERE binding_id=$1::text::uuid AND resource_key=$2::jsonb
      """,
      [context.binding, context.key]
    )
  end

  defp count_outbox(context),
    do:
      DB.scalar!(
        context.admin,
        "SELECT count(*) FROM mcp_sync.outbox WHERE binding_id=$1::text::uuid",
        [context.binding]
      )

  test "local SQL rollback removes both row mutation and transactional outbox", context do
    publish(context)
    original = record(context)

    assert {:error, :deliberate_abort} =
             Postgrex.transaction(context.app, fn conn ->
               DB.scalar!(
                 conn,
                 "SELECT mcp_sync.put($1::text::uuid,$2::jsonb,$3::jsonb,$4::bigint)",
                 [
                   context.binding,
                   context.key,
                   %{"title" => "uncommitted"},
                   original["localRevision"]
                 ]
               )

               Postgrex.rollback(conn, :deliberate_abort)
             end)

    assert record(context) == original
    assert count_outbox(context) == 0
    put(context, %{"title" => "committed"}, original["localRevision"])
    assert record(context)["payload"] == %{"title" => "committed"}
    assert record(context)["state"] == "pending"
    assert count_outbox(context) == 1
  end

  test "two real SQL transactions race one expected revision and only one outbox commits",
       context do
    publish(context)
    old = record(context)["localRevision"]
    parent = self()
    app_pid = DB.scalar!(context.app, "SELECT pg_backend_pid()")
    contender_pid = DB.scalar!(context.app2, "SELECT pg_backend_pid()")

    query =
      "UPDATE mcp_sync.records SET payload=$3::jsonb,expected_local_revision=$4::bigint WHERE binding_id=$1::text::uuid AND resource_key=$2::jsonb"

    first =
      Task.async(fn ->
        Postgrex.transaction(context.app, fn conn ->
          DB.query!(conn, query, [context.binding, context.key, %{"writer" => 1}, old])
          send(parent, {:locked, self()})

          receive do
            :commit -> :ok
          after
            5000 -> raise "commit barrier timed out"
          end
        end)
      end)

    assert_receive {:locked, first_process}, 1000

    second =
      Task.async(fn ->
        Postgrex.query(context.app2, query, [context.binding, context.key, %{"writer" => 2}, old])
      end)

    await_blocked!(context.admin, contender_pid, app_pid)
    send(first_process, :commit)
    assert {:ok, :ok} = Task.await(first, 5000)
    assert {:error, %Postgrex.Error{postgres: %{pg_code: "40001"}}} = Task.await(second, 5000)
    assert record(context)["payload"] == %{"writer" => 1}
    assert record(context)["localRevision"] == old + 1
    assert count_outbox(context) == 1
  end

  test "pending rows reject further edits and direct SQL cannot forge metadata or physically delete",
       context do
    publish(context)
    revision = record(context)["localRevision"]

    assert {:error, %Postgrex.Error{}} =
             Postgrex.query(
               context.app,
               "UPDATE mcp_sync.records SET source_revision='forged', expected_local_revision=$2 WHERE binding_id=$1::text::uuid",
               [context.binding, revision]
             )

    assert {:error, %Postgrex.Error{}} =
             Postgrex.query(
               context.app,
               "DELETE FROM mcp_sync.records WHERE binding_id=$1::text::uuid",
               [context.binding]
             )

    put(context, %{"title" => "queued"}, revision)

    assert {:error, %Postgrex.Error{postgres: %{pg_code: "55000"}}} =
             Postgrex.query(
               context.app,
               "SELECT mcp_sync.put($1::text::uuid,$2::jsonb,$3::jsonb,$4::bigint)",
               [context.binding, context.key, %{"title" => "second"}, revision + 1]
             )

    assert count_outbox(context) == 1
  end

  test "actual login roles cannot cross binding boundaries or bypass privileged hooks", context do
    publish(context)
    assert DB.scalar!(context.app, "SELECT session_user") == "sync_test_a"
    assert DB.scalar!(context.other, "SELECT session_user") == "sync_test_b"

    assert DB.scalar!(
             context.other,
             "SELECT count(*) FROM mcp_sync.records WHERE binding_id=$1::text::uuid",
             [context.binding]
           ) == 0

    for sql <- [
          "TRUNCATE mcp_sync.records",
          "ALTER TABLE mcp_sync.records DISABLE TRIGGER ALL",
          "SET ROLE mcp_sync_owner",
          "SET ROLE mcp_sync_apply",
          "SET ROLE mcp_sync_worker",
          "UPDATE mcp_sync.outbox SET state='acknowledged'",
          "DELETE FROM mcp_sync.checkpoints",
          "SELECT mcp_sync.claim_outbox('#{context.binding}'::uuid)"
        ] do
      assert {:error, %Postgrex.Error{postgres: %{pg_code: "42501"}}} =
               Postgrex.query(context.app, sql, [])
    end

    assert {:error, %Postgrex.Error{}} =
             Postgrex.query(
               context.other,
               "SELECT mcp_sync.put($1::text::uuid,$2::jsonb,'{}'::jsonb,0)",
               [context.binding, context.key]
             )

    DB.query!(
      context.admin,
      "UPDATE mcp_sync.bindings SET enabled=false WHERE id=$1::text::uuid",
      [context.binding]
    )

    assert DB.scalar!(
             context.app,
             "SELECT count(*) FROM mcp_sync.records WHERE binding_id=$1::text::uuid",
             [context.binding]
           ) == 0
  end

  defp mutation(context, operation, operation_id, precondition, value \\ nil) do
    base = %{
      "relation" => "notes",
      "key" => context.key,
      "operationId" => operation_id,
      "operation" => operation,
      "precondition" => precondition
    }

    if is_nil(value), do: base, else: Map.put(base, "value", value)
  end

  defp mutate(conn, context, request),
    do:
      DB.scalar!(conn, "SELECT mcp_sync.source_mutate($1::text::uuid,$2::jsonb)", [
        context.binding,
        request
      ])

  test "source writes enforce CAS and durable operation replay rejects different content",
       context do
    operation = Ecto.UUID.generate()
    request = mutation(context, "create", operation, %{"absent" => true}, %{"title" => "initial"})
    first = mutate(context.source, context, request)
    assert is_binary(first["revision"])
    assert mutate(context.source, context, request) == first

    assert {:error, %Postgrex.Error{}} =
             Postgrex.query(
               context.source,
               "SELECT mcp_sync.source_mutate($1::text::uuid,$2::jsonb)",
               [context.binding, Map.put(request, "value", %{"title" => "different"})]
             )

    update =
      mutation(context, "update", Ecto.UUID.generate(), %{"revision" => first["revision"]}, %{
        "title" => "winner"
      })

    winner = mutate(context.source, context, update)
    refute winner["revision"] == first["revision"]
    stale = %{update | "operationId" => Ecto.UUID.generate(), "value" => %{"title" => "loser"}}

    assert {:error, %Postgrex.Error{}} =
             Postgrex.query(
               context.source,
               "SELECT mcp_sync.source_mutate($1::text::uuid,$2::jsonb)",
               [context.binding, stale]
             )

    assert mutate(context.source, context, request) == first
  end

  test "controlled source cannot be changed through unversioned app SQL", context do
    for table <- ["source_records", "source_changes", "source_operations", "source_heads"] do
      assert {:error, %Postgrex.Error{postgres: %{pg_code: "42501"}}} =
               Postgrex.query(context.source, "DELETE FROM mcp_sync.#{table}", [])
    end
  end

  test "source commit cursors cannot skip a transaction still holding the source head", context do
    first_request =
      mutation(context, "create", Ecto.UUID.generate(), %{"absent" => true}, %{"writer" => 1})

    second_request =
      mutation(
        %{context | key: %{"id" => "two"}},
        "create",
        Ecto.UUID.generate(),
        %{"absent" => true},
        %{"writer" => 2}
      )

    parent = self()
    first_pid = DB.scalar!(context.source, "SELECT pg_backend_pid()")
    second_pid = DB.scalar!(context.source2, "SELECT pg_backend_pid()")

    first =
      Task.async(fn ->
        Postgrex.transaction(context.source, fn conn ->
          result = mutate(conn, context, first_request)
          send(parent, {:source_locked, self()})

          receive do
            :commit -> result
          after
            5000 -> raise "source commit barrier timed out"
          end
        end)
      end)

    assert_receive {:source_locked, first_process}, 1000
    second = Task.async(fn -> mutate(context.source2, context, second_request) end)
    await_blocked!(context.source_admin, second_pid, first_pid)

    before =
      DB.scalar!(context.source3, "SELECT mcp_sync.source_changes($1::text::uuid,NULL,500)", [
        context.binding
      ])

    assert before["events"] == []
    assert before["nextCursor"] == "sync:#{context.binding}:0"
    send(first_process, :commit)
    assert {:ok, _} = Task.await(first, 5000)
    Task.await(second, 5000)

    after_commit =
      DB.scalar!(context.source3, "SELECT mcp_sync.source_changes($1::text::uuid,$2::text,500)", [
        context.binding,
        before["nextCursor"]
      ])

    assert Enum.map(after_commit["events"], & &1["eventId"]) == ["1", "2"]
  end

  test "snapshot continuation retains one boundary while later changes and tombstones stay replayable",
       context do
    created =
      for index <- 1..3 do
        item = %{context | key: %{"id" => to_string(index)}}

        mutate(
          context.source,
          item,
          mutation(item, "create", Ecto.UUID.generate(), %{"absent" => true}, %{
            "index" => index,
            "generation" => 0
          })
        )
      end

    first =
      DB.scalar!(context.source, "SELECT mcp_sync.source_snapshot($1::text::uuid,NULL,1)", [
        context.binding
      ])

    item = %{context | key: %{"id" => "2"}}

    changed =
      mutate(
        context.source,
        item,
        mutation(
          item,
          "update",
          Ecto.UUID.generate(),
          %{"revision" => Enum.at(created, 1)["revision"]},
          %{"index" => 2, "generation" => 1}
        )
      )

    second =
      DB.scalar!(context.source, "SELECT mcp_sync.source_snapshot($1::text::uuid,$2::text,1)", [
        context.binding,
        first["nextCursor"]
      ])

    third =
      DB.scalar!(context.source, "SELECT mcp_sync.source_snapshot($1::text::uuid,$2::text,1)", [
        context.binding,
        second["nextCursor"]
      ])

    assert third["nextCursor"] == nil

    assert Enum.all?(
             [second, third],
             &(&1["snapshotId"] == first["snapshotId"] and
                 &1["changeCursor"] == first["changeCursor"])
           )

    assert Enum.all?(
             first["rows"] ++ second["rows"] ++ third["rows"],
             &(&1["value"]["generation"] == 0)
           )

    deleted =
      mutate(
        context.source,
        item,
        mutation(item, "delete", Ecto.UUID.generate(), %{"revision" => changed["revision"]})
      )

    assert deleted["deleted"] == true

    changes =
      DB.scalar!(context.source, "SELECT mcp_sync.source_changes($1::text::uuid,$2::text,500)", [
        context.binding,
        first["changeCursor"]
      ])

    assert length(changes["events"]) == 2
    assert List.last(changes["events"])["deleted"] == true

    assert DB.scalar!(
             context.source,
             "SELECT mcp_sync.source_changes($1::text::uuid,$2::text,500)",
             [context.binding, first["changeCursor"]]
           ) == changes

    DB.query!(
      context.source_admin,
      "UPDATE mcp_sync.source_snapshots SET expires_at=clock_timestamp()-interval '1 second'"
    )

    assert {:error, %Postgrex.Error{postgres: %{pg_code: "55000"}}} =
             Postgrex.query(
               context.source,
               "SELECT mcp_sync.source_snapshot($1::text::uuid,$2::text,1)",
               [context.binding, first["nextCursor"]]
             )
  end

  defp worker_opts(context) do
    [
      store_repo: SyncCacheRepo,
      binding_id: context.binding,
      source:
        {RevisionedDataset,
         %{repo: SyncSourceRepo, binding_id: context.binding, relation: "notes"}}
    ]
  end

  defp expire_lease(context) do
    DB.query!(
      context.admin,
      "UPDATE mcp_sync.outbox SET lease_until=clock_timestamp()-interval '1 second',next_attempt_at=clock_timestamp()-interval '1 second' WHERE binding_id=$1::text::uuid",
      [context.binding]
    )
  end

  test "two claimers cannot deliver one leased operation and expired fencing rejects old ACK",
       context do
    put(context, %{"value" => "local"}, 0)
    opts = worker_opts(context)

    parent = self()

    claimant =
      Task.async(fn ->
        Postgrex.transaction(context.worker, fn conn ->
          operation =
            DB.scalar!(conn, "SELECT mcp_sync.claim_outbox($1::text::uuid,30)", [context.binding])

          send(parent, {:claimed_under_lock, operation})

          receive do
            :commit_claim -> operation
          after
            5_000 -> raise "claim barrier was not released"
          end
        end)
      end)

    assert_receive {:claimed_under_lock, first}, 2_000
    # This uses another real connection while the first transaction retains its row lock.
    assert {:ok, nil} = Store.claim(SyncCacheRepo, context.binding, 30)
    send(claimant.pid, :commit_claim)
    assert {:ok, ^first} = Task.await(claimant)
    expire_lease(context)
    assert {:ok, second} = Store.claim(SyncCacheRepo, context.binding, 30)
    assert second["operationId"] == first["operationId"]
    assert second["fencingToken"] > first["fencingToken"]

    request =
      first
      |> Map.take(~w(operationId key operation precondition value))
      |> Map.put("relation", "notes")

    result = mutate(context.source, context, request)

    assert {:ok, %{"applied" => false}} =
             Store.ack(SyncCacheRepo, first["operationId"], first["fencingToken"], result)

    assert record(context)["state"] == "pending"

    assert {:ok, %{"applied" => true}} =
             Store.ack(SyncCacheRepo, second["operationId"], second["fencingToken"], result)

    assert {:ok, :idle} = Worker.run_once(opts)
    assert record(context)["state"] == "clean"
  end

  test "remote commit before local ACK recovers by operation lookup without duplicate effect",
       context do
    put(context, %{"value" => "committed remotely"}, 0)
    assert {:ok, claimed} = Store.claim(SyncCacheRepo, context.binding, 30)

    request =
      claimed
      |> Map.take(~w(operationId key operation precondition value))
      |> Map.put("relation", "notes")

    committed = mutate(context.source, context, request)
    # Process loss at this durable boundary leaves a claimed lease and committed source operation.
    expire_lease(context)
    assert {:ok, %{"applied" => true}} = Worker.run_once(worker_opts(context))
    assert record(context)["sourceRevision"] == committed["revision"]

    assert DB.scalar!(
             context.source_admin,
             "SELECT count(*) FROM mcp_sync.source_changes WHERE binding_id=$1::text::uuid",
             [context.binding]
           ) == 1

    assert {:ok, :idle} = Worker.run_once(worker_opts(context))
  end

  test "event acknowledgment followed by newer remote event cannot be regressed by delayed ACK",
       context do
    assert {:ok, _} = Worker.snapshot(worker_opts(context))
    put(context, %{"value" => "first"}, 0)
    assert {:ok, claimed} = Store.claim(SyncCacheRepo, context.binding, 30)

    request =
      claimed
      |> Map.take(~w(operationId key operation precondition value))
      |> Map.put("relation", "notes")

    original = mutate(context.source, context, request)
    assert {:ok, _} = Worker.pull_once(worker_opts(context))
    assert record(context)["state"] == "clean"

    newer =
      mutate(
        context.source,
        context,
        mutation(
          context,
          "update",
          Ecto.UUID.generate(),
          %{"revision" => original["revision"]},
          %{"value" => "newer"}
        )
      )

    assert {:ok, _} = Worker.pull_once(worker_opts(context))
    before = record(context)
    assert before["sourceRevision"] == newer["revision"]

    assert {:ok, %{"applied" => false}} =
             Store.ack(SyncCacheRepo, claimed["operationId"], claimed["fencingToken"], original)

    assert record(context) == before
  end

  test "remote pull preserves dirty local edit and conflicts require fresh observation before discard",
       context do
    original =
      mutate(
        context.source,
        context,
        mutation(context, "create", Ecto.UUID.generate(), %{"absent" => true}, %{
          "value" => "base"
        })
      )

    assert {:ok, _} = Worker.snapshot(worker_opts(context))
    put(context, %{"value" => "local"}, record(context)["localRevision"])

    remote =
      mutate(
        context.source,
        context,
        mutation(
          context,
          "update",
          Ecto.UUID.generate(),
          %{"revision" => original["revision"]},
          %{"value" => "remote"}
        )
      )

    assert {:ok, _} = Worker.pull_once(worker_opts(context))
    assert record(context)["payload"] == %{"value" => "local"}
    assert {:ok, _} = Worker.run_once(worker_opts(context))
    assert record(context)["state"] == "conflict"

    conflict =
      DB.scalar!(
        context.admin,
        "SELECT id::text FROM mcp_sync.conflicts WHERE binding_id=$1::text::uuid",
        [context.binding]
      )

    assert {:error, _} =
             Store.resolve(
               SyncAppRepo,
               conflict,
               "accept_remote",
               record(context)["localRevision"]
             )

    assert {:ok, _} = Worker.pull_once(worker_opts(context))

    assert {:ok, _} =
             Store.resolve(
               SyncAppRepo,
               conflict,
               "accept_remote",
               record(context)["localRevision"]
             )

    assert record(context)["payload"] == %{"value" => "remote"}
    assert record(context)["sourceRevision"] == remote["revision"]
  end

  test "expired dedupe horizon blocks unknown local work without another remote mutation",
       context do
    put(context, %{"value" => "uncertain"}, 0)
    assert {:ok, _} = Store.claim(SyncCacheRepo, context.binding, 30)
    expire_lease(context)

    DB.query!(
      context.admin,
      "UPDATE mcp_sync.outbox SET first_attempt_at=clock_timestamp()-interval '8 days' WHERE binding_id=$1::text::uuid",
      [context.binding]
    )

    assert {:ok, :idle} = Worker.run_once(worker_opts(context))
    assert record(context)["state"] == "blocked"

    assert DB.scalar!(context.source_admin, "SELECT count(*) FROM mcp_sync.source_changes", []) ==
             0
  end

  test "snapshot reconciliation retains tombstones and never resurrects removed rows", context do
    created =
      mutate(
        context.source,
        context,
        mutation(context, "create", Ecto.UUID.generate(), %{"absent" => true}, %{
          "value" => "base"
        })
      )

    assert {:ok, _} = Worker.snapshot(worker_opts(context))

    mutate(
      context.source,
      context,
      mutation(context, "delete", Ecto.UUID.generate(), %{"revision" => created["revision"]})
    )

    assert {:ok, _} = Worker.pull_once(worker_opts(context))
    assert record(context)["state"] == "tombstone"
    assert {:ok, _} = Worker.snapshot(worker_opts(context))
    assert record(context)["state"] == "tombstone"

    assert DB.scalar!(
             context.app,
             "SELECT count(*) FROM mcp_sync.records WHERE binding_id=$1::text::uuid AND NOT deleted",
             [context.binding]
           ) == 0
  end

  test "ten thousand indexed local rows remain queryable with source access disabled", context do
    rows =
      Enum.map(1..10_000, fn i ->
        %{
          "key" => %{"id" => i},
          "revision" => "r#{i}",
          "value" => %{"position" => i},
          "deleted" => false,
          "eventId" => "0"
        }
      end)

    assert {:ok, _} =
             Store.publish_snapshot(
               SyncCacheRepo,
               context.binding,
               rows,
               "sync:#{context.binding}:0",
               "bulk"
             )

    DB.query!(context.source_admin, "UPDATE mcp_sync.bindings SET enabled=false")

    assert DB.scalar!(
             context.app,
             "SELECT count(*) FROM mcp_sync.records WHERE binding_id=$1::text::uuid",
             [context.binding]
           ) == 10_000

    assert DB.scalar!(
             context.app,
             "SELECT payload FROM mcp_sync.records WHERE binding_id=$1::text::uuid AND resource_key=$2::jsonb",
             [context.binding, %{"id" => 5000}]
           ) == %{"position" => 5000}

    assert DB.scalar!(context.source_admin, "SELECT count(*) FROM mcp_sync.source_snapshots", []) ==
             0

    assert DB.scalar!(context.source_admin, "SELECT count(*) FROM mcp_sync.source_operations", []) ==
             0
  end

  test "malformed source mutations and direct local payload edits have no durable effect",
       context do
    valid =
      mutation(context, "create", Ecto.UUID.generate(), %{"absent" => true}, %{"value" => "valid"})

    for invalid <- [
          Map.put(valid, "key", %{}),
          Map.put(valid, "value", [1, 2]),
          Map.put(valid, "precondition", %{"absent" => true, "revision" => "ambiguous"})
        ] do
      assert {:error, %Postgrex.Error{}} =
               Postgrex.query(
                 context.source,
                 "SELECT mcp_sync.source_mutate($1::text::uuid,$2::jsonb)",
                 [context.binding, invalid]
               )
    end

    assert DB.scalar!(context.source_admin, "SELECT count(*) FROM mcp_sync.source_operations", []) ==
             0

    for payload <- [nil, [1, 2], "scalar"] do
      assert {:error, %Postgrex.Error{}} =
               Postgrex.query(
                 context.app,
                 "SELECT mcp_sync.put($1::text::uuid,$2::jsonb,$3::jsonb,0)",
                 [context.binding, context.key, payload]
               )
    end

    assert count_outbox(context) == 0
  end

  test "snapshot row bound failure preserves the previous published generation", context do
    mutate(
      context.source,
      context,
      mutation(context, "create", Ecto.UUID.generate(), %{"absent" => true}, %{"value" => "new"})
    )

    publish(context, %{"value" => "old"})
    before = record(context)
    assert {:error, _} = Worker.snapshot(Keyword.put(worker_opts(context), :max_snapshot_rows, 0))
    assert record(context) == before
    assert {:ok, %{"cursor" => cursor}} = Store.checkpoint(SyncCacheRepo, context.binding)
    assert cursor == "sync:#{context.binding}:0"
  end

  defp await_blocked!(admin, pid, blocker) do
    found =
      Enum.reduce_while(1..100, false, fn _, _ ->
        if DB.scalar!(admin, "SELECT $2::integer=ANY(pg_blocking_pids($1::integer))", [
             pid,
             blocker
           ]) do
          {:halt, true}
        else
          Process.sleep(10)
          {:cont, false}
        end
      end)

    assert found, "contender never waited on the independently held row lock"
  end
end
