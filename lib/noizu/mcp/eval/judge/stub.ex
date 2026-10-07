defmodule Noizu.MCP.Eval.Judge.Stub do
  @moduledoc """
  Deterministic no-LLM judge for tests and CI (spec §4).

  **Not a real evaluator.** It grades a criterion by a trivial, fully
  deterministic rule: the criterion *passes* iff its `description` text appears
  (case-insensitively) somewhere in the flattened transcript. This makes grading
  a pure function of the rendered description, so a description-tuning regression
  (a terser variant that drops a required phrase) surfaces as a failing criterion
  without any model in the loop.

  Real LLM-as-judge adapters are app-layer follow-ups; select one via the
  `:noizu_mcp` `:eval_judge` application env.
  """

  @behaviour Noizu.MCP.Eval.Judge

  @impl true
  def grade(criterion, description, transcript) do
    haystack = transcript |> flatten() |> String.downcase()
    needle = description |> to_string() |> String.downcase()
    pass = needle != "" and String.contains?(haystack, needle)

    %{
      pass: pass,
      score: if(pass, do: 1.0, else: 0.0),
      notes:
        "stub judge: criterion #{inspect(criterion)} description " <>
          "#{if pass, do: "found in", else: "absent from"} transcript"
    }
  end

  defp flatten(transcript) when is_binary(transcript), do: transcript
  defp flatten(transcript), do: inspect(transcript, limit: :infinity, printable_limit: :infinity)
end
