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

  describe "session_info/1" do
    test "move-capable backend advertises the move cap" do
      assert VFS.session_info(SingleMoveServer) == %{"proto" => 3, "caps" => ["move"]}
    end

    test "backend without move advertises empty caps" do
      assert VFS.session_info(SingleNullServer) == %{"proto" => 3, "caps" => []}
    end

    test "caps are the union across all registered backends (robot review #61)" do
      assert VFS.session_info(MixedServer) == %{"proto" => 3, "caps" => ["move"]}
      assert VFS.session_info(MixedReversedServer) == %{"proto" => 3, "caps" => ["move"]}
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
end
