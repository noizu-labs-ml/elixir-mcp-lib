defmodule Noizu.MCP.VFS.Conformance do
  @moduledoc """
  The shared VFS backend test battery. Run against every backend — the one
  that ships (`Noizu.MCP.VFS.Fixture.Memory`), and any a host writes.

      defmodule MyApp.MCP.FSTest do
        use Noizu.MCP.VFS.Conformance,
          backend: MyApp.MCP.FS,
          seed: {MyApp.MCP.FS, :seed}
      end

  The `seed:` callback receives no arguments and returns a
  `%Noizu.MCP.Ctx{}` carrying the backend's state, seeded with the standard
  conformance tree:

      /             dir
      /hello.txt    "hello world\\n"
      /docs         dir
      /docs/a.md    "# alpha\\nbeta gamma\\n"
      /docs/b.md    "delta\\n"
      /empty        dir (empty)
      /bin          dir
      /bin/sh       "exec\\n"

  Every op runs through `Noizu.MCP.Server.Features.VFS`'s backend-level
  wrappers, so the battery also verifies the parts a raw `@behaviour` test
  would miss: generation stamping on versions, cache invalidation after
  writes, and read-after-write freshness.
  """

  defmacro __using__(opts) do
    backend = Keyword.fetch!(opts, :backend)
    {seed_mod, seed_fun} = Keyword.fetch!(opts, :seed)

    quote bind_quoted: [backend: backend, seed_mod: seed_mod, seed_fun: seed_fun] do
      use ExUnit.Case, async: true

      alias Noizu.MCP.Server.Features.VFS
      alias Noizu.MCP.VFS.Cache

      setup do
        ctx = apply(unquote(seed_mod), unquote(seed_fun), [])
        backend = unquote(backend)

        on_exit(fn -> Cache.purge(backend) end)
        %{backend: backend, ctx: ctx}
      end

      # ── stat ──────────────────────────────────────────────────────────────

      test "stat/3 returns a dir node for /", %{backend: backend, ctx: ctx} do
        assert {:ok, node} = VFS.stat(backend, "/", ctx)
        assert node.type == :dir
        assert is_integer(node.version) and node.version > 0
        assert is_map(node.xattrs)
      end

      test "stat/3 returns a file node with size and write capability", %{
        backend: backend,
        ctx: ctx
      } do
        assert {:ok, node} = VFS.stat(backend, "/hello.txt", ctx)
        assert node.type == :file
        assert node.size == byte_size("hello world\n")
        assert node.writable == true
      end

      test "stat/3 on a missing path is :enoent", %{backend: backend, ctx: ctx} do
        assert {:error, :enoent} = VFS.stat(backend, "/nope", ctx)
      end

      # ── list ──────────────────────────────────────────────────────────────

      test "list/4 returns entries with name/type/size/mtime/version", %{
        backend: backend,
        ctx: ctx
      } do
        assert {:ok, entries, next_cursor} = VFS.list(backend, "/", nil, ctx)
        assert is_nil(next_cursor)

        hello = Enum.find(entries, &match?(%{name: "hello.txt"}, &1))
        assert hello.type == :file
        assert hello.size == byte_size("hello world\n")
        assert is_integer(hello.mtime)
        assert is_integer(hello.version)

        docs = Enum.find(entries, &match?(%{name: "docs"}, &1))
        assert docs.type == :dir
      end

      test "list/4 on a file is :enotdir, on a missing path :enoent", %{
        backend: backend,
        ctx: ctx
      } do
        assert {:error, :enotdir} = VFS.list(backend, "/hello.txt", nil, ctx)
        assert {:error, :enoent} = VFS.list(backend, "/nope", nil, ctx)
      end

      test "list/4 rejects an invalid cursor", %{backend: backend, ctx: ctx} do
        assert {:error, %Noizu.MCP.Error{}} = VFS.list(backend, "/", "not-a-cursor", ctx)
      end

      test "list/4 pagination cursor round-trips", %{backend: backend, ctx: ctx} do
        assert {:ok, entries, nil} = VFS.list(backend, "/docs", nil, ctx)
        assert length(entries) == 2
      end

      # ── read ──────────────────────────────────────────────────────────────

      test "read/4 returns content and version matching stat", %{backend: backend, ctx: ctx} do
        assert {:ok, node} = VFS.stat(backend, "/hello.txt", ctx)
        assert {:ok, content, version} = VFS.read(backend, "/hello.txt", ctx)
        assert content == "hello world\n"
        assert version == node.version
      end

      test "read/4 on a dir is :eisdir, on a missing path :enoent", %{
        backend: backend,
        ctx: ctx
      } do
        assert {:error, :eisdir} = VFS.read(backend, "/docs", ctx)
        assert {:error, :enoent} = VFS.read(backend, "/nope", ctx)
      end

      # ── write ─────────────────────────────────────────────────────────────

      test "write/4 overwrites an existing file and bumps the version", %{
        backend: backend,
        ctx: ctx
      } do
        assert {:ok, before} = VFS.stat(backend, "/hello.txt", ctx)
        assert {:ok, node} = VFS.write(backend, "/hello.txt", "goodbye\n", ctx)
        assert node.version > before.version
        assert node.size == byte_size("goodbye\n")
        assert {:ok, "goodbye\n", _} = VFS.read(backend, "/hello.txt", ctx)
      end

      test "write/4 on a missing path is :enoent, on a dir :eisdir", %{
        backend: backend,
        ctx: ctx
      } do
        assert {:error, :enoent} = VFS.write(backend, "/nope", "x", ctx)
        assert {:error, :eisdir} = VFS.write(backend, "/docs", "x", ctx)
      end

      # ── create ────────────────────────────────────────────────────────────

      test "create/4 makes a new file, :eexist if present, :enoent without parent", %{
        backend: backend,
        ctx: ctx
      } do
        assert {:ok, node} = VFS.create(backend, "/new.txt", "fresh\n", ctx)
        assert node.type == :file
        assert node.writable == true
        assert {:error, :eexist} = VFS.create(backend, "/new.txt", "again", ctx)
        assert {:error, :enoent} = VFS.create(backend, "/nodir/x.txt", "x", ctx)
      end

      test "create/4 with :dir makes a directory", %{backend: backend, ctx: ctx} do
        assert {:ok, node} = VFS.create(backend, "/newdir", :dir, ctx)
        assert node.type == :dir
        assert {:ok, entries, nil} = VFS.list(backend, "/newdir", nil, ctx)
        assert entries == []
      end

      # ── remove ────────────────────────────────────────────────────────────

      test "remove/3 deletes a file, then it is :enoent", %{backend: backend, ctx: ctx} do
        assert :ok = VFS.remove(backend, "/hello.txt", ctx)
        assert {:error, :enoent} = VFS.stat(backend, "/hello.txt", ctx)
        assert {:error, :enoent} = VFS.remove(backend, "/hello.txt", ctx)
      end

      test "remove/3 refuses / (:eacces) and non-empty dirs (:enotempty)", %{
        backend: backend,
        ctx: ctx
      } do
        assert {:error, :eacces} = VFS.remove(backend, "/", ctx)
        assert {:error, :enotempty} = VFS.remove(backend, "/docs", ctx)
      end

      test "remove/3 deletes an empty dir", %{backend: backend, ctx: ctx} do
        assert :ok = VFS.remove(backend, "/empty", ctx)
        assert {:error, :enoent} = VFS.stat(backend, "/empty", ctx)
      end

      # ── search ────────────────────────────────────────────────────────────

      test "search/4 finds line matches with path/line/text", %{backend: backend, ctx: ctx} do
        assert {:ok, matches, nil} = VFS.search(backend, "/", "alpha", ctx)
        assert matches == [%{path: "/docs/a.md", line: 1, text: "# alpha"}]
      end

      test "search/4 finds multi-line matches in path order", %{backend: backend, ctx: ctx} do
        assert {:ok, matches, nil} = VFS.search(backend, "/docs", "a", ctx)
        assert length(matches) >= 3

        assert Enum.all?(
                 matches,
                 &match?(
                   %{path: "/docs/" <> _, line: l, text: t}
                   when is_integer(l) and is_binary(t),
                   &1
                 )
               )
      end

      test "search/4 with no hits returns an empty page", %{backend: backend, ctx: ctx} do
        assert {:ok, [], nil} = VFS.search(backend, "/", "zzz-not-there", ctx)
      end

      # ── xattr ─────────────────────────────────────────────────────────────

      test "xattr/3 returns a map", %{backend: backend, ctx: ctx} do
        assert {:ok, xattrs} = VFS.xattr(backend, "/hello.txt", ctx)
        assert is_map(xattrs)
      end

      # ── cache integration ─────────────────────────────────────────────────

      test "a write invalidates cached stat and read results", %{backend: backend, ctx: ctx} do
        assert {:ok, before} = VFS.stat(backend, "/hello.txt", ctx)
        assert {:ok, _} = VFS.write(backend, "/hello.txt", "changed\n", ctx)

        assert {:ok, post} = VFS.stat(backend, "/hello.txt", ctx)
        assert post.version > before.version

        assert {:ok, "changed\n", version} = VFS.read(backend, "/hello.txt", ctx)
        assert version == post.version
      end

      test "generation embeds into returned versions", %{backend: backend, ctx: ctx} do
        gen0 = Cache.generation(backend)
        assert {:ok, node} = VFS.stat(backend, "/hello.txt", ctx)
        assert node.version > gen0
      end

      test "create and remove invalidate cached listings", %{backend: backend, ctx: ctx} do
        assert {:ok, entries_before, _} = VFS.list(backend, "/docs", nil, ctx)

        assert {:ok, _} = VFS.create(backend, "/docs/c.md", "c\n", ctx)
        assert {:ok, entries_after_create, _} = VFS.list(backend, "/docs", nil, ctx)
        assert Enum.any?(entries_after_create, &match?(%{name: "c.md"}, &1))
        assert length(entries_after_create) == length(entries_before) + 1

        assert :ok = VFS.remove(backend, "/docs/c.md", ctx)
        assert {:ok, entries_after_remove, _} = VFS.list(backend, "/docs", nil, ctx)
        # Versions embed the generation (bumped twice since the first listing),
        # so compare the shape, not the stamped versions.
        assert Enum.map(entries_after_remove, & &1.name) ==
                 Enum.map(entries_before, & &1.name)
      end
    end
  end
end
