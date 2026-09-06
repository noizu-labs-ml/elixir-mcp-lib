if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Noizu.MCP.Persistence.Ecto do
    @moduledoc """
    Postgres `Noizu.MCP.Persistence` provider over the lib-owned tables
    (PRD-4 §4.2), in **raw SQL**:

        use Noizu.MCP.Server, persistence: {Noizu.MCP.Persistence.Ecto, repo: MyApp.Repo}

    ## No Ecto schemas, deliberately

    Same philosophy as the auth-server store adapter: a schema is a claim
    about a table the host owns, and the library owning schemas would couple
    every host's repo to one shape. What ships instead is
    `Noizu.MCP.Migrations.V1Toolsets` (Oban-style — one host migration file
    delegates to `Noizu.MCP.Migration.Runner`) and this adapter speaking
    parameterized SQL through `Ecto.Adapters.SQL.query/4` and nothing else.

    ## Boot gate (D4 — config errors must not boot)

    `ping/1` verifies `noizu_mcp_schema_versions` and the three store tables
    exist (information_schema). Absent tables ⇒
    `{:error, {:tables_missing, names}}`, and the supervisor's boot child
    turns that into a failed boot. Run `Migration.Runner.up/3` BEFORE booting
    an Ecto-backed server — after `Runner.up`, boot succeeds (AC-4.8, both
    ways proven in the suite).

    ## The shared codec

    Storage mechanics differ from `Memory` (structured columns instead of one
    JSON blob) but the record semantics — validation, normalization, expiry,
    filtering, struct revival — are the SAME shared pipeline on
    `Noizu.MCP.Persistence` (AP-8). The conformance battery over this adapter
    is the proof.

    ## Options

      * `:repo` (required) — an `Ecto.Repo`. Missing/invalid `:repo` RAISES:
        a misconfigured store must fail loudly, never silently lose records.
    """

    @behaviour Noizu.MCP.Persistence

    alias Noizu.MCP.Persistence

    require Logger

    @toolsets_table "noizu_mcp_toolsets"
    @grants_table "noizu_mcp_toolset_grants"
    @negotiations_table "noizu_mcp_toolset_negotiations"
    @engine_servers_table "noizu_mcp_engine_servers"
    @versions_table "noizu_mcp_store_versions"
    @ledger_table "noizu_mcp_schema_versions"

    @required_tables [@ledger_table, @toolsets_table, @grants_table, @negotiations_table]

    # ── put ───────────────────────────────────────────────────────────────────

    @impl true
    def put(store_key, id, record, opts) when is_binary(id) do
      repo = fetch_repo!(opts)

      with :ok <- Persistence.guard_store_key(store_key),
           {:ok, _json, fields, _meta} <- Persistence.encode_record(store_key, record) do
        {sql, params} =
          case store_key do
            "toolsets" ->
              {toolset_upsert(), put_params("toolsets", id, fields)}

            "toolset_grants" ->
              {grant_upsert(), put_params("toolset_grants", id, fields)}

            "toolset_negotiations" ->
              {negotiation_upsert(), put_params("toolset_negotiations", id, fields)}

            "engine_servers" ->
              {engine_server_upsert(), put_params("engine_servers", id, fields)}
          end

        case query(repo, sql, params) do
          {:ok, _} ->
            bump_version(repo, store_key)
            :ok

          {:error, _} = error ->
            error
        end
      end
    end

    def put(_store_key, _id, _record, _opts), do: {:error, {:invalid_id, "id must be a string"}}

    defp toolset_upsert do
      """
      INSERT INTO #{@toolsets_table}
        (slug, title, description, base, immutable, include, exclude, tools, metadata,
         inserted_at, updated_at)
      VALUES ($1,$2,$3,$4,$5,$6::jsonb,$7::jsonb,$8::jsonb,$9::jsonb,$10,now())
      ON CONFLICT (slug) DO UPDATE SET
        title = EXCLUDED.title, description = EXCLUDED.description, base = EXCLUDED.base,
        immutable = EXCLUDED.immutable, include = EXCLUDED.include, exclude = EXCLUDED.exclude,
        tools = EXCLUDED.tools, metadata = EXCLUDED.metadata, updated_at = now()
      """
    end

    defp grant_upsert do
      """
      INSERT INTO #{@grants_table}
        (id, toolset_slug, authenticator, subject, effect, scopes, tool_overrides,
         expires_at, metadata, inserted_at)
      VALUES ($1,$2,$3,$4,$5,$6::jsonb,$7::jsonb,$8,$9::jsonb,$10)
      ON CONFLICT (id) DO UPDATE SET
        toolset_slug = EXCLUDED.toolset_slug, authenticator = EXCLUDED.authenticator,
        subject = EXCLUDED.subject, effect = EXCLUDED.effect, scopes = EXCLUDED.scopes,
        tool_overrides = EXCLUDED.tool_overrides, expires_at = EXCLUDED.expires_at,
        metadata = EXCLUDED.metadata, inserted_at = EXCLUDED.inserted_at
      """
    end

    defp negotiation_upsert do
      """
      INSERT INTO #{@negotiations_table}
        (id, toolset_slug, authenticator, tool, required_scopes, granted,
         metadata_overrides, expires_at, metadata, inserted_at)
      VALUES ($1,$2,$3,$4,$5::jsonb,$6,$7::jsonb,$8,$9::jsonb,$10)
      ON CONFLICT (id) DO UPDATE SET
        toolset_slug = EXCLUDED.toolset_slug, authenticator = EXCLUDED.authenticator,
        tool = EXCLUDED.tool, required_scopes = EXCLUDED.required_scopes,
        granted = EXCLUDED.granted, metadata_overrides = EXCLUDED.metadata_overrides,
        expires_at = EXCLUDED.expires_at, metadata = EXCLUDED.metadata,
        inserted_at = EXCLUDED.inserted_at
      """
    end

    defp engine_server_upsert do
      """
      INSERT INTO #{@engine_servers_table}
        (name, transport, command, url, auth_ref, enabled, inserted_at, updated_at)
      VALUES ($1,$2,$3,$4,$5,$6,$7,now())
      ON CONFLICT (name) DO UPDATE SET
        transport = EXCLUDED.transport, command = EXCLUDED.command,
        url = EXCLUDED.url, auth_ref = EXCLUDED.auth_ref,
        enabled = EXCLUDED.enabled, updated_at = now()
      """
    end

    # jsonb/text columns bind as Jason strings + `::jsonb` casts; datetimes
    # bind natively. Params line up 1:1 with the upsert column lists.
    defp put_params(store_key, id, f) do
      case store_key do
        "toolsets" ->
          [
            id,
            f.title,
            f.description,
            f.base,
            f.immutable,
            j(f.include),
            j(f.exclude),
            j(f.tools),
            j(f.metadata),
            f.inserted_at
          ]

        "toolset_grants" ->
          # effect stores as its string form (text column + check constraint).
          [
            id,
            f.toolset_slug,
            f.authenticator,
            f.subject,
            Atom.to_string(f.effect),
            j(f.scopes),
            j(f.tool_overrides),
            f.expires_at,
            j(f.metadata),
            f.inserted_at
          ]

        "toolset_negotiations" ->
          [
            id,
            f.toolset_slug,
            f.authenticator,
            f.tool,
            j(f.required_scopes),
            f.granted,
            j(f.metadata_overrides),
            f.expires_at,
            j(f.metadata),
            f.inserted_at
          ]

        "engine_servers" ->
          # The primary key IS the name — the id argument carries it.
          [f.name, f.transport, f.command, f.url, f.auth_ref, f.enabled, f.inserted_at]
      end
    end

    defp j(term), do: Jason.encode!(term)

    # ── get ───────────────────────────────────────────────────────────────────

    @impl true
    def get(store_key, id, opts) when is_binary(id) do
      repo = fetch_repo!(opts)

      with :ok <- Persistence.guard_store_key(store_key) do
        table = table_for(store_key)

        # Expiry is a store invariant for the grant/negotiation stores; the
        # toolsets and engine_servers tables have no expires_at column
        # (records outlive callers).
        {id_column, expiry} =
          case store_key do
            "toolsets" -> {"slug", ""}
            "engine_servers" -> {"name", ""}
            _other -> {"id", " AND (expires_at IS NULL OR expires_at > $2)"}
          end

        sql = "SELECT #{select_cols(store_key)} FROM #{table} WHERE #{id_column} = $1#{expiry}"

        params =
          case store_key do
            key when key in ["toolsets", "engine_servers"] -> [id]
            _other -> [id, DateTime.utc_now()]
          end

        case query(repo, sql, params) do
          {:ok, %{rows: [row]}} -> revive_row(store_key, row)
          {:ok, %{rows: []}} -> :error
          {:error, _} = error -> error
        end
      end
    end

    def get(_store_key, _id, _opts), do: {:error, {:invalid_id, "id must be a string"}}

    # ── list ──────────────────────────────────────────────────────────────────

    @impl true
    def list(store_key, filter, opts) do
      repo = fetch_repo!(opts)

      with :ok <- Persistence.guard_store_key(store_key) do
        filter = filter || %{}
        at = Map.get(filter, :at) || DateTime.utc_now()

        expiry =
          case store_key do
            key when key in ["toolsets", "engine_servers"] -> ""
            _other -> "WHERE (expires_at IS NULL OR expires_at > $1)\n"
          end

        sql = """
        SELECT #{select_cols(store_key)} FROM #{table_for(store_key)}
        #{expiry}ORDER BY inserted_at DESC
        """

        params = if expiry == "", do: [], else: [at]

        with {:ok, %{rows: rows}} <- query(repo, sql, params) do
          records =
            rows
            |> Enum.flat_map(fn row ->
              case revive_row(store_key, row) do
                {:ok, record} ->
                  [record]

                {:error, reason} ->
                  # A corrupted row degrades ITSELF, not the store (D5) —
                  # same posture as Memory.
                  Logger.warning("Ecto persistence: dropping unreadable row: #{inspect(reason)}")
                  []
              end
            end)
            |> Enum.filter(&Persistence.match_filter?(&1, filter))

          {:ok, records}
        end
      end
    end

    # ── delete ────────────────────────────────────────────────────────────────

    @impl true
    def delete(store_key, id, opts) when is_binary(id) do
      repo = fetch_repo!(opts)

      with :ok <- Persistence.guard_store_key(store_key) do
        id_column =
          case store_key do
            "toolsets" -> "slug"
            "engine_servers" -> "name"
            _other -> "id"
          end

        case query(repo, "DELETE FROM #{table_for(store_key)} WHERE #{id_column} = $1", [id]) do
          {:ok, _} ->
            bump_version(repo, store_key)
            :ok

          {:error, _} = error ->
            error
        end
      end
    end

    def delete(_store_key, _id, _opts), do: {:error, {:invalid_id, "id must be a string"}}

    # ── version ───────────────────────────────────────────────────────────────

    @impl true
    def version(store_key, opts) do
      repo = fetch_repo!(opts)

      with :ok <- Persistence.guard_store_key(store_key) do
        sql = "SELECT version FROM #{@versions_table} WHERE store_key = $1"

        case query(repo, sql, [store_key]) do
          {:ok, %{rows: [[n]]}} when is_integer(n) -> {:ok, Integer.to_string(n)}
          {:ok, %{rows: []}} -> {:ok, "0"}
          {:error, _} = error -> error
        end
      end
    end

    defp bump_version(repo, store_key) do
      sql = """
      INSERT INTO #{@versions_table} (store_key, version, bumped_at)
      VALUES ($1, 1, now())
      ON CONFLICT (store_key)
      DO UPDATE SET version = #{@versions_table}.version + 1, bumped_at = now()
      RETURNING version
      """

      case query(repo, sql, [store_key]) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    end

    # ── ping (D4 boot gate) ───────────────────────────────────────────────────

    @impl true
    def ping(opts) do
      repo = fetch_repo!(opts)

      sql = """
      SELECT table_name FROM information_schema.tables
      WHERE table_schema = current_schema() AND table_name = ANY($1)
      """

      case query(repo, sql, [@required_tables]) do
        {:ok, %{rows: rows}} ->
          present = MapSet.new(rows, &hd/1)
          missing = Enum.reject(@required_tables, &MapSet.member?(present, &1))

          if missing == [] do
            :ok
          else
            {:error, {:tables_missing, missing}}
          end

        {:error, _} = error ->
          error
      end
    end

    # ── internals ─────────────────────────────────────────────────────────────

    defp table_for("toolsets"), do: @toolsets_table
    defp table_for("toolset_grants"), do: @grants_table
    defp table_for("toolset_negotiations"), do: @negotiations_table
    defp table_for("engine_servers"), do: @engine_servers_table

    # Column list per store — the revive step consumes these back into the
    # lib structs through the shared pipeline. (The toolsets table's primary
    # key is `slug` — there is no separate id column.)
    defp select_cols("toolsets") do
      "slug, title, description, base, immutable, include, exclude, tools, metadata, inserted_at"
    end

    defp select_cols("toolset_grants") do
      "id, toolset_slug, authenticator, subject, effect, scopes, tool_overrides, expires_at, inserted_at, metadata"
    end

    defp select_cols("toolset_negotiations") do
      "id, toolset_slug, authenticator, tool, required_scopes, granted, metadata_overrides, expires_at, inserted_at, metadata"
    end

    defp select_cols("engine_servers") do
      "name, transport, command, url, auth_ref, enabled"
    end

    # Rebuild the string-keyed raw payload from the row and revive through the
    # shared pipeline. jsonb columns arrive DECODED when postgrex runs with a
    # json library, and as raw JSON binaries otherwise — decode defensively so
    # the provider behaves identically either way (no per-host forks).
    defp revive_row("toolsets", [
           slug,
           title,
           description,
           base,
           immutable,
           include,
           exclude,
           tools,
           metadata,
           inserted_at
         ]) do
      Persistence.revive_record("toolsets", %{
        "slug" => slug,
        "title" => title,
        "description" => description,
        "base" => base,
        "immutable" => immutable,
        "include" => jsonb(include),
        "exclude" => jsonb(exclude),
        "tools" => jsonb(tools),
        "metadata" => jsonb(metadata),
        "inserted_at" => iso(inserted_at)
      })
    end

    defp revive_row("toolset_grants", [
           id,
           slug,
           authenticator,
           subject,
           effect,
           scopes,
           tool_overrides,
           expires_at,
           inserted_at,
           metadata
         ]) do
      Persistence.revive_record("toolset_grants", %{
        "id" => id,
        "toolset_slug" => slug,
        "authenticator" => authenticator,
        "subject" => subject,
        "effect" => effect,
        "scopes" => jsonb(scopes),
        "tool_overrides" => jsonb(tool_overrides),
        "expires_at" => iso(expires_at),
        "inserted_at" => iso(inserted_at),
        "metadata" => jsonb(metadata)
      })
    end

    defp revive_row("toolset_negotiations", [
           id,
           slug,
           authenticator,
           tool,
           required_scopes,
           granted,
           metadata_overrides,
           expires_at,
           inserted_at,
           metadata
         ]) do
      Persistence.revive_record("toolset_negotiations", %{
        "id" => id,
        "toolset_slug" => slug,
        "authenticator" => authenticator,
        "tool" => tool,
        "required_scopes" => jsonb(required_scopes),
        "granted" => granted,
        "metadata_overrides" => jsonb(metadata_overrides),
        "expires_at" => iso(expires_at),
        "inserted_at" => iso(inserted_at),
        "metadata" => jsonb(metadata)
      })
    end

    defp revive_row("engine_servers", [name, transport, command, url, auth_ref, enabled]) do
      Persistence.revive_record("engine_servers", %{
        "name" => name,
        "transport" => transport,
        "command" => command,
        "url" => url,
        "auth_ref" => auth_ref,
        "enabled" => enabled
      })
    end

    defp jsonb(bin) when is_binary(bin), do: Jason.decode!(bin)
    defp jsonb(other), do: other

    defp iso(nil), do: nil
    defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

    defp fetch_repo!(opts) do
      case Keyword.fetch(opts, :repo) do
        {:ok, repo} when is_atom(repo) and repo != nil ->
          repo

        _other ->
          raise ArgumentError,
                "Noizu.MCP.Persistence.Ecto requires a `:repo` option — a misconfigured " <>
                  "store must fail loudly, never silently lose records (D4)"
      end
    end

    defp query(repo, sql, params) do
      Ecto.Adapters.SQL.query(repo, sql, params)
    end
  end
end
