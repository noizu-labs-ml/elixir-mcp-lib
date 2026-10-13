defmodule Noizu.MCP.Server.VFSTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.Server.VFS

  defmodule SingleMoveServer do
    def __mcp__(:vfs), do: [{Noizu.MCP.VFS.Fixture.Memory, []}]
  end

  defmodule SingleNullServer do
    def __mcp__(:vfs), do: [{Noizu.MCP.VFS.Null, []}]
  end

  # Union semantics: caps advertise that move exists SOMEWHERE on the server;
  # vfs/move still answers -32601 per call when the routed backend lacks it.
  defmodule MixedServer do
    def __mcp__(:vfs), do: [{Noizu.MCP.VFS.Null, []}, {Noizu.MCP.VFS.Fixture.Memory, []}]
  end

  defmodule MixedReversedServer do
    def __mcp__(:vfs), do: [{Noizu.MCP.VFS.Fixture.Memory, []}, {Noizu.MCP.VFS.Null, []}]
  end

  defmodule NoBackendServer do
    def __mcp__(:vfs), do: []
  end

  # A `use Noizu.MCP.VFS` backend that opts into move but NOT rmdir — the
  # probe-false case for the rmdir cap (Memory implements both).
  defmodule MoveOnlyBackend do
    use Noizu.MCP.VFS

    @impl true
    def stat("/", _ctx), do: {:ok, %Noizu.MCP.VFS{type: :dir, mtime: 0, version: 1}}
    def stat(_, _ctx), do: {:error, :enoent}

    @impl true
    def list("/", _cursor, _ctx), do: {:ok, [], nil}
    def list(_, _, _ctx), do: {:error, :enotdir}

    @impl true
    def read("/", _ctx), do: {:error, :eisdir}
    def read(_, _ctx), do: {:error, :enoent}

    @impl true
    def move(_from, _to, _ctx), do: {:error, :enosys}
  end

  defmodule SingleMoveOnlyServer do
    def __mcp__(:vfs), do: [{MoveOnlyBackend, []}]
  end

  describe "session_info/1" do
    test "rmdir-capable backend advertises move and rmdir caps" do
      assert VFS.session_info(SingleMoveServer) == %{"proto" => 3, "caps" => ["move", "rmdir"]}
    end

    test "move-only backend advertises just the move cap (rmdir probe false)" do
      assert VFS.session_info(SingleMoveOnlyServer) == %{"proto" => 3, "caps" => ["move"]}
    end

    test "backend without move advertises empty caps" do
      assert VFS.session_info(SingleNullServer) == %{"proto" => 3, "caps" => []}
    end

    test "caps are the union across all registered backends (robot review #61)" do
      assert VFS.session_info(MixedServer) == %{"proto" => 3, "caps" => ["move", "rmdir"]}

      assert VFS.session_info(MixedReversedServer) == %{
               "proto" => 3,
               "caps" => ["move", "rmdir"]
             }
    end

    test "no backends at all: proto still present, caps empty" do
      assert VFS.session_info(NoBackendServer) == %{"proto" => 3, "caps" => []}
    end
  end

  describe "move_capable?/1" do
    test "true for a use Noizu.MCP.VFS backend defining move/3" do
      assert VFS.move_capable?(Noizu.MCP.VFS.Fixture.Memory)
    end

    test "false for a use Noizu.MCP.VFS backend without move/3 (implemented-list, not function_exported?)" do
      refute VFS.move_capable?(Noizu.MCP.VFS.Null)
    end
  end

  describe "rmdir_capable?/1" do
    test "true for a use Noizu.MCP.VFS backend defining rmdir/2" do
      assert VFS.rmdir_capable?(Noizu.MCP.VFS.Fixture.Memory)
    end

    test "false for a use Noizu.MCP.VFS backend without rmdir/2 (implemented-list, not function_exported?)" do
      refute VFS.rmdir_capable?(Noizu.MCP.VFS.Null)
      refute VFS.rmdir_capable?(MoveOnlyBackend)
    end
  end
end
