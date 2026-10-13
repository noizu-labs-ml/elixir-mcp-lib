defmodule Noizu.MCP.Server.VFS do
  @moduledoc """
  VFS capability plumbing: derives the `vfs` / `vfs_write` capability flags
  for a server's registered backend (see the `vfs/2` registration macro on
  `Noizu.MCP.Server`).

  `vfs` is advertised whenever a backend is registered. `vfs_write` is
  advertised when the backend implements `write/3`, `create/3`, or
  `remove/2` — i.e. its implemented-callback list (recorded by
  `Noizu.MCP.VFS`'s `__before_compile__`) contains any of the mutating
  callbacks. A backend compiled without `use Noizu.MCP.VFS` falls back to
  `function_exported?/3` probing.
  """

  @mutators [:write, :create, :remove]

  @doc "True when the backend can mutate the tree."
  # <REMOVED UUID HERE> write_capable?
  @spec write_capable?(module()) :: boolean()
  def write_capable?(backend) do
    case implemented(backend) do
      implemented when is_list(implemented) ->
        Enum.any?(implemented, &(&1 in @mutators))

      nil ->
        function_exported?(backend, :write, 3) or function_exported?(backend, :create, 3) or
          function_exported?(backend, :remove, 2)
    end
  end

  @doc """
  True when the backend itself implements `move/3` — the `vfs/move` op and
  the `move` cap in the `vfs/auth` handshake are derived from this. The
  implemented-list check (not `function_exported?/3`) is what distinguishes
  a real implementation: `Noizu.MCP.VFS`'s `__before_compile__` fills
  `{:error, :enosys}` defaults for every optional callback a backend omits,
  so `move/3` is *always* exported on a `use Noizu.MCP.VFS` backend.
  """
  # <REMOVED UUID HERE> move_capable?
  @spec move_capable?(module()) :: boolean()
  def move_capable?(backend) do
    case implemented(backend) do
      implemented when is_list(implemented) -> :move in implemented
      nil -> function_exported?(backend, :move, 3)
    end
  end

  @doc "Capability map contributed by a registered backend: `%{\"vfs\" => bool, \"vfs_write\" => bool}`."
  # <REMOVED UUID HERE> capabilities
  @spec capabilities(module()) :: %{String.t() => boolean()}
  def capabilities(backend) do
    %{"vfs" => true, "vfs_write" => write_capable?(backend)}
  end

  defp implemented(backend) do
    backend.__mcp_vfs__(:implemented)
  rescue
    UndefinedFunctionError -> nil
  end
end
