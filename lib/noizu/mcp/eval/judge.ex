defmodule Noizu.MCP.Eval.Judge do
  @moduledoc """
  Behaviour for grading a single rubric criterion against a transcript (spec §4).

  Given one rubric `criterion` (the keyword key, e.g. `:covers_pitfall`), its
  `description` (what a good call/transcript must satisfy), and the `transcript`
  the paired `Noizu.MCP.Eval.Runner` produced, a judge returns a grade:

      %{pass: boolean(), score: float(), notes: binary()}

  `pass` gates the harness (and `mix noizu.mcp.eval --gate`); `score` and `notes`
  are recorded in the report for triage.

  Select the active judge via the `:noizu_mcp` `:eval_judge` application env; it
  defaults to `Noizu.MCP.Eval.Judge.Stub`. Real LLM-as-judge adapters are
  app-layer follow-ups.
  """

  @type grade :: %{pass: boolean(), score: float(), notes: binary()}

  @callback grade(
              criterion :: atom() | String.t(),
              description :: String.t(),
              transcript :: term()
            ) :: grade()
end
