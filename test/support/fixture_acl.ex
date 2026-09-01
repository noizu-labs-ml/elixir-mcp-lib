defmodule Noizu.MCP.Fixtures.ACL.ToolA do
  @moduledoc false
  use Noizu.MCP.Server.Tool, name: "tool_a", description: "ACL fixture tool A"

  @impl true
  def call(_args, _ctx), do: {:ok, "a"}
end

defmodule Noizu.MCP.Fixtures.ACL.ToolB do
  @moduledoc false
  use Noizu.MCP.Server.Tool, name: "tool_b", description: "ACL fixture tool B"

  @impl true
  def call(_args, _ctx), do: {:ok, "b"}
end

defmodule Noizu.MCP.Fixtures.ACL.ToolC do
  @moduledoc false
  use Noizu.MCP.Server.Tool, name: "tool_c", description: "ACL fixture tool C (verdict ABSENT)"

  @impl true
  def call(_args, _ctx), do: {:ok, "c"}
end

defmodule Noizu.MCP.Fixtures.ACL.AuthEcho do
  @moduledoc false
  # Echoes the caller's `ctx.auth` principal exactly as the lib delivered it —
  # `nil` comes back as plain "anonymous". There is no elevated identity to
  # fall back to (AP-4: forgeable contexts gain nothing).
  use Noizu.MCP.Server.Tool, name: "auth_echo", description: "Echoes the caller's principal"

  @impl true
  def call(_args, ctx) do
    case ctx.auth do
      nil ->
        {:ok, "anonymous"}

      %Noizu.MCP.Auth.Principal{} = principal ->
        {:ok,
         %{
           subject: principal.subject,
           authenticator: principal.authenticator,
           token_id: principal.token_id,
           scopes: principal |> Noizu.MCP.Auth.Principal.scope_list() |> Enum.sort(),
           metadata: principal.metadata
         }}
    end
  end
end

# ── ACL providers ─────────────────────────────────────────────────────────────

defmodule Noizu.MCP.Fixtures.ACL.AllowAllProvider do
  @moduledoc false
  @behaviour Noizu.MCP.ACL.Provider

  @impl true
  def check(_subject, _resource, _action, _ctx, _opts), do: :allow
end

defmodule Noizu.MCP.Fixtures.ACL.GarbageVerdictProvider do
  @moduledoc false
  # Returns a non-verdict — normalized to :deny (D5 fail-closed).
  @behaviour Noizu.MCP.ACL.Provider

  @impl true
  def check(_subject, _resource, _action, _ctx, _opts), do: :indifferent
end

defmodule Noizu.MCP.Fixtures.ACL.CrashProvider do
  @moduledoc false
  @behaviour Noizu.MCP.ACL.Provider

  @impl true
  def check(_subject, _resource, _action, _ctx, _opts), do: raise("pdp unreachable")
end

defmodule Noizu.MCP.Fixtures.ACL.PartialBatchProvider do
  @moduledoc false
  # AC-2.3 / AP-6: batch override that denies "tool_a", allows "tool_b", and
  # returns NO verdict for "tool_c" — the map miss proves default-DENY.
  @behaviour Noizu.MCP.ACL.Provider
  alias Noizu.MCP.ACL.Resource

  @impl true
  def check(_subject, %Resource{id: "tool_a"}, _action, _ctx, _opts), do: :deny
  def check(_subject, _resource, _action, _ctx, _opts), do: :allow

  @impl true
  def check_all(_subject, resources, _action, _ctx, _opts) do
    Enum.flat_map(resources, fn
      %Resource{id: "tool_a"} -> [{"tool_a", :deny}]
      %Resource{id: "tool_b"} -> [{"tool_b", :allow}]
      _resource -> []
    end)
    |> Map.new()
  end
end

defmodule Noizu.MCP.Fixtures.ACL.StaleBatchProvider do
  @moduledoc false
  # Q1: returns verdicts for ids that no longer exist — stale, not an error.
  @behaviour Noizu.MCP.ACL.Provider
  alias Noizu.MCP.ACL.Resource

  @impl true
  def check(_subject, _resource, _action, _ctx, _opts), do: :allow

  @impl true
  def check_all(_subject, resources, _action, _ctx, _opts) do
    resources
    |> Map.new(&{&1.id, :allow})
    |> Map.put("ghost_tool", :allow)
    |> Map.put("another_ghost", :deny)
  end
end

defmodule Noizu.MCP.Fixtures.ACL.FlakyProvider do
  @moduledoc false
  # AC-2.4: raises on the FIRST check after `reset/0`, healthy afterwards —
  # exercises deny-the-set, keep-the-server-alive crash recovery (D5).
  @behaviour Noizu.MCP.ACL.Provider

  @key {__MODULE__, :calls}

  def reset, do: :persistent_term.put(@key, 0)

  @impl true
  def check(_subject, _resource, _action, _ctx, _opts) do
    calls = (:persistent_term.get(@key, 0) || 0) + 1
    :persistent_term.put(@key, calls)

    if calls == 1 do
      raise("pdp cold start")
    else
      :allow
    end
  end
end

defmodule Noizu.MCP.Fixtures.ACL.PromptOnlyProvider do
  @moduledoc false
  # §4.7 kind registration: governs only :prompt — a :tool check must raise.
  @behaviour Noizu.MCP.ACL.Provider

  @impl true
  def check(_subject, _resource, _action, _ctx, _opts), do: :allow

  @impl true
  def supported_kinds, do: [:prompt]
end

# ── ACL-configured servers ────────────────────────────────────────────────────

defmodule Noizu.MCP.Fixtures.ACL.DenyAllServer do
  @moduledoc false
  use Noizu.MCP.Server, name: "acl-deny-all", version: "1.0.0", acl: :deny_all

  tool Noizu.MCP.Fixtures.Echo
  tool Noizu.MCP.Fixtures.Weather
end

defmodule Noizu.MCP.Fixtures.ACL.PartialServer do
  @moduledoc false
  use Noizu.MCP.Server,
    name: "acl-partial",
    version: "1.0.0",
    acl: Noizu.MCP.Fixtures.ACL.PartialBatchProvider

  tool Noizu.MCP.Fixtures.ACL.ToolA
  tool Noizu.MCP.Fixtures.ACL.ToolB
  tool Noizu.MCP.Fixtures.ACL.ToolC
end

defmodule Noizu.MCP.Fixtures.ACL.FlakyServer do
  @moduledoc false
  use Noizu.MCP.Server,
    name: "acl-flaky",
    version: "1.0.0",
    acl: Noizu.MCP.Fixtures.ACL.FlakyProvider

  tool Noizu.MCP.Fixtures.Echo
end

defmodule Noizu.MCP.Fixtures.ACL.DisabledServer do
  @moduledoc false
  use Noizu.MCP.Server, name: "acl-disabled", version: "1.0.0", acl: :disabled

  tool Noizu.MCP.Fixtures.ACL.AuthEcho
end

defmodule Noizu.MCP.Fixtures.ACL.UnconfiguredServer do
  @moduledoc false
  use Noizu.MCP.Server, name: "acl-unconfigured", version: "1.0.0"

  tool Noizu.MCP.Fixtures.ACL.AuthEcho
end

# ── principal mapping (§4.5) ──────────────────────────────────────────────────

defmodule Noizu.MCP.Fixtures.ACL.ClaimsMapper do
  @moduledoc false
  alias Noizu.MCP.Auth.Principal

  # AC-2.6: receives the RAW verifier-checked claims map plus the `principal:`
  # opt args, invoked as to_principal(claims, opts).
  def to_principal(claims, opts) do
    {:ok,
     %Principal{
       subject: claims["sub"],
       authenticator: :test,
       token_id: claims["tid"],
       claims: claims,
       granted_scopes: MapSet.new(List.wrap(Keyword.get(opts, :grant, []))),
       metadata: %{opts: Map.new(opts)}
     }}
  end

  def failing(_claims, _opts), do: {:error, :mapper_says_no}
  def raising(_claims, _opts), do: raise("mapper exploded")
  def garbage(_claims, _opts), do: :nonsense
end

defmodule Noizu.MCP.Fixtures.ACL.MappedServer do
  @moduledoc false
  use Noizu.MCP.Server,
    name: "acl-mapped",
    version: "1.0.0",
    principal: {Noizu.MCP.Fixtures.ACL.ClaimsMapper, :to_principal, [realm: :fixture]}

  tool Noizu.MCP.Fixtures.ACL.AuthEcho
end

defmodule Noizu.MCP.Fixtures.ACL.FailingMapperServer do
  @moduledoc false
  use Noizu.MCP.Server,
    name: "acl-failing-mapper",
    version: "1.0.0",
    principal: {Noizu.MCP.Fixtures.ACL.ClaimsMapper, :failing, []}

  tool Noizu.MCP.Fixtures.ACL.AuthEcho
end

defmodule Noizu.MCP.Fixtures.ACL.RaisingMapperServer do
  @moduledoc false
  use Noizu.MCP.Server,
    name: "acl-raising-mapper",
    version: "1.0.0",
    principal: {Noizu.MCP.Fixtures.ACL.ClaimsMapper, :raising, []}

  tool Noizu.MCP.Fixtures.ACL.AuthEcho
end

defmodule Noizu.MCP.Fixtures.ACL.GarbageMapperServer do
  @moduledoc false
  use Noizu.MCP.Server,
    name: "acl-garbage-mapper",
    version: "1.0.0",
    principal: {Noizu.MCP.Fixtures.ACL.ClaimsMapper, :garbage, []}

  tool Noizu.MCP.Fixtures.ACL.AuthEcho
end

# ── transport-level auth fixtures (per-request claims over HTTP) ──────────────

defmodule Noizu.MCP.Fixtures.ACL.SubjectVerifier do
  @moduledoc false
  @behaviour Noizu.MCP.Auth.TokenVerifier

  @impl true
  def verify("alice-token", _conn_info, _opts),
    do: {:ok, %{"sub" => "alice", "scope" => "mcp:read"}}

  def verify("bob-token", _conn_info, _opts),
    do: {:ok, %{"sub" => "bob", "scope" => "mcp:write pm:docs"}}

  def verify("no-sub-token", _conn_info, _opts), do: {:ok, %{"scope" => "mcp"}}

  def verify(_other, _conn_info, _opts), do: {:error, :invalid_token}
end

defmodule Noizu.MCP.Fixtures.ACL.AuthedServer do
  @moduledoc false
  # No `principal:` opt — exercises the built-in claims mapping end to end.
  use Noizu.MCP.Server, name: "acl-authed", version: "1.0.0"

  tool Noizu.MCP.Fixtures.ACL.AuthEcho
end
