defmodule Noizu.MCP.Engine.Session do
  @moduledoc """
  One supervised upstream client session (PRD-11 §4.3).

  A session owns a `Noizu.MCP.Client` connected to one upstream `servers` row
  over the row's transport. It resolves the row's `auth_ref` at connect time
  (§4.7), handshakes within `:connect_timeout_ms`, lists the upstream's tools,
  prompts, resources and — when the upstream advertises `experimental.sql` —
  its `sql/*` relations, and publishes the resulting catalog to the engine's
  federation layer.

  Failure semantics (D5, fail-open per server):

    * a connection failure sets `status = :error` with a REDACTED detail,
      empties the layer, and schedules a reconnect after exponential backoff
      with jitter (`Noizu.MCP.Engine.Config.compute_backoff/2`), reset on a
      successful handshake. A permanently unreachable upstream retries at
      `max_ms` forever and costs one idle process — it never crashes its
      supervisor and never affects another upstream.
    * only a programming error crashes; the supervisor's restart intensity
      then applies normally.

  Refresh triggers (FR-11.12, FR-11.13): upstream `list_changed` notifications
  (mirrored through the client's `:on_notification`) re-list that surface
  immediately, `:refresh_interval_ms` re-lists periodically as a backstop, and
  `engine.refresh` forces one. After a re-list that changed the tool layer the
  session has the engine emit its own downstream
  `notifications/tools/list_changed`.

  Pass-through rows (§4.6) run NO pooled session: a per-principal session is
  started on demand by `Noizu.MCP.Engine.Supervisor` and evicts itself after
  `:passthrough_idle_ms` of inactivity. The resolved credential of a session
  lives ONLY in the session process — no log line, status detail, telemetry
  payload or error message ever carries it (FR-11.5).
  """

  use GenServer
  require Logger

  alias Noizu.MCP.{Client, Engine}
  alias Noizu.MCP.Engine.Config
  alias Noizu.MCP.Types.Tool

  @registry Module.concat(Engine, Registry)

  defstruct [
    :name,
    :row,
    :key,
    :principal,
    :credential,
    :client,
    :monitor,
    :status,
    :status_detail,
    :last_seen,
    :tools,
    :prompts,
    :resources,
    :resource_templates,
    :sql_relations,
    :server_info,
    :protocol_version,
    :backoff_attempt,
    :retry_timer,
    :refresh_timer,
    :evict_timer
  ]

  @type t :: %__MODULE__{}

  # ── child spec / lifecycle ─────────────────────────────────────────────────

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {:noizu_mcp_engine_session, Keyword.fetch!(opts, :key)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc false
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    # The client is started via start_link (LINKED) and its transport may die
    # abnormally; connection failures must reach us as SIGNALS we handle, not
    # as the session's own death (D5 — a down upstream costs one idle process).
    Process.flag(:trap_exit, true)

    key = Keyword.fetch!(opts, :key)
    row = Keyword.fetch!(opts, :row)

    state =
      %__MODULE__{
        name: row["name"],
        row: row,
        key: key,
        principal: Keyword.get(opts, :principal),
        status: :connecting,
        tools: [],
        prompts: [],
        resources: [],
        resource_templates: [],
        sql_relations: [],
        backoff_attempt: 0
      }

    {:ok, _} = Registry.register(@registry, {:engine_upstream, key}, row["name"])
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case open_client(state) do
      {:ok, client, credential} ->
        state = %{
          state
          | client: client,
            monitor: Process.monitor(client),
            credential: credential
        }

        {:noreply, state, {:continue, :catalog}}

      {:error, detail} ->
        {:noreply, failed(state, detail)}
    end
  end

  def handle_continue(:catalog, state) do
    case list_surfaces(state) do
      {:ok, state} -> {:noreply, succeed(state) |> schedule_refresh()}
      {:error, detail} -> {:noreply, failed(state, detail)}
    end
  end

  # ── calls ──────────────────────────────────────────────────────────────────

  @typedoc "The live projection of one `servers` row (the `servers` scan merge)."
  @type status_view :: %{
          required(:status) => String.t(),
          required(:status_detail) => String.t() | nil,
          required(:last_seen) => DateTime.t() | nil,
          required(:tool_count) => non_neg_integer(),
          required(:protocol_version) => String.t() | nil,
          required(:server_info) => map() | nil
        }

  @doc "Ask the session for its live status view (the `servers` scan merge)."
  @spec status(pid()) :: status_view()
  def status(pid), do: GenServer.call(pid, :status)

  @doc "Ask the session for its namespaced tool catalog (federation read)."
  @spec catalog(pid()) :: {:ok, [Tool.t()]}
  def catalog(pid), do: GenServer.call(pid, :catalog)

  @doc "The non-tool surfaces of a ready session (federation reads)."
  @spec surfaces(pid()) :: {:ok, map()} | {:error, :not_ready}
  def surfaces(pid), do: GenServer.call(pid, :surfaces)

  @doc "The upstream's cached `sql/schema` relations (empty when not advertised)."
  @spec sql_relations(pid()) :: [map()]
  def sql_relations(pid), do: GenServer.call(pid, :sql_relations)

  @doc "Proxy a `tools/call` through the session (FR-11.11)."
  @spec call_tool(pid(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call_tool(pid, tool, args), do: GenServer.call(pid, {:call_tool, tool, args})

  @doc "Proxy a `prompts/get` through the session."
  @spec get_prompt(pid(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def get_prompt(pid, name, args), do: GenServer.call(pid, {:get_prompt, name, args})

  @doc "Proxy a `resources/read` through the session."
  @spec read_resource(pid(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def read_resource(pid, uri), do: GenServer.call(pid, {:read_resource, uri})

  @doc "Proxy a `sql/scan` to an upstream advertising `experimental.sql` (FR-11.19)."
  @spec sql_scan(pid(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def sql_scan(pid, relation, wire_opts),
    do: GenServer.call(pid, {:sql_scan, relation, wire_opts})

  @doc "Force a full re-list (engine.refresh, FR-11.13)."
  @spec refresh(pid()) :: map()
  def refresh(pid), do: GenServer.call(pid, :refresh)

  @doc "Touch the pass-through idle timer (each proxied call resets eviction)."
  @spec touch(pid()) :: :ok
  def touch(pid), do: GenServer.cast(pid, :touch)

  @impl true
  def handle_call(:status, _from, state), do: {:reply, status_view(state), state}

  def handle_call(:catalog, _from, state), do: {:reply, {:ok, tools_of(state)}, state}

  def handle_call(:surfaces, _from, %{status: :ready} = state) do
    {:reply,
     {:ok,
      %{
        prompts: state.prompts,
        resources: state.resources,
        resource_templates: state.resource_templates
      }}, state}
  end

  def handle_call(:surfaces, _from, state), do: {:reply, {:error, :not_ready}, state}

  def handle_call(:sql_relations, _from, state),
    do: {:reply, if(state.status == :ready, do: state.sql_relations, else: []), state}

  def handle_call({:call_tool, _tool, _args}, _from, %{client: nil} = state) do
    {:reply, {:error, upstream_down(state)}, state}
  end

  def handle_call({:call_tool, tool, args}, _from, state) do
    case Client.call_tool(state.client, tool, args) do
      {:ok, result} -> {:reply, {:ok, result}, %{state | last_seen: DateTime.utc_now()}}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:get_prompt, _name, _args}, _from, %{client: nil} = state) do
    {:reply, {:error, upstream_down(state)}, state}
  end

  def handle_call({:get_prompt, name, args}, _from, state) do
    {:reply, Client.get_prompt(state.client, name, args), state}
  end

  def handle_call({:read_resource, _uri}, _from, %{client: nil} = state) do
    {:reply, {:error, upstream_down(state)}, state}
  end

  def handle_call({:read_resource, uri}, _from, state) do
    {:reply, Client.read_resource(state.client, uri), state}
  end

  def handle_call({:sql_scan, _relation, _opts}, _from, %{client: nil} = state) do
    {:reply, {:error, upstream_down(state)}, state}
  end

  def handle_call({:sql_scan, relation, wire_opts}, _from, state) do
    {:reply, Client.request(state.client, "sql/scan", wire_params(relation, wire_opts)), state}
  end

  def handle_call(:refresh, _from, %{client: nil} = state) do
    {:reply, Map.put(status_view(state), :name, state.name), state}
  end

  def handle_call(:refresh, _from, state) do
    case relist_all(state) do
      {:ok, state} ->
        {:reply, Map.put(status_view(state), :name, state.name), state}

      {:error, detail} ->
        state = failed(state, detail)
        {:reply, Map.put(status_view(state), :name, state.name), state}
    end
  end

  @impl true
  def handle_cast(:touch, %{row: %{"auth_ref" => "passthrough"}} = state) do
    if state.evict_timer, do: Process.cancel_timer(state.evict_timer)

    idle = Config.get(:passthrough_idle_ms)

    {:noreply,
     %{
       state
       | evict_timer: Process.send_after(self(), :evict, idle),
         last_seen: DateTime.utc_now()
     }}
  end

  def handle_cast(:touch, state), do: {:noreply, state}

  # ── upstream notifications (mirrored via :on_notification, FR-11.12) ──────

  @impl true
  def handle_info({:mcp_notification, "notifications/tools/list_changed", _params}, state) do
    case relist(state, :tools) do
      {:ok, state} -> {:noreply, state}
      {:error, detail} -> {:noreply, failed(state, detail)}
    end
  end

  def handle_info({:mcp_notification, "notifications/prompts/list_changed", _params}, state) do
    case relist(state, :prompts) do
      {:ok, state} -> {:noreply, state}
      {:error, detail} -> {:noreply, failed(state, detail)}
    end
  end

  def handle_info({:mcp_notification, "notifications/resources/list_changed", _params}, state) do
    case relist(state, :resources) do
      {:ok, state} -> {:noreply, state}
      {:error, detail} -> {:noreply, failed(state, detail)}
    end
  end

  def handle_info({:mcp_notification, _method, _params}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state) do
    {:noreply, failed(%{state | client: nil, monitor: nil}, "connection lost")}
  end

  # The client link's exit companion of the :DOWN above (we trap exits); state
  # transitions are the monitor's job.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:retry, state) do
    {:noreply, %{state | retry_timer: nil}, {:continue, :connect}}
  end

  def handle_info(:refresh_timer, state) do
    case relist_all(state) do
      {:ok, state} -> {:noreply, schedule_refresh(state)}
      {:error, detail} -> {:noreply, failed(state, detail) |> schedule_refresh()}
    end
  end

  def handle_info(:evict, state) do
    Logger.debug("noizu_mcp engine: pass-through session idle — evicting #{inspect(state.key)}")
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.client, do: Client.close(state.client)
    :ok
  end

  # ── connect ────────────────────────────────────────────────────────────────

  # Resolve the credential at CONNECT time only (§4.7) — a row can be created
  # before its secret exists. A row with no auth_ref connects anonymously;
  # passthrough rows resolve from the principal.
  defp open_client(state) do
    with {:ok, credential} <- credential(state),
         {:ok, transport} <- transport_opts(state, credential),
         {:ok, client} <- start_client(transport) do
      {:ok, client, credential}
    end
  end

  defp credential(%{row: %{"auth_ref" => ref}}) when ref in [nil, ""], do: {:ok, nil}

  # A pass-through session without a principal is the pooled CATALOG session
  # (§4.6): it lists the upstream's surface but never carries a credential and
  # never proxies a call.
  defp credential(%{row: %{"auth_ref" => "passthrough"}, principal: nil}), do: {:ok, nil}

  defp credential(%{row: %{"auth_ref" => "passthrough"}} = state) do
    case Engine.Credentials.passthrough_credential(state.principal) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "pass-through upstream requires a caller credential"}
    end
  end

  defp credential(state) do
    case Engine.Credentials.resolve(state.row["auth_ref"]) do
      {:ok, value} -> {:ok, value}
      {:error, {:unresolved_auth_ref, ref}} -> {:error, "auth_ref could not be resolved: #{ref}"}
    end
  end

  # Transport wiring (§4.2/§4.6): stdio rows shell-split `command`; http rows
  # take `url`. A pass-through session carries the CALLER'S credential — env
  # var for stdio, Authorization header for http — never a stored one. The
  # pooled catalog session of a pass-through row connects with none.
  defp transport_opts(state, credential) do
    passthrough? = state.row["auth_ref"] == "passthrough" and credential != nil

    case state.row["transport"] do
      "stdio" -> stdio_transport(state.row["command"], credential, passthrough?)
      "http" -> http_transport(state.row["url"], credential, passthrough?)
      _other -> {:error, "unknown transport"}
    end
  end

  defp stdio_transport(command, _credential, false) do
    case OptionParser.split(command || "") do
      [executable | args] -> {:ok, {:stdio, command: executable, args: args, env: nil}}
      [] -> {:error, "stdio row has no command"}
    end
  end

  defp stdio_transport(command, credential, true) do
    case stdio_transport(command, credential, false) do
      {:ok, {:stdio, opts}} ->
        {:ok, {:stdio, Keyword.put(opts, :env, %{"MCP_PASSTHROUGH_TOKEN" => credential})}}

      other ->
        other
    end
  end

  defp http_transport(url, _credential, false) do
    {:ok, {:streamable_http, url: url, headers: []}}
  end

  defp http_transport(url, credential, true) do
    {:ok, {:streamable_http, url: url, headers: [{"authorization", "Bearer " <> credential}]}}
  end

  # A transport may RAISE on spawn failure (stdio: executable not found) —
  # the session must survive every connection error (D5), so start the client
  # behind an exit boundary.
  defp start_client(transport) do
    start_client_safe(transport)
  rescue
    _error -> {:error, "upstream could not be started"}
  catch
    :exit, _reason -> {:error, "upstream could not be started"}
  end

  defp start_client_safe(transport) do
    client_opts = [
      transport: transport,
      on_notification: self(),
      client_info: %{
        name: "noizu-mcp-engine",
        version: to_string(Application.spec(:noizu_mcp, :vsn) || "0.0.0")
      }
    ]

    case Client.start_link(client_opts) do
      {:ok, client} ->
        timeout = Config.get(:connect_timeout_ms)

        case Client.await_ready(client, timeout) do
          :ok ->
            {:ok, client}

          {:error, _reason} ->
            Client.close(client)
            {:error, "handshake failed"}
        end

      {:error, _reason} ->
        {:error, "upstream could not be started"}
    end
  end

  # ── catalog listing ────────────────────────────────────────────────────────

  defp list_surfaces(state) do
    with {:ok, tools} <- Client.list_tools(state.client),
         {:ok, prompts} <- Client.list_prompts(state.client),
         {:ok, resources} <- Client.list_resources(state.client),
         {:ok, templates} <- Client.list_resource_templates(state.client),
         {:ok, sql_relations} <- list_sql_relations(state) do
      {:ok,
       %{
         state
         | tools: tools,
           prompts: prompts,
           resources: resources,
           resource_templates: templates,
           sql_relations: sql_relations
       }}
    end
  end

  # An upstream advertising `experimental.sql` re-exports its relations
  # namespaced (FR-11.19). A failed schema call degrades to no relations.
  defp list_sql_relations(state) do
    if advertised_sql?(Client.server_capabilities(state.client)) do
      case Client.request(state.client, "sql/schema", %{}) do
        {:ok, %{"relations" => relations}} when is_list(relations) -> {:ok, relations}
        _other -> {:ok, []}
      end
    else
      {:ok, []}
    end
  end

  defp advertised_sql?(capabilities) when is_map(capabilities) do
    get_in(capabilities, ["experimental", "sql"]) != nil
  end

  defp advertised_sql?(_other), do: false

  # Re-list one surface; a changed TOOL layer flips the engine's own
  # downstream notification on (FR-11.12).
  defp relist(%{client: nil}, _surface), do: {:error, "connection lost"}

  defp relist(state, :tools) do
    with {:ok, tools} <- Client.list_tools(state.client) do
      if tools != state.tools, do: Engine.notify_changed(:tools)
      {:ok, %{state | tools: tools, last_seen: DateTime.utc_now()}}
    end
  end

  defp relist(state, :prompts) do
    with {:ok, prompts} <- Client.list_prompts(state.client) do
      if prompts != state.prompts, do: Engine.notify_changed(:prompts)
      {:ok, %{state | prompts: prompts, last_seen: DateTime.utc_now()}}
    end
  end

  defp relist(state, :resources) do
    with {:ok, resources} <- Client.list_resources(state.client),
         {:ok, templates} <- Client.list_resource_templates(state.client) do
      changed? = resources != state.resources or templates != state.resource_templates
      if changed?, do: Engine.notify_changed(:resources)

      {:ok,
       %{
         state
         | resources: resources,
           resource_templates: templates,
           last_seen: DateTime.utc_now()
       }}
    end
  end

  defp relist_all(state) do
    with {:ok, state} <- relist(state, :tools),
         {:ok, state} <- relist(state, :prompts) do
      relist(state, :resources)
    end
  end

  # ── state transitions ──────────────────────────────────────────────────────

  defp succeed(state) do
    if state.retry_timer, do: Process.cancel_timer(state.retry_timer)

    %{
      state
      | status: :ready,
        status_detail: nil,
        backoff_attempt: 0,
        retry_timer: nil,
        last_seen: DateTime.utc_now(),
        server_info: Client.server_info(state.client),
        protocol_version: Client.protocol_version(state.client)
    }
    |> maybe_notify_tools()
    |> schedule_evict()
  end

  # A pass-through session evicts itself after `:passthrough_idle_ms` of
  # inactivity (§4.6); the idle window opens at connect, and every proxied
  # call resets it.
  defp schedule_evict(%{row: %{"auth_ref" => "passthrough"}} = state) do
    idle = Config.get(:passthrough_idle_ms)
    if state.evict_timer, do: Process.cancel_timer(state.evict_timer)
    %{state | evict_timer: Process.send_after(self(), :evict, idle)}
  end

  defp schedule_evict(state), do: state

  # Downstream list_changed when a (re)connect materially changes the layer.
  # The last-published catalog lives in the process dictionary keyed by the
  # session key — connect-time state only, never a second registry (AP-P14).
  defp maybe_notify_tools(state) do
    key = {__MODULE__, :seen, state.key}
    prefixed = Engine.Toolset.prefix_tools(state.name, tools_of(state))

    if prefixed != Process.get(key) do
      Process.put(key, prefixed)
      Engine.notify_changed(:tools)
    end

    state
  end

  defp failed(state, detail) do
    if state.client do
      Client.close(state.client)
    end

    if state.monitor, do: Process.demonitor(state.monitor, [:flush])
    if state.refresh_timer, do: Process.cancel_timer(state.refresh_timer)

    delay = Config.backoff_delay(state.backoff_attempt)

    Logger.warning(
      "noizu_mcp engine: upstream #{inspect(state.name)} failed (#{detail}) — " <>
        "retrying in #{delay}ms"
    )

    %{
      state
      | status: :error,
        status_detail: detail,
        credential: nil,
        client: nil,
        monitor: nil,
        tools: [],
        prompts: [],
        resources: [],
        resource_templates: [],
        sql_relations: [],
        server_info: nil,
        protocol_version: nil,
        backoff_attempt: state.backoff_attempt + 1,
        refresh_timer: nil,
        retry_timer: Process.send_after(self(), :retry, delay)
    }
    |> maybe_notify_tools()
  end

  defp schedule_refresh(state) do
    interval = Config.get(:refresh_interval_ms)
    %{state | refresh_timer: Process.send_after(self(), :refresh_timer, interval)}
  end

  defp tools_of(%{status: :ready} = state), do: state.tools
  defp tools_of(_state), do: []

  defp status_view(state) do
    %{
      status: if(state.status == :ready, do: "ready", else: Atom.to_string(state.status)),
      status_detail: state.status_detail,
      last_seen: state.last_seen,
      tool_count: length(tools_of(state)),
      protocol_version: state.protocol_version,
      server_info: server_info_map(state.server_info)
    }
  end

  defp server_info_map(nil), do: nil

  defp server_info_map(%{__struct__: _} = info),
    do: %{"name" => info.name, "version" => info.version, "title" => info.title}

  defp upstream_down(state), do: "upstream #{state.name} is #{Atom.to_string(state.status)}"

  defp wire_params(relation, opts) do
    %{"relation" => relation, "quals" => Map.get(opts, "quals") || []}
    |> maybe_wire("columns", Map.get(opts, "columns"))
    |> maybe_wire("sort", Map.get(opts, "sort"))
    |> maybe_wire("limit", Map.get(opts, "limit"))
    |> maybe_wire("cursor", Map.get(opts, "cursor"))
  end

  defp maybe_wire(params, _key, nil), do: params
  defp maybe_wire(params, key, value), do: Map.put(params, key, value)
end
