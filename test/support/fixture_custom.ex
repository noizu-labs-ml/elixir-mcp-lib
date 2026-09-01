defmodule Noizu.MCP.Fixtures.Custom do
  @moduledoc """
  PRD-3 fixtures: servers with `toolset:` configured (static / MFA / bad),
  an ACL+toolset composition server, a catalog-audit probe, and the host
  fixtures the layered tests need. The `%Noizu.MCP.Toolset.Custom{}` values
  themselves are plain data — tests build most of them inline.
  """

  alias Noizu.MCP.Toolset.{Custom, Layer, Override}

  # ── providers ────────────────────────────────────────────────────────────────

  defmodule DenyEchoProvider do
    @moduledoc false
    # FR-3.8: denies exactly the base tool "echo" — every other tool allows.
    @behaviour Noizu.MCP.ACL.Provider

    @impl true
    def check(_subject, %Noizu.MCP.ACL.Resource{id: "echo"}, _action, _ctx, _opts), do: :deny
    def check(_subject, _resource, _action, _ctx, _opts), do: :allow
  end

  # ── resolvers (per-request selection, D3) ────────────────────────────────────

  defmodule Resolver do
    @moduledoc false
    # AC-3.7: different callers see their own surface through the SAME server.
    def resolve(ctx, _opts) do
      case ctx.assigns[:surface] do
        :minimal ->
          %Custom{
            slug: "minimal",
            base: Noizu.MCP.Fixtures.Server,
            include: ["echo"]
          }

        :weather ->
          %Custom{
            slug: "weather",
            base: Noizu.MCP.Fixtures.Server,
            include: ["get_weather"]
          }

        _other ->
          :none
      end
    end
  end

  defmodule GarbageResolver do
    @moduledoc false
    # FR-3.7: an MFA returning a non-toolset ⇒ warn + self fallback.
    def resolve(_ctx, _opts), do: "garbage"
  end

  defmodule RaisingResolver do
    @moduledoc false
    # FR-3.7: an MFA that raises ⇒ warn + self fallback.
    def resolve(_ctx, _opts), do: raise("resolver exploded")
  end

  # ── servers ──────────────────────────────────────────────────────────────────

  defmodule StaticToolsetServer do
    @moduledoc false
    # AC-3.1: filtered + renamed + re-described surface; wire-only field
    # rename (`message` → `text`) proven e2e through composition.
    use Noizu.MCP.Server,
      name: "static-toolset",
      version: "1.0.0",
      toolset: %Custom{
        slug: "echo-ping",
        base: Noizu.MCP.Fixtures.Server,
        include: ["echo", "get_weather"],
        tools: %{
          "echo" => [
            %Override{op: :set_name, target: "echo", value: "ping"},
            %Override{op: :set_description, target: "echo", value: "Ping via custom"},
            %Override{op: :rename_field, target: :message, value: "text"}
          ]
        }
      }

    # Registration keeps the generated handle_* defaults in place; the
    # selected toolset replaces the served surface either way (§4.7).
    tool Noizu.MCP.Fixtures.Echo
  end

  defmodule MFAToolsetServer do
    @moduledoc false
    use Noizu.MCP.Server,
      name: "mfa-toolset",
      version: "1.0.0",
      toolset: {Noizu.MCP.Fixtures.Custom.Resolver, :resolve, []}

    tool Noizu.MCP.Fixtures.Echo
  end

  defmodule GarbageToolsetServer do
    @moduledoc false
    use Noizu.MCP.Server,
      name: "garbage-toolset",
      version: "1.0.0",
      toolset: {Noizu.MCP.Fixtures.Custom.GarbageResolver, :resolve, []}

    tool Noizu.MCP.Fixtures.Echo
  end

  defmodule RaisingToolsetServer do
    @moduledoc false
    use Noizu.MCP.Server,
      name: "raising-toolset",
      version: "1.0.0",
      toolset: {Noizu.MCP.Fixtures.Custom.RaisingResolver, :resolve, []}

    tool Noizu.MCP.Fixtures.Echo
  end

  defmodule ACLCustomServer do
    @moduledoc false
    # FR-3.8: ACL denies apply to the SELECTED toolset's entries — "echo" is
    # included by the custom slice yet denied by the provider.
    use Noizu.MCP.Server,
      name: "acl-custom",
      version: "1.0.0",
      acl: Noizu.MCP.Fixtures.Custom.DenyEchoProvider,
      toolset: %Custom{
        slug: "acl-slice",
        base: Noizu.MCP.Fixtures.Server,
        include: ["echo", "get_weather"]
      }

    tool Noizu.MCP.Fixtures.Echo
  end

  defmodule CatalogProbeServer do
    @moduledoc false
    # §4.8: protocol mode enumerates the SELECTED toolset; static mode keeps
    # the raw registry. The base names this server's own module (the PRD's
    # recommended host shape — the module name is passed explicitly because
    # `__MODULE__` is not safe in the `use` literal pre-expansion).
    use Noizu.MCP.Server,
      name: "catalog-probe",
      version: "1.0.0",
      toolset: %Custom{
        slug: "probe",
        base: Noizu.MCP.Fixtures.Custom.CatalogProbeServer,
        include: ["echo", "catalog"],
        tools: %{
          "echo" => [%Override{op: :set_description, target: "echo", value: "Echo via probe"}]
        }
      }

    tool Noizu.MCP.Fixtures.Echo
    tool Noizu.MCP.Server.Tools.Catalog, hidden: true
  end

  defmodule ImmutableACLServer do
    @moduledoc false
    # §4.1 invariant: immutability never defeats authorization — the ACL
    # deny on "echo" still folds over an immutable slice.
    use Noizu.MCP.Server,
      name: "immutable-acl",
      version: "1.0.0",
      acl: Noizu.MCP.Fixtures.Custom.DenyEchoProvider,
      toolset: %Custom{
        slug: "immutable-slice",
        base: Noizu.MCP.Fixtures.Server,
        include: ["echo", "get_weather"],
        immutable: true
      }

    tool Noizu.MCP.Fixtures.Echo
  end

  # ── host seam fixtures ───────────────────────────────────────────────────────

  defmodule LayeredToolset do
    @moduledoc false
    # Host/PRD-4-style layers/3 override: a persisted-shaped layer at the
    # generic weight 250 — AP-8 asserts it composes per the GENERIC rules
    # (no special casing).
    use Noizu.MCP.Toolset.Behaviour

    defstruct [:specs]

    def __toolset_specs__(%__MODULE__{specs: specs}, _ctx, _opts) when is_list(specs),
      do: specs

    def __toolset_specs__(_toolset, _ctx, _opts), do: []

    @impl true
    def layers(_toolset, ctx, _opts) do
      if ctx.assigns[:host_layer] do
        [
          %Layer{
            id: {:host, "persisted-shaped"},
            weight: 250,
            ops: [
              %Override{op: :set_visible, target: "echo", value: false, tool: "echo"}
            ]
          }
        ]
      else
        []
      end
    end

    def metadata(_toolset, _ctx, _opts),
      do: {:ok, %{slug: "layered", title: nil, description: nil, version: "1.0.0"}}
  end

  defimpl Noizu.MCP.Toolset, for: Noizu.MCP.Fixtures.Custom.LayeredToolset do
    @moduledoc false

    def coerce(toolset), do: toolset

    def catalog(t, ctx, opts), do: Noizu.MCP.Fixtures.Custom.LayeredToolset.catalog(t, ctx, opts)

    def resolve(t, name, ctx, opts),
      do: Noizu.MCP.Fixtures.Custom.LayeredToolset.resolve(t, name, ctx, opts)

    def invoke(t, effective, args, ctx, opts),
      do: Noizu.MCP.Fixtures.Custom.LayeredToolset.invoke(t, effective, args, ctx, opts)

    def permissions(t, ctx, opts),
      do: Noizu.MCP.Fixtures.Custom.LayeredToolset.permissions(t, ctx, opts)

    def metadata(t, ctx, opts),
      do: Noizu.MCP.Fixtures.Custom.LayeredToolset.metadata(t, ctx, opts)
  end
end
