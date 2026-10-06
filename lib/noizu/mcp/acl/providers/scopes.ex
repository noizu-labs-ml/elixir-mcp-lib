defmodule Noizu.MCP.ACL.Providers.Scopes do
  @moduledoc """
  The declarative, scope-based ACL provider — a working permission model with
  no host-written policy code. Registered as a bare module plus rules:

      use Noizu.MCP.Server,
        acl: {Noizu.MCP.ACL.Providers.Scopes,
              rules: [
                %{scope: "mcp",       resource: "tools:**",          actions: [:call]},
                %{scope: "read:all",  resource: "content:/resources/**", actions: [:read, :list]},
                %{scope: "pm:*",      resource: "tools:project_*",   actions: [:call]}
              ]}

  A check allows when SOME rule holds for the caller: the principal carries
  `rule.scope`, the resource id matches the `rule.resource` glob, and the
  action is in `rule.actions`. Everything else denies — fail-closed always:
  no rules means deny-all, a non-`%Noizu.MCP.Auth.Principal{}` subject raises
  (same as the protocol's `Any` impl), and a malformed rule raises as a
  configuration error rather than being skipped.

  ## Patterns

  Resource patterns are globs on the resource id:

    * `**` matches any run of characters, crossing `/` — `tools:**` matches
      every tool, `content:/resources/**` matches everything under the
      content resources tree;
    * `*` matches any run of characters within one `/` segment —
      `tools:project_*` matches `tools:project_x` but not `tools:project_x/sub`;
    * any other character matches literally.

  No regex dependency; patterns are matched structurally at check time.

  ## Where the scopes come from

  Scopes are the principal's `granted_scopes` — whatever the host's
  authentication put there. Sources that compose:

    * a token verifier mapping JWT scope claims (`scope` / `scp`) into
      `granted_scopes` (see `Noizu.MCP.Auth.JWTVerifier.scopes/1` for the
      claim shapes consumed);
    * a basic-verifier (token/API-key) host that grants fixed scopes per
      credential;
    * the server's `principal:` claims mapping (`Noizu.MCP.Auth.Principal`).

  Rule scopes may themselves carry a trailing `*` glob (`"pm:*"` matches any
  granted `pm:` scope), reusing `Noizu.MCP.Auth.Principal.has_scope?/2`.

  ## Registration

  Works through the standard `acl:` seam — bare module with opts, per-call
  override, or application env; the rules keyword is threaded into every
  `check/5` as `opts`. An empty `rules:` list (or none at all) denies
  everything, mirroring `Noizu.MCP.ACL.Providers.DenyAll`.

  Listing/dispatch gating needs no extra wiring: the provider is consulted by
  `Noizu.MCP.ACL.Provider.filter_entries/4`, so a tool whose wire name
  matches no rule is hidden (`visible: false, callable: false`) exactly as
  with any other provider.
  """

  @behaviour Noizu.MCP.ACL.Provider

  @raise_msg "ACL subjects must be explicit participants (a %Noizu.MCP.Auth.Principal{})"

  @impl true
  # :allow iff some rule matches: principal holds the rule's scope, the
  # resource id matches the rule's glob, and the action is in the rule's
  # action list. Everything else — no rules, no match — denies (fail-closed).
  def check(subject, resource, action, ctx, opts)

  def check(%Noizu.MCP.Auth.Principal{} = subject, resource, action, _ctx, opts) do
    rules = Keyword.get(opts, :rules, [])
    id = to_string(resource.id)
    action_s = to_string(action)

    if Enum.any?(rules, &rule_allows?(&1, subject, id, action_s)), do: :allow, else: :deny
  end

  # Direct behaviour calls bypass the protocol's fail-closed Any impl — keep
  # the same guarantee here rather than silently denying untyped subjects.
  def check(_subject, _resource, _action, _ctx, _opts), do: raise(ArgumentError, @raise_msg)

  defp rule_allows?(rule, subject, id, action_s) do
    validate!(rule)

    Noizu.MCP.Auth.Principal.has_scope?(subject, rule.scope) and
      resource_matches?(rule.resource, id) and
      Enum.any?(rule.actions, &(to_string(&1) == action_s))
  end

  # A malformed rule is a configuration error — raise, never skip (a skipped
  # rule could only ever loosen, and the surface denies crashed checks anyway).
  defp validate!(%{scope: scope, resource: pattern, actions: actions})
       when is_binary(scope) and is_binary(pattern) and is_list(actions) and actions != [],
       do: :ok

  defp validate!(other),
    do:
      raise(
        ArgumentError,
        "Noizu.MCP.ACL.Providers.Scopes rules must be %{scope: binary, resource: binary, " <>
          "actions: [atom | binary]} — got: #{inspect(other)}"
      )

  # ── glob matching ──────────────────────────────────────────────────────────

  # Character-level glob: `**` matches any run of characters (crossing `/`),
  # `*` matches any run within one `/`-segment, other characters match
  # literally. So `tools:**` matches every tool id, `tools:project_*` stays
  # inside one segment, and `content:/resources/**` matches the whole subtree.
  defp resource_matches?(pattern, id),
    do: glob?(tokenize(String.graphemes(pattern)), String.graphemes(id))

  # Runs of `*` collapse into a single `**` token, so a double-star is
  # distinguishable from two adjacent single-segment stars.
  defp tokenize(graphemes) do
    graphemes
    |> Enum.reduce([], fn
      "*", ["*" | rest] -> ["**" | rest]
      "*", acc -> ["*" | acc]
      char, acc -> [char | acc]
    end)
    |> Enum.reverse()
  end

  defp glob?([], []), do: true

  defp glob?(["**" | p_rest], chars) do
    glob?(p_rest, chars) or (chars != [] and glob?(["**" | p_rest], tl(chars)))
  end

  # `*` matches exactly one whole `/`-segment — at least one character, never
  # crossing a `/`.
  defp glob?(["*" | p_rest], chars) do
    case Enum.split_while(chars, &(&1 != "/")) do
      {[_ | _], rest} -> glob?(p_rest, rest)
      {[], _} -> false
    end
  end

  # `/**` matches zero or more whole `/`-segments: `prefix/**` covers `prefix`
  # itself and everything under it, but neither `prefix/` nor `prefixx`.
  defp glob?(["/", "**" | p_rest], chars) do
    glob?(p_rest, chars) or slash_star?(p_rest, chars)
  end

  defp glob?([p | p_rest], [c | c_rest]) when p == c, do: glob?(p_rest, c_rest)
  defp glob?(_pattern, _chars), do: false

  defp slash_star?(p_rest, ["/" | chars]) do
    {seg, rest} = Enum.split_while(chars, &(&1 != "/"))
    seg != [] and glob?(["/", "**" | p_rest], rest)
  end

  defp slash_star?(_p_rest, _chars), do: false
end
