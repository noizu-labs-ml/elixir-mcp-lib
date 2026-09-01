defmodule Noizu.MCP.VFS.Null do
  @moduledoc """
  The empty read-only VFS: a bare `"/"` directory and nothing else.

  Useful as a placeholder registration (`vfs Noizu.MCP.VFS.Null`) and as the
  base case for the M2 transport — every path other than `"/"` is `:enoent`,
  and every mutating operation is `:enosys`, so servers carrying a Null VFS
  advertise `vfs` but not `vfs_write`.
  """

  use Noizu.MCP.VFS

  @impl true
  def stat("/", _ctx), do: {:ok, %Noizu.MCP.VFS{type: :dir, mtime: 0, version: 1}}

  def stat(_path, _ctx), do: {:error, :enoent}

  @impl true
  def list("/", _cursor, _ctx), do: {:ok, [], nil}

  def list(_path, _cursor, _ctx), do: {:error, :enotdir}

  @impl true
  def read("/", _ctx), do: {:error, :eisdir}

  def read(_path, _ctx), do: {:error, :enoent}
end
