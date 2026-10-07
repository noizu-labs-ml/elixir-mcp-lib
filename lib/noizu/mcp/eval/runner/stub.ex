defmodule Noizu.MCP.Eval.Runner.Stub do
  @moduledoc """
  Deterministic no-LLM runner for tests and CI (spec §4).

  Calls no model. It echoes the rendered tool (name, resolved description, and
  the full wire map) plus the eval prompt back as the transcript, so the harness
  pipeline — and "the rendered description varies per permutation" assertions —
  can run without network access. Pairs with `Noizu.MCP.Eval.Judge.Stub`.

  Real LLM runners are app-layer follow-ups; select one via the `:noizu_mcp`
  `:eval_runner` application env.
  """

  @behaviour Noizu.MCP.Eval.Runner

  @impl true
  def run(rendered_tool, prompt, ctx) do
    {:ok,
     %{
       "tool" => rendered_tool["name"],
       "description" => rendered_tool["description"],
       "rendered" => rendered_tool,
       "prompt" => prompt,
       "verbosity" => ctx[:verbosity],
       "runner" => ctx[:runner] && to_string(ctx[:runner]),
       "model" => ctx[:model] && to_string(ctx[:model])
     }}
  end
end
