# pg_mcp spike fixture server (PRD-6 §7.5).
#
# Boots `Noizu.MCP.Fixtures.Server` behind two Bandit listeners:
#
#   * open  — no auth (spike uses `auth 'none'` against 127.0.0.1, ADR-004)
#   * auth  — bearer via ApiKeyVerifier with two static keys, so two Postgres
#             roles can present two different principals (AC-6.6) and a wrong
#             token can be shown to raise 42501 (AC-6.5)
#
# Prints `SPIKE_PORTS <json>` on stdout when both listeners are up, then idles.
# Run from the repo root:  mix run pg/pg_mcp/spike/server.exs

{:ok, _} = Application.ensure_all_started(:bandit)
Noizu.MCP.Test.ensure_server_started(Noizu.MCP.Fixtures.Server)

{:ok, open_pid} =
  Bandit.start_link(
    plug: {Noizu.MCP.Transport.StreamableHTTP.Plug, server: Noizu.MCP.Fixtures.Server},
    port: 0,
    ip: :loopback,
    startup_log: false
  )

{:ok, {_ip, open_port}} = ThousandIsland.listener_info(open_pid)

keys = [
  {"mcp_live_spike_a", %{"sub" => "spike_a"}},
  {"mcp_live_spike_b", %{"sub" => "spike_b"}}
]

auth = [
  verifier:
    {Noizu.MCP.Auth.ChainVerifier,
     [verifiers: [{Noizu.MCP.Auth.ApiKeyVerifier, keys: keys}]]}
]

{:ok, auth_pid} =
  Bandit.start_link(
    plug:
      {Noizu.MCP.Transport.StreamableHTTP.Plug,
       server: Noizu.MCP.Fixtures.Server, auth: auth},
    port: 0,
    ip: :loopback,
    startup_log: false
  )

{:ok, {_ip, auth_port}} = ThousandIsland.listener_info(auth_pid)

# Black-hole listener: accepts TCP connections and never answers, so the
# extension's FR-6.12 total-deadline timeout can be measured against loopback
# (a non-loopback unroutable host is rightly rejected at CREATE SERVER).
{:ok, blackhole} =
  :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: :loopback, backlog: 5])

{:ok, blackhole_port} = :inet.port(blackhole)

spawn(fn ->
  loop = fn loop ->
    case :gen_tcp.accept(blackhole) do
      {:ok, sock} ->
        # Hold the socket open; never read or write.
        loop.(loop)
      _ ->
        :ok
    end
  end

  loop.(loop)
end)

IO.puts(
  "SPIKE_PORTS " <>
    Jason.encode!(%{open: open_port, auth: auth_port, blackhole: blackhole_port})
)

Process.sleep(:infinity)
