defmodule Noizu.MCP.Fixtures.Persistence do
  @moduledoc """
  PRD-4 fixtures: persistence providers for the D3/D4/D5 tests, servers with
  `persistence:`/`providers:` opts, and the grant/negotiation E2E servers
  (AC-4.2/4.3). The `%Noizu.MCP.Permission.Grant{}`/`%Negotiation{}` records
  themselves are plain data — tests build them inline.
  """

  alias Noizu.MCP.Persistence
  alias Noizu.MCP.Toolset.Custom

  # ── persistence providers ────────────────────────────────────────────────────

  defmodule CrashProvider do
    @moduledoc false
    # D5 outage flavor 1: the provider RAISES on every callback.
    @behaviour Persistence

    @impl true
    def put(_k, _id, _r, _o), do: raise("persistence exploded")
    @impl true
    def get(_k, _id, _o), do: raise("persistence exploded")
    @impl true
    def list(_k, _f, _o), do: raise("persistence exploded")
    @impl true
    def delete(_k, _id, _o), do: raise("persistence exploded")
    @impl true
    def version(_k, _o), do: raise("persistence exploded")
  end

  defmodule ErrorProvider do
    @moduledoc false
    # D5 outage flavor 2: the provider returns {:error, :down} on every callback.
    @behaviour Persistence

    @impl true
    def put(_k, _id, _r, _o), do: {:error, :down}
    @impl true
    def get(_k, _id, _o), do: {:error, :down}
    @impl true
    def list(_k, _f, _o), do: {:error, :down}
    @impl true
    def delete(_k, _id, _o), do: {:error, :down}
    @impl true
    def version(_k, _o), do: {:error, :down}
  end

  defmodule FailingPingProvider do
    @moduledoc false
    # D4 boot gate, failing flavor: pings {:tables_missing, _} — a supervisor
    # resolving to this provider must fail to boot (AC-4.8).
    @behaviour Persistence

    @impl true
    def put(_k, _id, _r, _o), do: {:error, :unused}
    @impl true
    def get(_k, _id, _o), do: {:error, :unused}
    @impl true
    def list(_k, _f, _o), do: {:error, :unused}
    @impl true
    def delete(_k, _id, _o), do: {:error, :unused}
    @impl true
    def version(_k, _o), do: {:error, :unused}
    @impl true
    def ping(_opts), do: {:error, {:tables_missing, ["noizu_mcp_toolsets"]}}
  end

  defmodule MemoryPingProvider do
    @moduledoc false
    # D4 boot gate, passing flavor: a custom provider delegating to Memory
    # with a real ping/1 — the ping child starts and passes, boot succeeds.
    @behaviour Persistence

    @impl true
    def put(k, id, r, o), do: Persistence.Memory.put(k, id, r, o)
    @impl true
    def get(k, id, o), do: Persistence.Memory.get(k, id, o)
    @impl true
    def list(k, f, o), do: Persistence.Memory.list(k, f, o)
    @impl true
    def delete(k, id, o), do: Persistence.Memory.delete(k, id, o)
    @impl true
    def version(k, o), do: Persistence.Memory.version(k, o)
    @impl true
    def ping(_opts), do: :ok
  end

  # ── selection servers (§4.3) ────────────────────────────────────────────────

  defmodule DisabledServer do
    @moduledoc false
    use Noizu.MCP.Server,
      name: "persistence-disabled",
      version: "1.0.0",
      persistence: :disabled

    tool Noizu.MCP.Fixtures.Echo
  end

  defmodule BootFailServer do
    @moduledoc false
    # D4: a provider whose boot ping fails must fail the whole boot.
    use Noizu.MCP.Server,
      name: "persistence-boot-fail",
      version: "1.0.0",
      persistence: {FailingPingProvider, []}

    tool Noizu.MCP.Fixtures.Echo
  end

  defmodule BootOkServer do
    @moduledoc false
    # D4: a custom provider with a passing ping boots with the ping child live.
    use Noizu.MCP.Server,
      name: "persistence-boot-ok",
      version: "1.0.0",
      persistence: {MemoryPingProvider, []}

    tool Noizu.MCP.Fixtures.Echo
  end

  defmodule ProvidersFormServer do
    @moduledoc false
    # §4.3: the combined `providers:` form WINS over individual keys —
    # `acl: AllowAll` is present but `providers: [acl: DenyAll]` governs.
    use Noizu.MCP.Server,
      name: "providers-form",
      version: "1.0.0",
      acl: Noizu.MCP.Fixtures.ACL.AllowAllProvider,
      providers: [acl: Noizu.MCP.ACL.Providers.DenyAll]

    tool Noizu.MCP.Fixtures.Echo
  end

  # ── grant E2E server (AC-4.2) ────────────────────────────────────────────────

  defmodule GrantServer do
    @moduledoc false
    # A hidden-but-callable base tool (`secret_echo`) + visible `echo` and
    # `get_weather`. An :allow grant with [set_visible true, set_name
    # "echo_pro"] ops reveals+renames `secret_echo` FOR THE GRANTED PRINCIPAL
    # only; every other principal sees the base surface (grants never hide —
    # AP-10: absence of a grant is not a denial).
    #
    # The base names this server's own module explicitly (`__MODULE__` is not
    # safe in the `use` literal pre-expansion — same trick as CatalogProbeServer).
    use Noizu.MCP.Server,
      name: "grant-e2e",
      version: "1.0.0",
      acl: Noizu.MCP.Fixtures.ACL.AllowAllProvider,
      toolset: %Custom{
        slug: "grant-slice",
        base: Noizu.MCP.Fixtures.Persistence.GrantServer,
        include: ["echo", "get_weather", "secret_echo"]
      }

    tool Noizu.MCP.Fixtures.Echo
    tool Noizu.MCP.Fixtures.Weather
    tool Noizu.MCP.Fixtures.Echo, name: "secret_echo", hidden: true
  end

  # ── negotiation E2E server (AC-4.3) ──────────────────────────────────────────

  defmodule NegotiationServer do
    @moduledoc false
    # `get_weather` sits behind a consent gate: unsatisfied ⇒ visible but
    # resolving is the honest `:forbidden` (missing-scopes data); satisfied by
    # scope or by `granted: true` ⇒ callable, with metadata_overrides folded
    # onto the tool's `_meta` when granted.
    use Noizu.MCP.Server,
      name: "negotiation-e2e",
      version: "1.0.0",
      acl: Noizu.MCP.Fixtures.ACL.AllowAllProvider,
      toolset: %Custom{
        slug: "negotiation-slice",
        base: Noizu.MCP.Fixtures.Persistence.NegotiationServer,
        include: ["echo", "get_weather"]
      }

    tool Noizu.MCP.Fixtures.Echo
    tool Noizu.MCP.Fixtures.Weather
  end
end
