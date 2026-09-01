defmodule Noizu.MCP.Toolset.Ref do
  @moduledoc """
  Reference wrapper pointing at a toolset module (a server or any
  behaviour-backed toolset). `Noizu.MCP.Toolset.coerce/1` wraps module atoms
  into refs; the protocol impl delegates unconditionally to the target.
  """

  @enforce_keys [:target]
  defstruct [:target]

  @type t :: %__MODULE__{target: module()}
end

defimpl Noizu.MCP.Toolset, for: Noizu.MCP.Toolset.Ref do
  @moduledoc false
  # Delegates unconditionally to the target module's functions — no runtime
  # exported-function probing of user modules (D4). A target lacking the
  # functions raises UndefinedFunctionError, which call sites normalize to
  # {:error, %Noizu.MCP.Error{}} per D5 (set disabled, server healthy).

  def coerce(%Noizu.MCP.Toolset.Ref{} = ref), do: ref

  def catalog(%Noizu.MCP.Toolset.Ref{target: target}, ctx, opts),
    do: target.catalog(target, ctx, opts)

  def resolve(%Noizu.MCP.Toolset.Ref{target: target}, name, ctx, opts),
    do: target.resolve(target, name, ctx, opts)

  def invoke(%Noizu.MCP.Toolset.Ref{target: target}, effective, args, ctx, opts),
    do: target.invoke(target, effective, args, ctx, opts)

  def permissions(%Noizu.MCP.Toolset.Ref{target: target}, ctx, opts),
    do: target.permissions(target, ctx, opts)

  def metadata(%Noizu.MCP.Toolset.Ref{target: target}, ctx, opts),
    do: target.metadata(target, ctx, opts)
end

defimpl Noizu.MCP.Toolset, for: Atom do
  @moduledoc false
  # Atoms are server/toolset modules: coerce wraps into a Ref, semantic calls
  # re-dispatch through the Ref impl. `false`/`nil` are atoms too — they wrap
  # as any other and fail at the Ref delegation, keeping the path uniform.

  def coerce(toolset), do: %Noizu.MCP.Toolset.Ref{target: toolset}

  def catalog(toolset, ctx, opts),
    do: Noizu.MCP.Toolset.catalog(%Noizu.MCP.Toolset.Ref{target: toolset}, ctx, opts)

  def resolve(toolset, name, ctx, opts),
    do: Noizu.MCP.Toolset.resolve(%Noizu.MCP.Toolset.Ref{target: toolset}, name, ctx, opts)

  def invoke(toolset, effective, args, ctx, opts),
    do:
      Noizu.MCP.Toolset.invoke(
        %Noizu.MCP.Toolset.Ref{target: toolset},
        effective,
        args,
        ctx,
        opts
      )

  def permissions(toolset, ctx, opts),
    do: Noizu.MCP.Toolset.permissions(%Noizu.MCP.Toolset.Ref{target: toolset}, ctx, opts)

  def metadata(toolset, ctx, opts),
    do: Noizu.MCP.Toolset.metadata(%Noizu.MCP.Toolset.Ref{target: toolset}, ctx, opts)
end
