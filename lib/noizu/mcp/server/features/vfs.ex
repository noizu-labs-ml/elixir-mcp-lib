defmodule Noizu.MCP.Server.Features.VFS do
  @moduledoc """
  VFS feature plumbing: the helpers behind the `vfs/*` extension operations.

  Two layers, mirroring `Noizu.MCP.Server.Features.Resources`:

    * Backend-level (`stat/3`, `list/4`, `read/3`, `write/4`, `create/4`,
      `remove/3`, `search/4`, `xattr/3`) — cache-aware wrappers over a backend
      module. Read results go through `Noizu.MCP.VFS.Cache` and get the
      backend's generation stamped into node versions; successful writes bump
      the generation first. This is the layer the conformance battery
      (`Noizu.MCP.VFS.Conformance`) exercises.
    * Server-level (`stat(server, params, ctx)`, ...) — param extraction and
      validation over the server's registered backend (first entry of
      `__mcp__(:vfs)`), returning wire-shaped maps or `Noizu.MCP.Error` structs.

  Every mount also serves a generated, read-only `/README.md`
  (`Noizu.MCP.VFS.Readme`) at its root, backend-wins: paths the backend
  answers `:enoent` fall back to the generated document, first-page root
  listings gain a `README.md` entry when the backend does not list one, and
  writes to the reserved path are `:erofs` unless the backend owns a writable
  node there.
  """

  alias Noizu.MCP.Ctx
  alias Noizu.MCP.Error
  alias Noizu.MCP.Server.Features.Pagination
  alias Noizu.MCP.Server.VFSPubSub
  alias Noizu.MCP.VFS
  alias Noizu.MCP.VFS.Cache
  alias Noizu.MCP.VFS.Readme

  @errno_codes %{
    eacces: -32040,
    eexist: -32041,
    erofs: -32042,
    eisdir: -32043,
    enotdir: -32044,
    enotempty: -32045,
    enosys: -32046,
    eio: -32048
  }

  # ── backend-level (cache-aware) ───────────────────────────────────────────

  @doc "Stat `path` against `backend`, through the cache."
  # ⟦𓆒⟧ stat
  @spec stat(module(), String.t(), Ctx.t()) ::
          {:ok, VFS.t()} | {:error, term()}
  def stat(backend, path, ctx) when is_binary(path) do
    case Cache.get(backend, :stat, path) do
      nil ->
        case backend.stat(path, ctx) do
          {:ok, node} ->
            Cache.put(backend, :stat, path, node, ttl())
            {:ok, stamp(backend, node)}

          {:error, :enoent} = error ->
            if Readme.path?(path), do: readme_stat(backend, path, ctx), else: error

          {:error, _} = error ->
            error
        end

      node ->
        {:ok, stamp(backend, node)}
    end
  end

  # Generated /README.md fallback — cached like any backend node.
  defp readme_stat(backend, path, ctx) do
    node = Readme.node(backend, ctx)
    Cache.put(backend, :stat, path, node, ttl())
    {:ok, stamp(backend, node)}
  end

  @doc "List `path`'s children against `backend`, through the cache."
  # ⟦𓆒⟧ list
  @spec list(module(), String.t(), String.t() | nil, Ctx.t()) ::
          {:ok, [map()], String.t() | nil} | {:error, term()}
  def list(backend, path, cursor, ctx) when is_binary(path) do
    cache_key = "#{path}\0#{cursor || ""}"

    case Cache.get(backend, :list, cache_key) do
      nil ->
        case backend.list(path, cursor, ctx) do
          {:ok, entries, next_cursor} ->
            entries = Enum.map(entries, &stamp_entry(backend, &1))
            entries = first_root_page(path, cursor, entries, backend, ctx)
            Cache.put(backend, :list, cache_key, {entries, next_cursor}, ttl())
            {:ok, entries, next_cursor}

          {:error, _} = error ->
            error
        end

      {entries, next_cursor} ->
        {:ok, entries, next_cursor}
    end
  end

  # The generated README node joins first-page root listings when the backend
  # does not list its own README.md.
  defp first_root_page("/", nil, entries, backend, ctx), do: Readme.prepend(backend, entries, ctx)
  defp first_root_page(_path, _cursor, entries, _backend, _ctx), do: entries

  @doc "Read `path` against `backend`, through the cache."
  # ⟦𓆒⟧ read
  @spec read(module(), String.t(), Ctx.t(), non_neg_integer() | nil) ::
          {:ok, binary(), non_neg_integer()} | {:error, term()}
  def read(backend, path, ctx, expected_version \\ nil) when is_binary(path) do
    cache_opts = if expected_version, do: [version: unstamp(backend, expected_version)], else: []

    case Cache.get(backend, :read, path, cache_opts) do
      nil ->
        case backend.read(path, ctx) do
          {:ok, content, version} = result ->
            Cache.put(backend, :read, path, result, ttl())
            {:ok, content, version + Cache.generation(backend)}

          {:error, :enoent} = error ->
            if Readme.path?(path), do: readme_read(backend, path, ctx), else: error

          {:error, _} = error ->
            error
        end

      {:ok, content, version} ->
        {:ok, content, version + Cache.generation(backend)}

      {:error, _} = error ->
        error
    end
  end

  # Generated /README.md fallback — cached like any backend node.
  defp readme_read(backend, path, ctx) do
    result = {:ok, Readme.content(backend, ctx), 1}
    Cache.put(backend, :read, path, result, ttl())
    {:ok, elem(result, 1), 1 + Cache.generation(backend)}
  end

  @doc "Overwrite `path` via `backend`; bumps the generation on success."
  # ⟦𓆒⟧ write
  @spec write(module(), String.t(), binary(), Ctx.t()) :: {:ok, VFS.t()} | {:error, term()}
  def write(backend, path, data, ctx) when is_binary(path) and is_binary(data) do
    if Readme.reserved?(backend, path, ctx),
      do: {:error, :erofs},
      else: write_node(backend, path, data, ctx)
  end

  defp write_node(backend, path, data, ctx) do
    case backend.write(path, data, ctx) do
      {:ok, node} ->
        Cache.bump_generation(backend)
        node = stamp(backend, node)
        VFSPubSub.publish(backend, :write, path, node.version, ctx)
        {:ok, node}

      {:error, _} = error ->
        error
    end
  end

  @doc "Create `path` via `backend`; bumps the generation on success."
  # ⟦𓆒⟧ create
  @spec create(module(), String.t(), binary() | :dir, Ctx.t()) ::
          {:ok, VFS.t()} | {:error, term()}
  def create(backend, path, data, ctx) when is_binary(path) do
    if Readme.reserved?(backend, path, ctx),
      do: {:error, :erofs},
      else: create_node(backend, path, data, ctx)
  end

  defp create_node(backend, path, data, ctx) do
    case backend.create(path, data, ctx) do
      {:ok, node} ->
        Cache.bump_generation(backend)
        node = stamp(backend, node)
        VFSPubSub.publish(backend, :create, path, node.version, ctx)
        {:ok, node}

      {:error, _} = error ->
        error
    end
  end

  @doc "Remove `path` via `backend`; bumps the generation on success."
  # ⟦𓆒⟧ remove
  @spec remove(module(), String.t(), Ctx.t()) :: :ok | {:error, term()}
  def remove(backend, path, ctx) when is_binary(path) do
    if Readme.reserved?(backend, path, ctx),
      do: {:error, :erofs},
      else: remove_node(backend, path, ctx)
  end

  defp remove_node(backend, path, ctx) do
    case backend.remove(path, ctx) do
      :ok ->
        gen = Cache.bump_generation(backend)
        VFSPubSub.publish(backend, :remove, path, gen, ctx)
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc "Search under `root` via `backend` (uncached)."
  # ⟦𓆒⟧ search
  @spec search(module(), String.t(), String.t(), Ctx.t()) ::
          {:ok, [map()], String.t() | nil} | {:error, term()}
  def search(backend, root, query, ctx) when is_binary(root) and is_binary(query) do
    case backend.search(root, query, ctx) do
      {:ok, matches, next_cursor} -> {:ok, matches, next_cursor}
      {:error, _} = error -> error
    end
  end

  @doc "Extended attributes for `path` via `backend` (uncached)."
  # ⟦𓆒⟧ xattr
  @spec xattr(module(), String.t(), Ctx.t()) :: {:ok, map()} | {:error, term()}
  def xattr(backend, path, ctx) when is_binary(path) do
    case backend.xattr(path, ctx) do
      {:ok, xattrs} ->
        {:ok, xattrs}

      {:error, :enoent} = error ->
        if Readme.path?(path) do
          {:ok, Readme.node(backend, ctx).xattrs}
        else
          error
        end

      {:error, _} = error ->
        error
    end
  end

  # ── server-level (params → wire maps) ─────────────────────────────────────

  @doc "vfs_stat operation."
  # ⟦𓆒⟧ vfs_stat
  def vfs_stat(server, params, ctx) do
    with_backend(server, fn backend ->
      with_path(params, fn path ->
        stat(backend, path, ctx) |> to_result(&node_to_map/1)
      end)
    end)
  end

  @doc "vfs_list operation."
  # ⟦𓆒⟧ vfs_list
  def vfs_list(server, params, ctx) do
    with_backend(server, fn backend ->
      with_path(params, fn path ->
        cursor = (params || %{})["cursor"]

        list(backend, path, cursor, ctx)
        |> to_result(fn {entries, next_cursor} ->
          result = %{"entries" => entries}
          if next_cursor, do: Map.put(result, "nextCursor", next_cursor), else: result
        end)
      end)
    end)
  end

  @doc "vfs_read operation."
  # ⟦𓆒⟧ vfs_read
  def vfs_read(server, params, ctx) do
    with_backend(server, fn backend ->
      with_path(params, fn path ->
        expected = version_param(params)

        read(backend, path, ctx, expected)
        |> to_result(fn {content, version} ->
          %{"content" => content, "version" => version}
        end)
      end)
    end)
  end

  @doc "vfs_write operation."
  # ⟦𓆒⟧ vfs_write
  def vfs_write(server, params, ctx) do
    with_backend(server, fn backend ->
      with_path(params, fn path ->
        with_data(params, fn data ->
          write(backend, path, data, ctx) |> to_result(&node_to_map/1)
        end)
      end)
    end)
  end

  @doc "vfs_create operation."
  # ⟦𓆒⟧ vfs_create
  def vfs_create(server, params, ctx) do
    with_backend(server, fn backend ->
      with_path(params, fn path ->
        data =
          case (params || %{})["data"] do
            nil -> :dir
            data when is_binary(data) -> data
          end

        create(backend, path, data, ctx) |> to_result(&node_to_map/1)
      end)
    end)
  end

  @doc "vfs_remove operation."
  # ⟦𓆒⟧ vfs_remove
  def vfs_remove(server, params, ctx) do
    with_backend(server, fn backend ->
      with_path(params, fn path ->
        remove(backend, path, ctx) |> to_result(fn :ok -> %{"removed" => path} end)
      end)
    end)
  end

  @doc "vfs_search operation."
  # ⟦𓆒⟧ vfs_search
  def vfs_search(server, params, ctx) do
    params = params || %{}

    with_backend(server, fn backend ->
      root = params["root"] || "/"

      with {:ok, _root} <- validate_binary(root, "root"),
           {:ok, query} <- validate_binary(params["query"], "query") do
        case search(backend, root, query, ctx) do
          {:ok, matches, _backend_cursor} ->
            case Pagination.paginate(matches, params["cursor"]) do
              {:ok, page, next_cursor} ->
                result = %{"matches" => page}

                if next_cursor,
                  do: {:ok, Map.put(result, "nextCursor", next_cursor)},
                  else: {:ok, result}

              {:error, %Error{}} = error ->
                error
            end

          {:error, %Error{}} = error ->
            error

          {:error, errno} when is_atom(errno) ->
            {:error, errno_error(errno)}

          {:error, other} ->
            {:error, Error.internal("vfs error: #{inspect(other)}")}
        end
      end
    end)
  end

  @doc "vfs_xattr operation."
  # ⟦𓆒⟧ vfs_xattr
  def vfs_xattr(server, params, ctx) do
    with_backend(server, fn backend ->
      with_path(params, fn path ->
        xattr(backend, path, ctx) |> to_result(& &1)
      end)
    end)
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp with_backend(server, fun) do
    case server.__mcp__(:vfs) do
      [{backend, _opts} | _] -> fun.(backend)
      _ -> {:error, Error.capability_not_supported("vfs")}
    end
  end

  defp with_path(params, fun) do
    with {:ok, path} <- validate_binary((params || %{})["path"], "path"), do: fun.(path)
  end

  defp with_data(params, fun) do
    with {:ok, data} <- validate_binary((params || %{})["data"], "data"), do: fun.(data)
  end

  defp validate_binary(value, _name) when is_binary(value), do: {:ok, value}
  defp validate_binary(_value, name), do: {:error, Error.invalid_params("vfs requires a #{name}")}

  defp version_param(params) do
    case (params || %{})["version"] do
      version when is_integer(version) -> version
      _ -> nil
    end
  end

  defp to_result(:ok, wrap), do: {:ok, wrap.(:ok)}
  defp to_result({:ok, value}, wrap), do: {:ok, wrap.(value)}
  defp to_result({:ok, a, b}, wrap), do: {:ok, wrap.({a, b})}
  defp to_result({:error, %Error{}} = error, _wrap), do: error
  defp to_result({:error, errno}, _wrap) when is_atom(errno), do: {:error, errno_error(errno)}

  defp to_result({:error, other}, _wrap),
    do: {:error, Error.internal("vfs error: #{inspect(other)}")}

  @doc "Map a VFS errno atom to a `Noizu.MCP.Error` (M2 wire mapping)."
  # ⟦𓆒⟧ errno_error
  def errno_error(:enoent), do: Error.resource_not_found("vfs path")

  def errno_error(errno) do
    case @errno_codes do
      %{^errno => code} -> Error.custom(code, "vfs error: #{errno}", %{errno: errno})
      _ -> Error.internal("vfs error: #{inspect(errno)}")
    end
  end

  defp stamp(backend, %VFS{} = node),
    do: %{node | version: node.version + Cache.generation(backend)}

  defp stamp_entry(backend, entry) when is_map(entry) do
    case entry do
      %{version: version} -> %{entry | version: version + Cache.generation(backend)}
      _ -> entry
    end
  end

  # Strip the generation back off so a client-supplied version can be compared
  # against a backend's raw cached read version.
  defp unstamp(backend, version), do: version - Cache.generation(backend)

  defp node_to_map(%VFS{} = node) do
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

  defp ttl, do: Application.get_env(:noizu_mcp, :vfs_cache_ttl_ms, 60_000)
end
