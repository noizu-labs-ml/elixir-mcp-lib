# Local Surface: VFS Mounts, Inspector, Transports

Detail for T-009…T-011.

## VFS mount daemons (T-010)

Two paths put an MCP server's VFS on the local desktop:

- `daemon/mcp_mount` — Elixir escript, WebSocket transport to the server.
- `fuse/` — Go FUSE daemon over a unix socket.

Server side, `vfs/auth` requires an API-key handshake (validated through the
configured token verifier) before any other method; a second `vfs/auth` and
any pre-auth method are refused. Residual exposure is the local trust
boundary: the **unix socket's accessibility rides on filesystem permissions**
— operators must restrict the socket directory (and who may run the daemon).
The FUSE mount itself makes remote content executable-adjacent local files;
treat mounted data as untrusted input (same rule as any network fetch).

## Inspector (T-009)

- Bandit bound to `127.0.0.1` only; localhost `Origin` check rejects
  cross-origin browser requests; random per-run bearer token.
- Residual: any process/user on the same machine can read the token the same
  way the launching shell can. Dev tool, not a production surface — never
  expose it through a proxy.
- `TapTransport` mirrors raw frames into the History tab — running the
  Inspector against a production credential puts those frames on localhost
  display; prefer scratch credentials.

## Transport DoS posture (T-011)

- Task-per-request: handler code runs in supervised tasks; ping,
  cancellation, and progress stay responsive during long tool calls.
- EventStore is a bounded ETS ring — SSE floods cannot grow memory unboundedly;
  `Last-Event-ID` resumption is served from the same bounded buffer.
- JSON-RPC batching is not implemented (parser-level flood vector removed).
- Host/plug responsibility: request body limits, timeouts, connection caps on
  the Streamable HTTP Plug; the library does not impose its own rate limits.
