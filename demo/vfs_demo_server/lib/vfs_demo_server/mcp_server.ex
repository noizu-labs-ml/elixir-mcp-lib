defmodule VfsDemoServer.McpServer do
  @moduledoc """
  Minimal MCP server module exposing `VfsDemoServer.Backend` as the server's
  `vfs` capability — everything the lib's `Noizu.MCP.Transport.VFSWS`
  transport needs to resolve the backend and build per-connection contexts.
  """

  use Noizu.MCP.Server, name: "vfs-demo", version: "1.0.0"

  vfs(VfsDemoServer.Backend)
end
