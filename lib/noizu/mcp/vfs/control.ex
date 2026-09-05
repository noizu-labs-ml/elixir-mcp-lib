defmodule Noizu.MCP.VFS.Control do
  @moduledoc """
  The `/etc/dev` control and introspection tree, composed into a server's VFS
  at the mount root.

      defmodule MyApp.MCP.FS do
        use Noizu.MCP.VFS.Control,
          server: MyApp.MCP,
          real: MyApp.MCP.PM
      end

      defmodule MyApp.MCP do
        use Noizu.MCP.Server, name: "myapp", version: "1.0.0"
        tool MyApp.MCP.PM.SendTicket
        vfs MyApp.MCP.FS
      end

  Paths under `/etc/dev/**` are served by this module; every other path is
  delegated verbatim to the `:real` backend (omit `:real` for a standalone
  control-only tree). Composition is by delegation rather than overlay —
  `Noizu.MCP.Server.Features.VFS` selects a single registered backend (first
  registration wins), so the generated module *is* the backend the server
  registers.

  The root listing merges the real backend's entries with the `etc/dev` branch,
  so the control tree is discoverable from `/`.

  ## Node table

  | Path | Writable | Read | Write |
  | ---- | -------- | ---- | ----- |
  | `/etc/dev/tools/<tool>` | yes | tool definition JSON (`name`, `description`, `inputSchema`, `annotations`) | one JSON line `{"args": {...}}` — invokes the tool through `handle_call_tool/3`; the result is buffered per connection and the next read of the node returns it as JSON |
  | `/etc/dev/runtime/status` | no | uptime, session count, `serverInfo`, capabilities, transports | `:eacces` |
  | `/etc/dev/runtime/sessions/<id>` | no | per-session JSON | `:eacces` |
  | `/etc/dev/cache/stats` | no | generation + entry counts per backend | `:eacces` |
  | `/etc/dev/cache/flush` | yes | flush hint JSON | any write — bumps every VFS cache generation; `"ok"` in the node's `xattrs["response"]` |
  | `/etc/dev/config/<toggle>` | yes | current value as JSON | a JSON document — validated, then applied |

  Seed config toggles:

    * `trace` (boolean) — `Logger.debug` on every VFS operation through the
      composing backend
    * `cache_enabled` (boolean) — mirrors `Application.put_env(:noizu_mcp,
      :vfs_cache_enabled, ...)`

  Servers add their own with the `:toggles` option:

      use Noizu.MCP.VFS.Control,
        server: MyApp.MCP,
        real: MyApp.MCP.PM,
        toggles: [
          %{name: "maintenance", get: {MyApp.Runtime, :maintenance?, []},
            set: {MyApp.Runtime, :set_maintenance, []}}
        ]

  `get` is invoked `apply(m, f, args)`; `set` receives the decoded JSON value
  appended: `apply(m, f, args ++ [value])`. A `set` returning
  `{:error, term}` surfaces as `:eio`.

  ## Tool invocation gating

  Writes to `tools/<tool>` run through `server.handle_call_tool/3` — the same
  path as `tools/call` — so authz/PDP wrappers in the server apply untouched.
  On top of that, the control layer gates invocations:

    1. `tool_gate: {mod, fun}` (or `{mod, fun, args}`) — the hook's verdict is
       final. Invoked `apply(mod, fun, args ++ [tool_name, arguments, ctx])`,
       returning `:ok` or `{:error, term}`.
    2. Otherwise, a per-token allowlist claim — `ctx.assigns[:auth_claims]`
       carrying `"vfs_tool_allowlist"` (a list of tool names) — is enforced;
       unlisted tools are `:eacces`.
    3. Otherwise, tools annotated `destructive_hint: true` fail closed
       (`:eacces`): a destructive invocation requires an explicit gate or
       allowlist.
    4. Everything else is allowed.

  ## Safety

    * Server-level opt `use Noizu.MCP.Server, vfs_readonly: true` — every write
      through the composing backend (control tree included) returns `:erofs`.
      Config toggles freeze with it; restart the transport or flip it off to
      recover write access.
    * The unix-socket transport (`Noizu.MCP.Transport.VFSSocket`) binds with
      0600 and requires the `vfs/auth` handshake before any operation — keep
      the control mount on a socket only trusted clients can reach.
    * Tool results buffered under `/etc/dev/tools/<tool>` are keyed per
      connection context and never visible across sessions.

  ## Error conventions

  Unknown paths/tools/toggles are `:enoent`; malformed JSON (a tool write that
  is not a JSON object, or a non-JSON config value) is `:eio`; denied
  invocations are `:eacces`; readonly is `:erofs`.

  ## Dispatcher-cache interaction

  `Noizu.MCP.Server.Features.VFS` caches reads for the configured TTL
  (`:noizu_mcp, :vfs_cache_ttl_ms`, default 60s), and successful control
  writes bump the generation (dropping every cached entry) — so reads are
  fresh right after any write. A *repeat* read that consumes a buffered tool
  result may, within the TTL window, be served the cached copy again; pass a
  `version` on `vfs/read` or wait out the TTL to force a fresh read. (A
  backend opt-out from the read cache — e.g. a `__mcp_vfs__(:cacheable)`
  flag — is the clean long-term fix and is flagged upstream.)
  """

  alias Noizu.MCP.Ctx
  alias Noizu.MCP.Error
  alias Noizu.MCP.Server.Features.{Pagination, Tools}
  alias Noizu.MCP.Types.{Tool, ToolResult}
  alias Noizu.MCP.VFS
  alias Noizu.MCP.VFS.Cache

  require Logger

  @mount "/etc/dev"
  @built_in_toggles ["trace", "cache_enabled"]

  # ── composition DSL ───────────────────────────────────────────────────────

  @doc """
  Compose the control tree into a VFS backend module. Options:

    * `:server` (required) — the `Noizu.MCP.Server` module whose tools,
      sessions, capabilities and opts the tree introspects, and whose
      `handle_call_tool/3` executes tool writes
    * `:real` — the backend receiving everything outside `/etc/dev`
    * `:tool_gate` — `{mod, fun}` or `{mod, fun, args}` invocation gate (see
      the moduledoc)
    * `:toggles` — extra config toggles, `%{name:, get: {m,f,a}, set: {m,f,a}}`
  """
  # ⟦𓆒⟧ __using__
  defmacro __using__(opts) do
    server = Keyword.fetch!(opts, :server)
    real = Keyword.get(opts, :real)
    toggles = Keyword.get(opts, :toggles, [])

    # Splice the gate AST raw into the accessor — a `{m, f}` / `{m, f, extra}`
    # tuple literal compiles to itself, with aliases resolved to atoms.
    tool_gate = Keyword.get(opts, :tool_gate)

    quote do
      use Noizu.MCP.VFS

      @doc false
      def __mcp_vfs_control__(:server), do: unquote(server)
      def __mcp_vfs_control__(:real), do: unquote(real)
      def __mcp_vfs_control__(:tool_gate), do: unquote(tool_gate)
      def __mcp_vfs_control__(:toggles), do: unquote(toggles)

      @impl true
      def stat(path, ctx), do: Noizu.MCP.VFS.Control.stat(__MODULE__, path, ctx)

      @impl true
      def list(path, cursor, ctx), do: Noizu.MCP.VFS.Control.list(__MODULE__, path, cursor, ctx)

      @impl true
      def read(path, ctx), do: Noizu.MCP.VFS.Control.read(__MODULE__, path, ctx)

      @impl true
      def write(path, data, ctx), do: Noizu.MCP.VFS.Control.write(__MODULE__, path, data, ctx)

      @impl true
      def create(path, data, ctx), do: Noizu.MCP.VFS.Control.create(__MODULE__, path, data, ctx)

      @impl true
      def remove(path, ctx), do: Noizu.MCP.VFS.Control.remove(__MODULE__, path, ctx)

      @impl true
      def search(root, query, ctx), do: Noizu.MCP.VFS.Control.search(__MODULE__, root, query, ctx)

      @impl true
      def xattr(path, ctx), do: Noizu.MCP.VFS.Control.xattr(__MODULE__, path, ctx)
    end
  end

  @doc false
  def __mcp_vfs_control__(_), do: nil

  # ── VFS callbacks (backend module passed in as `backend`) ─────────────────

  @doc false
  # ⟦𓆒⟧ stat
  @spec stat(module(), String.t(), Ctx.t()) :: {:ok, VFS.t()} | {:error, VFS.errno()}
  def stat(backend, path, ctx) do
    trace(backend, "stat", path)

    cond do
      control_path?(path) -> control_stat(backend, path)
      path == "/" and real(backend) -> real(backend).stat("/", ctx)
      path == "/" -> {:ok, dir_node()}
      true -> delegate(backend, :stat, [path, ctx])
    end
  end

  @doc false
  # ⟦𓆒⟧ list
  @spec list(module(), String.t(), String.t() | nil, Ctx.t()) ::
          {:ok, [map()], String.t() | nil} | {:error, term()}
  def list(backend, path, cursor, ctx) do
    trace(backend, "list", path)

    cond do
      control_path?(path) -> control_list(backend, path, cursor, ctx)
      path == "/" and real(backend) -> merge_root(backend, cursor, ctx)
      path == "/" -> control_list(backend, "/", cursor, ctx)
      true -> delegate(backend, :list, [path, cursor, ctx])
    end
  end

  @doc false
  # ⟦𓆒⟧ read
  @spec read(module(), String.t(), Ctx.t()) ::
          {:ok, binary(), non_neg_integer()} | {:error, VFS.errno()}
  def read(backend, path, ctx) do
    trace(backend, "read", path)

    cond do
      control_path?(path) -> control_read(backend, path, ctx)
      path == "/" -> {:error, :eisdir}
      true -> delegate(backend, :read, [path, ctx])
    end
  end

  @doc false
  # ⟦𓆒⟧ write
  @spec write(module(), String.t(), binary(), Ctx.t()) :: {:ok, VFS.t()} | {:error, term()}
  def write(backend, path, data, ctx) do
    trace(backend, "write", path)

    cond do
      control_path?(path) and readonly?(backend) -> {:error, :erofs}
      control_path?(path) -> control_write(backend, path, data, ctx)
      path == "/" and readonly?(backend) -> {:error, :erofs}
      path == "/" and real(backend) -> real(backend).write("/", data, ctx)
      path == "/" -> {:error, :eisdir}
      readonly?(backend) -> {:error, :erofs}
      true -> delegate(backend, :write, [path, data, ctx])
    end
  end

  @doc false
  # ⟦𓆒⟧ create
  @spec create(module(), String.t(), binary() | :dir, Ctx.t()) ::
          {:ok, VFS.t()} | {:error, VFS.errno()}
  def create(backend, path, data, ctx) do
    trace(backend, "create", path)

    cond do
      control_path?(path) and readonly?(backend) -> {:error, :erofs}
      control_path?(path) -> {:error, :eacces}
      readonly?(backend) -> {:error, :erofs}
      true -> delegate(backend, :create, [path, data, ctx])
    end
  end

  @doc false
  # ⟦𓆒⟧ remove
  @spec remove(module(), String.t(), Ctx.t()) :: :ok | {:error, VFS.errno()}
  def remove(backend, path, ctx) do
    trace(backend, "remove", path)

    cond do
      control_path?(path) and readonly?(backend) -> {:error, :erofs}
      control_path?(path) -> {:error, :eacces}
      readonly?(backend) -> {:error, :erofs}
      true -> delegate(backend, :remove, [path, ctx])
    end
  end

  @doc false
  # ⟦𓆒⟧ search
  @spec search(module(), String.t(), String.t(), Ctx.t()) ::
          {:ok, [map()], String.t() | nil} | {:error, term()}
  def search(backend, root, query, ctx) do
    trace(backend, "search", root)
    delegate(backend, :search, [root, query, ctx])
  end

  @doc false
  # ⟦𓆒⟧ xattr
  @spec xattr(module(), String.t(), Ctx.t()) :: {:ok, map()} | {:error, VFS.errno()}
  def xattr(backend, path, ctx) do
    cond do
      control_path?(path) -> {:ok, %{}}
      true -> delegate(backend, :xattr, [path, ctx])
    end
  end

  # ── control tree: stat ────────────────────────────────────────────────────

  defp control_stat(_backend, @mount), do: {:ok, dir_node()}

  defp control_stat(_backend, "/etc"), do: {:ok, dir_node()}

  defp control_stat(_backend, @mount <> "/tools"), do: {:ok, dir_node()}

  defp control_stat(backend, @mount <> "/tools/" <> name) do
    if visible_spec(backend, name),
      do: {:ok, control_node(true)},
      else: {:error, :enoent}
  end

  defp control_stat(_backend, @mount <> "/runtime"), do: {:ok, dir_node()}
  defp control_stat(_backend, @mount <> "/runtime/status"), do: {:ok, control_node(false)}

  defp control_stat(_backend, @mount <> "/runtime/sessions"), do: {:ok, dir_node()}

  defp control_stat(backend, @mount <> "/runtime/sessions/" <> id) do
    if id in session_ids(backend), do: {:ok, control_node(false)}, else: {:error, :enoent}
  end

  defp control_stat(_backend, @mount <> "/cache"), do: {:ok, dir_node()}
  defp control_stat(_backend, @mount <> "/cache/stats"), do: {:ok, control_node(false)}
  defp control_stat(_backend, @mount <> "/cache/flush"), do: {:ok, control_node(true)}

  defp control_stat(_backend, @mount <> "/config"), do: {:ok, dir_node()}

  defp control_stat(backend, @mount <> "/config/" <> name) do
    if toggle?(backend, name), do: {:ok, control_node(true)}, else: {:error, :enoent}
  end

  defp control_stat(_backend, _path), do: {:error, :enoent}

  # ── control tree: list ────────────────────────────────────────────────────

  defp control_list(_backend, "/", _cursor, _ctx) do
    {:ok, [dir_entry("etc")], nil}
  end

  defp control_list(_backend, "/etc", _cursor, _ctx), do: {:ok, [dir_entry("dev")], nil}

  defp control_list(_backend, @mount, _cursor, _ctx) do
    {:ok,
     [
       dir_entry("tools"),
       dir_entry("runtime"),
       dir_entry("cache"),
       dir_entry("config")
     ]
     |> Enum.sort_by(& &1.name), nil}
  end

  defp control_list(backend, @mount <> "/tools", cursor, _ctx) do
    entries =
      backend
      |> tool_specs()
      |> Enum.reject(& &1.hidden)
      |> Enum.map(
        &%{name: &1.definition.name, type: :control, size: 0, mtime: now_ms(), version: 1}
      )
      |> Enum.sort_by(& &1.name)

    Pagination.paginate(entries, cursor)
  end

  defp control_list(_backend, @mount <> "/runtime", _cursor, _ctx) do
    {:ok, [dir_entry("sessions"), dir_entry("status")], nil}
  end

  defp control_list(backend, @mount <> "/runtime/sessions", cursor, _ctx) do
    entries = Enum.map(session_ids(backend), &dir_entry/1)
    Pagination.paginate(entries, cursor)
  end

  defp control_list(_backend, @mount <> "/cache", _cursor, _ctx) do
    # flush/stats are control nodes (see control_stat/2) — the LIST view must
    # agree, or clients that trust list's type (mcp-mount's walker) queue them
    # as dirs and crash-loop on the enotdir.
    {:ok, [control_entry("flush"), control_entry("stats")], nil}
  end

  defp control_list(backend, @mount <> "/config", cursor, _ctx) do
    entries =
      backend
      |> toggle_names()
      |> Enum.sort()
      |> Enum.map(&%{name: &1, type: :control, size: 0, mtime: now_ms(), version: 1})

    Pagination.paginate(entries, cursor)
  end

  # File-type control nodes are not listable.
  defp control_list(_backend, @mount <> "/runtime/status", _cursor, _ctx), do: {:error, :enotdir}
  defp control_list(_backend, @mount <> "/cache/stats", _cursor, _ctx), do: {:error, :enotdir}
  defp control_list(_backend, @mount <> "/cache/flush", _cursor, _ctx), do: {:error, :enotdir}

  defp control_list(backend, @mount <> "/tools/" <> name, _cursor, _ctx) do
    if visible_spec(backend, name), do: {:error, :enotdir}, else: {:error, :enoent}
  end

  defp control_list(backend, @mount <> "/runtime/sessions/" <> id, _cursor, _ctx) do
    if id in session_ids(backend), do: {:error, :enotdir}, else: {:error, :enoent}
  end

  defp control_list(backend, @mount <> "/config/" <> name, _cursor, _ctx) do
    if toggle?(backend, name), do: {:error, :enotdir}, else: {:error, :enoent}
  end

  defp control_list(_backend, path, _cursor, _ctx) when is_binary(path), do: {:error, :enoent}

  # ── control tree: read ────────────────────────────────────────────────────

  defp control_read(backend, @mount <> "/tools/" <> name, ctx) do
    case visible_spec(backend, name) do
      nil ->
        {:error, :enoent}

      spec ->
        case take_buffer(backend, ctx, @mount <> "/tools/" <> name) do
          {:ok, json} -> {:ok, json, 1}
          :none -> {:ok, Jason.encode!(Tool.to_map(spec.definition)), 1}
        end
    end
  end

  defp control_read(backend, @mount <> "/runtime/status", _ctx) do
    server = server(backend)
    info = server.server_info()

    payload = %{
      "server" => %{"name" => info.name, "version" => info.version},
      "uptime_ms" => System.os_time(:millisecond) - booted_at(backend),
      "sessions" => length(session_ids(backend)),
      "capabilities" => server.__mcp__(:capabilities),
      "transports" => transports()
    }

    {:ok, Jason.encode!(payload), 1}
  end

  defp control_read(backend, @mount <> "/runtime/sessions/" <> id, _ctx) do
    if id in session_ids(backend) do
      {:ok, Jason.encode!(%{"id" => id}), 1}
    else
      {:error, :enoent}
    end
  end

  defp control_read(backend, @mount <> "/cache/stats", _ctx) do
    {:ok, Jason.encode!(cache_stats(backend)), 1}
  end

  defp control_read(backend, @mount <> "/cache/flush", _ctx) do
    {:ok,
     Jason.encode!(%{
       "hint" => "write any content to flush",
       "generation" => Cache.generation(backend)
     }), 1}
  end

  defp control_read(backend, @mount <> "/config/" <> name, _ctx) do
    case toggle_get(backend, name) do
      {:ok, value} -> {:ok, Jason.encode!(value), 1}
      {:error, errno} -> {:error, errno}
    end
  end

  defp control_read(_backend, path, _ctx) when is_binary(path),
    do: if(control_dir?(path), do: {:error, :eisdir}, else: {:error, :enoent})

  # ── control tree: write ───────────────────────────────────────────────────

  defp control_write(backend, @mount <> "/tools/" <> name, data, ctx) do
    invoke_tool(backend, name, data, ctx)
  end

  defp control_write(backend, @mount <> "/cache/flush", _data, _ctx) do
    # The dispatcher bumps the composed backend on every successful write; the
    # real backend's entries live under its own module, so bump that too.
    if mod = real(backend), do: Cache.bump_generation(mod)

    {:ok, %{control_node(true) | xattrs: %{"response" => "ok"}}}
  end

  defp control_write(backend, @mount <> "/config/" <> name, data, _ctx) do
    toggle_set(backend, name, data)
  end

  defp control_write(_backend, @mount <> "/runtime/status", _data, _ctx), do: {:error, :eacces}

  defp control_write(_backend, @mount <> "/runtime/sessions/" <> _id, _data, _ctx),
    do: {:error, :eacces}

  defp control_write(_backend, @mount <> "/cache/stats", _data, _ctx), do: {:error, :eacces}

  defp control_write(_backend, path, _data, _ctx) when is_binary(path),
    do: if(control_dir?(path), do: {:error, :eisdir}, else: {:error, :enoent})

  # ── tool invocation ───────────────────────────────────────────────────────

  defp invoke_tool(backend, name, data, ctx) do
    node_path = @mount <> "/tools/" <> name

    case visible_spec(backend, name) do
      nil ->
        {:error, :enoent}

      spec ->
        case parse_args(data) do
          {:ok, args} ->
            case gate(backend, spec, args, ctx) do
              :ok ->
                result =
                  server(backend).handle_call_tool(spec.definition.name, args, ctx)
                  |> Tools.normalize(nil)

                buffer_result(backend, ctx, node_path, serialize_result(result))
                {:ok, control_node(true)}

              {:error, _} ->
                {:error, :eacces}
            end

          _ ->
            {:error, :eio}
        end
    end
  end

  defp serialize_result(%ToolResult{} = result), do: Jason.encode!(ToolResult.to_map(result))

  defp serialize_result(%Error{} = error),
    do: Jason.encode!(%{"error" => %{"code" => error.code, "message" => error.message}})

  defp parse_args(data) do
    with {:ok, decoded} <- Jason.decode(data),
         :ok <- if(is_map(decoded), do: :ok, else: {:error, :eio}) do
      case decoded do
        %{"args" => args} when is_map(args) -> {:ok, args}
        %{"args" => _} -> {:error, :eio}
        _ -> {:ok, %{}}
      end
    end
  end

  defp gate(backend, spec, args, ctx) do
    case backend.__mcp_vfs_control__(:tool_gate) do
      nil ->
        claims_gate(spec, ctx)

      {m, f} ->
        apply(m, f, [spec.definition.name, args, ctx])

      {m, f, extra} ->
        apply(m, f, List.wrap(extra) ++ [spec.definition.name, args, ctx])
    end
  end

  defp claims_gate(spec, ctx) do
    claims = ctx.assigns[:auth_claims]
    allowlist = claims && (claims["vfs_tool_allowlist"] || claims[:vfs_tool_allowlist])

    cond do
      is_list(allowlist) ->
        if spec.definition.name in allowlist, do: :ok, else: {:error, :eacces}

      destructive?(spec) ->
        {:error, :eacces}

      true ->
        :ok
    end
  end

  defp destructive?(spec) do
    case spec.definition.annotations do
      nil -> false
      annotations -> annotations[:destructive_hint] == true
    end
  end

  # Per-connection result buffer. Control operations are rare, so a
  # `:persistent_term` slot (one per {backend, session, node}) is enough — the
  # read consumes it, so there is no accumulation.
  defp buffer_result(backend, ctx, path, json) do
    :persistent_term.put({__MODULE__, :result, backend, session_key(ctx), path}, json)
  end

  defp take_buffer(backend, ctx, path) do
    key = {__MODULE__, :result, backend, session_key(ctx), path}

    case :persistent_term.get(key, :none) do
      :none ->
        :none

      json ->
        :persistent_term.erase(key)
        {:ok, json}
    end
  end

  defp session_key(%Ctx{session_id: id}) when is_binary(id), do: {:sid, id}
  defp session_key(%Ctx{session: pid}) when is_pid(pid), do: {:pid, pid}
  defp session_key(_), do: :default

  # ── config toggles ────────────────────────────────────────────────────────

  defp toggle_names(backend), do: @built_in_toggles ++ Enum.map(toggles(backend), & &1.name)

  defp toggle?(backend, name), do: name in toggle_names(backend)

  defp toggle_get(backend, "trace"), do: {:ok, trace?(backend)}

  defp toggle_get(_backend, "cache_enabled"),
    do: {:ok, Application.get_env(:noizu_mcp, :vfs_cache_enabled, true)}

  defp toggle_get(backend, name) do
    case Enum.find(toggles(backend), &(&1.name == name)) do
      %{get: {m, f, args}} -> {:ok, apply(m, f, args)}
      _ -> {:error, :enoent}
    end
  end

  defp toggle_set(backend, "trace", data) do
    with {:ok, value} when is_boolean(value) <- Jason.decode(data) do
      :persistent_term.put({__MODULE__, :trace, backend}, value)
      {:ok, control_node(true)}
    else
      _ -> {:error, :eio}
    end
  end

  defp toggle_set(_backend, "cache_enabled", data) do
    with {:ok, value} when is_boolean(value) <- Jason.decode(data) do
      Application.put_env(:noizu_mcp, :vfs_cache_enabled, value)
      {:ok, control_node(true)}
    else
      _ -> {:error, :eio}
    end
  end

  defp toggle_set(backend, name, data) do
    case Enum.find(toggles(backend), &(&1.name == name)) do
      nil ->
        {:error, :enoent}

      %{set: {m, f, args}} ->
        with {:ok, value} <- Jason.decode(data),
             :ok <- apply(m, f, args ++ [value]) do
          {:ok, control_node(true)}
        else
          _ -> {:error, :eio}
        end
    end
  end

  defp toggles(backend), do: backend.__mcp_vfs_control__(:toggles) || []

  # ── introspection data ────────────────────────────────────────────────────

  defp server(backend), do: backend.__mcp_vfs_control__(:server)

  defp real(backend), do: backend.__mcp_vfs_control__(:real)

  defp tool_specs(backend) do
    server = server(backend)
    Tools.expand(server.__mcp__(:tools))
  rescue
    _ -> []
  end

  defp visible_spec(backend, name) do
    backend
    |> tool_specs()
    |> Enum.reject(& &1.hidden)
    |> Enum.find(&(&1.definition.name == name))
  end

  defp session_ids(backend) do
    registry = Module.concat(server(backend), Registry)

    if Process.whereis(registry) do
      Registry.select(registry, [{{{:session, :"$1"}, :_, :_}, [], [:"$1"]}])
    else
      []
    end
  rescue
    _ -> []
  end

  @transports [
    {Noizu.MCP.Transport.Stdio, "stdio"},
    {Noizu.MCP.Transport.SSE, "sse"},
    {Noizu.MCP.Transport.StreamableHTTP, "streamable_http"},
    {Noizu.MCP.Transport.VFSSocket, "vfs_socket"}
  ]

  defp transports do
    for {mod, name} <- @transports, Code.ensure_loaded?(mod), do: name
  end

  defp cache_stats(backend) do
    real = real(backend)

    %{
      "generation" => %{
        # The dispatcher caches under the composed module the server registers.
        "composed" => Cache.generation(backend),
        "real" => real && Cache.generation(real)
      },
      "entries" => %{
        "composed" => cache_entries(backend),
        "real" => real && cache_entries(real)
      },
      "enabled" => Application.get_env(:noizu_mcp, :vfs_cache_enabled, true)
    }
  end

  # Reads Noizu.MCP.VFS.Cache's persistent_term layout directly — the entry
  # map is private to the cache, so this is introspection, not API.
  defp cache_entries(module) do
    :persistent_term.get({:noizu_mcp_vfs_cache, module}, {0, %{}}) |> elem(1) |> map_size()
  end

  defp booted_at(backend) do
    key = {__MODULE__, :booted_at, backend}

    case :persistent_term.get(key, :none) do
      :none ->
        now = System.os_time(:millisecond)
        :persistent_term.put(key, now)
        now

      at ->
        at
    end
  end

  # ── safety + helpers ──────────────────────────────────────────────────────

  defp readonly?(backend) do
    server(backend).__mcp__(:opts)[:vfs_readonly] == true
  end

  defp trace(backend, op, path) do
    if trace?(backend), do: Logger.debug("[vfs-control] #{op} #{path}")
  end

  defp trace?(backend), do: :persistent_term.get({__MODULE__, :trace, backend}, false)

  defp control_path?("/etc"), do: true
  defp control_path?(@mount), do: true
  defp control_path?("/etc/dev" <> _rest), do: true
  defp control_path?(_), do: false

  defp control_dir?("/"), do: true
  defp control_dir?("/etc"), do: true
  defp control_dir?(@mount), do: true

  defp control_dir?(@mount <> "/" <> rest),
    do: rest in ["tools", "runtime", "cache", "config"] or dir_child?(rest)

  defp control_dir?(_), do: false

  defp dir_child?("runtime/sessions"), do: true
  defp dir_child?(_), do: false

  defp merge_root(backend, cursor, ctx) do
    case real(backend).list("/", cursor, ctx) do
      {:ok, entries, next_cursor} ->
        {:ok, [dir_entry("etc") | entries], next_cursor}

      {:error, _} = error ->
        error
    end
  end

  # Delegation outside the control tree. Without a `:real` backend the tree is
  # standalone and every non-control path is `:enoent`.
  defp delegate(backend, op, args) do
    case real(backend) do
      nil -> {:error, :enoent}
      mod -> apply(mod, op, args)
    end
  end

  # ── node builders ─────────────────────────────────────────────────────────

  defp dir_node, do: %VFS{type: :dir, mtime: now_ms(), version: 1}

  defp control_node(writable),
    do: %VFS{type: :control, mtime: now_ms(), version: 1, writable: writable}

  defp dir_entry(name), do: %{name: name, type: :dir, size: 0, mtime: now_ms(), version: 1}

  defp control_entry(name),
    do: %{name: name, type: :control, size: 0, mtime: now_ms(), version: 1}
  defp now_ms, do: System.os_time(:millisecond)
end
