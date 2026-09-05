defmodule Noizu.MCP.VFS.ReadmeTest.Overrides do
  @moduledoc false
  def dynamic(_ctx), do: "# dynamic override\n"
end

defmodule Noizu.MCP.VFS.ReadmeTest.Wrapper do
  @moduledoc false
  use Noizu.MCP.VFS.Control,
    server: Noizu.MCP.VFS.ReadmeTest.Server,
    real: Noizu.MCP.VFS.Fixture.Memory
end

defmodule Noizu.MCP.VFS.ReadmeTest.Server do
  @moduledoc false
  use Noizu.MCP.Server, name: "readme-test", version: "1.0.0"

  tool Noizu.MCP.Fixtures.Echo
  vfs(Noizu.MCP.VFS.ReadmeTest.Wrapper)
end

defmodule Noizu.MCP.VFS.ReadmeTest.StandaloneWrapper do
  @moduledoc false
  use Noizu.MCP.VFS.Control, server: Noizu.MCP.VFS.ReadmeTest.Server
end

defmodule Noizu.MCP.VFS.ReadmeTest.StaticWrapper do
  @moduledoc false
  use Noizu.MCP.VFS.Control,
    server: Noizu.MCP.VFS.ReadmeTest.StaticServer,
    real: Noizu.MCP.VFS.Fixture.Memory
end

defmodule Noizu.MCP.VFS.ReadmeTest.StaticServer do
  @moduledoc false
  use Noizu.MCP.Server, name: "readme-static", version: "1.0.0", vfs_readme: "# static override\n"

  vfs(Noizu.MCP.VFS.ReadmeTest.StaticWrapper)
end

defmodule Noizu.MCP.VFS.ReadmeTest.DynamicWrapper do
  @moduledoc false
  use Noizu.MCP.VFS.Control,
    server: Noizu.MCP.VFS.ReadmeTest.DynamicServer,
    real: Noizu.MCP.VFS.Fixture.Memory
end

defmodule Noizu.MCP.VFS.ReadmeTest.DynamicServer do
  @moduledoc false
  use Noizu.MCP.Server,
    name: "readme-dynamic",
    version: "1.0.0",
    vfs_readme: {Noizu.MCP.VFS.ReadmeTest.Overrides, :dynamic}

  vfs(Noizu.MCP.VFS.ReadmeTest.DynamicWrapper)
end

defmodule Noizu.MCP.VFS.ReadmeTest.OwnReadme do
  @moduledoc false
  # A backend that serves its own /README.md — the generated node must not
  # shadow it.
  use Noizu.MCP.VFS

  @own_node %Noizu.MCP.VFS{type: :file, size: 3, mtime: 0, version: 1, writable: true}

  @impl true
  def stat("/README.md", _ctx), do: {:ok, @own_node}
  def stat(_path, _ctx), do: {:error, :enoent}

  @impl true
  def list("/", _cursor, _ctx),
    do: {:ok, [%{name: "README.md", type: :file, size: 3, mtime: 0, version: 1}], nil}

  def list(_path, _cursor, _ctx), do: {:error, :enoent}

  @impl true
  def read("/README.md", _ctx), do: {:ok, "own", 1}
  def read(_path, _ctx), do: {:error, :enoent}

  @impl true
  def write("/README.md", data, _ctx),
    do:
      {:ok,
       %Noizu.MCP.VFS{type: :file, size: byte_size(data), mtime: 0, version: 2, writable: true}}

  def write(_path, _data, _ctx), do: {:error, :enoent}
end

defmodule Noizu.MCP.VFS.ReadmeTest.Described do
  @moduledoc false
  use Noizu.MCP.VFS

  def __mcp_vfs__(:describe), do: "Wiki pages as files."

  @impl true
  def stat(_path, _ctx), do: {:error, :enoent}

  @impl true
  def list(_path, _cursor, _ctx), do: {:ok, [], nil}

  @impl true
  def read(_path, _ctx), do: {:error, :enoent}
end

defmodule Noizu.MCP.VFS.ReadmeTest do
  # The generated /README.md node Features.VFS serves for every mount.
  use ExUnit.Case, async: false

  alias Noizu.MCP.Server.Features.VFS
  alias Noizu.MCP.VFS.Cache
  alias Noizu.MCP.VFS.Fixture.Memory

  @plain Noizu.MCP.VFS.Fixture.Memory
  @wrapper Noizu.MCP.VFS.ReadmeTest.Wrapper
  @standalone Noizu.MCP.VFS.ReadmeTest.StandaloneWrapper
  @static Noizu.MCP.VFS.ReadmeTest.StaticWrapper
  @dynamic Noizu.MCP.VFS.ReadmeTest.DynamicWrapper

  setup do
    %{ctx: Memory.seed()}
  end

  setup context do
    on_exit(fn ->
      for backend <- [@plain, @wrapper, @standalone, @static, @dynamic] do
        Cache.purge(backend)
      end
    end)

    context
  end

  # ── generated node ────────────────────────────────────────────────────────

  test "stat /README.md is a read-only file node sized to the content", %{ctx: ctx} do
    assert {:ok, node} = VFS.stat(@plain, "/README.md", ctx)
    assert node.type == :file
    assert node.writable == false
    assert node.size > 0
    assert {:ok, content, _} = VFS.read(@plain, "/README.md", ctx)
    assert node.size == byte_size(content)
  end

  test "read returns generated content", %{ctx: ctx} do
    assert {:ok, content, version} = VFS.read(@plain, "/README.md", ctx)
    assert is_integer(version) and version > 0
    assert content =~ "virtual filesystem"
    assert content =~ "README.md"
    # a plain mount has no delegation chain to document
    refute content =~ "delegates to"
  end

  test "root listing gains a README.md entry", %{ctx: ctx} do
    assert {:ok, entries, nil} = VFS.list(@plain, "/", nil, ctx)

    assert %{name: "README.md", type: :file} =
             entry = Enum.find(entries, &(&1.name == "README.md"))

    assert entry.size > 0
    # the backend's own entries are untouched
    assert Enum.any?(entries, &match?(%{name: "hello.txt", type: :file}, &1))
  end

  test "stat and read stay coherent across the cache", %{ctx: ctx} do
    assert {:ok, node} = VFS.stat(@plain, "/README.md", ctx)
    assert {:ok, content, version} = VFS.read(@plain, "/README.md", ctx)
    assert byte_size(content) == node.size
    assert version >= node.version
  end

  # ── read-only enforcement ─────────────────────────────────────────────────

  test "write/create/remove on /README.md are :erofs (plain mount)", %{ctx: ctx} do
    assert {:error, :erofs} = VFS.write(@plain, "/README.md", "x", ctx)
    assert {:error, :erofs} = VFS.create(@plain, "/README.md", "x", ctx)
    assert {:error, :erofs} = VFS.remove(@plain, "/README.md", ctx)
  end

  test "write/create/remove on /README.md are :erofs (composed mount)", %{ctx: ctx} do
    assert {:error, :erofs} = VFS.write(@wrapper, "/README.md", "x", ctx)
    assert {:error, :erofs} = VFS.create(@wrapper, "/README.md", "x", ctx)
    assert {:error, :erofs} = VFS.remove(@wrapper, "/README.md", ctx)
  end

  test "the reservation does not touch neighbouring paths", %{ctx: ctx} do
    assert {:error, :enoent} = VFS.stat(@plain, "/README.md.bak", ctx)
    assert {:ok, _} = VFS.create(@plain, "/README.md.bak", "not reserved\n", ctx)
    assert {:ok, _} = VFS.write(@plain, "/README.md.bak", "still not\n", ctx)
    assert :ok = VFS.remove(@plain, "/README.md.bak", ctx)
  end

  test "a backend-owned README.md wins — no shadowing, no duplicate entry", %{ctx: ctx} do
    backend = Noizu.MCP.VFS.ReadmeTest.OwnReadme

    assert {:ok, node} = VFS.stat(backend, "/README.md", ctx)
    assert node.writable == true
    assert {:ok, "own", 1} = VFS.read(backend, "/README.md", ctx)
    assert {:ok, entries, nil} = VFS.list(backend, "/", nil, ctx)
    assert length(entries) == 1
    assert {:ok, _} = VFS.write(backend, "/README.md", "x", ctx)
  end

  # ── composed mounts ───────────────────────────────────────────────────────

  test "composed mount content names the registered backends and the control plane", %{ctx: ctx} do
    assert {:ok, content, _} = VFS.read(@wrapper, "/README.md", ctx)
    assert content =~ "Noizu.MCP.VFS.ReadmeTest.Wrapper"
    assert content =~ "Noizu.MCP.VFS.Fixture.Memory"
    assert content =~ "/etc/dev"
    assert content =~ "write-to-invoke" or content =~ "`{\"args\": {...}}`"
    assert content =~ ":erofs"
  end

  test "composed mount content includes the transport summary", %{ctx: ctx} do
    assert {:ok, content, _} = VFS.read(@wrapper, "/README.md", ctx)
    assert content =~ "vfs_socket"
    assert content =~ "stdio"
    assert content =~ "vfs/auth"
  end

  test "composed root listing merges README.md, etc, and real entries", %{ctx: ctx} do
    assert {:ok, entries, nil} = VFS.list(@wrapper, "/", nil, ctx)
    names = Enum.map(entries, & &1.name)
    assert "README.md" in names
    assert "etc" in names
    assert "hello.txt" in names
  end

  test "standalone control tree serves the node too", %{ctx: ctx} do
    assert {:ok, %Noizu.MCP.VFS{type: :file, writable: false}} =
             VFS.stat(@standalone, "/README.md", ctx)

    assert {:ok, [%{name: "README.md", type: :file}, %{name: "etc", type: :dir}], nil} =
             VFS.list(@standalone, "/", nil, ctx)

    assert {:error, :erofs} = VFS.write(@standalone, "/README.md", "x", ctx)
  end

  # ── vfs_readme server opt ─────────────────────────────────────────────────

  test "a binary override replaces the generated document", %{ctx: ctx} do
    assert {:ok, "# static override\n", _} = VFS.read(@static, "/README.md", ctx)

    assert {:ok, node} = VFS.stat(@static, "/README.md", ctx)
    assert node.size == byte_size("# static override\n")
  end

  test "an {m, f} override is invoked with the ctx", %{ctx: ctx} do
    assert {:ok, "# dynamic override\n", _} = VFS.read(@dynamic, "/README.md", ctx)
  end

  # ── __mcp_vfs__(:describe) ────────────────────────────────────────────────

  test "describe defaults to nil and may be overridden" do
    assert nil == @plain.__mcp_vfs__(:describe)
    assert "Wiki pages as files." == Noizu.MCP.VFS.ReadmeTest.Described.__mcp_vfs__(:describe)
  end

  test "describing a backend does not disturb the implemented list" do
    assert Noizu.MCP.VFS.ReadmeTest.Described.__mcp_vfs__(:implemented) == [:stat, :list, :read]
  end

  test "describe text lands in the generated document", %{ctx: ctx} do
    assert {:ok, content, _} = VFS.read(Noizu.MCP.VFS.ReadmeTest.Described, "/README.md", ctx)
    assert content =~ "Wiki pages as files."
  end
end

defmodule Noizu.MCP.VFS.ReadmeTest.Wire do
  # One mount, one socket client: the generated node survives the wire, and
  # the reservation reads as :erofs (-32042) over vfs_socket.
  use ExUnit.Case, async: false

  alias Noizu.MCP.Transport.VFSClient
  alias Noizu.MCP.VFS.Fixture.Memory

  defmodule Server do
    @moduledoc false
    use Noizu.MCP.Server, name: "readme-wire", version: "1.0.0"
    vfs(Noizu.MCP.VFS.Fixture.Memory)
  end

  @key "readme-wire-key"
  @path Path.join(System.tmp_dir(), "mcp-vfs-readme-test.sock")

  defp auth_opts do
    verifier_opts = [
      keys: [{@key, %{"sub" => "readme-tester"}}],
      default_claims: %{"scope" => "mcp"}
    ]

    [auth: [verifier: {Noizu.MCP.Auth.ApiKeyVerifier, verifier_opts}]]
  end

  setup do
    tree = Memory.seed().assigns.tree
    File.rm(@path)

    spec =
      Supervisor.child_spec(
        {Server,
         transport:
           {:vfs_socket,
            [socket_path: @path, acceptors: 1, context: fn _ -> %{tree: tree} end] ++ auth_opts()}},
        restart: :temporary
      )

    start_supervised!(spec)
    wait_for_socket(@path)

    {:ok, client} = VFSClient.connect(@path)
    on_exit(fn -> VFSClient.close(client) end)

    assert {:ok, %{"authenticated" => true}} = VFSClient.auth(client, @key)
    %{client: client}
  end

  defp wait_for_socket(path) do
    unless File.exists?(path), do: wait_for_socket(path)
  end

  test "vfs/read of /README.md returns the generated document", %{client: client} do
    assert {:ok, %{"content" => content, "version" => version}} =
             VFSClient.read(client, "/README.md")

    assert content =~ "virtual filesystem"
    assert is_integer(version)
  end

  test "vfs/list of / includes the README.md entry", %{client: client} do
    assert {:ok, %{"entries" => entries}} = VFSClient.list(client, "/")

    assert %{"name" => "README.md", "type" => "file", "size" => size} =
             Enum.find(entries, &(&1["name"] == "README.md"))

    assert is_integer(size) and size > 0
  end

  test "vfs/stat of /README.md is a read-only file", %{client: client} do
    assert {:ok, %{"type" => "file", "writable" => false}} = VFSClient.stat(client, "/README.md")
  end

  test "vfs/write on /README.md is -32042 erofs", %{client: client} do
    assert {:error, %{"code" => -32042, "data" => %{"errno_atom" => "erofs"}}} =
             VFSClient.write(client, "/README.md", "x")
  end
end
