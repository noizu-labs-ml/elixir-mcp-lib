defmodule Noizu.MCP.Toolset.Static do
  @moduledoc """
  Internal toolset wrapper over an already-expanded `[%Noizu.MCP.Server.Tool.Spec{}]`
  list. The bridge that keeps `Features.Tools.list_registered/3` and
  `dispatch/4` as thin shims over the behaviour defaults (D1) — no second code
  path — without requiring a server module. Also handy in tests.

  Note: the protocol impl is written explicitly (Ref-style) rather than via
  `@derive` — Elixir's derive delegates to the protocol's `Any` impl, and this
  architecture's `Any` impl is deliberately fail-closed (D4).
  """

  use Noizu.MCP.Toolset.Behaviour

  defstruct [:specs, opts: []]

  @type t :: %__MODULE__{
          specs: [Noizu.MCP.Server.Tool.Spec.t()],
          opts: keyword()
        }

  @impl true
  def __toolset_specs__(%__MODULE__{specs: specs}, _ctx, _opts) when is_list(specs), do: specs
  def __toolset_specs__(_toolset, _ctx, _opts), do: []
end

defimpl Noizu.MCP.Toolset, for: Noizu.MCP.Toolset.Static do
  @moduledoc false
  # Explicit delegation to the struct module's behaviour functions (the
  # Behaviour injects them; hosts may override any of them).

  def coerce(%Noizu.MCP.Toolset.Static{} = static), do: static

  def catalog(%Noizu.MCP.Toolset.Static{} = static, ctx, opts),
    do: Noizu.MCP.Toolset.Static.catalog(static, ctx, opts)

  def resolve(%Noizu.MCP.Toolset.Static{} = static, name, ctx, opts),
    do: Noizu.MCP.Toolset.Static.resolve(static, name, ctx, opts)

  def invoke(%Noizu.MCP.Toolset.Static{} = static, effective, args, ctx, opts),
    do: Noizu.MCP.Toolset.Static.invoke(static, effective, args, ctx, opts)

  def permissions(%Noizu.MCP.Toolset.Static{} = static, ctx, opts),
    do: Noizu.MCP.Toolset.Static.permissions(static, ctx, opts)

  def metadata(%Noizu.MCP.Toolset.Static{} = static, ctx, opts),
    do: Noizu.MCP.Toolset.Static.metadata(static, ctx, opts)
end
