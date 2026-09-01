defmodule Noizu.MCP.Toolset.Validator.Issue do
  @moduledoc """
  One structural problem found while materializing overrides onto a spec.

  Issues are *returned*, never raised — `Noizu.MCP.Toolset.Overrides.apply/3`
  collects them per op so hosts can surface actionable messages. The cross-tool
  `Noizu.MCP.Toolset.Validator.compile/3` arrives in the 0.3.0 series' third PR;
  this PR ships only the issue shape.
  """

  defstruct [:code, :message, :op, :tool, :field, :meta]

  @type t :: %__MODULE__{
          code: atom(),
          message: String.t(),
          op: atom() | nil,
          tool: String.t() | nil,
          field: atom() | nil,
          meta: map() | nil
        }
end

defmodule Noizu.MCP.Toolset.Validator do
  @moduledoc """
  Structural validation for override sets.

  PRD-1 ships the `Issue` struct only; cross-tool compile-time validation
  (`compile/3`) lands with the `%CustomToolset{}` merge engine in a later PR of
  the series. Today every check happens per-spec inside
  `Noizu.MCP.Toolset.Overrides.apply/3`.
  """
end
