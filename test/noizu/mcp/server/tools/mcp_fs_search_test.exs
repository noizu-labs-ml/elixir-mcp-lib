defmodule Noizu.MCP.Server.Tools.McpFsSearchTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.Error
  alias Noizu.MCP.Server.Features.Pagination
  alias Noizu.MCP.Server.Tools.McpFsSearch
  alias Noizu.MCP.VFS.Fixture.Memory

  # ── static fixture backends ────────────────────────────────────────────────

  defmodule BackendAlpha do
    use Noizu.MCP.VFS

    @lines [{1, "alpha beta"}, {2, "gamma"}, {3, "alpha again"}]

    @impl true
    def stat("/a.txt", _ctx), do: {:ok, file_node()}
    def stat(_, _ctx), do: {:error, :enoent}

    @impl true
    def list(_path, _cursor, _ctx), do: {:ok, [file_node()], nil}

    @impl true
    def read("/a.txt", _ctx), do: {:ok, "alpha beta\ngamma\nalpha again\n", 1}
    def read(_, _ctx), do: {:error, :enoent}

    @impl true
    def search(_root, query, _ctx) do
      matches =
        @lines
        |> Enum.filter(fn {_line, text} -> String.contains?(text, query) end)
        |> Enum.map(fn {line, text} -> %{path: "/a.txt", line: line, text: text} end)

      {:ok, matches, nil}
    end

    defp file_node, do: %Noizu.MCP.VFS{type: :file, size: 27, version: 1, writable: true}
  end

  defmodule BackendBeta do
    use Noizu.MCP.VFS

    @lines [{1, "beta says alpha"}, {2, "nothing here"}]

    @impl true
    def stat("/b.txt", _ctx), do: {:ok, file_node()}
    def stat(_, _ctx), do: {:error, :enoent}

    @impl true
    def list(_path, _cursor, _ctx), do: {:ok, [file_node()], nil}

    @impl true
    def read("/b.txt", _ctx), do: {:ok, "beta says alpha\nnothing here\n", 1}
    def read(_, _ctx), do: {:error, :enoent}

    @impl true
    def search(_root, query, _ctx) do
      matches =
        @lines
        |> Enum.filter(fn {_line, text} -> String.contains?(text, query) end)
        |> Enum.map(fn {line, text} -> %{path: "/b.txt", line: line, text: text} end)

      {:ok, matches, nil}
    end

    defp file_node, do: %Noizu.MCP.VFS{type: :file, size: 29, version: 1, writable: true}
  end

  # No search/3 — the behaviour default (`:enosys`) applies.
  defmodule BackendNoSearch do
    use Noizu.MCP.VFS

    @impl true
    def stat(_, _ctx), do: {:error, :enoent}

    @impl true
    def list(_path, _cursor, _ctx), do: {:ok, [], nil}

    @impl true
    def read(_, _ctx), do: {:error, :enoent}
  end

  defmodule BackendFailing do
    use Noizu.MCP.VFS

    @impl true
    def stat(_, _ctx), do: {:error, :enoent}

    @impl true
    def list(_path, _cursor, _ctx), do: {:ok, [], nil}

    @impl true
    def read(_, _ctx), do: {:error, :enoent}

    @impl true
    def search(_root, _query, _ctx), do: {:error, :eacces}
  end

  defmodule BackendBig do
    use Noizu.MCP.VFS

    @total Noizu.MCP.Server.Features.Pagination.default_page_size() + 5

    @impl true
    def stat(_, _ctx), do: {:error, :enoent}

    @impl true
    def list(_path, _cursor, _ctx), do: {:ok, [], nil}

    @impl true
    def read(_, _ctx), do: {:error, :enoent}

    @impl true
    def search(_root, query, _ctx) do
      matches =
        for i <- 1..@total do
          %{path: "/big/#{i}.txt", line: 1, text: "hit #{i} #{query}"}
        end

      {:ok, matches, nil}
    end
  end

  # ── stub servers ───────────────────────────────────────────────────────────

  defmodule MultiServer do
    def __mcp__(:vfs),
      do: [{BackendAlpha, []}, {BackendBeta, []}, {BackendNoSearch, []}]
  end

  defmodule BareServer do
    def __mcp__(:vfs), do: []
  end

  defmodule FailingServer do
    def __mcp__(:vfs), do: [{BackendAlpha, []}, {BackendFailing, []}]
  end

  defmodule BigServer do
    def __mcp__(:vfs), do: [{BackendBig, []}]
  end

  defmodule SearchServer do
    use Noizu.MCP.Server, name: "mcp-fs-search-test", version: "1.0.0"

    vfs(Noizu.MCP.VFS.Fixture.Memory)
    tool(Noizu.MCP.Server.Tools.McpFsSearch)
  end

  defp ctx(server, assigns \\ %{}), do: %Noizu.MCP.Ctx{server: server, assigns: assigns}

  defp alpha, do: inspect(BackendAlpha)
  defp beta, do: inspect(BackendBeta)

  # ── unit: merge semantics ──────────────────────────────────────────────────

  test "merges matches across every registered backend, tagged with backend" do
    {:ok, result} = McpFsSearch.call(%{"query" => "alpha"}, ctx(MultiServer))

    assert [
             %{path: "/a.txt", line: 1, text: "alpha beta"},
             %{path: "/a.txt", line: 3, text: "alpha again"},
             %{path: "/b.txt", line: 1, text: "beta says alpha"}
           ] = result["matches"]

    assert [%{backend: a1}, %{backend: a2}, %{backend: b1}] = result["matches"]
    assert a1 == a2 and a1 == alpha() and b1 == beta()

    refute Map.has_key?(result, "nextCursor")
  end

  test "backends without search/3 (:enosys default) are skipped silently" do
    {:ok, result} = McpFsSearch.call(%{"query" => "alpha"}, ctx(MultiServer))
    assert Enum.all?(result["matches"], &(&1.path in ["/a.txt", "/b.txt"]))
  end

  test "no matches is an empty list, not an error" do
    assert {:ok, %{"matches" => []}} =
             McpFsSearch.call(%{"query" => "zzz-not-there"}, ctx(MultiServer))
  end

  test "backend filter by short name" do
    {:ok, result} =
      McpFsSearch.call(%{"query" => "alpha", "backend" => "backendbeta"}, ctx(MultiServer))

    assert [%{path: "/b.txt", line: 1, backend: b}] = result["matches"]
    assert b == beta()
  end

  test "backend filter by full module name" do
    {:ok, result} =
      McpFsSearch.call(
        %{"query" => "alpha", "backend" => inspect(BackendAlpha)},
        ctx(MultiServer)
      )

    assert [%{path: "/a.txt", line: 1}, %{path: "/a.txt", line: 3}] = result["matches"]
    assert Enum.all?(result["matches"], &(&1.backend == alpha()))
  end

  test "unknown backend filter is -32002, not an empty result" do
    assert {:error, %Error{code: -32002}} =
             McpFsSearch.call(%{"query" => "alpha", "backend" => "nope"}, ctx(MultiServer))
  end

  test "missing query is invalid params" do
    assert {:error, %Error{reason: :invalid_params}} = McpFsSearch.call(%{}, ctx(MultiServer))

    assert {:error, %Error{reason: :invalid_params}} =
             McpFsSearch.call(%{"query" => 4}, ctx(MultiServer))
  end

  test "server without a VFS capability is refused" do
    assert {:error, %Error{reason: :capability_not_supported}} =
             McpFsSearch.call(%{"query" => "alpha"}, ctx(BareServer))
  end

  test "non-enosys backend errors abort the merge through the errno wire mapping" do
    assert {:error, %Error{code: -32040, data: %{errno: :eacces}}} =
             McpFsSearch.call(%{"query" => "alpha"}, ctx(FailingServer))
  end

  test "results paginate past the default page size" do
    {:ok, first} = McpFsSearch.call(%{"query" => "hit"}, ctx(BigServer))

    assert length(first["matches"]) == Pagination.default_page_size()
    assert cursor = first["nextCursor"]

    {:ok, second} = McpFsSearch.call(%{"query" => "hit", "cursor" => cursor}, ctx(BigServer))

    assert length(second["matches"]) == 5
    refute second["nextCursor"]
  end

  # ── integration: registered on a real server ───────────────────────────────

  describe "server integration" do
    setup do
      tree = %{
        "/" => :dir,
        "/docs" => :dir,
        "/docs/a.md" => "alpha first\nsecond\n",
        "/docs/b.md" => "third alpha\n"
      }

      on_exit(fn -> Noizu.MCP.VFS.Cache.purge(Memory) end)
      %{ctx: Memory.seed(tree)}
    end

    test "tool is listed among registered tools" do
      assert Noizu.MCP.Server.Tools.McpFsSearch in Enum.map(
               SearchServer.__mcp__(:tools),
               &elem(&1, 0)
             )
    end

    test "dispatches through handle_call_tool against the fixture backend", %{ctx: base} do
      ctx = %Noizu.MCP.Ctx{base | server: SearchServer}

      assert %Noizu.MCP.Types.ToolResult{is_error: false} =
               result =
               SearchServer.handle_call_tool("mcp_fs_search", %{"query" => "alpha"}, ctx)

      assert [
               %{path: "/docs/a.md", line: 1, text: "alpha first"},
               %{path: "/docs/b.md", line: 1, text: "third alpha"}
             ] =
               result.structured["matches"]

      assert Enum.all?(result.structured["matches"], &(&1.backend == inspect(Memory)))
    end
  end
end
