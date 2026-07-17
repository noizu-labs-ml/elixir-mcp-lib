defmodule Noizu.MCP.Eval.Spec do
  @moduledoc """
  A compiled eval specification attached to a tool (spec §4).

  Evals drive continuous description-quality tuning across model × verbosity
  permutations. They live only on `Noizu.MCP.Server.Tool.Spec.evals` — they are
  compile-time metadata for the `mix noizu.mcp.eval` harness and are **never**
  serialized onto the wire.

    * `name` — normalized to a string; unique per tool
    * `prompt` — the messages (a list) or a single string that drive a model to
      use the tool; carried opaquely and handed to the runner
    * `rubric` — a keyword list of `criterion => description` where each
      description states what a good tool call/transcript must satisfy; the judge
      grades each criterion independently
  """

  defstruct [:name, :prompt, rubric: []]

  @type criterion :: atom()

  @type t :: %__MODULE__{
          name: String.t(),
          prompt: [term()] | String.t(),
          rubric: [{criterion(), String.t()}]
        }
end
