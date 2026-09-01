defmodule Noizu.MCP.VFS.MemoryConformanceTest do
  # The full battery from `Noizu.MCP.VFS.Conformance` (stat/list/read/write/
  # create/remove/search/xattr, error atoms, cursors, cache invalidation) run
  # against the in-memory fixture backend.
  use Noizu.MCP.VFS.Conformance,
    backend: Noizu.MCP.VFS.Fixture.Memory,
    seed: {Noizu.MCP.VFS.Fixture.Memory, :seed}
end

defmodule Noizu.MCP.VFS.NullTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.Server.Features.VFS
  alias Noizu.MCP.VFS.Null

  @ctx %Noizu.MCP.Ctx{}

  test "stat/2: / is a read-only dir, everything else :enoent" do
    assert {:ok, node} = Null.stat("/", @ctx)
    assert node.type == :dir
    assert node.writable == false
    assert {:error, :enoent} = Null.stat("/x", @ctx)
  end

  test "list/3: / is empty, other paths :enotdir" do
    assert {:ok, [], nil} = Null.list("/", nil, @ctx)
    assert {:error, :enotdir} = Null.list("/x", nil, @ctx)
  end

  test "read/2: / is :eisdir, other paths :enoent" do
    assert {:error, :eisdir} = Null.read("/", @ctx)
    assert {:error, :enoent} = Null.read("/x", @ctx)
  end

  test "mutating defaults are :enosys, xattr defaults to {:ok, %{}}" do
    assert {:error, :enosys} = Null.write("/x", "data", @ctx)
    assert {:error, :enosys} = Null.create("/x", "data", @ctx)
    assert {:error, :enosys} = Null.remove("/x", @ctx)
    assert {:error, :enosys} = Null.search("/", "query", @ctx)
    assert {:ok, %{}} = Null.xattr("/x", @ctx)
  end

  test "not write-capable" do
    assert Noizu.MCP.Server.VFS.write_capable?(Null) == false
    assert Noizu.MCP.Server.VFS.capabilities(Null) == %{"vfs" => true, "vfs_write" => false}
  end
end

defmodule Noizu.MCP.VFS.CacheTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.VFS.Cache

  defmodule Backend, do: []

  setup do
    Cache.purge(Backend)
    Cache.bump_generation(Backend)
    :ok
  end

  test "put/get round-trips under the current generation" do
    Cache.put(Backend, :stat, "/x", :the_node, 60_000)
    assert Cache.get(Backend, :stat, "/x") == :the_node
    assert Cache.get(Backend, :stat, "/missing") == nil
  end

  test "bump_generation invalidates entries" do
    Cache.put(Backend, :stat, "/x", :stale, 60_000)
    Cache.bump_generation(Backend)
    assert Cache.generation(Backend) > 0
    assert Cache.get(Backend, :stat, "/x") == nil
  end

  test "expired entries are misses" do
    Cache.put(Backend, :read, "/x", {:ok, "data", 1}, 1)
    Process.sleep(5)
    assert Cache.get(Backend, :read, "/x") == nil
  end

  test "read entries validate against an expected version" do
    Cache.put(Backend, :read, "/x", {:ok, "v1", 7}, 60_000)
    assert Cache.get(Backend, :read, "/x", version: 7) == {:ok, "v1", 7}
    assert Cache.get(Backend, :read, "/x", version: 8) == nil
  end

  test "purge drops everything for the module" do
    Cache.put(Backend, :stat, "/x", :node, 60_000)
    Cache.put(Backend, :list, "/", {:e, nil}, 60_000)
    Cache.purge(Backend)
    assert Cache.get(Backend, :stat, "/x") == nil
    assert Cache.get(Backend, :list, "/") == nil
  end

  test "disabled cache is a pass-through miss" do
    Application.put_env(:noizu_mcp, :vfs_cache_enabled, false)

    try do
      Cache.put(Backend, :stat, "/x", :node, 60_000)
      assert Cache.get(Backend, :stat, "/x") == nil
    after
      Application.delete_env(:noizu_mcp, :vfs_cache_enabled)
    end
  end
end

defmodule Noizu.MCP.VfsDispatcherTest do
  use ExUnit.Case, async: false

  alias Noizu.MCP.Error
  alias Noizu.MCP.Server.Features.VFS
  alias Noizu.MCP.VFS.Fixture.Memory

  defmodule TestServer do
    use Noizu.MCP.Server, name: "vfs-dispatch-test", version: "1.0.0"
    vfs(Noizu.MCP.VFS.Fixture.Memory)
  end

  defmodule NullServer do
    use Noizu.MCP.Server, name: "vfs-null-test", version: "1.0.0"
    vfs(Noizu.MCP.VFS.Null)
  end

  defmodule BareServer do
    use Noizu.MCP.Server, name: "vfs-bare-test", version: "1.0.0"
  end

  setup do
    ctx = Memory.seed()
    on_exit(fn -> Noizu.MCP.VFS.Cache.purge(Memory) end)
    %{ctx: ctx}
  end

  test "vfs_stat returns a node map", %{ctx: ctx} do
    assert {:ok, node} = VFS.vfs_stat(TestServer, %{"path" => "/hello.txt"}, ctx)
    assert node["type"] == "file"
    assert node["size"] == byte_size("hello world\n")
    assert is_boolean(node["writable"])
    assert is_map(node["xattrs"])
  end

  test "vfs_stat validates params and maps errnos to errors", %{ctx: ctx} do
    assert {:error, %Error{code: -32602}} = VFS.vfs_stat(TestServer, %{}, ctx)
    assert {:error, %Error{}} = VFS.vfs_stat(TestServer, %{"path" => "/nope"}, ctx)
  end

  test "vfs_list returns entries (and nextCursor when paginated)", %{ctx: ctx} do
    assert {:ok, %{"entries" => entries}} = VFS.vfs_list(TestServer, %{"path" => "/"}, ctx)
    assert Enum.any?(entries, &match?(%{name: "hello.txt", type: :file}, &1))

    assert {:error, %Error{}} =
             VFS.vfs_list(TestServer, %{"path" => "/", "cursor" => "junk"}, ctx)
  end

  test "vfs_read returns content and version", %{ctx: ctx} do
    assert {:ok, %{"content" => "hello world\n", "version" => v}} =
             VFS.vfs_read(TestServer, %{"path" => "/hello.txt"}, ctx)

    assert is_integer(v)
  end

  test "vfs_write bumps the generation: the next stat sees a higher version", %{ctx: ctx} do
    {:ok, before} = VFS.vfs_stat(TestServer, %{"path" => "/hello.txt"}, ctx)

    assert {:ok, node} =
             VFS.vfs_write(TestServer, %{"path" => "/hello.txt", "data" => "new\n"}, ctx)

    assert node["version"] > before["version"]

    {:ok, post} = VFS.vfs_stat(TestServer, %{"path" => "/hello.txt"}, ctx)
    assert post["version"] == node["version"]
  end

  test "vfs_create: binary data makes a file, missing data makes a dir", %{ctx: ctx} do
    assert {:ok, %{"type" => "file"}} =
             VFS.vfs_create(TestServer, %{"path" => "/made.txt", "data" => "x"}, ctx)

    assert {:ok, %{"type" => "dir"}} = VFS.vfs_create(TestServer, %{"path" => "/made-dir"}, ctx)
    assert {:error, %Error{}} = VFS.vfs_create(TestServer, %{"path" => "/made.txt"}, ctx)
  end

  test "vfs_remove reports the removed path and then it is gone", %{ctx: ctx} do
    assert {:ok, %{"removed" => "/hello.txt"}} =
             VFS.vfs_remove(TestServer, %{"path" => "/hello.txt"}, ctx)

    assert {:error, %Error{}} = VFS.vfs_stat(TestServer, %{"path" => "/hello.txt"}, ctx)
  end

  test "vfs_search paginates full match lists with a wire cursor", %{ctx: ctx} do
    assert {:ok, %{"matches" => matches}} =
             VFS.vfs_search(TestServer, %{"query" => "alpha"}, ctx)

    assert matches == [%{path: "/docs/a.md", line: 1, text: "# alpha"}]

    assert {:error, %Error{}} =
             VFS.vfs_search(TestServer, %{"query" => "alpha", "cursor" => "junk"}, ctx)
  end

  test "vfs_xattr returns the attribute map", %{ctx: ctx} do
    assert {:ok, xattrs} = VFS.vfs_xattr(TestServer, %{"path" => "/hello.txt"}, ctx)
    assert xattrs == %{}
  end

  test "server without a VFS registration is capability_not_supported", %{ctx: ctx} do
    assert {:error, %Error{}} = VFS.vfs_stat(BareServer, %{"path" => "/x"}, ctx)
  end

  test "Null-backed server stats the empty tree and refuses writes", %{ctx: ctx} do
    assert {:ok, %{"type" => "dir"}} = VFS.vfs_stat(NullServer, %{"path" => "/"}, ctx)
    assert {:error, %Error{}} = VFS.vfs_write(NullServer, %{"path" => "/x", "data" => "y"}, ctx)
  end
end

defmodule Noizu.MCP.VfsDslTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.VFS.Fixture.Memory

  defmodule WritableServer do
    use Noizu.MCP.Server, name: "vfs-dsl-writable", version: "1.0.0"
    vfs(Noizu.MCP.VFS.Fixture.Memory)
  end

  defmodule ReadOnlyServer do
    use Noizu.MCP.Server, name: "vfs-dsl-readonly", version: "1.0.0"
    vfs(Noizu.MCP.VFS.Null)
  end

  defmodule OverrideServer do
    use Noizu.MCP.Server, name: "vfs-dsl-override", version: "1.0.0"
    vfs(Noizu.MCP.VFS.Null, name: "etc")
  end

  defmodule BareServer do
    use Noizu.MCP.Server, name: "vfs-dsl-bare", version: "1.0.0"
  end

  test "vfs/2 registers the backend" do
    assert WritableServer.__mcp__(:vfs) == [{Memory, []}]
    assert OverrideServer.__mcp__(:vfs) == [{Noizu.MCP.VFS.Null, name: "etc"}]
    assert BareServer.__mcp__(:vfs) == []
  end

  test "writable backend advertises vfs and vfs_write capabilities" do
    caps = WritableServer.__mcp__(:capabilities)
    assert caps["vfs"] == true
    assert caps["vfs_write"] == true
  end

  test "read-only backend advertises vfs but not vfs_write" do
    caps = ReadOnlyServer.__mcp__(:capabilities)
    assert caps["vfs"] == true
    assert caps["vfs_write"] == nil
  end

  test "servers without a VFS have neither flag" do
    defmodule NoVfsServer do
      use Noizu.MCP.Server, name: "vfs-dsl-none", version: "1.0.0"
    end

    caps = NoVfsServer.__mcp__(:capabilities)
    assert caps["vfs"] == nil
    assert caps["vfs_write"] == nil
  end
end
