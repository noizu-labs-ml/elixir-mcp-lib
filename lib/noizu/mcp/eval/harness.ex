defmodule Noizu.MCP.Eval.Harness do
  @moduledoc """
  Core of the `mix noizu.mcp.eval` description-tuning harness (spec §4).

  For every selected `(tool, eval, verbosity permutation)`, the harness renders
  the tool's wire schema through the §0/§2/§3 resolution pipeline
  (`Noizu.MCP.Types.Tool.to_map/2`) with the permutation's `RenderCtx` — this is
  the point of the whole exercise: evals exercise the *rendered* descriptions.
  It then runs the eval prompt against a target via a `Noizu.MCP.Eval.Runner` and
  grades each rubric criterion via a `Noizu.MCP.Eval.Judge`, collecting a JSON
  -ready report.

  ## `run/1` options

    * `:server` (required) — the `Noizu.MCP.Server` module to eval
    * `:tool` — restrict to one tool by wire name (default: all tools with evals)
    * `:verbosity` — `0..9`, `:all` (permute over `0..9`), or `nil` (a single
      permutation at the server/global default level)
    * `:runner` — a `RenderCtx` runner atom (e.g. `:codex`) applied to every
      permutation; not to be confused with the runner *adapter* below
    * `:model` — a `RenderCtx` model (atom or string) applied to every permutation
    * `:runner_adapter` — the `Noizu.MCP.Eval.Runner` module (default:
      `:noizu_mcp` `:eval_runner` app env, else `Noizu.MCP.Eval.Runner.Stub`)
    * `:judge_adapter` — the `Noizu.MCP.Eval.Judge` module (default: `:noizu_mcp`
      `:eval_judge` app env, else `Noizu.MCP.Eval.Judge.Stub`)

  ## Report shape

      %{
        "server" => "...", "runner_adapter" => "...", "judge_adapter" => "...",
        "runner" => "codex" | nil, "model" => "5.4" | nil,
        "generated_at" => iso8601,
        "summary" => %{"total" => n, "passed" => n, "failed" => n},
        "results" => [
          %{
            "tool" => "...", "eval" => "...", "verbosity" => 0..9 | nil,
            "runner" => ..., "model" => ..., "description" => rendered_text,
            "runner_status" => "ok" | "error",
            "criteria" => [%{"criterion" => "...", "pass" => bool,
                             "score" => float, "notes" => "..."}],
            "pass" => bool
          }
        ]
      }

  A result fails when its runner errors or any of its rubric criteria fail;
  `summary.failed` counts failing results — the signal `mix noizu.mcp.eval
  --gate` turns into a non-zero exit.
  """

  alias Noizu.MCP.{RenderCtx, Types}
  alias Noizu.MCP.Server.Features

  @default_runner Noizu.MCP.Eval.Runner.Stub
  @default_judge Noizu.MCP.Eval.Judge.Stub

  @doc "Run the selected evals and return a JSON-ready report map."
  @spec run(keyword()) :: map()
  def run(opts) do
    server = Keyword.fetch!(opts, :server)

    runner_adapter =
      opts[:runner_adapter] || Application.get_env(:noizu_mcp, :eval_runner, @default_runner)

    judge_adapter =
      opts[:judge_adapter] || Application.get_env(:noizu_mcp, :eval_judge, @default_judge)

    runner = opts[:runner]
    model = opts[:model]
    verbosities = expand_verbosity(opts[:verbosity])
    defaults = RenderCtx.server_defaults(server)

    specs = select_specs(server, opts[:tool])

    results =
      for spec <- specs,
          eval <- spec.evals,
          verbosity <- verbosities do
        run_permutation(%{
          server: server,
          spec: spec,
          eval: eval,
          verbosity: verbosity,
          runner: runner,
          model: model,
          defaults: defaults,
          runner_adapter: runner_adapter,
          judge_adapter: judge_adapter
        })
      end

    report(server, runner_adapter, judge_adapter, runner, model, results)
  end

  # ── selection ────────────────────────────────────────────────────────────────

  defp select_specs(server, tool_filter) do
    server.__mcp__(:tools)
    |> Features.Tools.expand()
    |> Enum.filter(fn spec -> (spec.evals || []) != [] end)
    |> then(fn specs ->
      if tool_filter,
        do: Enum.filter(specs, &(&1.definition.name == tool_filter)),
        else: specs
    end)
  end

  defp expand_verbosity(:all), do: Enum.to_list(0..9)
  defp expand_verbosity(nil), do: [nil]
  defp expand_verbosity(v) when is_integer(v), do: [v]

  # ── one permutation ───────────────────────────────────────────────────────────

  defp run_permutation(p) do
    ctx = %RenderCtx{
      verbosity: p.verbosity,
      runner: p.runner,
      model: p.model,
      defaults: p.defaults
    }

    rendered = Types.Tool.to_map(p.spec.definition, ctx)
    tool_name = p.spec.definition.name

    base = %{
      "tool" => tool_name,
      "eval" => p.eval.name,
      "verbosity" => p.verbosity,
      "runner" => p.runner && to_string(p.runner),
      "model" => p.model && to_string(p.model),
      "description" => rendered["description"]
    }

    run_ctx = %{
      server: p.server,
      tool: tool_name,
      eval: p.eval.name,
      verbosity: p.verbosity,
      runner: p.runner,
      model: p.model,
      render_ctx: ctx
    }

    case p.runner_adapter.run(rendered, p.eval.prompt, run_ctx) do
      {:ok, transcript} ->
        criteria = grade_all(p.eval.rubric, transcript, p.judge_adapter)

        Map.merge(base, %{
          "runner_status" => "ok",
          "criteria" => criteria,
          "pass" => Enum.all?(criteria, & &1["pass"])
        })

      {:error, reason} ->
        Map.merge(base, %{
          "runner_status" => "error",
          "error" => describe_error(reason),
          "criteria" => [],
          "pass" => false
        })
    end
  end

  defp grade_all(rubric, transcript, judge_adapter) do
    Enum.map(rubric, fn {criterion, description} ->
      grade = judge_adapter.grade(criterion, description, transcript)

      %{
        "criterion" => to_string(criterion),
        "description" => description,
        "pass" => Map.get(grade, :pass) == true,
        "score" => Map.get(grade, :score),
        "notes" => Map.get(grade, :notes)
      }
    end)
  end

  defp describe_error(reason) when is_binary(reason), do: reason
  defp describe_error(reason), do: inspect(reason)

  # ── report ─────────────────────────────────────────────────────────────────────

  defp report(server, runner_adapter, judge_adapter, runner, model, results) do
    total = length(results)
    failed = Enum.count(results, &(&1["pass"] != true))

    %{
      "server" => inspect(server),
      "runner_adapter" => inspect(runner_adapter),
      "judge_adapter" => inspect(judge_adapter),
      "runner" => runner && to_string(runner),
      "model" => model && to_string(model),
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "summary" => %{"total" => total, "passed" => total - failed, "failed" => failed},
      "results" => results
    }
  end
end
