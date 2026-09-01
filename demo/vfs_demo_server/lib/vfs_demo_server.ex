defmodule VfsDemoServer do
  @moduledoc """
  Demo VFS server: a YAML-seeded static tree (`priv/seed/tree.yaml`) served
  over the MCP VFS WebSocket protocol — reference implementation and test
  fixture for the mcp-vfs mounter. See the repo README.
  """

  @doc "Auth token for `vfs/auth` (env VFS_DEMO_TOKEN, default \"demo-token\")."
  def token do
    Application.get_env(:vfs_demo_server, :token) || System.get_env("VFS_DEMO_TOKEN") ||
      "demo-token"
  end

  @doc """
  Bandit plug options for the lib's real `Noizu.MCP.Transport.VFSWS` transport:
  a minimal MCP server module exposing the demo backend as its `vfs`
  capability, plus an API-key verifier binding the single demo token to the
  `"demo"` identity.
  """
  def ws_plug_opts do
    verifier_opts = [
      keys: [{token(), %{"sub" => "demo"}}],
      default_claims: %{"scope" => "vfs"}
    ]

    [
      server: VfsDemoServer.McpServer,
      auth: [verifier: {Noizu.MCP.Auth.ApiKeyVerifier, verifier_opts}]
    ]
  end
end
