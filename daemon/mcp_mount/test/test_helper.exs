ExUnit.start()

# Real-server e2e tests (IntegrationRealWSTest) run only when explicitly
# included AND a server URL is provided:
#   MCP_MOUNT_E2E_URL=ws://host:port/vfs mix test --include e2e_real
ExUnit.configure(exclude: [e2e_real: true])

if System.get_env("MCP_MOUNT_E2E_URL") do
  ExUnit.configure(include: [e2e_real: true])
end
