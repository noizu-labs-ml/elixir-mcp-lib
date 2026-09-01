defmodule Noizu.MCP.VFS.Fixture.Memory do
  @moduledoc """
  In-memory VFS backend for the conformance battery.

  State is a `{tree, contents}` pair — path→node and path→content maps — held
  in an ETS table whose tid lives in `ctx.assigns[:tree]`. Every test seeds its
  own table, so suites stay isolated and async-safe. Use `seed/0` as the
  conformance `seed:` callback:

      use Noizu.MCP.VFS.Conformance,
        backend: Noizu.MCP.VFS.Fixture.Memory,
        seed: {Noizu.MCP.VFS.Fixture.Memory, :seed}

  Spec format: `%{path => content}` where content is the `:dir` atom or file
  content as a binary.
  """

  use Noizu.MCP.VFS

  alias Noizu.MCP.Ctx
  alias Noizu.MCP.Server.Features.Pagination

  @standard_tree %{
    "/" => :dir,
    "/hello.txt" => "hello world\n",
    "/docs" => :dir,
    "/docs/a.md" => "# alpha\nbeta gamma\n",
    "/docs/b.md" => "delta\n",
    "/empty" => :dir,
    "/bin" => :dir,
    "/bin/sh" => "exec\n"
  }

  @doc "A ctx carrying the standard seeded tree."
  def seed, do: seed(@standard_tree)

  @doc "A ctx carrying a tree built from `spec` (`%{path => :dir | binary}`)."
  def seed(spec) when is_map(spec) do
    # :public — handler processes (transport connections, tasks) are not the
    # seeding process, and the tid travels via ctx.assigns.
    tid = :ets.new(:mcp_vfs_fixture_tree, [:set, :public])

    state =
      Enum.reduce(spec, {%{}, %{}}, fn
        {path, :dir}, {tree, contents} ->
          {Map.put(tree, path, dir_node()), contents}

        {path, content}, {tree, contents} when is_binary(content) ->
          {Map.put(tree, path, file_node(byte_size(content), 1)),
           Map.put(contents, path, content)}
      end)

    :ets.insert(tid, {:state, state})
    %Ctx{assigns: %{tree: tid}}
  end

  @impl true
  def stat(path, ctx) do
    peek(ctx, fn {tree, _contents} ->
      case Map.fetch(tree, path) do
        {:ok, node} -> {:ok, node}
        :error -> {:error, :enoent}
      end
    end)
  end

  @impl true
  def list(path, cursor, ctx) do
    peek(ctx, fn {tree, _contents} ->
      case Map.get(tree, path) do
        %Noizu.MCP.VFS{type: :dir} ->
          entries =
            tree
            |> Enum.filter(fn {child, _node} -> parent(child) == path end)
            |> Enum.sort()
            |> Enum.map(fn {child, node} ->
              %{
                name: Path.basename(child),
                type: node.type,
                size: node.size,
                mtime: node.mtime,
                version: node.version
              }
            end)

          Pagination.paginate(entries, cursor)

        %Noizu.MCP.VFS{} ->
          {:error, :enotdir}

        nil ->
          {:error, :enoent}
      end
    end)
  end

  @impl true
  def read(path, ctx) do
    peek(ctx, fn {tree, contents} ->
      case Map.get(tree, path) do
        %Noizu.MCP.VFS{type: :file, version: version} ->
          {:ok, Map.get(contents, path, ""), version}

        %Noizu.MCP.VFS{type: :dir} ->
          {:error, :eisdir}

        nil ->
          {:error, :enoent}
      end
    end)
  end

  @impl true
  def write(path, data, ctx) when is_binary(data) do
    transact(ctx, fn {tree, contents} ->
      case Map.get(tree, path) do
        %Noizu.MCP.VFS{type: :file, version: version} ->
          node = file_node(byte_size(data), version + 1)
          {:ok, {Map.put(tree, path, node), Map.put(contents, path, data)}, {:ok, node}}

        %Noizu.MCP.VFS{type: :dir} ->
          {:error, :eisdir}

        nil ->
          {:error, :enoent}
      end
    end)
  end

  @impl true
  def create(path, data, ctx) do
    transact(ctx, fn {tree, contents} ->
      cond do
        Map.has_key?(tree, path) ->
          {:error, :eexist}

        not dir?(tree, parent(path)) ->
          {:error, :enoent}

        true ->
          case data do
            :dir ->
              node = dir_node()
              {:ok, {Map.put(tree, path, node), contents}, {:ok, node}}

            data when is_binary(data) ->
              node = file_node(byte_size(data), 1)
              {:ok, {Map.put(tree, path, node), Map.put(contents, path, data)}, {:ok, node}}

            _ ->
              {:error, {:bad_data, data}}
          end
      end
    end)
  end

  @impl true
  def remove(path, ctx) do
    transact(ctx, fn {tree, contents} ->
      cond do
        path == "/" ->
          {:error, :eacces}

        dir?(tree, path) and Enum.any?(tree, fn {child, _node} -> parent(child) == path end) ->
          {:error, :enotempty}

        Map.has_key?(tree, path) ->
          {:ok, {Map.delete(tree, path), Map.delete(contents, path)}, :ok}

        true ->
          {:error, :enoent}
      end
    end)
  end

  @impl true
  def search(root, query, ctx) do
    peek(ctx, fn {tree, contents} ->
      prefix = if String.ends_with?(root, "/"), do: root, else: root <> "/"

      matches =
        contents
        |> Enum.filter(fn {path, _content} ->
          Map.has_key?(tree, path) and (path == root or String.starts_with?(path, prefix))
        end)
        |> Enum.sort()
        |> Enum.flat_map(fn {path, content} ->
          content
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {text, _line} -> String.contains?(text, query) end)
          |> Enum.map(fn {text, line} -> %{path: path, line: line, text: text} end)
        end)

      {:ok, matches, nil}
    end)
  end

  @impl true
  def xattr(path, ctx) do
    case stat(path, ctx) do
      {:ok, %Noizu.MCP.VFS{xattrs: xattrs}} -> {:ok, xattrs}
      {:error, _} = error -> error
    end
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp dir_node, do: %Noizu.MCP.VFS{type: :dir, mtime: 0, version: 1, writable: true}

  defp file_node(size, version),
    do: %Noizu.MCP.VFS{type: :file, size: size, mtime: 0, version: version, writable: true}

  defp tree_ref(%Ctx{assigns: %{tree: tid}}), do: tid

  # Read-only access: fun receives the state and returns a plain result.
  defp peek(ctx, fun) do
    [{:state, state}] = :ets.lookup(tree_ref(ctx), :state)
    fun.(state)
  end

  # Read-modify-write: fun returns `{:ok, new_state, result}` (committed) or a
  # plain error tuple.
  defp transact(ctx, fun) do
    tid = tree_ref(ctx)
    [{:state, state}] = :ets.lookup(tid, :state)

    case fun.(state) do
      {:ok, new_state, result} ->
        :ets.insert(tid, {:state, new_state})
        result

      {:error, _} = error ->
        error
    end
  end

  defp dir?(tree, path), do: match?(%Noizu.MCP.VFS{type: :dir}, Map.get(tree, path))

  defp parent("/"), do: nil

  defp parent(path) do
    case String.split(String.trim_trailing(path, "/"), "/", trim: true) do
      [_only] -> "/"
      parts -> "/" <> Enum.join(Enum.drop(parts, -1), "/")
    end
  end
end
