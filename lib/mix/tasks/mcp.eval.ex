defmodule Mix.Tasks.Noizu.Mcp.Eval do
  @shortdoc "Grade a Noizu.MCP server's rendered descriptions with inline @eval specs"

  @moduledoc """
  Run the description-tuning eval harness (spec §4) against a `Noizu.MCP.Server`.

  For every selected `(tool, eval, verbosity permutation)`, the tool's wire
  schema is rendered through the §0/§2/§3 resolution pipeline for that context,
  the eval prompt is run against a target via a `Noizu.MCP.Eval.Runner`, and each
  rubric criterion is graded via a `Noizu.MCP.Eval.Judge`. A JSON report is
  written to `--output` (or stdout).

      # eval every tool with @eval specs, at the server default verbosity
      mix noizu.mcp.eval --server MyApp.MCP

      # one tool, across every verbosity level, gated for CI
      mix noizu.mcp.eval --server MyApp.MCP --tool search --verbosity all --gate

      # tailor the render context to a weak runner/model, write a report file
      mix noizu.mcp.eval --server MyApp.MCP --runner codex --model 5.4 \\
        --output eval.json

  ## Options

    * `--server MODULE` (required) — the server module to eval
    * `--tool NAME` — restrict to one tool by wire name
    * `--verbosity N | all` — a level `0..9`, or `all` to permute over `0..9`
      (default: the server/global default level)
    * `--runner R` — a render-context runner (e.g. `codex`) applied to every
      permutation
    * `--model M` — a render-context model (e.g. `5.4`) applied to every
      permutation
    * `--output PATH` — write the JSON report to `PATH` (default: stdout)
    * `--gate` — exit non-zero if any criterion fails (for CI regression gating)

  The runner/judge *adapters* are selected via the `:noizu_mcp` `:eval_runner` /
  `:eval_judge` application env; both default to the deterministic no-LLM stubs
  (`Noizu.MCP.Eval.Runner.Stub` / `Noizu.MCP.Eval.Judge.Stub`). Real LLM adapters
  are app-layer follow-ups.
  """

  use Mix.Task

  alias Noizu.MCP.Eval.Harness

  @switches [
    server: :string,
    tool: :string,
    runner: :string,
    model: :string,
    verbosity: :string,
    output: :string,
    gate: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    opts = parse_args!(argv)
    report = Harness.run(opts)
    emit(report, opts[:output])

    failed = report["summary"]["failed"]

    if opts[:gate] && failed > 0 do
      Mix.raise(
        "eval gate failed: #{failed} of #{report["summary"]["total"]} permutations failed"
      )
    end

    report
  end

  @doc """
  Parse CLI args into `Noizu.MCP.Eval.Harness.run/1` options.

  Resolves and validates `--server` into a loaded server module and normalizes
  `--verbosity`, `--runner`, and `--model`. Raises `Mix.Error` on bad input.
  """
  @spec parse_args!([String.t()]) :: keyword()
  def parse_args!(argv) do
    {parsed, _positional, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [], do: Mix.raise("Invalid options: #{inspect(invalid)}")

    server = parsed[:server] || Mix.raise("--server MODULE is required")

    [
      server: resolve_server!(server),
      tool: parsed[:tool],
      runner: parsed[:runner] && String.to_atom(parsed[:runner]),
      model: parsed[:model],
      verbosity: parse_verbosity!(parsed[:verbosity]),
      output: parsed[:output],
      gate: parsed[:gate] == true
    ]
  end

  defp resolve_server!(name) do
    module = Module.concat([name])

    unless Code.ensure_loaded?(module) and function_exported?(module, :__mcp__, 1) do
      Mix.raise(
        "#{inspect(module)} is not a Noizu.MCP.Server module (missing __mcp__/1). " <>
          "Did you mean a fully-qualified module name?"
      )
    end

    module
  end

  defp parse_verbosity!(nil), do: nil
  defp parse_verbosity!("all"), do: :all

  defp parse_verbosity!(str) do
    case Integer.parse(str) do
      {n, ""} when n in 0..9 -> n
      _ -> Mix.raise("--verbosity expects an integer 0..9 or \"all\", got: #{inspect(str)}")
    end
  end

  defp emit(report, nil), do: Mix.shell().info(Jason.encode!(report, pretty: true))

  defp emit(report, path) do
    File.write!(path, Jason.encode!(report, pretty: true))
    Mix.shell().info("wrote eval report → #{path}")
  end
end
