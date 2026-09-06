defmodule Noizu.MCP.Engine.Supervisor do
  @moduledoc """
  Session lifecycle for the engine's upstreams (PRD-11 §4.3).

  Upstream sessions run under the engine server tree's own
  `DynamicSupervisor` — one child per enabled upstream (FR-11.6), restart
  semantics owned by the session itself (connection errors never crash the
  supervisor; D5). Keys are registry keys under the engine's `Registry`:

    * `name` — the pooled session of an enabled row;
    * `{name, subject}` — a per-principal pass-through session (§4.6).
  """

  alias Noizu.MCP.Engine
  alias Noizu.MCP.Engine.{Credentials, Session}

  @registry Module.concat(Engine, Registry)
  @dynamic_supervisor Module.concat(Engine, SessionSupervisor)

  @typedoc "A session key: the pooled `name`, or `{name, subject}` for pass-through."
  @type key :: String.t() | {String.t(), term()}

  @doc """
  The session a proxied `tools/call` runs on (§4.6): the pooled session when
  one exists, else — for a `passthrough` row — a per-principal session started
  on demand and left to self-evict. A caller with no credential calling a
  pass-through upstream is refused BEFORE any session or upstream request
  (FR-11.16): `{:error, :forbidden}`.
  """
  @spec invoke_session(String.t(), term()) :: {:ok, pid()} | {:error, :forbidden | :unknown}
  def invoke_session(name, ctx) when is_binary(name) do
    case row_auth_ref(name) do
      "passthrough" ->
        principal = if is_map(ctx), do: Map.get(ctx, :auth)

        case Credentials.passthrough_credential(principal) do
          {:ok, _credential} -> pass_through_session(name, principal)
          :error -> {:error, :forbidden}
        end

      _other ->
        case pooled_pid(name) do
          pid when is_pid(pid) -> {:ok, pid}
          nil -> {:error, :unknown}
        end
    end
  end

  defp row_auth_ref(name) do
    case row_for(name) do
      {:ok, row} -> row["auth_ref"]
      _error -> nil
    end
  end

  defp pass_through_session(name, principal) do
    key = {name, principal_subject(principal)}

    case session_pid(key) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        start_pass_through(name, principal, key)
    end
  end

  defp start_pass_through(name, principal, key) do
    case row_for(name) do
      {:ok, row} ->
        case start_session(row, principal) do
          {:ok, _pid} ->
            await_ready(key, deadline())

          {:error, {:already_started, _}} ->
            {:ok, session_pid(key)}

          {:error, _reason} ->
            {:error, :forbidden}
        end

      {:error, _} = error ->
        error
    end
  end

  defp await_ready(key, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :forbidden}
    else
      case session_pid(key) do
        nil ->
          Process.sleep(20)
          await_ready(key, deadline)

        pid ->
          await_ready_session(pid, key, deadline)
      end
    end
  end

  defp await_ready_session(pid, key, deadline) do
    case Session.status(pid) do
      %{status: "ready"} -> {:ok, pid}
      _other -> await_ready(key, deadline)
    end
  end

  defp deadline,
    do: System.monotonic_time(:millisecond) + Engine.Config.get(:connect_timeout_ms)

  defp principal_subject(%Noizu.MCP.Auth.Principal{subject: subject}), do: subject
  defp principal_subject(other), do: other

  defp row_for(name) do
    {provider, popts} = Engine.Config.persistence()

    case provider.get(Engine.Config.store_key(), name, popts) do
      {:ok, row} -> {:ok, stringify(row)}
      _other -> {:error, :unknown}
    end
  end

  defp stringify(row) when is_map(row) do
    %{
      "name" => row["name"] || row[:name],
      "transport" => to_string(row["transport"] || row[:transport]),
      "command" => row["command"] || row[:command],
      "url" => row["url"] || row[:url],
      "auth_ref" => row["auth_ref"] || row[:auth_ref],
      "enabled" =>
        case row["enabled"] || row[:enabled] do
          nil -> true
          enabled -> enabled != false
        end
    }
  end

  @doc "Start (or replace) the pooled session for a `servers` row."
  @spec start_session(map()) :: DynamicSupervisor.on_start_child()
  def start_session(row) when is_map(row) do
    start_session(row, nil)
  end

  @doc "Start the session for `row`, optionally per-principal (pass-through)."
  @spec start_session(map(), term()) :: DynamicSupervisor.on_start_child()
  def start_session(row, principal) when is_map(row) do
    opts = [key: key_for(row, principal), row: row, principal: principal]

    DynamicSupervisor.start_child(@dynamic_supervisor, {Session, opts})
  end

  @doc "Stop the session for `key` (idempotent)."
  @spec stop_session(key()) :: :ok
  def stop_session(key) do
    case session_pid(key) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@dynamic_supervisor, pid)
    end
  end

  @doc "Stop then start the pooled session for `row` (a changed row restarts it, §4.2)."
  @spec restart_session(map()) :: DynamicSupervisor.on_start_child()
  def restart_session(row) do
    stop_session(row["name"])
    start_session(row)
  end

  @doc "The pid of the live session for `key`, or nil."
  @spec session_pid(key()) :: pid() | nil
  def session_pid(key) do
    @registry
    |> Registry.select([{{{:engine_upstream, key}, :"$1", :_}, [], [:"$1"]}])
    |> case do
      [pid] -> pid
      [] -> nil
      pids -> List.first(pids)
    end
  end

  @doc "Stop every pass-through session for upstream `name` (row deleted, §4.2)."
  @spec stop_pass_through(String.t()) :: :ok
  def stop_pass_through(name) do
    for {{^name, _subject} = key, _pid} <- sessions() do
      stop_session(key)
    end

    :ok
  end

  @doc "The pooled session pid for a row name (never a pass-through session)."
  @spec pooled_pid(String.t()) :: pid() | nil
  def pooled_pid(name), do: session_pid(name)

  @doc "All live session keys with their pids."
  @spec sessions() :: [{key(), pid()}]
  def sessions do
    if Process.whereis(@registry) do
      Registry.select(@registry, [
        {{{:engine_upstream, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}
      ])
      |> List.flatten()
    else
      []
    end
  end

  @doc "Stop every live session (used when rows are deleted or the engine drains)."
  @spec stop_all() :: :ok
  def stop_all do
    for {key, _pid} <- sessions(), do: stop_session(key)

    :ok
  end

  defp key_for(row, nil), do: row["name"]
  defp key_for(row, principal), do: {row["name"], principal_key(principal)}

  defp principal_key(%Noizu.MCP.Auth.Principal{subject: subject}), do: subject
  defp principal_key(other), do: other
end
