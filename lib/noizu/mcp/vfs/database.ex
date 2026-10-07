if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Noizu.MCP.VFS.Database do
    @moduledoc """
    Postgres-backed VFS backend over **raw SQL** — no Ecto schemas, no
    migrations module. Same philosophy as `Noizu.MCP.Persistence.Ecto` and
    `Noizu.MCP.Auth.Server.Store.Ecto`: parameterized SQL through
    `Ecto.Adapters.SQL.query/4` and nothing else. The DDL ships as a
    Liquibase changelog template (`priv/liquibase/noizu_mcp_vfs.yaml`) that
    hosts copy into their own changelog directory and apply, mirroring how
    the lib-owned tables work today.

        defmodule MyApp.MCP.FS do
          use Noizu.MCP.VFS.Database,
            repo: MyApp.Repo,
            table: "noizu_mcp_vfs_nodes"   # the default
        end

    Apply the changelog BEFORE mounting:

        liquibase --changelog-file noizu_mcp_vfs.yaml update

    The generated module is a complete `Noizu.MCP.VFS` backend: `stat/2`,
    `list/3`, `read/2` plus `write/3`, `create/3`, `remove/2`, and
    `search/3` (line grep over file content). `xattr/2` keeps the behaviour
    default (`{:ok, %{}}`).

    ## Table layout

    Files are rows with `data` BYTEA content; directories are explicit rows
    (so empty dirs persist). `parent_path` is maintained on create and backs
    the list index. `version` is a real monotonic counter (`version + 1` in
    the UPDATE — CAS-grade monotonic, unlike an mtime), bumped on every
    write. Timestamps follow the lib convention: `created_at`/`updated_at`,
    never `modified_at`. The root `/` is an explicit row — insert it after
    applying the changelog:

        INSERT INTO noizu_mcp_vfs_nodes (path, parent_path, type)
        VALUES ('/', NULL, 'dir')
        ON CONFLICT (path) DO NOTHING;

    ## Options (`use`)

      * `:repo` (required at call time) — an `Ecto.Repo`. A backend used
        without one RAISES: a misconfigured store must fail loudly, never
        silently lose records (same posture as `Persistence.Ecto`).
      * `:table` — default `"noizu_mcp_vfs_nodes"`.
      * `:prefix` — optional SQL schema prefix (`"my_schema"` →
        `"my_schema"."noizu_mcp_vfs_nodes"`).
      * `:read_only` — default `false`. `true` turns `write/3`, `create/3`,
        and `remove/2` into `{:error, :erofs}` before any SQL runs.

    Any of these can be overridden per call through `ctx.assigns[:vfs_db]`
    (a keyword list) — how the test suite points many isolated tables at one
    repo without one backend module per table.
    """

    require Logger

    alias Noizu.MCP.Server.Features.Pagination
    alias Noizu.MCP.VFS

    @default_table "noizu_mcp_vfs_nodes"

    @columns ~w(path parent_path type data mime writable version mtime created_at updated_at)

    @doc "The column list the backend speaks — what the Liquibase template must match."
    def columns, do: @columns

    @doc false
    def default_table, do: @default_table

    # The `IF NOT EXISTS` guards make re-runs idempotent (hand-run psql, a
    # crashed half-apply) — same posture as `Migrations.V1Toolsets`. The
    # conformance suite reuses this DDL for its per-test scratch tables so
    # the tested shape is the shipped shape.
    @doc false
    def create_table_ddl(table) do
      """
      CREATE TABLE IF NOT EXISTS #{table} (
        path text PRIMARY KEY,
        parent_path text,
        type varchar(8) NOT NULL CHECK (type IN ('file','dir')),
        data bytea,
        mime text,
        writable boolean NOT NULL DEFAULT true,
        version bigint NOT NULL DEFAULT 1,
        mtime bigint NOT NULL DEFAULT 0,
        created_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now()
      )
      """
    end

    defmacro __using__(opts) do
      repo = Keyword.get(opts, :repo)
      table = Keyword.get(opts, :table, @default_table)
      prefix = Keyword.get(opts, :prefix)
      read_only = Keyword.get(opts, :read_only, false)

      quote do
        use Noizu.MCP.VFS

        @doc false
        def __mcp_vfs_database__ do
          [
            repo: unquote(repo),
            table: unquote(table),
            prefix: unquote(prefix),
            read_only: unquote(read_only)
          ]
        end

        @impl true
        def stat(path, ctx),
          do: Noizu.MCP.VFS.Database.stat(__mcp_vfs_database__(), path, ctx)

        @impl true
        def list(path, cursor, ctx),
          do: Noizu.MCP.VFS.Database.list(__mcp_vfs_database__(), path, cursor, ctx)

        @impl true
        def read(path, ctx),
          do: Noizu.MCP.VFS.Database.read(__mcp_vfs_database__(), path, ctx)

        @impl true
        def write(path, data, ctx),
          do: Noizu.MCP.VFS.Database.write(__mcp_vfs_database__(), path, data, ctx)

        @impl true
        def create(path, data, ctx),
          do: Noizu.MCP.VFS.Database.create(__mcp_vfs_database__(), path, data, ctx)

        @impl true
        def remove(path, ctx),
          do: Noizu.MCP.VFS.Database.remove(__mcp_vfs_database__(), path, ctx)

        @impl true
        def search(root, query, ctx),
          do: Noizu.MCP.VFS.Database.search(__mcp_vfs_database__(), root, query, ctx)

        @doc false
        def __mcp_vfs__(:describe) do
          "Postgres-backed VFS — the `#{unquote(table)}` table (Noizu.MCP.VFS.Database)."
        end
      end
    end

    # ── stat ──────────────────────────────────────────────────────────────────

    def stat(base, path, ctx) do
      conf = conf(base, ctx)

      sql = """
      SELECT type, octet_length(data), writable, version, mtime
      FROM #{qualified(conf)} WHERE path = $1
      """

      run(conf, fn repo ->
        case query(repo, sql, [path]) do
               {:ok, %{rows: [[type, size, writable, version, mtime]]}} ->
                 {:ok,
                  %VFS{
                    type: String.to_existing_atom(type),
                    size: size || 0,
                    mtime: mtime || 0,
                    version: version,
                    writable: writable,
                    xattrs: %{}
                  }}

               {:ok, %{rows: []}} ->
                 {:error, :enoent}

               {:error, _} = error ->
                 error
             end
      end)
    end

    # ── list ──────────────────────────────────────────────────────────────────

    def list(base, path, cursor, ctx) do
      conf = conf(base, ctx)

      run(conf, fn repo ->
        # The directory check is its own round trip: `:enotdir` vs `:enoent`
        # cannot fall out of the children query alone.
        case query(repo, "SELECT type FROM #{qualified(conf)} WHERE path = $1", [path]) do
          {:ok, %{rows: [["dir"]]}} ->
            sql = """
            SELECT path, type, octet_length(data), version, mtime
            FROM #{qualified(conf)} WHERE parent_path = $1 ORDER BY path
            """

            with {:ok, %{rows: rows}} <- query(repo, sql, [path]) do
              entries =
                Enum.map(rows, fn [child, type, size, version, mtime] ->
                  %{
                    name: Path.basename(child),
                    type: String.to_existing_atom(type),
                    size: size || 0,
                    mtime: mtime || 0,
                    version: version
                  }
                end)

              Pagination.paginate(entries, cursor)
            end

          {:ok, %{rows: []}} ->
            {:error, :enoent}

          {:ok, %{rows: [_file]}} ->
            {:error, :enotdir}

          {:error, _} = error ->
            error
        end
      end)
    end

    # ── read ──────────────────────────────────────────────────────────────────

    def read(base, path, ctx) do
      conf = conf(base, ctx)

      sql = "SELECT type, data, version FROM #{qualified(conf)} WHERE path = $1"

      run(conf, fn repo ->
        case query(repo, sql, [path]) do
          {:ok, %{rows: [["file", data, version]]}} -> {:ok, data || "", version}
          {:ok, %{rows: [["dir" | _]]}} -> {:error, :eisdir}
          {:ok, %{rows: []}} -> {:error, :enoent}
          {:error, _} = error -> error
        end
      end)
    end

    # ── write ─────────────────────────────────────────────────────────────────

    def write(base, path, data, ctx) when is_binary(data) do
      conf = conf(base, ctx)

      if conf[:read_only] do
        {:error, :erofs}
      else
        run(conf, fn repo ->
          # version + 1 in the UPDATE — a real monotonic counter, not a
          # read-modify-write race.
          sql = """
          UPDATE #{qualified(conf)}
          SET data = $2, version = version + 1, mtime = $3, updated_at = now()
          WHERE path = $1 AND type = 'file'
          RETURNING version, octet_length(data), writable
          """

          case query(repo, sql, [path, data, now_ms()]) do
            {:ok, %{rows: [[version, size, writable]]}} ->
              {:ok,
               %VFS{
                 type: :file,
                 size: size,
                 mtime: now_ms(),
                 version: version,
                 writable: writable,
                 xattrs: %{}
               }}

            {:ok, %{rows: []}} ->
              case query(repo, "SELECT type FROM #{qualified(conf)} WHERE path = $1", [path]) do
                {:ok, %{rows: [["dir"]]}} -> {:error, :eisdir}
                _ -> {:error, :enoent}
              end

            {:error, _} = error ->
              error
          end
        end)
      end
    end

    # ── create ────────────────────────────────────────────────────────────────

    def create(base, path, data, ctx) do
      conf = conf(base, ctx)

      cond do
        conf[:read_only] ->
          {:error, :erofs}

        path == "/" ->
          {:error, :eacces}

        not (is_binary(data) or data == :dir) ->
          {:error, {:bad_data, data}}

        true ->
          run(conf, fn repo -> do_create(conf, repo, path, data) end)
      end
    end

    defp do_create(conf, repo, path, data) do
      parent_path = parent(path)

      with {:ok, %{rows: parent_rows}} <-
             query(repo, "SELECT type FROM #{qualified(conf)} WHERE path = $1", [parent_path]) do
        case parent_rows do
          [["dir"]] ->
            {type, mime} =
              case data do
                :dir -> {"dir", nil}
                binary when is_binary(binary) -> {"file", nil}
              end

            insert =
              """
              INSERT INTO #{qualified(conf)}
                (path, parent_path, type, data, mime, writable, version, mtime)
              VALUES ($1, $2, $3, $4, $5, true, 1, $6)
              ON CONFLICT (path) DO NOTHING
              RETURNING version, writable
              """

            case query(repo, insert, [path, parent_path, type, file_data(data), mime, now_ms()]) do
              {:ok, %{rows: [[version, writable]]}} ->
                {:ok,
                 %VFS{
                   type: String.to_existing_atom(type),
                   size: data_size(data),
                   mtime: now_ms(),
                   version: version,
                   writable: writable,
                   xattrs: %{}
                 }}

              # ON CONFLICT swallowed the insert — the path was taken between
              # the parent check and now.
              {:ok, %{rows: []}} ->
                {:error, :eexist}

              {:error, _} = error ->
                error
            end

          # A parent that is a file, and a missing parent, are both :enoent —
          # same as the Memory fixture (no :enotdir fork in the create path).
          _ ->
            {:error, :enoent}
        end
      end
    end

    defp file_data(:dir), do: nil
    defp file_data(binary) when is_binary(binary), do: binary

    defp data_size(:dir), do: 0
    defp data_size(binary) when is_binary(binary), do: byte_size(binary)

    # ── remove ────────────────────────────────────────────────────────────────

    def remove(base, path, ctx) do
      conf = conf(base, ctx)

      cond do
        conf[:read_only] ->
          {:error, :erofs}

        path == "/" ->
          {:error, :eacces}

        true ->
          run(conf, fn repo ->
            with {:ok, %{rows: children}} <-
                   query(repo, "SELECT 1 FROM #{qualified(conf)} WHERE parent_path = $1 LIMIT 1", [
                     path
                   ]) do
              if children != [] do
                {:error, :enotempty}
              else
                case query(repo, "DELETE FROM #{qualified(conf)} WHERE path = $1", [path]) do
                  {:ok, %{num_rows: 1}} -> :ok
                  {:ok, %{num_rows: 0}} -> {:error, :enoent}
                  {:error, _} = error -> error
                end
              end
            end
          end)
      end
    end

    # ── search ────────────────────────────────────────────────────────────────

    def search(base, root, query_text, ctx) do
      conf = conf(base, ctx)
      prefix = if String.ends_with?(root, "/"), do: root, else: root <> "/"

      sql = """
      SELECT path, data FROM #{qualified(conf)}
      WHERE type = 'file' AND (path = $1 OR path LIKE $2 ESCAPE '\\')
      ORDER BY path
      """

      run(conf, fn repo ->
        with {:ok, %{rows: rows}} <- query(repo, sql, [root, escape_like(prefix) <> "%"]) do
          matches =
            rows
            |> Enum.flat_map(fn [path, data] ->
              content = data || ""

              content
              |> String.split("\n")
              |> Enum.with_index(1)
              |> Enum.filter(fn {text, _line} -> String.contains?(text, query_text) end)
              |> Enum.map(fn {text, line} -> %{path: path, line: line, text: text} end)
            end)

          {:ok, matches, nil}
        end
      end)
    end

    # ── internals ─────────────────────────────────────────────────────────────

    # Per-call overrides — `ctx.assigns[:vfs_db]` (keyword) merges over the
    # compile-time `use` options. This is how one backend module serves many
    # isolated tables (the conformance suite) without module-per-table.
    defp conf(base, ctx) do
      case ctx do
        %{assigns: %{vfs_db: overrides}} when is_list(overrides) -> Keyword.merge(base, overrides)
        _ -> base
      end
    end

    defp qualified(conf) do
      case conf[:prefix] do
        prefix when is_binary(prefix) and prefix != "" -> ~s("#{prefix}".#{conf[:table]})
        _ -> conf[:table]
      end
    end

    # D4: a missing `:repo` RAISES — misconfiguration must fail loudly.
    defp run(conf, fun) do
      case conf[:repo] do
        repo when is_atom(repo) and repo != nil -> fun.(repo)
        _ -> raise ArgumentError, "Noizu.MCP.VFS.Database requires a `:repo` option"
      end
    end

    # Unexpected DB failures degrade to `:eio` (mapped by the M2 transport)
    # and log — they are never silently swallowed, never crash the caller.
    defp query(repo, sql, params) do
      case Ecto.Adapters.SQL.query(repo, sql, params) do
        {:ok, result} ->
          {:ok, result}

        {:error, exception} ->
          Logger.warning("VFS.Database: query failed: #{Exception.message(exception)}")
          {:error, :eio}
      end
    end

    defp now_ms, do: System.system_time(:millisecond)

    defp escape_like(text), do: String.replace(text, ~r/[\\%_]/, &"\\#{&1}")

    defp parent("/"), do: nil

    defp parent(path) do
      case String.split(String.trim_trailing(path, "/"), "/", trim: true) do
        [_only] -> "/"
        parts -> "/" <> Enum.join(Enum.drop(parts, -1), "/")
      end
    end
  end
end
