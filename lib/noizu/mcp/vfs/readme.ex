defmodule Noizu.MCP.VFS.Readme do
  @moduledoc """
  The generated `/README.md` every VFS mount serves at its root.

  `Noizu.MCP.Server.Features.VFS` — the layer every server op and wire
  transport (`vfs_socket`, `vfs_ws`) dispatches through — serves the node
  whenever the registered backend does not provide one itself:

    * `stat` / `read` fall back to the generated document on `:enoent`
      (backend-wins: a backend that serves its own `/README.md` is untouched)
    * first-page root listings gain a `README.md` entry when the backend does
      not list one
    * `write` / `create` / `remove` on the reserved path are `:erofs` unless
      the backend owns a writable node there

  Content resolution:

    1. Server opt `vfs_readme:` — a literal binary, or `{mod, fun}` invoked
       `apply(mod, fun, [ctx])` and returning a binary (host-specific docs).
       Resolved through the backend's composing `Noizu.MCP.VFS.Control`
       server, so it applies to composed mounts.
    2. The generated document: a section per registered VFS backend (name +
       description), the `/etc/dev` control-plane guide on composed mounts,
       and the transport/auth summary.

  Backends customize their section with the `__mcp_vfs__(:describe)` callback
  (`use Noizu.MCP.VFS` defaults it to `nil`); composed control backends fall
  back to a blurb naming their `:real` backend. The document is computed
  lazily per cache miss — nothing is precomputed at compile or registration
  time — and rides the normal dispatcher cache: stable and re-readable,
  refreshed whenever a write bumps the generation.
  """

  alias Noizu.MCP.Ctx
  alias Noizu.MCP.VFS
  alias Noizu.MCP.VFS.Control

  @path "/README.md"

  # ── path + node helpers ───────────────────────────────────────────────────

  @doc "The reserved self-documentation path."
  # ⟦𓆒⟧ path
  @spec path() :: String.t()
  def path, do: @path

  @doc "True when `path` is the reserved self-documentation node."
  # ⟦𓆒⟧ path?
  @spec path?(String.t()) :: boolean()
  def path?(path), do: path == @path

  @doc "Stat node for the generated document — always `writable: false`."
  # ⟦𓆒⟧ node
  @spec node(module(), Ctx.t()) :: VFS.t()
  def node(backend, ctx) do
    %VFS{
      type: :file,
      size: byte_size(content(backend, ctx)),
      mtime: 0,
      version: 1,
      writable: false,
      xattrs: %{"generated" => "true"}
    }
  end

  @doc "List entry for the generated document."
  # ⟦𓆒⟧ entry
  @spec entry(module(), Ctx.t()) :: map()
  def entry(backend, ctx) do
    %{
      name: "README.md",
      type: :file,
      size: byte_size(content(backend, ctx)),
      mtime: 0,
      version: 1
    }
  end

  @doc """
  Prepend the generated entry to a root listing unless the backend already
  lists its own `README.md`.
  """
  # ⟦𓆒⟧ prepend
  @spec prepend(module(), [map()], Ctx.t()) :: [map()]
  def prepend(backend, entries, ctx) when is_list(entries) do
    if Enum.any?(entries, &(&1[:name] == "README.md")) do
      entries
    else
      [entry(backend, ctx) | entries]
    end
  end

  @doc """
  True when `path` may not be written through the dispatcher — the reserved
  path, unless the backend serves a writable node there.
  """
  # ⟦𓆒⟧ reserved?
  @spec reserved?(module(), String.t(), Ctx.t()) :: boolean()
  def reserved?(backend, path, ctx) do
    path?(path) and backend_node(backend, ctx) == nil
  end

  # Backend-wins: a writable backend-owned node means the backend owns the
  # path outright and the reservation does not apply.
  defp backend_node(backend, ctx) do
    case backend.stat(@path, ctx) do
      {:ok, %VFS{writable: true}} -> :owned
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # ── content ───────────────────────────────────────────────────────────────

  @doc "The README content for `backend`'s mount: the `vfs_readme` override when set, else generated."
  # ⟦𓆒⟧ content
  @spec content(module(), Ctx.t()) :: String.t()
  def content(backend, ctx) do
    case override(backend, ctx) do
      {:ok, binary} when is_binary(binary) -> binary
      _ -> render(backend)
    end
  end

  defp override(backend, ctx) do
    server = composing_server(backend)

    case server && server.__mcp__(:opts)[:vfs_readme] do
      binary when is_binary(binary) ->
        {:ok, binary}

      {m, f} when is_atom(m) and is_atom(f) ->
        {:ok, apply(m, f, [ctx])}

      _ ->
        :none
    end
  end

  @doc "The generated document."
  # ⟦𓆒⟧ render
  @spec render(module()) :: String.t()
  def render(backend) do
    server = composing_server(backend)

    [
      header(backend, server),
      backends_section(backend, server),
      control_section(server),
      self_section(),
      transports_section(server)
    ]
    |> IO.iodata_to_binary()
  end

  # The composing server of a `Noizu.MCP.VFS.Control` backend — plain
  # backends have no reverse mapping to their server, so their mounts always
  # serve the generated document.
  defp composing_server(backend) do
    if function_exported?(backend, :__mcp_vfs_control__, 1) do
      backend.__mcp_vfs_control__(:server)
    end
  rescue
    _ -> nil
  end

  # ── sections ──────────────────────────────────────────────────────────────

  defp header(backend, server) do
    title =
      case server && server_info(server) do
        %{name: name, version: version} -> "#{name} (v#{version})"
        _ -> inspect(backend)
      end

    """
    # #{title} — virtual filesystem

    This mount is self-documenting. `/README.md` (this file) is generated by
    the server and is read-only. Operate paths with the `vfs/*` extension
    operations — `vfs/stat`, `vfs/list`, `vfs/read`, `vfs/write`,
    `vfs/create`, `vfs/remove`, `vfs/search`, `vfs/xattr`.
    """
  end

  defp server_info(server) do
    server.server_info()
  rescue
    _ -> nil
  end

  defp backends_section(backend, server) do
    registered =
      case server && server.__mcp__(:vfs) do
        [{_, _} | _] = registrations -> Enum.map(registrations, &elem(&1, 0))
        _ -> [backend]
      end

    ["\n## Backends\n\n", Enum.map(registered, &backend_blurb/1)]
  end

  defp backend_blurb(mod) do
    ["### `#{inspect(mod)}`\n\n", describe(mod), real_note(mod), "\n"]
  end

  # A backend's own `__mcp_vfs__(:describe)` wins; composed control backends
  # fall back to a blurb naming their `:real` backend.
  defp describe(mod) do
    text =
      case safe_describe(mod) do
        text when is_binary(text) and text != "" -> String.trim_trailing(text, "\n")
        _ -> fallback_describe(mod)
      end

    [text, "\n\n"]
  end

  defp safe_describe(mod) do
    if function_exported?(mod, :__mcp_vfs__, 1), do: mod.__mcp_vfs__(:describe)
  rescue
    _ -> nil
  end

  defp fallback_describe(mod) do
    if composed?(mod) do
      "Composed control backend — serves the `/etc/dev/**` control tree and delegates every other path to the real backend."
    else
      "Virtual filesystem backend."
    end
  end

  defp real_note(mod) do
    if composed?(mod) do
      real = mod.__mcp_vfs_control__(:real)
      ["- delegates to `#{inspect(real)}` — ", describe(real)]
    else
      []
    end
  end

  defp composed?(mod) do
    function_exported?(mod, :__mcp_vfs_control__, 1) and mod.__mcp_vfs_control__(:real) != nil
  end

  defp control_section(nil), do: []

  defp control_section(_server) do
    """

    ## Control plane — `/etc/dev`

    | Path | Writable | Use |
    | ---- | -------- | --- |
    | `/etc/dev/tools/<tool>` | yes | read a tool's JSON definition; write `{"args": {...}}` to invoke it — the result is buffered and returned by the next read of the node |
    | `/etc/dev/runtime/status` | no | uptime, session count, serverInfo, capabilities, transports |
    | `/etc/dev/runtime/sessions/<id>` | no | per-session info |
    | `/etc/dev/cache/stats` | no | dispatcher-cache generation + entry counts |
    | `/etc/dev/cache/flush` | yes | write anything to drop every cached VFS read |
    | `/etc/dev/config/<toggle>` | yes | read the current value as JSON; write JSON to apply it (`trace`, `cache_enabled`, plus server-defined toggles) |

    Tool invocations run through the server's normal tool path — authz and
    gate hooks apply — and destructive tools fail closed without an explicit
    gate or allowlist.
    """
  end

  defp self_section do
    """

    ## This file

    `/README.md` is generated per mount and read-only — writes fail with
    `:erofs`. Hosts replace it with the `vfs_readme:` server opt (a binary,
    or `{mod, fun}` called with the ctx); backends customize their blurb with
    the `__mcp_vfs__(:describe)` callback.
    """
  end

  defp transports_section(nil), do: []

  defp transports_section(_server) do
    transports = Enum.join(Control.transports(), ", ")

    """

    ## Transports & auth

    - available transports: #{transports}
    - the unix-socket transport (`vfs_socket`) binds `0600` and requires the
      `vfs/auth` handshake before any operation — expose mounts only where
      trusted clients can reach them.
    """
  end
end
