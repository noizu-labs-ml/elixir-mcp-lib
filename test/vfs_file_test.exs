defmodule Noizu.MCP.VFS.FileTest do
  @moduledoc """
  The full conformance battery (`Noizu.MCP.VFS.Conformance`) run against the
  directory-backed backend, plus containment coverage — `..` traversal and
  symlink escape attempts must never leave the mount root.
  """

  use Noizu.MCP.VFS.Conformance,
    backend: Noizu.MCP.VFS.File,
    seed: {Noizu.MCP.VFS.FileTest, :seed}

  alias Noizu.MCP.Server.Features.VFS

  # Materialize the standard conformance tree on disk; the seed callback
  # returns the ctx every battery op is driven through.
  def seed do
    root =
      Path.join(System.tmp_dir!(), "mcp-vfs-file-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    write_tree(root)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)

    Noizu.MCP.Ctx.assign(%Noizu.MCP.Ctx{}, :vfs_opts, root: root)
  end

  defp write_tree(root) do
    File.mkdir_p!(Path.join(root, "docs"))
    File.mkdir_p!(Path.join(root, "empty"))
    File.mkdir_p!(Path.join(root, "bin"))
    File.write!(Path.join(root, "hello.txt"), "hello world\n")
    File.write!(Path.join(root, "docs/a.md"), "# alpha\nbeta gamma\n")
    File.write!(Path.join(root, "docs/b.md"), "delta\n")
    File.write!(Path.join(root, "bin/sh"), "exec\n")
  end

  defp root_of(ctx), do: ctx.assigns[:vfs_opts][:root]

  # ── cache namespace (regression) ──────────────────────────────────────────
  #
  # The battery is async and every test seeds a fresh root, but all of them
  # share the backend module — and pre-namespace the cache was keyed only on
  # `{module, kind, path}`. A stat cached under one root could satisfy another
  # root's stat, so the battery's `post.version > before.version` across a
  # write became a coin flip between two unrelated hash-derived versions (the
  # PR #40 CI flake). Cache entries are namespaced by vfs_opts now: two mounts
  # on one backend module never see each other's entries.
  test "two mounts on one backend share no cache entries", %{backend: backend, ctx: ctx} do
    other =
      Path.join(System.tmp_dir!(), "mcp-vfs-file-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(other)
    File.write!(Path.join(other, "hello.txt"), "other mount\n")
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(other) end)
    other_ctx = Noizu.MCP.Ctx.assign(%Noizu.MCP.Ctx{}, :vfs_opts, root: other)

    # Warm both namespaces for stat and read.
    assert {:ok, ours} = VFS.stat(backend, "/hello.txt", ctx)
    assert {:ok, theirs} = VFS.stat(backend, "/hello.txt", other_ctx)
    assert ours.size == byte_size("hello world\n")
    assert theirs.size == byte_size("other mount\n")

    assert {:ok, "hello world\n", _} = VFS.read(backend, "/hello.txt", ctx)
    assert {:ok, "other mount\n", _} = VFS.read(backend, "/hello.txt", other_ctx)

    # A write through one mount leaves the other mount's view intact.
    assert {:ok, _} = VFS.write(backend, "/hello.txt", "changed\n", ctx)
    assert {:ok, changed, _} = VFS.read(backend, "/hello.txt", ctx)
    assert changed == "changed\n"
    assert {:ok, "other mount\n", _} = VFS.read(backend, "/hello.txt", other_ctx)
  end

  # ── containment ───────────────────────────────────────────────────────────

  test "traversal past the root is :enoent", %{backend: backend, ctx: ctx} do
    assert {:error, :enoent} = VFS.read(backend, "/../etc/passwd", ctx)
    assert {:error, :enoent} = VFS.read(backend, "/docs/../../etc/passwd", ctx)
    assert {:error, :enoent} = VFS.stat(backend, "/..", ctx)
    assert {:error, :enoent} = VFS.stat(backend, "/docs/../..", ctx)
    assert {:error, :enoent} = VFS.list(backend, "/..", nil, ctx)
  end

  test "traversal cannot write or create outside the root", %{backend: backend, ctx: ctx} do
    assert {:error, :enoent} = VFS.write(backend, "/../escape.txt", "x", ctx)
    assert {:error, :enoent} = VFS.create(backend, "/../escape.txt", "x", ctx)
    assert {:error, :enoent} = VFS.remove(backend, "/../hello.txt", ctx)

    # Nothing landed beside the mount.
    refute File.exists?(Path.join(Path.dirname(root_of(ctx)), "escape.txt"))
  end

  test "symlinks escaping the root are :eacces", %{backend: backend, ctx: ctx} do
    root = root_of(ctx)
    outside = Path.join(Path.dirname(root), "outside-#{System.unique_integer([:positive])}")
    File.write!(outside, "secret\n")
    File.mkdir_p!(Path.join(root, "link"))
    File.mkdir_p!(Path.join(root, "dir-link-target"))

    :ok = File.ln_s(outside, Path.join(root, "link/out"))
    :ok = File.ln_s("../../" <> Path.basename(outside), Path.join(root, "link/rel-out"))
    :ok = File.ln_s(Path.dirname(root), Path.join(root, "dir-link"))
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(outside) end)

    assert {:error, :eacces} = VFS.read(backend, "/link/out", ctx)
    assert {:error, :eacces} = VFS.read(backend, "/link/rel-out", ctx)
    assert {:error, :eacces} = VFS.stat(backend, "/link/out", ctx)
    # A link to a directory outside is not listable past the mount either.
    assert {:error, :eacces} = VFS.list(backend, "/dir-link", nil, ctx)
  end

  test "a symlink inside the root is followed", %{backend: backend, ctx: ctx} do
    root = root_of(ctx)
    :ok = File.ln_s("hello.txt", Path.join(root, "alias.txt"))

    assert {:ok, "hello world\n", _} = VFS.read(backend, "/alias.txt", ctx)
    assert {:ok, %{type: :file}} = VFS.stat(backend, "/alias.txt", ctx)
  end

  test "listing skips symlinks that escape the root or dangle", %{backend: backend, ctx: ctx} do
    root = root_of(ctx)

    outside = Path.join(Path.dirname(root), "outside-list-#{System.unique_integer([:positive])}")
    File.write!(outside, String.duplicate("secret", 20))
    :ok = File.ln_s(outside, Path.join(root, "escape-link.txt"))
    :ok = File.ln_s("nowhere", Path.join(root, "dangling-link.txt"))
    :ok = File.ln_s("hello.txt", Path.join(root, "alias.txt"))
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(outside) end)

    assert {:ok, entries, _} = VFS.list(backend, "/", nil, ctx)
    names = Enum.map(entries, & &1.name)
    assert "alias.txt" in names
    refute "escape-link.txt" in names
    refute "dangling-link.txt" in names

    # An inside-tree link reports its (in-root) target's shape, not a leak.
    alias_entry = Enum.find(entries, &(&1.name == "alias.txt"))
    assert alias_entry.size == byte_size("hello world\n")
  end

  test "search stays inside the root", %{backend: backend, ctx: ctx} do
    assert {:ok, matches, nil} = VFS.search(backend, "/", "alpha", ctx)
    assert matches == [%{path: "/docs/a.md", line: 1, text: "# alpha"}]

    assert {:error, :enoent} = VFS.search(backend, "/..", "alpha", ctx)
  end

  # ── mime typing ───────────────────────────────────────────────────────────

  test "stat xattrs carry the mime type", %{backend: backend, ctx: ctx} do
    assert {:ok, %{xattrs: %{mime: "text/markdown"}}} = VFS.stat(backend, "/docs/a.md", ctx)

    assert {:ok, %{xattrs: %{mime: "application/octet-stream"}}} =
             VFS.stat(backend, "/bin/sh", ctx)
  end

  test "mime_type/2 honors :mime_types overrides" do
    assert Noizu.MCP.VFS.File.mime_type("/x.log", mime_types: %{".log" => "text/x-log"}) ==
             "text/x-log"

    assert Noizu.MCP.VFS.File.mime_type("/x.md") == "text/markdown"
    assert Noizu.MCP.VFS.File.mime_type("/x.unknown") == "application/octet-stream"
  end
end

defmodule Noizu.MCP.VFS.FileReadOnlyTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.Server.Features.VFS
  # NOTE: no `alias Noizu.MCP.VFS.File` here — it would shadow Elixir.File.
  defp backend, do: Noizu.MCP.VFS.File

  setup do
    root = Path.join(System.tmp_dir!(), "mcp-vfs-file-ro-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "hello.txt"), "hello world\n")
    on_exit(fn -> File.rm_rf!(root) end)

    ctx = Noizu.MCP.Ctx.assign(%Noizu.MCP.Ctx{}, :vfs_opts, root: root, read_only: true)
    %{root: root, ctx: ctx}
  end

  test "mutators are :erofs", %{ctx: ctx} do
    assert {:error, :erofs} = backend().write("/hello.txt", "x", ctx)
    assert {:error, :erofs} = backend().create("/new.txt", "x", ctx)
    assert {:error, :erofs} = backend().create("/newdir", :dir, ctx)
    assert {:error, :erofs} = backend().remove("/hello.txt", ctx)
  end

  test "nodes are not writable, reads still work", %{ctx: ctx} do
    assert {:ok, node} = backend().stat("/hello.txt", ctx)
    assert node.writable == false
    assert {:ok, "hello world\n", _} = backend().read("/hello.txt", ctx)
    assert {:ok, _, nil} = backend().list("/", nil, ctx)
  end

  test "missing :root raises ArgumentError" do
    assert_raise ArgumentError, ~r/:root/, fn ->
      backend().stat("/x", Noizu.MCP.Ctx.assign(%Noizu.MCP.Ctx{}, :vfs_opts, []))
    end

    # And an opts-free ctx falls back to the (unset) application env.
    assert_raise ArgumentError, ~r/:root/, fn ->
      backend().stat("/x", %Noizu.MCP.Ctx{})
    end
  end
end

defmodule Noizu.MCP.VFS.FileDslTest do
  use ExUnit.Case, async: true

  defmodule RwServer do
    use Noizu.MCP.Server, name: "vfs-file-rw", version: "1.0.0"
    vfs(Noizu.MCP.VFS.File, root: "/tmp/vfs-file-rw-unused")
  end

  defmodule RoServer do
    use Noizu.MCP.Server, name: "vfs-file-ro", version: "1.0.0"
    vfs(Noizu.MCP.VFS.File, root: "/tmp/vfs-file-ro-unused", read_only: true)
  end

  test "registration opts are recorded" do
    assert [{Noizu.MCP.VFS.File, opts}] = RwServer.__mcp__(:vfs)
    assert opts[:root] == "/tmp/vfs-file-rw-unused"

    assert [{Noizu.MCP.VFS.File, opts}] = RoServer.__mcp__(:vfs)
    assert opts[:read_only] == true
  end

  test "read-write mount advertises vfs + vfs_write" do
    caps = RwServer.__mcp__(:capabilities)
    assert caps["vfs"] == true
    assert caps["vfs_write"] == true
  end

  test "read_only mount advertises vfs but not vfs_write" do
    caps = RoServer.__mcp__(:capabilities)
    assert caps["vfs"] == true
    refute Map.has_key?(caps, "vfs_write")
  end
end

defmodule Noizu.MCP.VFS.FileServerTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.Server.Features.VFS

  defmodule MountedServer do
    use Noizu.MCP.Server, name: "vfs-file-mounted", version: "1.0.0"
    vfs(Noizu.MCP.VFS.File, root: Path.expand("support", __DIR__))
  end

  setup do
    on_exit(fn -> Noizu.MCP.VFS.Cache.purge(Noizu.MCP.VFS.File) end)
    :ok
  end

  @ctx %Noizu.MCP.Ctx{}

  test "registration opts reach the backend through the server wrappers" do
    assert {:ok, node} =
             VFS.vfs_stat(MountedServer, %{"path" => "/vfs_conformance.ex"}, @ctx)

    assert node["type"] == "file"
    assert node["size"] > 0
    assert is_map(node["xattrs"])
  end

  test "list and read flow through the same plumbing" do
    assert {:ok, %{"entries" => entries}} = VFS.vfs_list(MountedServer, %{"path" => "/"}, @ctx)
    assert Enum.any?(entries, &match?(%{name: "vfs_conformance.ex", type: :file}, &1))

    assert {:ok, %{"content" => content, "version" => version}} =
             VFS.vfs_read(MountedServer, %{"path" => "/vfs_conformance.ex"}, @ctx)

    assert is_binary(content) and is_integer(version) and version > 0
  end

  test "a missing path maps to an error struct" do
    assert {:error, %Noizu.MCP.Error{}} =
             VFS.vfs_stat(MountedServer, %{"path" => "/definitely-not-here"}, @ctx)
  end
end
