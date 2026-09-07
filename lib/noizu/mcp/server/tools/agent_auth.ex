defmodule Noizu.MCP.Server.Tools.AgentAuth do
  @moduledoc """
  MCP-tool face of anonymous keypair authentication for agents
  (`Noizu.MCP.Auth.Server.Agent`).

  An autonomous agent has no browser to click a consent screen and no operator
  to type a password — but it does have a keypair, and every step of that
  flow is naturally something an agent can drive itself by calling tools. This
  toolkit wraps `Noizu.MCP.Auth.Server.Agent`'s four-step flow one-to-one, plus
  key management, as seven tools:

      tool Noizu.MCP.Server.Tools.AgentAuth

  ## The flow, tool by tool

      1. auth_start_session   — open a session for your public key (no auth)
      2. auth_register_agent  — create a `pending` account (skip if returning)
      3. auth_authenticate    — trade a signed assertion for an access token
      4. auth_whoami / auth_list_keys / auth_add_key / auth_revoke_key
         — everything after step 3, using the token from it

  ## Identity is never an argument

  `auth_whoami`, `auth_list_keys`, `auth_add_key`, and `auth_revoke_key` all
  act on "the caller's own account" — resolved **only** from the verified
  claims on `ctx.auth` (the access token `auth_authenticate` handed back).
  None of them accept an `account_id` (or similar) argument: a tool that let
  the caller name its own account would let any agent act as any other. A
  caller with no verified token, or a token that isn't its own, simply has no
  account to look up — see `Noizu.MCP.Auth.Server.Agent.caller_account/2`.

  `auth_add_key` and `auth_revoke_key` additionally require the token to have
  been obtained by key signature (`amr: ["sig"]`, i.e. via `auth_authenticate`,
  never a password- or admin-issued token) — enforced by the facade itself,
  not re-implemented here.

  ## Errors

  Every facade failure surfaces as a tool execution error (`isError: true`)
  whose text is `"<code>: <description>"`, where `<code>` is the exact atom
  from `Noizu.MCP.Auth.Server.Agent.error_code()` (e.g. `account_pending`,
  `key_limit_reached`) so a calling agent can branch on it programmatically
  rather than parsing prose.

  ## Configuration

  These tools need the host's `%Noizu.MCP.Auth.Server.Config{}` — the same one
  passed to `Noizu.MCP.Auth.Server.Router` and friends. Register it under
  `agent_auth_config:` in the server's `opts`, alongside how other tools reach
  server-scoped configuration (`:acl`, `:vfs_readonly`, `:principal`, ...):

      use Noizu.MCP.Server,
        name: "my-agent-host",
        opts: [agent_auth_config: MyApp.MCPAuthConfig.as_opts()]

      tool Noizu.MCP.Server.Tools.AgentAuth
  """

  use Noizu.MCP.Server.Toolkit, category: "Auth"

  alias Noizu.MCP.Auth.Principal
  alias Noizu.MCP.Auth.Server.Agent
  alias Noizu.MCP.Auth.Server.Config

  # ── step 1 ───────────────────────────────────────────────────────────────

  @mcp description:
         "Open an anonymous authentication session for this agent's Ed25519 " <>
           "keypair — no credentials required. Call this FIRST, before any other " <>
           "auth_* tool. The response's `registration_required` field tells you " <>
           "whether to call auth_register_agent next (new key) or go straight to " <>
           "auth_authenticate (a key that already has an account).",
       # Not read-only: it persists a session row. Marking it read-only would tell
       # a client this call is free to retry or replay, and the whole point of the
       # session is that its nonce is spent exactly once.
       annotations: [idempotent_hint: false],
       input: [
         public_key: [
           type: :string,
           required: true,
           description: "Base64 or base64url-encoded Ed25519 public key for this agent."
         ],
         alg: [
           type: :string,
           default: "ed25519",
           description: "Key algorithm. Currently only \"ed25519\" is supported."
         ]
       ]
  def auth_start_session(args, ctx) do
    with {:ok, config} <- config(ctx) do
      respond(Agent.start_session(config, stringify(args)))
    end
  end

  # ── step 2 ───────────────────────────────────────────────────────────────

  @mcp description:
         "Register a new agent account, binding it to the key from your current " <>
           "auth_start_session. Call this only when that call reported " <>
           "registration_required: true — a key that already has an account skips " <>
           "straight to auth_authenticate. The new account starts in `pending` " <>
           "status until a host admin approves it; you can still authenticate " <>
           "while pending.",
       input: [
         session_token: [
           type: :string,
           required: true,
           description: "The session_token returned by auth_start_session."
         ],
         handle: [
           type: :string,
           required: true,
           description: "Unique handle for this account: 3-32 characters of a-z, 0-9, - or _."
         ],
         kind: [
           type: :enum,
           values: [:agent, :human],
           default: :agent,
           description: "What kind of account this is."
         ],
         display_name: [
           type: :string,
           description: "Optional human-readable display name."
         ]
       ]
  def auth_register_agent(args, ctx) do
    with {:ok, config} <- config(ctx) do
      params = stringify(args)
      session_token = Map.get(params, "session_token")
      respond(Agent.register(config, session_token, Map.delete(params, "session_token")))
    end
  end

  # ── step 3 ───────────────────────────────────────────────────────────────

  @mcp description:
         "Exchange a signed JWT assertion (RFC 7523 jwt-bearer grant) for an " <>
           "access token. Call this after auth_start_session (a returning key) or " <>
           "auth_register_agent (a new key) to obtain the bearer token that " <>
           "authenticates auth_whoami, auth_list_keys, auth_add_key, " <>
           "auth_revoke_key, and this server's other tools.",
       input: [
         assertion: [
           type: :string,
           required: true,
           description:
             "The signed JWT assertion proving possession of the key bound to your " <>
               "session (sub/sid/nonce/aud claims per the auth-server docs)."
         ],
         resource: [
           type: :string,
           description:
             "Optional resource URI to scope the minted token to one MCP mount. " <>
               "Omit for a general authorization-server-scoped token."
         ]
       ]
  def auth_authenticate(args, ctx) do
    with {:ok, config} <- config(ctx) do
      params = stringify(args)
      assertion = Map.get(params, "assertion")
      respond(Agent.authenticate(config, assertion, Map.delete(params, "assertion")))
    end
  end

  # ── step 4: identity + key management ───────────────────────────────────

  @mcp description:
         "Return the caller's own account, active keys, granted scopes, and how " <>
           "the current token was obtained (amr). Identity is read from your " <>
           "access token — there is no way to look up another account. Call this " <>
           "to confirm which scopes you hold or whether your account is still " <>
           "`pending`.",
       annotations: [read_only_hint: true]
  def auth_whoami(_args, ctx) do
    with {:ok, config} <- config(ctx) do
      respond(Agent.whoami(config, claims(ctx)))
    end
  end

  @mcp description:
         "List every key on the caller's own account, including revoked ones. " <>
           "Identity is read from your access token, not an argument. Call this " <>
           "before auth_add_key or auth_revoke_key to see current fingerprints.",
       annotations: [read_only_hint: true]
  def auth_list_keys(_args, ctx) do
    with {:ok, config} <- config(ctx) do
      respond(Agent.list_keys(config, claims(ctx)))
    end
  end

  @mcp description:
         "Add a new key to the caller's own account (identity from your access " <>
           "token, not an argument). Requires two proofs — proof_new (the new key " <>
           "signing its own thumbprint) and proof_existing (a key already on the " <>
           "account signing the new key's thumbprint) — and requires that your " <>
           "current access token was obtained via auth_authenticate (amr: sig); a " <>
           "password- or admin-issued token is refused. Call this to rotate or add " <>
           "a backup key before the current one is lost.",
       input: [
         public_key: [
           type: :string,
           required: true,
           description: "Base64 or base64url-encoded Ed25519 public key to add."
         ],
         alg: [
           type: :string,
           default: "ed25519",
           description: "Key algorithm. Currently only \"ed25519\" is supported."
         ],
         label: [
           type: :string,
           description: "Optional human-readable label for the new key."
         ],
         proof_new: [
           type: :string,
           required: true,
           description:
             "Self-signed JWS by the NEW key, over op: \"add_key\" and its own thumbprint."
         ],
         proof_existing: [
           type: :string,
           required: true,
           description:
             "JWS signed by a key ALREADY on your account, over op: \"add_key\" and the " <>
               "new key's thumbprint."
         ]
       ]
  def auth_add_key(args, ctx) do
    with {:ok, config} <- config(ctx) do
      respond(Agent.add_key(config, claims(ctx), stringify(args)))
    end
  end

  @mcp description:
         "Revoke one of the caller's own keys by fingerprint (identity from your " <>
           "access token, not an argument). Requires that your current access " <>
           "token was obtained via auth_authenticate (amr: sig). Refuses to revoke " <>
           "the account's last active key. Call this after a key is compromised or " <>
           "retired.",
       annotations: [destructive_hint: true],
       input: [
         fingerprint: [
           type: :string,
           required: true,
           description: "Fingerprint of the key (on your own account) to revoke."
         ]
       ]
  def auth_revoke_key(%{fingerprint: fingerprint}, ctx) do
    with {:ok, config} <- config(ctx) do
      respond(Agent.revoke_key(config, claims(ctx), fingerprint))
    end
  end

  # ── shared helpers ───────────────────────────────────────────────────────

  # The server-scoped `%Config{}`, registered by the host under
  # `agent_auth_config:` in `use Noizu.MCP.Server, opts: [...]` — the same
  # `__mcp__(:opts)` surface `:acl`, `:vfs_readonly` and `:principal` already
  # use for per-server configuration reachable from a running tool.
  defp config(ctx) do
    case ctx.server && ctx.server.__mcp__(:opts)[:agent_auth_config] do
      %Config{} = config ->
        {:ok, config}

      _ ->
        {:error,
         "agent_auth_not_configured: this server has no agent_auth_config registered " <>
           "in its opts."}
    end
  end

  # The caller's verified token claims — NEVER an argument. `ctx.auth` is a
  # `%Noizu.MCP.Auth.Principal{}` (or `nil`, the only anonymous identity) whose
  # `claims` field is the raw string-keyed JWT claims map `Agent`'s facade
  # functions read `"act"`/`"amr"`/`"epoch"` from.
  defp claims(%{auth: %Principal{claims: claims}}) when is_map(claims), do: claims
  defp claims(_ctx), do: %{}

  # The field DSL delivers atom-keyed, cast args; the facade reads string keys.
  defp stringify(args) when is_map(args), do: Map.new(args, fn {k, v} -> {to_string(k), v} end)

  defp respond({:ok, result}), do: {:ok, result}
  defp respond({:error, code}) when is_atom(code), do: tool_error(code)

  # Machine-readable code stays in the error text (`"<code>: <description>"`)
  # so a calling agent can branch on it (e.g. `account_pending`) instead of
  # parsing prose.
  defp tool_error(code) do
    {_status, %{"error" => error, "error_description" => description}} = Agent.error(code)
    {:error, "#{error}: #{description}"}
  end
end
