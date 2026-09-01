defmodule VfsDemoServer.Store do
  @moduledoc """
  In-memory VFS tree: a GenServer owning the node map. All state lives here;
  the on-disk truth is the YAML seed loaded at boot. Reads and mutations are
  serialized through this process so multi-step mutations are atomic.

  Nodes are `%{path, type, content, mode, version, mtime, xattrs, writable,
  executable}`. Per-node versions are monotonic (`version` bumps on every
  write); the backend's cache generation (bumped by `Noizu.MCP.Server.Features.VFS`
  after each mutation) rides on top of that, so wire-visible versions strictly
  increase across the tree.
  """

  use GenServer

  @page_size 100

  # ── client API ────────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def stat(path), do: GenServer.call(__MODULE__, {:stat, path})
  def read(path), do: GenServer.call(__MODULE__, {:read, path})
  def list(path, cursor), do: GenServer.call(__MODULE__, {:list, path, cursor})
  def write(path, data), do: GenServer.call(__MODULE__, {:write, path, data})
  def create(path, data), do: GenServer.call(__MODULE__, {:create, path, data})
  def remove(path), do: GenServer.call(__MODULE__, {:remove, path})
  def search(root, query), do: GenServer.call(__MODULE__, {:search, root, query})
  def xattr(path), do: GenServer.call(__MODULE__, {:xattr, path})

  @doc "All node paths (debug/tests)."
  def paths, do: GenServer.call(__MODULE__, :paths)

  # ── server ────────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    nodes =
      case Keyword.fetch(opts, :seed) do
        {:ok, seed_nodes} when is_list(seed_nodes) -> seed_nodes
        {:ok, :default} -> VfsDemoServer.Seed.load(default_seed_path())
      end

    tree =
      Enum.reduce(nodes, %{}, fn node, acc ->
        Map.put(acc, node.path, node)
      end)

    {:ok, %{tree: tree}}
  end

  defp default_seed_path, do: Path.join(:code.priv_dir(:vfs_demo_server), "seed/tree.yaml")

  @impl GenServer
  def handle_call({:stat, path}, _from, state) do
    case VfsDemoServer.Paths.normalize(path) do
      {:error, errno} -> {:reply, {:error, errno}, state}
      path -> {:reply, fetch(state.tree, path), state}
    end
  end

  def handle_call({:read, path}, _from, state) do
    case VfsDemoServer.Paths.normalize(path) do
      {:error, errno} ->
        {:reply, {:error, errno}, state}

      path ->
        case fetch(state.tree, path) do
          {:ok, %{type: :file, content: content, version: v}} ->
            {:reply, {:ok, content, v}, state}

          {:ok, %{type: :dir}} ->
            {:reply, {:error, :eisdir}, state}

          error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:list, path, cursor}, _from, state) do
    case VfsDemoServer.Paths.normalize(path) do
      {:error, errno} ->
        {:reply, {:error, errno}, state}

      path ->
        case fetch(state.tree, path) do
          {:ok, %{type: :dir}} ->
            offset = cursor_offset(cursor)
            children = children(state.tree, path)
            page = Enum.slice(children, offset, @page_size)

            next =
              if offset + @page_size < length(children),
                do: Integer.to_string(offset + @page_size)

            {:reply, {:ok, Enum.map(page, &entry/1), next}, state}

          {:ok, %{type: :file}} ->
            {:reply, {:error, :enotdir}, state}

          error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:write, path, data}, _from, state) when is_binary(data) do
    case VfsDemoServer.Paths.normalize(path) do
      {:error, errno} ->
        {:reply, {:error, errno}, state}

      path ->
        case fetch(state.tree, path) do
          {:ok, %{type: :file} = node} ->
            node = %{node | content: data, mtime: now(), version: node.version + 1}
            {:reply, {:ok, node}, %{state | tree: Map.put(state.tree, path, node)}}

          {:ok, %{type: :dir}} ->
            {:reply, {:error, :eisdir}, state}

          error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:write, _path, _data}, _from, state), do: {:reply, {:error, :enotdir}, state}

  def handle_call({:create, path, data}, _from, state) do
    case VfsDemoServer.Paths.normalize(path) do
      {:error, errno} ->
        {:reply, {:error, errno}, state}

      "/" ->
        {:reply, {:error, :eexist}, state}

      path ->
        parent = VfsDemoServer.Paths.parent(path)

        cond do
          Map.has_key?(state.tree, path) ->
            {:reply, {:error, :eexist}, state}

          not Map.has_key?(state.tree, parent) ->
            {:reply, {:error, :enoent}, state}

          true ->
            node =
              case data do
                :dir -> new_node(path, :dir, nil)
                content when is_binary(content) -> new_node(path, :file, content)
                _ -> {:error, :enosys}
              end

            case node do
              {:error, errno} -> {:reply, {:error, errno}, state}
              node -> {:reply, {:ok, node}, %{state | tree: Map.put(state.tree, path, node)}}
            end
        end
    end
  end

  def handle_call({:remove, path}, _from, state) do
    case VfsDemoServer.Paths.normalize(path) do
      {:error, errno} ->
        {:reply, {:error, errno}, state}

      "/" ->
        {:reply, {:error, :enotempty}, state}

      path ->
        cond do
          not Map.has_key?(state.tree, path) ->
            {:reply, {:error, :enoent}, state}

          children(state.tree, path) != [] ->
            {:reply, {:error, :enotempty}, state}

          true ->
            {:reply, :ok, %{state | tree: Map.delete(state.tree, path)}}
        end
    end
  end

  def handle_call({:search, root, query}, _from, state) do
    case VfsDemoServer.Paths.normalize(root) do
      {:error, errno} ->
        {:reply, {:error, errno}, state}

      root ->
        matches =
          state.tree
          |> Map.values()
          |> Enum.filter(&(&1.type == :file and VfsDemoServer.Paths.under?(&1.path, root)))
          |> Enum.flat_map(&match_lines(&1, query))

        {:reply, {:ok, matches}, state}
    end
  end

  def handle_call({:xattr, path}, _from, state) do
    case VfsDemoServer.Paths.normalize(path) do
      {:error, errno} ->
        {:reply, {:error, errno}, state}

      path ->
        case fetch(state.tree, path) do
          {:ok, node} -> {:reply, {:ok, node.xattrs}, state}
          error -> {:reply, error, state}
        end
    end
  end

  def handle_call(:paths, _from, state), do: {:reply, Map.keys(state.tree), state}

  # ── internals ─────────────────────────────────────────────────────────────

  defp fetch(tree, path) do
    case Map.fetch(tree, path) do
      {:ok, node} -> {:ok, node}
      :error -> {:error, :enoent}
    end
  end

  defp children(tree, dir) do
    tree
    |> Map.values()
    |> Enum.filter(&(VfsDemoServer.Paths.parent(&1.path) == dir))
    |> Enum.sort_by(& &1.path)
  end

  defp entry(node),
    do: %{
      name: VfsDemoServer.Paths.basename(node.path),
      type: node.type,
      size: size(node),
      mtime: node.mtime,
      version: node.version
    }

  defp size(%{type: :dir}), do: 0
  defp size(%{content: content}), do: byte_size(content || "")

  defp match_lines(node, query) do
    node.content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _i} -> String.contains?(line, query) end)
    |> Enum.map(fn {line, i} -> %{path: node.path, line: i, text: line} end)
  end

  defp new_node(path, type, content) do
    mode = if(type == :dir, do: 0o755, else: 0o644)

    %{
      path: path,
      type: type,
      content: if(type == :file, do: content || "", else: nil),
      mode: mode,
      version: 1,
      mtime: now(),
      xattrs: %{},
      writable: true,
      executable: false
    }
  end

  defp cursor_offset(nil), do: 0

  defp cursor_offset(cursor) when is_binary(cursor) do
    case Integer.parse(cursor) do
      {n, ""} when n >= 0 -> n
      _ -> raise ArgumentError, "bad cursor: #{inspect(cursor)}"
    end
  end

  defp now, do: System.system_time(:millisecond)
end
