defmodule Noizu.MCP.Engine.Servers do
  @moduledoc """
  The engine's upstream registry as a writable Dataset (PRD-11 §4.2, ADR-005).

  Attaching an MCP server is a row: `sql/modify` insert over this relation, the
  equivalent `engine.attach` tool call (the SAME code path — D1), or static
  config seeded at boot. Rows persist through the configured
  `Noizu.MCP.Persistence` provider under the `"engine_servers"` store key;
  the engine adds no storage layer (FR-11.3).

  `auth_ref` is a reference and nothing else: `env:VAR`, `secret:<name>`,
  `infisical:<path>/<KEY>`, or `passthrough`. Anything else — anything that
  looks like a raw credential — is rejected at insert with a message explaining
  exactly why (§4.2; AP-P13).

  Derived columns (`status`, `status_detail`, `last_seen`, `tool_count`,
  `protocol_version`, `server_info`) are live session state, never persisted
  and never writable. `scan/3` merges persisted rows with live session state,
  honors no quals (the registry is small; the caller re-checks per the PRD-9
  one-directional contract), and filters rows on the SAME ACL that governs
  federated tools: a principal denied an upstream sees no row for it — the
  registry cannot be used to enumerate what one may not use (§4.5, AP-P17).
  """

  use Noizu.MCP.Server.Dataset

  alias Noizu.MCP.{ACL, Engine, Error}
  alias Noizu.MCP.ACL.Resource
  alias Noizu.MCP.Auth.Principal
  alias Noizu.MCP.Engine.{Credentials, Supervisor}
  alias Noizu.MCP.SQL.Quals

  @name_format ~r/^[a-z][a-z0-9_]{0,30}$/
  @reserved ["engine"]

  @derived ~w(status status_detail last_seen tool_count protocol_version server_info)

  @impl true
  def info do
    %{
      name: "servers",
      title: "Upstream servers",
      description:
        "The engine's upstream registry. Insert a row to attach an MCP server; " <>
          "status and health columns are derived from the supervised session.",
      primary_key: ["name"],
      writable: true
    }
  end

  @impl true
  def columns do
    [
      %{
        name: "name",
        type: :text,
        nullable: false,
        description: "Primary key; the namespace prefix"
      },
      %{
        name: "transport",
        type: {:enum, ["stdio", "http"]},
        nullable: false,
        description: "Upstream transport"
      },
      %{name: "command", type: :text, nullable: true, description: "stdio argv, shell-split"},
      %{name: "url", type: :text, nullable: true, description: "Streamable HTTP endpoint"},
      %{
        name: "auth_ref",
        type: :text,
        nullable: true,
        description:
          "Credential reference: env:VAR, secret:<name>, infisical:<path>/<KEY>, passthrough"
      },
      %{name: "enabled", type: :boolean, nullable: false, description: "Session runs when true"},
      %{
        name: "status",
        type: {:enum, ["disconnected", "connecting", "ready", "error", "disabled"]},
        nullable: false,
        description: "Live session state"
      },
      %{name: "status_detail", type: :text, nullable: true, description: "Last error, redacted"},
      %{
        name: "last_seen",
        type: :timestamptz,
        nullable: true,
        description: "Last successful request"
      },
      %{
        name: "tool_count",
        type: :bigint,
        nullable: true,
        description: "Tools in the current layer"
      },
      %{
        name: "protocol_version",
        type: :text,
        nullable: true,
        description: "Negotiated protocol version"
      },
      %{name: "server_info", type: :jsonb, nullable: true, description: "Upstream serverInfo"}
    ]
  end

  # ── scan ───────────────────────────────────────────────────────────────────

  @impl true
  def scan(_args, ctx, _opts) do
    case list_rows() do
      {:ok, rows} ->
        {:ok,
         rows
         |> Enum.reject(&hidden?(&1, ctx))
         |> Enum.map(&live_row/1), nil}

      {:error, reason} ->
        {:error, Error.internal("servers store unavailable: #{inspect(reason)}")}
    end
  end

  # ── writes ─────────────────────────────────────────────────────────────────

  @doc """
  Insert rows. `engine.attach` calls the same path (FR-11.17). Duplicate
  names, the reserved `engine` prefix, and credential-shaped `auth_ref`
  values are rejected.
  """
  @impl true
  def insert(rows, _ctx) when is_list(rows) do
    with {:ok, validated} <- validate_rows(rows),
         :ok <- validate_unique(Enum.map(validated, & &1["name"])),
         :ok <- validate_not_taken(Enum.map(validated, & &1["name"])) do
      insert_rows(validated)
    end
  end

  def insert(_other, _ctx), do: {:error, Error.invalid_params("insert requires a rows array")}

  defp insert_rows(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case insert_row(row) do
        {:ok, merged} -> {:cont, {:ok, acc ++ [merged]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp insert_row(row) do
    case persist_row(row) do
      :ok ->
        {:ok, inserted_row(row, start_if_enabled(row))}

      {:error, reason} ->
        {:error, Error.internal("servers store write failed: #{inspect(reason)}")}
    end
  end

  # A just-started session has not handshaken yet — the row reads `connecting`
  # (§4.2) regardless of what the registry shows in this instant.
  defp inserted_row(row, started?) do
    if started? do
      Map.put(live_row(row), "status", "connecting")
    else
      live_row(row)
    end
  end

  @doc """
  Apply `changes` to every row matching `quals`. Writing a derived column is
  rejected, naming it. Changing `transport`, `command`, `url`, `auth_ref` or
  `enabled` restarts the session (§4.2).
  """
  @impl true
  def update(quals, changes, _ctx) when is_map(changes) do
    if Map.has_key?(changes, "name") do
      {:error, Error.invalid_params("column \"name\" is insert-only and cannot be updated")}
    else
      apply_update(quals, changes)
    end
  end

  def update(_quals, _changes, _ctx),
    do: {:error, Error.invalid_params("update requires changes")}

  defp apply_update(quals, changes) do
    with :ok <- validate_changes(changes) do
      case matching_rows(quals) do
        {:error, reason} ->
          {:error, Error.internal("servers store unavailable: #{inspect(reason)}")}

        {:ok, rows} ->
          apply_updates(rows, changes)
      end
    end
  end

  defp apply_updates(rows, changes) do
    rows
    |> Enum.map(&merge_changes(&1, changes))
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case apply_update_row(row) do
        {:ok, merged} -> {:cont, {:ok, acc ++ [merged]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp apply_update_row(row) do
    case validate_row(row) do
      :ok -> persist_and_restart(row)
      {:error, message} -> {:error, Error.invalid_params(message)}
    end
  end

  defp persist_and_restart(row) do
    case persist_row(row) do
      :ok ->
        # Any changed row restarts its session; a disabled or pass-through row
        # just stays stopped (§4.2/§4.6).
        Supervisor.stop_session(row["name"])
        started? = start_if_enabled(row)

        {:ok, inserted_row(row, started?)}

      {:error, reason} ->
        {:error, Error.internal("servers store write failed: #{inspect(reason)}")}
    end
  end

  @doc "Delete every row matching `quals`; stops the sessions. Returns the count."
  @impl true
  def delete(quals, _ctx) do
    case matching_rows(quals) do
      {:error, reason} ->
        {:error, Error.internal("servers store unavailable: #{inspect(reason)}")}

      {:ok, rows} ->
        for row <- rows do
          Supervisor.stop_session(row["name"])
          Supervisor.stop_pass_through(row["name"])

          {provider, popts} = Engine.Config.persistence()
          provider.delete(Engine.Config.store_key(), row["name"], popts)
        end

        {:ok, length(rows)}
    end
  end

  @doc """
  Seed `:static_servers` config rows (idempotent — existing names win). Static
  config seeds ROWS (D3); it does not bypass them: the row lands in the store
  and the session starts from the store like any other.
  """
  @spec seed_static() :: :ok | {:error, term()}
  def seed_static do
    existing =
      case list_rows() do
        {:ok, rows} -> Enum.map(rows, & &1["name"])
        _error -> []
      end

    rows =
      Noizu.MCP.Engine.Config.get(:static_servers)
      |> Enum.map(&stringify_row/1)
      |> Enum.reject(&(&1["name"] in existing))

    case insert(rows, nil) do
      {:ok, _rows} -> :ok
      {:error, _} = error -> error
    end
  end

  # ── validation (the AP-P13 gate) ──────────────────────────────────────────

  defp validate_rows(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case validate_row(normalize_row(row)) do
        :ok -> {:cont, {:ok, acc ++ [normalize_row(row)]}}
        {:error, message} -> {:halt, {:error, Error.invalid_params(message)}}
      end
    end)
  end

  defp validate_row(row) do
    with :ok <- validate_name(row["name"]),
         :ok <- validate_transport(row) do
      validate_auth_ref(row["auth_ref"])
    end
  end

  defp validate_name(name) when is_binary(name) do
    cond do
      name in @reserved ->
        {:error,
         "the upstream name \"engine\" is reserved — it would collide with the " <>
           "engine's own tools (engine.attach, engine.detach, engine.refresh)"}

      Regex.match?(@name_format, name) ->
        :ok

      true ->
        {:error,
         "name must match ^[a-z][a-z0-9_]{0,30}$ (it becomes the tool namespace " <>
           "prefix), got: #{inspect(name)}"}
    end
  end

  defp validate_name(other), do: {:error, "name must be a string, got: #{inspect(other)}"}

  defp validate_unique(names) do
    dupes = names -- Enum.uniq(names)

    if dupes == [] do
      :ok
    else
      {:error, Error.invalid_params("duplicate upstream names: #{inspect(Enum.uniq(dupes))}")}
    end
  end

  # A name already in the store is a duplicate too (the registry is keyed).
  defp validate_not_taken(names) do
    case list_rows() do
      {:ok, stored} ->
        taken = MapSet.new(stored, & &1["name"])

        case Enum.filter(names, &MapSet.member?(taken, &1)) do
          [] -> :ok
          clash -> {:error, Error.invalid_params("duplicate upstream names: #{Enum.uniq(clash)}")}
        end

      _error ->
        :ok
    end
  end

  defp validate_transport(%{"transport" => "stdio", "command" => command} = row)
       when is_binary(command) and command != "" do
    if row["url"] in [nil, ""],
      do: :ok,
      else: {:error, "url must be NULL for a stdio upstream"}
  end

  defp validate_transport(%{"transport" => "http", "url" => url} = row)
       when is_binary(url) and url != "" do
    if row["command"] in [nil, ""],
      do: :ok,
      else: {:error, "command must be NULL for an http upstream"}
  end

  defp validate_transport(%{"transport" => "stdio"}),
    do: {:error, "a stdio upstream requires a command"}

  defp validate_transport(%{"transport" => "http"}),
    do: {:error, "an http upstream requires a url"}

  defp validate_transport(%{"transport" => other}),
    do: {:error, "transport must be stdio or http, got: #{inspect(other)}"}

  defp validate_transport(_row), do: {:error, "transport is required"}

  defp validate_auth_ref(ref) when ref in [nil, ""], do: :ok

  defp validate_auth_ref(ref) do
    if Credentials.valid_form?(ref) do
      :ok
    else
      {:error, Credentials.rejection_message(ref)}
    end
  end

  defp validate_changes(changes) do
    case Enum.filter(Map.keys(changes), &(&1 in @derived)) do
      [] ->
        :ok

      derived ->
        {:error,
         Error.invalid_params(
           "columns #{Enum.sort(derived)} are derived from the live session and cannot be written"
         )}
    end
  end

  # ── persistence + live merge ───────────────────────────────────────────────

  defp list_rows do
    {provider, popts} = Engine.Config.persistence()

    case provider.list(Engine.Config.store_key(), nil, popts) do
      {:ok, records} -> {:ok, Enum.map(records, &stringify_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp matching_rows(quals) do
    case list_rows() do
      {:ok, rows} -> {:ok, Enum.filter(rows, &Quals.satisfies?(&1, quals))}
      error -> error
    end
  end

  defp persist_row(row) do
    {provider, popts} = Engine.Config.persistence()

    # The shared codec normalizes ATOM-keyed records (the struct shape every
    # other store feeds it); rows here are string-keyed (the dataset wire
    # shape), so convert at the store boundary.
    record = %{
      name: row["name"],
      transport: row["transport"],
      command: row["command"],
      url: row["url"],
      auth_ref: row["auth_ref"],
      enabled: row["enabled"] != false
    }

    provider.put(Engine.Config.store_key(), row["name"], record, popts)
  end

  defp start_if_enabled(row) do
    # Pass-through rows keep a credential-free CATALOG session (their tools
    # must be advertised); invocation never uses it (§4.6, Supervisor).
    if row["enabled"] != false do
      case Supervisor.start_session(row) do
        {:ok, _pid} -> true
        _other -> false
      end
    else
      false
    end
  end

  defp merge_changes(row, changes), do: Map.merge(row, changes)

  # Merge live session state into the persisted operator columns. A row whose
  # session is not running reads `disconnected` (§4.2).
  defp live_row(row) do
    view = live_view(row["name"])

    row
    |> Map.put("enabled", row["enabled"] != false)
    |> Map.put("status", view.status)
    |> Map.put("status_detail", view.status_detail)
    |> Map.put("last_seen", view.last_seen)
    |> Map.put("tool_count", view.tool_count)
    |> Map.put("protocol_version", view.protocol_version)
    |> Map.put("server_info", view.server_info)
  end

  defp live_view(name) do
    case Supervisor.pooled_pid(name) do
      nil -> disconnected_view(name)
      pid -> session_status(pid)
    end
  end

  # No pooled session: a disabled row reads `disabled`; otherwise, a live
  # pass-through session implies the upstream is serving through it (§4.6),
  # anything else is plain `disconnected`.
  defp disconnected_view(name) do
    cond do
      row_disabled?(name) -> base_view("disabled")
      pass_through_session_running?(name) -> ready_without_session_view()
      true -> base_view("disconnected")
    end
  end

  defp row_disabled?(name) do
    case list_rows() do
      {:ok, rows} ->
        case Enum.find(rows, &(&1["name"] == name)) do
          %{"enabled" => false} -> true
          _other -> false
        end

      _error ->
        false
    end
  end

  defp pass_through_session_running?(name) do
    Enum.any?(Supervisor.sessions(), fn
      {{^name, _subject}, _pid} -> true
      _other -> false
    end)
  end

  defp ready_without_session_view do
    %{
      status: "ready",
      status_detail: nil,
      last_seen: nil,
      tool_count: 0,
      protocol_version: nil,
      server_info: nil
    }
  end

  defp session_status(pid) do
    Engine.Session.status(pid)
  rescue
    _error -> base_view("disconnected")
  catch
    :exit, _reason -> base_view("disconnected")
  end

  defp base_view(status) do
    %{
      status: status,
      status_detail: nil,
      last_seen: nil,
      tool_count: 0,
      protocol_version: nil,
      server_info: nil
    }
  end

  # ── ACL row-hiding (§4.5, AP-P17) ──────────────────────────────────────────

  # A principal denied an upstream sees no row for it: the registry filters on
  # the same ACL as the federated tools, keyed by the upstream's own id. No
  # provider configured = inert (allow), the library's back-compat posture.
  defp hidden?(row, ctx) do
    case ACL.Provider.resolve_provider(Engine, []) do
      nil ->
        false

      {provider, check_opts} ->
        resource = %Resource{kind: :tool, id: row["name"]}

        ACL.Provider.check(provider, subject_for(ctx), resource, :call, ctx, check_opts) != :allow
    end
  end

  defp subject_for(%{auth: %Principal{} = principal}), do: principal
  defp subject_for(_ctx), do: nil

  # ── row normalization ──────────────────────────────────────────────────────

  defp normalize_row(row) when is_map(row) do
    %{
      "name" => row["name"],
      "transport" => row["transport"],
      "command" => row["command"],
      "url" => row["url"],
      "auth_ref" => row["auth_ref"],
      "enabled" => row["enabled"] != false
    }
  end

  defp stringify_row(row) when is_map(row) do
    %{
      "name" => row["name"] || row[:name],
      "transport" => to_string(row["transport"] || row[:transport]),
      "command" => row["command"] || row[:command],
      "url" => row["url"] || row[:url],
      "auth_ref" => row["auth_ref"] || row[:auth_ref],
      "enabled" =>
        case row["enabled"] do
          nil -> row[:enabled] != false
          enabled -> enabled != false
        end
    }
  end
end
