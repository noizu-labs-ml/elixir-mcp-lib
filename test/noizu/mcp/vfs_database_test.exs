db_url = System.get_env("MCP_OAUTH_TEST_DATABASE_URL")

if db_url do
  defmodule Noizu.MCP.VFS.Database.TestFS do
    @moduledoc false
    # Repo + table travel per-call via `ctx.assigns[:vfs_db]` (the seed sets
    # them), so one backend module serves every isolated scratch table.
    use Noizu.MCP.VFS.Database, repo: nil, table: "mcp_vfs_test_scratch"
  end

  defmodule Noizu.MCP.VFS.Database.ReadOnlyFS do
    @moduledoc false
    use Noizu.MCP.VFS.Database, repo: nil, table: "mcp_vfs_test_scratch", read_only: true
  end

  defmodule Noizu.MCP.VFS.DatabaseTest do
    @moduledoc """
    The raw-SQL VFS backend against the SAME conformance battery as the
    memory fixture (`Noizu.MCP.VFS.Conformance` — no per-backend forks),
    plus the read-only posture and the monotonic-version proof.

    **DB-gated** on `MCP_OAUTH_TEST_DATABASE_URL` (same scratch database as
    the Ecto batteries; the table namespace `mcp_vfs_test_*` is disjoint).
    Every test seeds its own table (async-safe, the way the memory fixture
    uses its own ETS tid), and each seed garbage-collects scratch tables
    left behind by crashed runs older than an hour.
    """

    alias Noizu.MCP.Ctx
    alias Noizu.MCP.VFS.Database.TestFS
    alias Noizu.MCP.VFS.Database.ReadOnlyFS

    # Fully-qualified backend: aliases declared after (or via) `use` are not
    # in scope for the macro's expansion.
    use Noizu.MCP.VFS.Conformance,
      backend: Noizu.MCP.VFS.Database.TestFS,
      seed: {__MODULE__, :conformance_seed}

    # Repo startup only — `drop_lib_tables: false`. This suite is async:true
    # and lives entirely in its own mcp_vfs_test_* tables; the fixture's
    # default drop of every noizu_mcp_% table would fire mid-run against the
    # concurrently-running async:false DB suites (Ecto/Runner/V1Toolsets).
    use Noizu.MCP.Fixtures.PersistenceDB, drop_lib_tables: false

    @table_prefix "mcp_vfs_test_"
    @gc_age_ms :timer.hours(1)

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

    # The battery's seed callback — a fresh isolated table per test.
    def conformance_seed, do: %Ctx{assigns: %{vfs_db: [repo: TestRepo, table: seed_table()]}}

    defp seed_table do
      gc_stale_tables!(TestRepo)

      table = @table_prefix <> Integer.to_string(System.system_time(:millisecond))
      suffix = String.replace_prefix(table, @table_prefix, "")

      TestRepo.query!(Noizu.MCP.VFS.Database.create_table_ddl(table), [])

      TestRepo.query!(
        "CREATE INDEX IF NOT EXISTS idx_mcp_vfs_test_#{suffix}_parent ON #{table} (parent_path)",
        []
      )

      now = System.system_time(:millisecond)

      for {path, content} <- @standard_tree do
        {type, parent_path, data} =
          case content do
            :dir ->
              parent = if path == "/", do: nil, else: parent_of(path)
              {"dir", parent, nil}

            binary when is_binary(binary) ->
              {"file", parent_of(path), binary}
          end

        TestRepo.query!(
          """
          INSERT INTO #{table} (path, parent_path, type, data, writable, version, mtime)
          VALUES ($1, $2, $3, $4, true, 1, $5)
          ON CONFLICT (path) DO NOTHING
          """,
          [path, parent_path, type, data, now]
        )
      end

      table
    end

    # Cleanup on the way IN, not on_exit (the setup process is torn down
    # before on_exit runs in some shapes, and a crashed run must not poison
    # the next one) — but only tables old enough that no concurrent seed
    # could still be using them.
    defp gc_stale_tables!(repo) do
      cutoff = System.system_time(:millisecond) - @gc_age_ms

      %{rows: rows} =
        repo.query!(
          "SELECT table_name FROM information_schema.tables " <>
            "WHERE table_schema = current_schema() AND table_name LIKE '" <> @table_prefix <> "%'",
          []
        )

      for [table] <- rows do
        suffix = String.replace_prefix(table, @table_prefix, "")

        case Integer.parse(suffix) do
          {born_at, ""} when born_at < cutoff -> repo.query!("DROP TABLE IF EXISTS #{table}", [])
          _ -> :ok
        end
      end

      :ok
    end

    defp parent_of(path) do
      case String.split(String.trim_trailing(path, "/"), "/", trim: true) do
        [_only] -> "/"
        parts -> "/" <> Enum.join(Enum.drop(parts, -1), "/")
      end
    end

    # ── backend-specific behavior ─────────────────────────────────────────

    describe "database-specific" do
      test "missing :repo raises (a misconfigured store must fail loudly, D4)", %{ctx: ctx} do
        bare_ctx = %Ctx{assigns: %{}}

        assert_raise ArgumentError, ~r/requires a `:repo` option/, fn ->
          TestFS.stat("/hello.txt", bare_ctx)
        end

        # The seeded ctx carries a repo — sanity-check the control side.
        assert {:ok, _} = TestFS.stat("/hello.txt", ctx)
      end

      test "write bumps version monotonically (real counter, not a race)", %{ctx: ctx} do
        assert {:ok, v1} = TestFS.stat("/hello.txt", ctx)
        assert {:ok, _} = TestFS.write("/hello.txt", "one\n", ctx)
        assert {:ok, _} = TestFS.write("/hello.txt", "two\n", ctx)
        assert {:ok, v3} = TestFS.stat("/hello.txt", ctx)
        assert v3.version == v1.version + 2
      end

      test "empty dirs persist and list as empty", %{ctx: ctx} do
        assert {:ok, _} = TestFS.create("/still-empty", :dir, ctx)
        assert {:ok, node} = TestFS.stat("/still-empty", ctx)
        assert node.type == :dir
        assert {:ok, [], nil} = TestFS.list("/still-empty", nil, ctx)
      end

      test "per-call assigns override the table (isolation between seeds)", %{ctx: battery_ctx} do
        other = seed_table()
        assert {:ok, seeded} = TestFS.stat("/hello.txt", battery_ctx)

        other_ctx = %Ctx{assigns: %{vfs_db: [repo: TestRepo, table: other]}}
        # The standard tree exists in the OTHER table too — independent seeds.
        assert {:ok, node} = TestFS.stat("/hello.txt", other_ctx)
        assert node.type == :file
        assert node.version == seeded.version
      end

      test "read_only posture: writes are :erofs, reads still work", %{ctx: ctx} do
        assert {:ok, node} = ReadOnlyFS.stat("/hello.txt", ctx)
        assert node.type == :file
        assert {:ok, "hello world\n", _} = ReadOnlyFS.read("/hello.txt", ctx)

        assert {:error, :erofs} = ReadOnlyFS.write("/hello.txt", "nope\n", ctx)
        assert {:error, :erofs} = ReadOnlyFS.create("/new.txt", "nope\n", ctx)
        assert {:error, :erofs} = ReadOnlyFS.remove("/hello.txt", ctx)
      end

      test "a dropped table degrades to :eio, not a crash" do
        # Points at a table that does not exist — the query fails, the
        # backend logs and maps the failure to :eio (an errno, never an
        # exception through the behaviour boundary).
        ghost = %Ctx{assigns: %{vfs_db: [repo: TestRepo, table: "mcp_vfs_test_does_not_exist"]}}
        assert {:error, :eio} = TestFS.stat("/hello.txt", ghost)
      end
    end
  end
else
  defmodule Noizu.MCP.VFS.Database.SkippedTest do
    @moduledoc false

    use ExUnit.Case, async: true

    test "VFS Database suite skipped without MCP_OAUTH_TEST_DATABASE_URL", do: :ok
  end
end
