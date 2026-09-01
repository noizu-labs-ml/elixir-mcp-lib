if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Noizu.MCP.Migration.Runner do
    @moduledoc """
    The host migration entry (PRD-4 §4.6, Oban shape): apply/revert the lib
    (or host-extended) change sets transactionally against a Postgres repo,
    tracking applied sets in the lib-owned `noizu_mcp_schema_versions` ledger.

        def up,   do: Noizu.MCP.Migration.Runner.up(MyApp.Repo, Noizu.MCP.Migrations, to: :latest)
        def down, do: Noizu.MCP.Migration.Runner.down(MyApp.Repo, Noizu.MCP.Migrations, to: 0)

    ## Semantics (normative)

    * The ledger is created on demand BEFORE anything applies (bootstrap-first
      ordering — `Migrations.V1Toolsets` never references it in its own DDL).
    * Each set applies in its own Postgres transaction (`BEGIN` … `COMMIT` on
      a checked-out connection): a set whose SQL raises — or whose thunk
      returns `{:error, reason}` — rolls back WHOLE (no partial set ever
      survives) and fails the run with `{:error, {name, reason}}`; already-
      applied earlier sets stay applied.
    * `up/3` applies pending sets in ascending version order up to `to:`
      (default `:latest`); re-runs are no-ops for applied sets. `down/3`
      reverts applied sets in DESCENDING version order down to `to:` — a set
      without a `down` thunk in the revert path is `{:error, {:no_down, name}}`.
    * Out-of-order `to:` guards are honored literally: `up(to: 0)` applies
      nothing; `down(to: :latest)` reverts nothing above the latest.
    """

    alias Noizu.MCP.Migrations.ChangeSet

    @versions_table "noizu_mcp_schema_versions"

    @type applied :: %{name: String.t(), version: integer(), applied_at: DateTime.t()}
    @type state :: %{name: String.t(), version: integer(), state: :applied | :pending}

    # ── up / down ─────────────────────────────────────────────────────────────

    @doc "Apply pending sets in order up to `to:` (default `:latest`)."
    # ⟦𓎼𓊪⟧ up :: Apply pending sets in order up to `to:` (default `:latest`).
    @spec up(module(), module(), keyword()) ::
            {:ok, [%{name: String.t(), version: integer()}]} | {:error, term()}
    def up(repo, migrations, opts \\ []) do
      with {:ok, _} <- ensure_versions_table(repo) do
        target = Keyword.get(opts, :to, :latest)
        applied = MapSet.new(applied_names(repo))

        migrations.change_sets()
        |> sort_sets()
        |> Enum.filter(fn %ChangeSet{version: version, name: name} ->
          not MapSet.member?(applied, name) and within_target?(version, target)
        end)
        |> Enum.reduce_while({:ok, []}, fn set, {:ok, acc} ->
          case apply_set(repo, set, :up) do
            :ok -> {:cont, {:ok, [%{name: set.name, version: set.version} | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, applied_now} -> {:ok, Enum.reverse(applied_now)}
          error -> error
        end
      end
    end

    @doc "Revert applied sets in reverse order down to `to:` (required)."
    # ⟦𓂧𓍯𓍢𓈖⟧ down :: Revert applied sets in reverse order down to `to:` (required).
    @spec down(module(), module(), keyword()) ::
            {:ok, [%{name: String.t(), version: integer()}]} | {:error, term()}
    def down(repo, migrations, opts) do
      with {:ok, _} <- ensure_versions_table(repo) do
        target = Keyword.fetch!(opts, :to)
        ledger = applied_versions(repo)

        migrations.change_sets()
        |> sort_sets()
        |> Enum.reverse()
        |> Enum.filter(fn %ChangeSet{version: version, name: name} ->
          version > target and Map.has_key?(ledger, name)
        end)
        |> Enum.reduce_while({:ok, []}, fn set, {:ok, acc} ->
          case apply_set(repo, set, :down) do
            :ok -> {:cont, {:ok, [%{name: set.name, version: set.version} | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, reverted} -> {:ok, Enum.reverse(reverted)}
          error -> error
        end
      end
    end

    # ── introspection ─────────────────────────────────────────────────────────

    @doc "The ledger rows: `{:ok, [%{name, version, applied_at}]}` ordered by version."
    # ⟦𓄿𓊪𓊪𓃭𓇋𓅂𓂧⟧ applied :: The ledger rows.
    @spec applied(module()) :: {:ok, [applied()]} | {:error, term()}
    def applied(repo) do
      with {:ok, _} <- ensure_versions_table(repo) do
        case query(
               repo,
               "SELECT name, version, applied_at FROM #{@versions_table} ORDER BY version",
               []
             ) do
          {:ok, %{rows: rows}} ->
            {:ok,
             Enum.map(rows, fn [name, version, applied_at] ->
               %{name: name, version: version, applied_at: applied_at}
             end)}

          {:error, _} = error ->
            error
        end
      end
    end

    @doc "Per-set `:applied | :pending` state for `migrations`."
    # ⟦𓋴𓏏𓄿𓏏𓎲𓋴⟧ status :: Per-set `:applied | :pending` state for `migrations`.
    @spec status(module(), module()) :: {:ok, [state()]} | {:error, term()}
    def status(repo, migrations) do
      with {:ok, _} <- ensure_versions_table(repo) do
        applied = MapSet.new(applied_names(repo))

        states =
          migrations.change_sets()
          |> sort_sets()
          |> Enum.map(fn %ChangeSet{name: name, version: version} ->
            %{name: name, version: version, state: state_for(applied, name)}
          end)

        {:ok, states}
      end
    end

    defp state_for(applied, name) do
      if MapSet.member?(applied, name), do: :applied, else: :pending
    end

    # ── internals ─────────────────────────────────────────────────────────────

    defp sort_sets(sets), do: Enum.sort_by(sets, & &1.version)

    defp within_target?(_version, :latest), do: true
    defp within_target?(version, target) when is_integer(target), do: version <= target

    # One set = one `repo.transaction`. Thunks run raw SQL through
    # `repo.query!/2` — inside the transaction every query from this process
    # rides the transaction's connection, so the DDL commits or rolls back
    # WHOLE. A raising thunk (SQL error path) aborts the transaction the same
    # way — Ecto rolls back before the exception escapes.
    defp apply_set(repo, %ChangeSet{} = set, direction) do
      result =
        repo.transaction(fn ->
          thunk = if direction == :up, do: set.up, else: set.down

          case run_thunk(thunk, repo) do
            :ok ->
              case direction do
                :up -> record(repo, set)
                :down -> unrecord(repo, set)
              end

              :ok

            {:error, reason} ->
              repo.rollback({set.name, reason})
          end
        end)

      case result do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    rescue
      e -> {:error, {set.name, Exception.message(e)}}
    end

    # A thunk returns `:ok` / `{:ok, _}` (proceeds) or `{:error, reason}`
    # (rollback). Raising thunks are the SQL-error path (query!/2); the rescue
    # above rolls those back too.
    defp run_thunk(nil, _repo), do: {:error, :no_down}

    defp run_thunk(thunk, repo) do
      case thunk.(repo, []) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, {:bad_thunk_result, other}}
      end
    end

    defp ensure_versions_table(repo) do
      case query(repo, versions_ddl(), []) do
        {:ok, _} -> {:ok, @versions_table}
        {:error, _} = error -> error
      end
    end

    defp versions_ddl do
      """
      create table if not exists #{@versions_table} (
        name text primary key,
        version integer not null,
        applied_at timestamptz not null default now()
      )
      """
    end

    defp applied_names(repo) do
      case query(repo, "SELECT name FROM #{@versions_table}", []) do
        {:ok, %{rows: rows}} -> Enum.map(rows, &hd/1)
        {:error, _} -> []
      end
    end

    defp applied_versions(repo) do
      case query(repo, "SELECT name, version FROM #{@versions_table}", []) do
        {:ok, %{rows: rows}} -> Map.new(rows, fn [name, version] -> {name, version} end)
        {:error, _} -> %{}
      end
    end

    defp record(repo, %ChangeSet{name: name, version: version}) do
      {:ok, _} =
        query(
          repo,
          "INSERT INTO #{@versions_table} (name, version) VALUES ($1, $2) " <>
            "ON CONFLICT (name) DO UPDATE SET version = EXCLUDED.version, applied_at = now()",
          [name, version]
        )

      :ok
    end

    defp unrecord(repo, %ChangeSet{name: name}) do
      {:ok, _} = query(repo, "DELETE FROM #{@versions_table} WHERE name = $1", [name])
      :ok
    end

    # repo (module) or checked-out conn — Ecto.Adapters.SQL.query/4 accepts both.
    defp query(repo_or_conn, sql, params) do
      Ecto.Adapters.SQL.query(repo_or_conn, sql, params)
    end
  end
end
