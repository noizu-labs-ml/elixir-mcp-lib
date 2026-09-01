defmodule Noizu.MCP.Server.Tools.McpFsSearch do
  @moduledoc """
  Virtual grep tool over the server's registered VFS backends.

  Where the `vfs/*` operations address exactly one backend (the first
  registration), `mcp_fs_search` fans a query out to **every** backend on
  `server.__mcp__(:vfs)` and merges the matches — the MCP-tool face of the
  filesystem grep metaphor, usable from any transport (stdio, Streamable HTTP,
  the VFS socket/WS surfaces) without filesystem mounting:

      tool Noizu.MCP.Server.Tools.McpFsSearch

  ## Arguments

    * `query` — required substring to grep for (line-oriented, like
      `vfs/search`)
    * `root` — subtree root, defaults to `"/"`
    * `backend` — optional backend filter; matched case-insensitively against
      the registered backend's full (`"MyApp.VFS.PM"`) or short (`"pm"`)
      module name. An unknown name is a `-32002` resource-not-found, not an
      empty result.
    * `cursor` — opaque pagination cursor from a previous page

  Backends that do not implement `search/3` (the behaviour default is
  `:enosys`) are skipped; any other backend error aborts the merge and is
  surfaced through the standard VFS errno wire mapping. Each returned match
  gains a `backend` key naming the module that produced it. Read-only by
  definition, so the tool works under `vfs_readonly: true` kill-switches.

  Result shape mirrors `vfs_search`:

      %{"matches" => [%{path: "/docs/a.md", line: 1, text: "alpha",
                       backend: "Noizu.MCP.VFS.Fixture.Memory"}, ...],
        "nextCursor" => "..."}   # only when more pages remain
  """

  use Noizu.MCP.Server.Tool,
    name: "mcp_fs_search",
    description:
      "Grep-style search across every VFS backend registered on the server. " <>
        "Returns line matches (path, line number, text, backend) under an optional " <>
        "subtree root, filterable to a single backend, paginated.",
    annotations: [read_only_hint: true, idempotent_hint: true]

  input_schema %{
    "type" => "object",
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "Substring to search for (case-sensitive, line-oriented)"
      },
      "root" => %{
        "type" => "string",
        "default" => "/",
        "description" => "Only search paths under this subtree root"
      },
      "backend" => %{
        "type" => "string",
        "description" =>
          "Restrict the search to one registered backend (full or short module name, case-insensitive)"
      },
      "cursor" => %{
        "type" => "string",
        "description" => "Pagination cursor from a previous result page"
      }
    }
  }

  alias Noizu.MCP.Error
  alias Noizu.MCP.Server.Features.Pagination
  alias Noizu.MCP.Server.Features.VFS

  @impl true
  # ⟦𓌰𓐟𓆬𓈾⟧ call :: auto-generated pointer for public function call
  def call(args, ctx) do
    args = args || %{}

    case backends(ctx.server) do
      [_ | _] = registered -> search(registered, args, ctx)
      _ -> {:error, Error.capability_not_supported("vfs")}
    end
  end

  defp backends(server), do: List.wrap(server.__mcp__(:vfs))

  defp search(registered, args, ctx) do
    with {:ok, query} <- validate_binary(args["query"], "query"),
         root when is_binary(root) <- args["root"] || "/",
         {:ok, selected} <- select_backends(registered, args["backend"]),
         matches when is_list(matches) <- collect(selected, root, query, ctx) do
      case Pagination.paginate(matches, args["cursor"]) do
        {:ok, page, next_cursor} ->
          result = %{"matches" => page}

          if next_cursor,
            do: {:ok, Map.put(result, "nextCursor", next_cursor)},
            else: {:ok, result}

        {:error, %Error{}} = error ->
          error
      end
    end
  end

  defp validate_binary(value, _name) when is_binary(value), do: {:ok, value}

  defp validate_binary(_, name),
    do: {:error, Error.invalid_params("mcp_fs_search requires a #{name}")}

  defp select_backends(registered, nil), do: {:ok, Enum.map(registered, &elem(&1, 0))}

  defp select_backends(registered, filter) do
    wanted = String.downcase(filter)

    selected =
      Enum.filter(registered, fn {backend, _opts} ->
        name = backend |> inspect() |> String.downcase()
        name == wanted or String.split(name, ".") |> List.last() == wanted
      end)

    if selected == [],
      do: {:error, Error.resource_not_found("vfs backend")},
      else: {:ok, Enum.map(selected, &elem(&1, 0))}
  end

  # Merge in registration order; `:enosys` means the backend has no search
  # implementation (behaviour default) — skip it, surface anything else.
  defp collect(backends, root, query, ctx) do
    Enum.reduce_while(backends, [], fn backend, acc ->
      case VFS.search(backend, root, query, ctx) do
        {:ok, matches, _cursor} ->
          {:cont, [Enum.map(matches, &Map.put(&1, :backend, inspect(backend))) | acc]}

        {:error, :enosys} ->
          {:cont, acc}

        {:error, errno} when is_atom(errno) ->
          {:halt, {:error, VFS.errno_error(errno)}}

        {:error, %Error{}} = error ->
          {:halt, error}

        {:error, other} ->
          {:halt, {:error, Error.internal("vfs error: #{inspect(other)}")}}
      end
    end)
    |> case do
      lists when is_list(lists) -> lists |> Enum.reverse() |> Enum.concat()
      error -> error
    end
  end
end
