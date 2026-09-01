defmodule VfsDemoServer.BackendTest do
  use ExUnit.Case, async: false

  alias VfsDemoServer.{Backend, TestServer}

  setup do
    _sup = start_supervised!({TestServer, seed: :default})
    :ok
  end

  @ctx %Noizu.MCP.Ctx{server: Backend, transport: :vfs_demo_test}

  test "seed tree is loaded" do
    {:ok, root} = Backend.stat("/", @ctx)
    assert root.type == :dir

    {:ok, file} = Backend.stat("/notes/welcome.md", @ctx)
    assert file.type == :file
    assert file.version >= 1
    assert file.writable
  end

  test "read round-trips seed content" do
    {:ok, content, version} = Backend.read("/notes/welcome.md", @ctx)
    assert content =~ "real files"
    assert is_integer(version)
  end

  test "write bumps version monotonically" do
    {:ok, _c, v0} = Backend.read("/etc/dev/flag", @ctx)

    {:ok, node1} = Backend.write("/etc/dev/flag", "on\n", @ctx)
    {:ok, node2} = Backend.write("/etc/dev/flag", "off\n", @ctx)

    assert node1.version == v0 + 1
    assert node2.version == node1.version + 1
  end

  test "create file and directory, then remove" do
    {:ok, node} = Backend.create("/notes/new.md", "fresh\n", @ctx)
    assert node.type == :file
    assert {:ok, "fresh\n", _} = Backend.read("/notes/new.md", @ctx)

    {:ok, dir} = Backend.create("/notes/archive", :dir, @ctx)
    assert dir.type == :dir

    assert :ok = Backend.remove("/notes/new.md", @ctx)
    assert :ok = Backend.remove("/notes/archive", @ctx)
    assert {:error, :enoent} = Backend.read("/notes/new.md", @ctx)
  end

  test "list returns direct children with entries" do
    {:ok, entries, nil} = Backend.list("/notes", nil, @ctx)
    names = Enum.map(entries, & &1.name)
    assert "welcome.md" in names
    assert entries |> Enum.all?(&is_map/1)
  end

  test "search finds line matches under root" do
    {:ok, matches, nil} = Backend.search("/", "Welcome", @ctx)
    assert [%{path: "/notes/welcome.md", line: 1, text: text}] = matches
    assert text =~ "Welcome"
  end

  test "xattr defaults" do
    assert {:ok, xattrs} = Backend.xattr("/notes/welcome.md", @ctx)
    assert xattrs == %{}
  end

  test "errno matrix" do
    assert {:error, :enoent} = Backend.read("/missing", @ctx)
    assert {:error, :enoent} = Backend.stat("/missing", @ctx)
    assert {:error, :enoent} = Backend.write("/missing", "x", @ctx)
    assert {:error, :eexist} = Backend.create("/notes/welcome.md", "dup", @ctx)
    assert {:error, :eexist} = Backend.create("/", :dir, @ctx)
    assert {:error, :eisdir} = Backend.read("/notes", @ctx)
    assert {:error, :eisdir} = Backend.write("/notes", "x", @ctx)
    assert {:error, :enotdir} = Backend.list("/notes/welcome.md", nil, @ctx)
    assert {:error, :enotempty} = Backend.remove("/notes", @ctx)
    assert {:error, :enoent} = Backend.remove("/missing", @ctx)
    assert {:error, :enoent} = Backend.create("/no/parent/file", "x", @ctx)
  end

  test "Test.mutate mirrors the wire path (versions + results)" do
    {:ok, before} = Backend.stat("/etc/dev/flag", @ctx)
    {:ok, node} = VfsDemoServer.Test.mutate("/etc/dev/flag", :write, "mutated\n")
    assert node["version"] > before.version

    {:ok, content, _} = Backend.read("/etc/dev/flag", @ctx)
    assert content == "mutated\n"

    assert {:ok, %{"type" => "file"}} =
             VfsDemoServer.Test.mutate("/notes/mutated.md", :create, "x\n")

    assert {:ok, %{"type" => "dir"}} = VfsDemoServer.Test.mutate("/notes/mutated-dir", :create)
    assert {:ok, %{"removed" => _}} = VfsDemoServer.Test.mutate("/notes/mutated.md", :remove)
    assert {:ok, %{"removed" => _}} = VfsDemoServer.Test.mutate("/notes/mutated-dir", :remove)
  end

  test "generation counter bumps on mutation (stamped versions strictly increase)" do
    {:ok, node1} = VfsDemoServer.Test.mutate("/etc/dev/flag", :write, "gen-test-1\n")
    {:ok, node2} = VfsDemoServer.Test.mutate("/etc/dev/flag", :write, "gen-test-2\n")

    assert node2["version"] > node1["version"]
  end
end
