defprotocol Noizu.MCP.ACL do
  @moduledoc """
  The authorization decision protocol (PRD-2): does `subject` get to `action`
  `resource` under `ctx`? Returns `:allow` or `:deny` — no third verdict.

  Subjects are explicit participants (D4), mirroring `Noizu.MCP.Toolset`:

    * `%Noizu.MCP.Auth.Principal{}` — consults the server-configured provider
      (`use Noizu.MCP.Server, acl: ...`, or a per-call `opts[:acl]`); with no
      provider configured the check allows (inert, back-compat);
    * anything else raises `ArgumentError` via the fail-closed `Any` impl —
      there is no semantic fallback for untyped subjects.

  Providers rarely interact with this protocol directly; the behaviour
  defaults gate listing/dispatch through `Noizu.MCP.ACL.Provider.filter_entries/4`
  (the chokepoint), which fans out via `check_all/5`. Enforcement inside the
  defaults is what makes ACL non-decorative: it cannot be bypassed by calling
  a feature shim or the behaviour directly.
  """

  @fallback_to_any true

  @doc ":allow | :deny — no third verdict. Unregistered kinds at rule time: raise (§4.7)."
  @spec check(t(), Noizu.MCP.ACL.Resource.t(), atom() | String.t(), term(), keyword()) ::
          :allow | :deny
  def check(subject, resource, action, ctx, opts)
end

defimpl Noizu.MCP.ACL, for: Noizu.MCP.Auth.Principal do
  @moduledoc false
  # Consults the server-configured provider: per-call opts[:acl] wins, else
  # the ctx's server registration. No provider ⇒ :allow (inert). The kind
  # guard inside Provider.check/6 raises for ungoverned kinds (§4.7).

  def check(subject, resource, action, ctx, opts) do
    server = if is_map(ctx), do: Map.get(ctx, :server)

    case Noizu.MCP.ACL.Provider.resolve_provider(server, opts) do
      nil ->
        :allow

      {provider, check_opts} ->
        Noizu.MCP.ACL.Provider.check(provider, subject, resource, action, ctx, check_opts)
    end
  end
end

defimpl Noizu.MCP.ACL, for: Any do
  @moduledoc false
  # Fail-closed Any impl (D4, same pattern as Noizu.MCP.Toolset): NO semantic
  # fallback — ACL subjects must be explicit participants.
  @raise_msg "ACL subjects must be explicit participants (a %Noizu.MCP.Auth.Principal{})"

  def check(_subject, _resource, _action, _ctx, _opts), do: raise(ArgumentError, @raise_msg)
end
