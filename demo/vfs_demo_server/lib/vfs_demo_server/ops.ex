defmodule VfsDemoServer.Ops do
  @moduledoc """
  Wire-level op dispatch for the demo server: `dispatch/3` maps
  `vfs/<op>` requests to `Noizu.MCP.Server.Features.VFS` calls against
  `VfsDemoServer.Backend` and renders the string-keyed wire maps (shapes
  mirror the M2 unix-socket contract). Also used by `VfsDemoServer.Test.mutate/3`.
  """

  alias Noizu.MCP.Server.Features.VFS
  alias VfsDemoServer.Backend

  @page 100

  @errno_codes %{
    enoent: -32002,
    eacces: -32040,
    eexist: -32041,
    erofs: -32042,
    eisdir: -32043,
    enotdir: -32044,
    enotempty: -32045,
    enosys: -32046
  }

  def errno_codes, do: @errno_codes

  @doc "Dispatch one op. Returns `{:ok, wire_map}` or `{:error, errno_atom}`."
  def dispatch("vfs/stat", params, ctx) do
    with_path(params, fn path ->
      VFS.stat(Backend, path, ctx) |> map_result(&node_to_map/1)
    end)
  end

  def dispatch("vfs/list", params, ctx) do
    with_path(params, fn path ->
      cursor = params["cursor"]

      VFS.list(Backend, path, cursor, ctx)
      |> map_result(fn {entries, next} ->
        result = %{"entries" => Enum.map(entries, &entry_to_map/1)}
        if next, do: Map.put(result, "nextCursor", next), else: result
      end)
    end)
  end

  def dispatch("vfs/read", params, ctx) do
    with_path(params, fn path ->
      VFS.read(Backend, path, ctx, params["version"])
      |> map_result(fn {content, version} -> %{"content" => content, "version" => version} end)
    end)
  end

  def dispatch("vfs/write", params, ctx) do
    with_path(params, fn path ->
      case params["data"] do
        data when is_binary(data) ->
          VFS.write(Backend, path, data, ctx) |> map_result(&node_to_map/1)

        _ ->
          {:error, :enosys}
      end
    end)
  end

  def dispatch("vfs/create", params, ctx) do
    with_path(params, fn path ->
      data = if is_binary(params["data"]), do: params["data"], else: :dir
      VFS.create(Backend, path, data, ctx) |> map_result(&node_to_map/1)
    end)
  end

  def dispatch("vfs/remove", params, ctx) do
    with_path(params, fn path ->
      VFS.remove(Backend, path, ctx) |> map_result(fn _ -> %{"removed" => path} end)
    end)
  end

  def dispatch("vfs/search", params, ctx) do
    query = params["query"]
    root = params["root"] || "/"

    if is_binary(query) and is_binary(root) do
      case VFS.search(Backend, root, query, ctx) do
        {:ok, matches, _next} ->
          {page, next} = paginate(matches, params["cursor"])
          result = %{"matches" => Enum.map(page, &match_to_map/1)}
          {:ok, if(next, do: Map.put(result, "nextCursor", next), else: result)}

        {:error, _} = error ->
          error
      end
    else
      {:error, :enosys}
    end
  end

  def dispatch("vfs/xattr", params, ctx) do
    with_path(params, fn path ->
      VFS.xattr(Backend, path, ctx)
    end)
  end

  def dispatch("vfs/ping", _params, _ctx), do: {:ok, %{"pong" => true}}

  def dispatch(method, _params, _ctx), do: {:error, {:unknown_method, method}}

  # ── helpers ───────────────────────────────────────────────────────────────

  defp with_path(params, fun) when is_map(params) do
    case params["path"] do
      path when is_binary(path) -> fun.(path)
      _ -> {:error, :enosys}
    end
  end

  defp with_path(_params, _fun), do: {:error, :enosys}

  defp map_result(:ok, wrap), do: {:ok, wrap.(:ok)}
  defp map_result({:ok, value}, wrap), do: {:ok, wrap.(value)}
  defp map_result({:ok, a, b}, wrap), do: {:ok, wrap.({a, b})}
  defp map_result({:error, _} = error, _wrap), do: error

  defp node_to_map(%Noizu.MCP.VFS{} = node) do
    %{
      "type" => Atom.to_string(node.type),
      "size" => node.size,
      "mtime" => node.mtime,
      "version" => node.version,
      "writable" => node.writable,
      "executable" => node.executable,
      "xattrs" => node.xattrs
    }
  end

  defp entry_to_map(entry) do
    %{
      "name" => entry.name,
      "type" => Atom.to_string(entry.type),
      "size" => entry.size,
      "mtime" => entry.mtime,
      "version" => entry.version
    }
  end

  defp match_to_map(match),
    do: %{"path" => match.path, "line" => match.line, "text" => match.text}

  defp paginate(list, nil), do: paginate(list, 0)

  defp paginate(list, cursor) when is_binary(cursor) do
    {offset, ""} = Integer.parse(cursor)
    paginate(list, offset)
  end

  defp paginate(list, offset) when is_integer(offset) do
    page = Enum.slice(list, offset, @page)
    next = if offset + @page < length(list), do: Integer.to_string(offset + @page)
    {page, next}
  end
end
