defmodule Noizu.MCP.Eval.Runner do
  @moduledoc """
  Behaviour for executing an eval prompt against a target (spec §4).

  A runner receives the tool as **already rendered** through the §0/§2/§3
  resolution pipeline for the permutation under test (its `description` and field
  descriptions resolved for the requested verbosity/runner/model), the eval's
  `prompt`, and a context map, and returns a transcript for the judge to grade.

  The context map carries the permutation:

      %{
        server: module(),
        tool: String.t(),
        eval: String.t(),
        verbosity: 0..9 | nil,
        runner: atom() | nil,
        model: String.t() | atom() | nil,
        render_ctx: Noizu.MCP.RenderCtx.t()
      }

  The `transcript` is opaque to the harness — whatever shape the paired judge
  understands (a string, a list of messages, a structured map, ...).

  Select the active runner via the `:noizu_mcp` `:eval_runner` application env;
  it defaults to `Noizu.MCP.Eval.Runner.Stub`. Real LLM runners (driving an
  actual model to call the tool) are app-layer follow-ups.
  """

  @typedoc "Opaque transcript handed to the paired `Noizu.MCP.Eval.Judge`."
  @type transcript :: term()

  @callback run(rendered_tool :: map(), prompt :: [term()] | String.t(), ctx :: map()) ::
              {:ok, transcript()} | {:error, term()}
end
