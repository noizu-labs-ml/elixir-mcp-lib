defmodule Noizu.MCP.Server.VFSPubSubTest do
  use ExUnit.Case, async: false

  alias Noizu.MCP.Ctx
  alias Noizu.MCP.Server.Features.VFS
  alias Noizu.MCP.Server.VFSPubSub
  alias Noizu.MCP.VFS.Fixture.Memory

  @backend Memory
  @event_timeout 500

  defmodule MemoryServer do
    use Noizu.MCP.Server, name: "vfs-pubsub-memory", version: "1.0.0"
    vfs(Noizu.MCP.VFS.Fixture.Memory)
  end

  defp tree_spec do
    %{
      "/" => :dir,
      "/hello.txt" => "hello world\n",
      "/docs" => :dir,
      "/docs/a.md" => "# alpha\n",
      "/docs/sub" => :dir,
      "/docs/sub/deep.md" => "deep\n"
    }
  end

  defp seeded_ctx do
    Memory.seed(tree_spec())
  end

  setup do
    start_supervised!(VFSPubSub)
    %{ctx: seeded_ctx()}
  end

  defp write(ctx, path, data), do: VFS.write(@backend, path, data, ctx)
  defp create(ctx, path, data), do: VFS.create(@backend, path, data, ctx)
  defp remove(ctx, path), do: VFS.remove(@backend, path, ctx)

  defp event_fields(timeout \\ @event_timeout) do
    assert_receive {:vfs_event, event}, timeout
    event
  end

  # ── exact + subtree delivery ──────────────────────────────────────────────

  test "exact watch receives the write event with version and seq", %{ctx: ctx} do
    :ok = VFSPubSub.watch(@backend, "/hello.txt", depth: 0)

    {:ok, node} = write(ctx, "/hello.txt", "new\n")
    event = event_fields()

    assert %{op: :write, path: "/hello.txt", seq: 1} = event
    assert event.version == node.version
    assert is_integer(event.at)
  end

  test "subtree watch (default depth) catches writes below the root", %{ctx: ctx} do
    :ok = VFSPubSub.watch(@backend, "/docs")

    {:ok, _} = write(ctx, "/docs/a.md", "x")
    assert %{op: :write, path: "/docs/a.md"} = event_fields()

    {:ok, _} = create(ctx, "/docs/new.md", "y")
    assert %{op: :create, path: "/docs/new.md"} = event_fields()

    :ok = remove(ctx, "/docs/new.md")
    assert %{op: :remove, path: "/docs/new.md"} = event_fields()
  end

  test "root watch catches everything", %{ctx: ctx} do
    :ok = VFSPubSub.watch(@backend, "/")

    {:ok, _} = write(ctx, "/hello.txt", "x")
    assert %{path: "/hello.txt"} = event_fields()

    {:ok, _} = write(ctx, "/docs/sub/deep.md", "y")
    assert %{path: "/docs/sub/deep.md"} = event_fields()
  end

  test "unrelated writes produce no events", %{ctx: ctx} do
    :ok = VFSPubSub.watch(@backend, "/docs", depth: 0)

    {:ok, _} = write(ctx, "/hello.txt", "x")

    refute_receive {:vfs_event, _}, 150
  end

  test "depth bounds subtree delivery", %{ctx: ctx} do
    :ok = VFSPubSub.watch(@backend, "/docs", depth: 1)

    # delta 1 — delivered.
    {:ok, _} = write(ctx, "/docs/a.md", "x")
    assert %{path: "/docs/a.md"} = event_fields()

    # delta 2 — filtered.
    {:ok, _} = write(ctx, "/docs/sub/deep.md", "y")
    refute_receive {:vfs_event, _}, 150
  end

  # ── debounce coalescing ───────────────────────────────────────────────────

  test "a burst of writes to one path coalesces into the final version", %{ctx: ctx} do
    :ok = VFSPubSub.watch(@backend, "/hello.txt")

    {:ok, _} = write(ctx, "/hello.txt", "1\n")
    {:ok, _} = write(ctx, "/hello.txt", "22\n")
    {:ok, final} = write(ctx, "/hello.txt", "333\n")

    event = event_fields()
    assert event.version == final.version
    assert event.seq == 1

    refute_receive {:vfs_event, _}, 150
  end

  test "writes to different paths in a burst stay separate events", %{ctx: ctx} do
    :ok = VFSPubSub.watch(@backend, "/")

    {:ok, _} = write(ctx, "/hello.txt", "1\n")
    {:ok, _} = write(ctx, "/docs/a.md", "2\n")

    events = [event_fields(), event_fields()]
    assert Enum.map(events, & &1.path) |> Enum.sort() == ["/docs/a.md", "/hello.txt"]
  end

  test "seq is monotonic per subscriber across events", %{ctx: ctx} do
    :ok = VFSPubSub.watch(@backend, "/")

    {:ok, _} = write(ctx, "/hello.txt", "1\n")
    {:ok, _} = write(ctx, "/docs/a.md", "2\n")

    seqs = [event_fields().seq, event_fields().seq]
    assert seqs == Enum.sort(seqs)
    assert length(Enum.uniq(seqs)) == 2
  end

  test "carries the writer identity from ctx claims", %{ctx: ctx} do
    :ok = VFSPubSub.watch(@backend, "/hello.txt")

    %Ctx{assigns: assigns} = ctx
    claims_ctx = %Ctx{ctx | assigns: Map.put(assigns, :auth_claims, %{"sub" => "writer-1"})}
    {:ok, _} = write(claims_ctx, "/hello.txt", "x\n")

    assert %{by: "writer-1"} = event_fields()
  end

  # ── unwatch / cap / lifecycle ─────────────────────────────────────────────

  test "unwatch stops delivery", %{ctx: ctx} do
    :ok = VFSPubSub.watch(@backend, "/hello.txt")
    :ok = VFSPubSub.unwatch(@backend, "/hello.txt")

    {:ok, _} = write(ctx, "/hello.txt", "x\n")

    refute_receive {:vfs_event, _}, 150
  end

  test "watch cap returns ewouldwatch", %{ctx: ctx} do
    paths = Enum.map(1..10_000, &"/cap-#{String.pad_leading(Integer.to_string(&1), 5, "0")}")
    assert :ok = VFSPubSub.watch(@backend, paths)
    assert {:error, :ewouldwatch} = VFSPubSub.watch(@backend, "/hello.txt")

    # Freeing one slot makes room again.
    :ok = VFSPubSub.unwatch(@backend, Enum.take(paths, 1))
    assert :ok = VFSPubSub.watch(@backend, "/hello.txt")
    assert VFSPubSub.watch_count(self()) == 10_000
  end

  test "dead subscribers are cleaned up", %{ctx: ctx} do
    parent = self()

    pid =
      spawn(fn ->
        :ok = VFSPubSub.watch(@backend, "/hello.txt")
        send(parent, :watched)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :watched
    Process.exit(pid, :kill)
    Process.sleep(50)

    assert VFSPubSub.watch_count(pid) == 0
    assert VFSPubSub.watchers(@backend, "/hello.txt") == []

    # The hub survives publishing to a dead watcher and still serves others.
    {:ok, _} = write(ctx, "/hello.txt", "x\n")
    :ok = VFSPubSub.watch(@backend, "/hello.txt")
    {:ok, _} = write(ctx, "/hello.txt", "y\n")

    assert %{path: "/hello.txt", version: _} = event_fields()
  end

  test "publish with no pubsub running is a no-op", %{ctx: ctx} do
    stop_supervised!(VFSPubSub)

    {:ok, _} = write(ctx, "/hello.txt", "x\n")
    assert {:ok, _, _} = VFS.read(@backend, "/hello.txt", ctx)
  end

  test "invalid depth is rejected", %{ctx: ctx} do
    assert {:error, :ebaddepth} = VFSPubSub.watch(@backend, "/hello.txt", depth: -1)
    assert {:error, :ebaddepth} = VFSPubSub.watch(@backend, "/hello.txt", depth: "all")
  end

  test "server-level ops publish through the dispatcher", %{ctx: ctx} do
    server_ctx = %Ctx{server: MemoryServer, assigns: ctx.assigns}
    :ok = VFSPubSub.watch(@backend, "/")

    assert {:ok, _} =
             VFS.vfs_write(MemoryServer, %{"path" => "/hello.txt", "data" => "z\n"}, server_ctx)

    assert %{op: :write, path: "/hello.txt"} = event_fields()
  end
end
