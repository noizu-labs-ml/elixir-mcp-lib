defmodule Noizu.MCP.Server.Tool.Spec do
  @moduledoc """
  Normalized runtime descriptor for one registered tool.

  Every tool module — classic `use Noizu.MCP.Server.Tool` modules and
  `use Noizu.MCP.Server.Toolkit` multi-tool modules alike — exports
  `__mcp_tools__/0` returning a list of these. The server runtime
  (`Noizu.MCP.Server.Features.Tools.expand/1`) works exclusively on specs:
  the `definition` is what `tools/list` advertises, `module`/`fun`/`arity`
  are how `tools/call` invokes the handler, and `cast_plan`/`output_schema`
  drive argument casting and structured-output checking.

  `evals` holds compiled `Noizu.MCP.Eval.Spec` structs (spec §4) —
  description-tuning eval definitions attached via the tool DSL. They are
  compile-time metadata for the `mix noizu.mcp.eval` harness and are **never**
  serialized onto the wire: only `definition` reaches `tools/list` / the catalog.

  `callable` (toolset architecture, 0.3.0 series) marks whether the tool may be
  dispatched at all — `hidden` controls listing, `callable` controls dispatch;
  both feed the `%Noizu.MCP.Toolset.Entry{}` projection. Static registrations
  default to `callable: true`; the override vocabulary flips it per caller.
  """

  defstruct [
    :module,
    :fun,
    :arity,
    :definition,
    :cast_plan,
    :output_schema,
    hidden: false,
    callable: true,
    evals: []
  ]

  @type t :: %__MODULE__{
          module: module(),
          fun: atom(),
          arity: 0..2,
          definition: Noizu.MCP.Types.Tool.t(),
          cast_plan: list() | nil,
          output_schema: map() | nil,
          hidden: boolean(),
          callable: boolean(),
          evals: [Noizu.MCP.Eval.Spec.t()]
        }
end
