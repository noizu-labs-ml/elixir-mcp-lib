defmodule Noizu.MCP.VFS.File do
  @moduledoc """
  Directory-backed VFS backend: mounts a real filesystem directory at `/`.

      defmodule MyApp.MCP.FS do
        use Noizu.MCP.Server, name: "my-app", version: "1.0.0"
        vfs(Noizu.MCP.VFS.File, root: "/srv/pub")
      end

  Registration opts (delivered to every call through `ctx.assigns[:vfs_opts]`;
  `Application.get_env(:noizu_mcp, #{inspect(__MODULE__)})` is the fallback for
  bare module calls such as conformance seeds):

    * `:root` — required, the directory mounted at `/`
    * `:read_only` — default `false`; when `true` every mutating op is
      `:erofs`, nodes serve `writable: false`, and the registration no longer
      advertises the server's `vfs_write` capability
    * `:mime_types` — extension→mime overrides layered over the builtin map

  ## Paths & containment

  VFS paths are absolute under the mount. Every op resolves against `root` and
  refuses anything that escapes it — hard requirement, no exceptions:

    * `..` (or any expansion) landing outside `root` → `:enoent`
    * a symlink resolving outside `root` → `:eacces` (symlinks *inside* the
      tree are followed by `stat`/`read` like any other node)

  Non-regular, non-directory nodes (devices, fifos, sockets) are not served —
  `:eacces`.

  ## Versions

  A node's version is a stable integer keyed on the file's `{mtime, size}`
  signature: equal signatures serve equal versions (so read/version matches
  stat/version), writes through this backend bump strictly, and an out-of-band
  change (new signature) re-derives. Versions are advisory — an external
  modification that preserves both mtime and size reuses the old version. The
  signature table is a process-lifetime ETS table keyed on resolved paths;
  it is never pruned (bounded by the number of distinct files touched).
  """

  use Noizu.MCP.VFS

  alias Noizu.MCP.Ctx
  alias Noizu.MCP.Server.Features.Pagination
  # This module's name ends in `.File` — Elixir's implicit self-alias shadows
  # the stdlib filesystem module inside the body, so every FS call below goes
  # through the explicit `Elixir.File.` prefix.

  @vtab :noizu_mcp_vfs_file_versions

  @default_mime_types %{
    ".txt" => "text/plain",
    ".md" => "text/markdown",
    ".html" => "text/html",
    ".css" => "text/css",
    ".js" => "text/javascript",
    ".json" => "application/json",
    ".xml" => "application/xml",
    ".yaml" => "application/yaml",
    ".yml" => "application/yaml",
    ".ex" => "text/x-elixir",
    ".exs" => "text/x-elixir",
    ".erl" => "text/x-erlang",
    ".hrl" => "text/x-erlang",
    ".pdf" => "application/pdf",
    ".zip" => "application/zip",
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".svg" => "image/svg+xml",
    ".ico" => "image/x-icon"
  }

  @impl true
  def stat(path, ctx) do
    with {:ok, abs} <- confine(path, root!(ctx)),
         {:ok, info} <- file_stat(abs) do
      {:ok, node(ctx, abs, info)}
    end
  end

  @impl true
  def list(path, cursor, ctx) do
    root = root!(ctx)

    with {:ok, abs} <- confine(path, root),
         {:ok, %Elixir.File.Stat{type: :directory}} <- Elixir.File.stat(abs) do
      entries =
        abs
        |> children(ctx)
        |> Enum.sort_by(fn entry -> {entry.type != :dir, entry.name} end)

      Pagination.paginate(entries, cursor)
    else
      {:ok, %Elixir.File.Stat{}} -> {:error, :enotdir}
      {:error, _} = error -> error
    end
  end

  @impl true
  def read(path, ctx) do
    with {:ok, abs} <- confine(path, root!(ctx)),
         {:ok, info} <- file_stat(abs) do
      if info.type == :directory do
        {:error, :eisdir}
      else
        case Elixir.File.read(abs) do
          {:ok, content} -> {:ok, content, version_for(abs, signature(info))}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  @impl true
  def write(path, data, ctx) when is_binary(data) do
    if read_only?(ctx) do
      {:error, :erofs}
    else
      with {:ok, abs} <- confine(path, root!(ctx)),
           {:ok, info} <- file_stat(abs) do
        if info.type == :directory do
          {:error, :eisdir}
        else
          case Elixir.File.write(abs, data) do
            :ok -> written_node(ctx, abs)
            {:error, reason} -> {:error, reason}
          end
        end
      end
    end
  end

  @impl true
  def create(path, data, ctx) do
    if read_only?(ctx) do
      {:error, :erofs}
    else
      root = root!(ctx)

      with {:ok, abs} <- confine_expanded(path, root),
           :ok <- occupied(abs),
           :ok <- parent_dir(abs, root) do
        cond do
          data == :dir ->
            case Elixir.File.mkdir(abs) do
              :ok -> written_node(ctx, abs)
              {:error, reason} -> {:error, reason}
            end

          is_binary(data) ->
            case Elixir.File.write(abs, data) do
              :ok -> written_node(ctx, abs)
              {:error, reason} -> {:error, reason}
            end

          true ->
            {:error, {:bad_data, data}}
        end
      end
    end
  end

  @impl true
  def remove(path, ctx) do
    if read_only?(ctx) do
      {:error, :erofs}
    else
      root = root!(ctx)

      with {:ok, abs} <- confine(path, root) do
        if abs == root do
          {:error, :eacces}
        else
          case Elixir.File.stat(abs) do
            {:error, _} = error -> error

            {:ok, %Elixir.File.Stat{type: :directory}} ->
              # POSIX lets rmdir report either EEXIST or ENOTEMPTY for a
              # non-empty dir; macOS picks EEXIST — normalize.
              case Elixir.File.rmdir(abs) do
                :ok -> :ok
                {:error, :eexist} -> {:error, :enotempty}
                {:error, reason} -> {:error, reason}
              end

            {:ok, %Elixir.File.Stat{}} -> unlink(Elixir.File.rm(abs))
          end
        end
      end
    end
  end

  @impl true
  def search(root, query, ctx) do
    with {:ok, abs} <- confine(root, root!(ctx)) do
      matches =
        abs
        |> walk()
        |> Enum.flat_map(fn path ->
          case Elixir.File.read(path) do
            {:ok, content} ->
              content
              |> String.split("\n")
              |> Enum.with_index(1)
              |> Enum.filter(fn {text, _line} -> String.contains?(text, query) end)
              |> Enum.map(fn {text, line} ->
                %{path: to_vpath(path, root!(ctx)), line: line, text: text}
              end)

            {:error, _} ->
              []
          end
        end)

      {:ok, matches, nil}
    end
  end

  @impl true
  def xattr(path, ctx) do
    case stat(path, ctx) do
      {:ok, %Noizu.MCP.VFS{xattrs: xattrs}} -> {:ok, xattrs}
      {:error, _} = error -> error
    end
  end

  @doc "Mime type for a VFS path — builtin extension map, overridable with `:mime_types`."
  # <REMOVED UUID HERE> mime_type
  def mime_type(path, opts \\ [])

  def mime_type(path, opts) when is_binary(path) and is_list(opts) do
    ext = path |> Path.extname() |> String.downcase()
    overrides = Keyword.get(opts, :mime_types, %{})

    Map.get(overrides, ext) || Map.get(@default_mime_types, ext) || "application/octet-stream"
  end

  @doc false
  @impl true
  def __mcp_vfs__(:describe) do
    "A real directory on the host filesystem mounted at `/` — plain files and " <>
      "subdirectories with traversal/symlink containment; read-write unless " <>
      "registered `read_only: true`."
  end

  # ── options ───────────────────────────────────────────────────────────────

  # Registration opts ride into every call via `ctx.assigns[:vfs_opts]`
  # (`Noizu.MCP.Server.Features.VFS` injects them); bare backend-module calls
  # (conformance seeds, scripts) fall back to the application env.
  defp config(%Ctx{assigns: %{vfs_opts: opts}}) when is_list(opts), do: opts
  defp config(_ctx), do: Application.get_env(:noizu_mcp, __MODULE__, [])

  defp read_only?(ctx), do: Keyword.get(config(ctx), :read_only, false)

  defp root!(ctx) do
    case Keyword.fetch(config(ctx), :root) do
      {:ok, root} -> Path.expand(root)
      :error -> raise ArgumentError, "Noizu.MCP.VFS.File requires a :root option"
    end
  end

  # ── containment ───────────────────────────────────────────────────────────

  # Expansion containment only — `abs` must lexically stay under `root`.
  # Anything that climbs out (`..`-style) reads as a path that does not exist
  # inside the tree we serve. VFS paths are absolute, so the mount-relative
  # form is what gets expanded against `root` (an absolute argument would make
  # `Path.expand/2` ignore the base).
  defp confine_expanded(path, root) do
    abs = Path.expand(String.trim_leading(path, "/"), root)

    if abs == root or String.starts_with?(abs, root <> "/"),
      do: {:ok, abs},
      else: {:error, :enoent}
  end

  # Full containment for existing targets: whatever `abs` resolves to through
  # symlinks must still land under `root`.
  defp confine(path, root) do
    with {:ok, abs} <- confine_expanded(path, root) do
      case resolve_links(abs, root) do
        {:ok, real} ->
          if real == root or String.starts_with?(real, root <> "/"),
            do: {:ok, abs},
            else: {:error, :eacces}

        {:error, _} = error ->
          error
      end
    end
  end

  # The parent of `abs` must be a real directory inside the mount — no symlink
  # slip-through for `create` either.
  defp parent_dir(abs, root) do
    with {:ok, real} <- resolve_links(Path.dirname(abs), root),
         true <- real == root or String.starts_with?(real, root <> "/"),
         {:ok, %Elixir.File.Stat{type: :directory}} <- Elixir.File.stat(real) do
      :ok
    else
      {:error, _} -> {:error, :enoent}
      false -> {:error, :eacces}
      {:ok, %Elixir.File.Stat{}} -> {:error, :enotdir}
    end
  end

  # A name that already exists (including a dangling symlink — a name is a
  # name) is `:eexist`, and never followed. `lstat` does not follow links.
  defp occupied(abs) do
    case Elixir.File.lstat(abs) do
      {:ok, _} -> {:error, :eexist}
      {:error, _} -> :ok
    end
  end

  # Symlink resolution, component-wise, below the mount root (Elixir 1.20
  # dropped `File.realpath/1`). The root's own ancestry is taken as given —
  # only links inside the tree are resolved, and any that climbs out is caught
  # by the caller's prefix check. Lexical `..` in a link target is normalized
  # against the link's resolved directory.
  defp resolve_links(abs, root) do
    root_segments = Path.split(root)
    do_resolve(Path.split(abs) |> Enum.drop(length(root_segments)), root_segments)
  end

  defp do_resolve([], stack), do: {:ok, rebuild(stack)}

  defp do_resolve([seg | work], stack) do
    cond do
      # `Path.split` yields a leading "/" segment on absolute paths.
      seg in ["", ".", "/"] ->
        do_resolve(work, stack)

      seg == ".." ->
        do_resolve(work, Enum.drop(stack, -1))

      true ->
        next = Path.join(rebuild(stack), seg)

        case Elixir.File.lstat(next) do
          {:ok, %Elixir.File.Stat{type: :symlink}} ->
            case Elixir.File.read_link(next) do
              {:ok, target} ->
                case Path.type(target) do
                  :absolute -> do_resolve(Path.split(target) ++ work, [])
                  :relative -> do_resolve(Path.split(target) ++ work, stack)
                  _ -> {:error, :eacces}
                end

              {:error, _} = error ->
                error
            end

          {:ok, _} ->
            do_resolve(work, stack ++ [seg])

          {:error, _} = error ->
            error
        end
    end
  end

  defp rebuild([]), do: "/"
  defp rebuild(segments), do: "/" <> Enum.join(Enum.reject(segments, &(&1 == "/")), "/")

  # ── internals ─────────────────────────────────────────────────────────────

  # Only regular files and directories are served.
  defp file_stat(abs) do
    case Elixir.File.stat(abs) do
      {:ok, %Elixir.File.Stat{type: type}} = ok when type in [:regular, :directory] -> ok
      {:ok, _} -> {:error, :eacces}
      {:error, _} = error -> error
    end
  end

  defp children(abs, ctx) do
    root = root!(ctx)

    case Elixir.File.ls(abs) do
      {:ok, names} ->
        for name <- names,
            child = Path.join(abs, name),
            {:ok, entry} <- [child_entry(child, root)] do
          entry
        end

      {:error, _} ->
        []
    end
  end

  # `lstat` first: a symlink child only joins the listing when it resolves
  # back inside the mount (the same confinement `search/3`'s walk applies) —
  # a link that escapes, or dangles, is skipped rather than leaking the
  # target's size/mtime through `vfs_list`.
  defp child_entry(child, root) do
    case Elixir.File.lstat(child) do
      {:ok, %Elixir.File.Stat{type: :symlink}} ->
        with {:ok, real} <- resolve_links(child, root),
             true <- real == root or String.starts_with?(real, root <> "/"),
             {:ok, info} <- file_stat(real) do
          {:ok, entry(child, real, info)}
        else
          _ -> {:error, :skipped}
        end

      {:ok, %Elixir.File.Stat{type: type} = info} when type in [:regular, :directory] ->
        {:ok, entry(child, child, info)}

      # Raced away, or a non-regular node (device, fifo, socket) — not served.
      _ ->
        {:error, :skipped}
    end
  end

  defp entry(name_from, version_from, info) do
    sig = signature(info)

    %{
      name: Path.basename(name_from),
      type: if(info.type == :directory, do: :dir, else: :file),
      size: info.size,
      mtime: elem(sig, 0),
      version: version_for(version_from, sig)
    }
  end

  defp walk(dir) do
    case Elixir.File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.flat_map(fn name ->
          child = Path.join(dir, name)

          case Elixir.File.lstat(child) do
            # Symlinks are skipped on the walk — containment already refused
            # anything that points out, and we do not grep through links.
            {:ok, %Elixir.File.Stat{type: :directory}} -> walk(child)
            {:ok, %Elixir.File.Stat{type: :regular}} -> [child]
            _ -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp to_vpath(path, root) do
    case Path.relative_to(path, root) do
      "." -> "/"
      rel -> "/" <> rel
    end
  end

  defp node(ctx, abs, info, mode \\ :derive) do
    opts = config(ctx)
    sig = signature(info)

    %Noizu.MCP.VFS{
      type: if(info.type == :directory, do: :dir, else: :file),
      size: info.size,
      mtime: elem(sig, 0),
      version: version(abs, sig, mode),
      writable: write_access?(info) and not read_only?(ctx),
      executable: :erlang.band(info.mode, 0o111) != 0,
      xattrs: %{mime: mime_type(abs, opts)}
    }
  end

  # Post-write node: the version bumps strictly past anything the path had
  # before (filesystem mtime granularity is coarser than back-to-back writes).
  defp written_node(ctx, abs) do
    with {:ok, info} <- file_stat(abs), do: {:ok, node(ctx, abs, info, :bump)}
  end

  # `File.Stat.mtime` shape varies across Elixir versions — a `DateTime` on
  # older releases, a naive `{{y, m, d}, {h, m, s}}` tuple on newer ones.
  # Normalize both to unix milliseconds (tuple treated as UTC).
  defp signature(info), do: {mtime_ms(info.mtime), info.size}

  defp mtime_ms(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)

  defp mtime_ms({{_, _, _}, {_, _, _}} = erl) do
    erl
    |> NaiveDateTime.from_erl!()
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:millisecond)
  end

  # `Stat.access` is `:read_write`, `:read`, `:write`, or `:none`.
  defp write_access?(%Elixir.File.Stat{access: access}), do: access in [:read_write, :write]

  defp version(abs, sig, :derive), do: version_for(abs, sig)
  defp version(abs, sig, :bump), do: bump_version(abs, sig)

  # Version bookkeeping — a stable integer per {resolved path, signature}.
  # Keyed on the resolved path, so the same file served from two mounts of the
  # same directory shares history while distinct roots stay distinct.
  defp version_for(abs, sig) do
    ensure_versions()

    case :ets.lookup(@vtab, abs) do
      [{^abs, ^sig, version}] ->
        version

      _ ->
        version = derived_version(sig)
        :ets.insert(@vtab, {abs, sig, version})
        version
    end
  end

  defp bump_version(abs, sig) do
    ensure_versions()
    prev = lookup_prev(abs)
    version = max(derived_version(sig), prev + 1)
    :ets.insert(@vtab, {abs, sig, version})
    version
  end

  defp lookup_prev(abs) do
    case :ets.lookup(@vtab, abs) do
      [{^abs, _sig, version}] -> version
      _ -> 0
    end
  end

  defp derived_version(sig), do: :erlang.phash2(sig, 2_147_483_647) + 1

  defp ensure_versions do
    if :ets.whereis(@vtab) == :undefined do
      try do
        :ets.new(@vtab, [:named_table, :set, :public, read_concurrency: true])
      rescue
        # Lost the race — another process created it first.
        ArgumentError -> :ok
      end
    end
  end

  defp unlink(:ok), do: :ok
  defp unlink({:error, reason}), do: {:error, reason}
end
