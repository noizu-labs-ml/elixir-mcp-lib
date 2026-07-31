defmodule Noizu.MCP.Eval.RecordingRunner do
  @moduledoc false
  # Test runner: records the rendered description the harness hands it (per
  # tool/verbosity) into the calling process mailbox, then delegates to the stub
  # so grading still runs. Harness.run/1 is synchronous, so `self()` here is the
  # test process.
  @behaviour Noizu.MCP.Eval.Runner

  @impl true
  def run(rendered_tool, prompt, ctx) do
    send(self(), {:rendered, ctx[:tool], ctx[:verbosity], rendered_tool["description"]})
    Noizu.MCP.Eval.Runner.Stub.run(rendered_tool, prompt, ctx)
  end
end

defmodule Noizu.MCP.Eval.HarnessTest do
  @moduledoc """
  Spec §4: end-to-end eval harness over the resolution pipeline, with the
  deterministic stub adapters. Asserts the *rendered* description varies per
  verbosity permutation in what the runner receives, and that criterion grading
  gates as expected.
  """
  use ExUnit.Case, async: true

  alias Noizu.MCP.Eval.Harness
  alias Noizu.MCP.Fixtures

  describe "run/1 with the default stub adapters, verbosity: :all" do
    setup do
      %{report: Harness.run(server: Fixtures.EvalServer, verbosity: :all)}
    end

    test "reports every (tool, eval, verbosity) permutation", %{report: report} do
      # eval_tool: 2 evals, ek.echo: 1 eval → 3 evals × 10 verbosity levels.
      assert report["summary"]["total"] == 30
      assert length(report["results"]) == 30
    end

    test "names the stub adapters and the server", %{report: report} do
      assert report["server"] =~ "EvalServer"
      assert report["runner_adapter"] == "Noizu.MCP.Eval.Runner.Stub"
      assert report["judge_adapter"] == "Noizu.MCP.Eval.Judge.Stub"
    end

    test "the terse simple_task fails until the description covers the rubric", %{report: report} do
      by_verbosity =
        report["results"]
        |> Enum.filter(&(&1["tool"] == "eval_tool" and &1["eval"] == "simple_task"))
        |> Map.new(&{&1["verbosity"], &1["pass"]})

      # rubric needs "search query" AND "against the index"; only the {7,9} band
      # of the description carries both.
      for v <- 0..6, do: refute(by_verbosity[v], "expected fail at verbosity #{v}")
      for v <- 7..9, do: assert(by_verbosity[v], "expected pass at verbosity #{v}")
    end

    test "the always-covered evals pass at every verbosity", %{report: report} do
      always =
        report["results"]
        |> Enum.filter(&(&1["eval"] in ["terse_ok", "kit_eval"]))

      assert length(always) == 20
      assert Enum.all?(always, & &1["pass"])
    end

    test "summary counts the failing simple_task permutations", %{report: report} do
      # simple_task fails at verbosity 0..6 (7 levels); everything else passes.
      assert report["summary"]["failed"] == 7
      assert report["summary"]["passed"] == 23
    end

    test "each criterion is graded with score and notes", %{report: report} do
      result =
        Enum.find(
          report["results"],
          &(&1["tool"] == "eval_tool" and &1["eval"] == "simple_task" and &1["verbosity"] == 9)
        )

      assert [q, idx] = result["criteria"]
      assert q["criterion"] == "mentions_query"
      assert q["pass"] == true
      assert q["score"] == 1.0
      assert is_binary(q["notes"])
      assert idx["criterion"] == "mentions_index"
      assert idx["pass"] == true
    end
  end

  describe "the rendered description varies per permutation in what the runner receives" do
    test "the recording runner sees a different description per verbosity band" do
      Harness.run(
        server: Fixtures.EvalServer,
        tool: "eval_tool",
        verbosity: :all,
        runner_adapter: Noizu.MCP.Eval.RecordingRunner
      )

      received = drain_rendered() |> Enum.filter(&(elem(&1, 0) == "eval_tool"))

      by_verbosity =
        received
        |> Enum.map(fn {_tool, v, desc} -> {v, desc} end)
        |> Map.new()

      # The three verbosity bands render three distinct strings.
      assert by_verbosity[0] == "search"
      assert by_verbosity[5] == "run a search query"
      assert by_verbosity[9] == "run a full-text search query against the index"

      distinct = by_verbosity |> Map.values() |> Enum.uniq()
      assert length(distinct) == 3
    end
  end

  describe "gating" do
    test "a low-verbosity run produces failures (non-zero gate signal)" do
      report = Harness.run(server: Fixtures.EvalServer, tool: "eval_tool", verbosity: 0)
      assert report["summary"]["failed"] > 0
    end

    test "a high-verbosity run is clean" do
      report = Harness.run(server: Fixtures.EvalServer, tool: "eval_tool", verbosity: 9)
      assert report["summary"]["failed"] == 0
    end

    test "runner/model tailoring flows into the render context and report" do
      report =
        Harness.run(
          server: Fixtures.EvalServer,
          tool: "eval_tool",
          verbosity: 9,
          runner: :codex,
          model: "5.4"
        )

      assert report["runner"] == "codex"
      assert report["model"] == "5.4"
      assert Enum.all?(report["results"], &(&1["runner"] == "codex" and &1["model"] == "5.4"))
    end
  end

  defp drain_rendered(acc \\ []) do
    receive do
      {:rendered, tool, v, desc} -> drain_rendered([{tool, v, desc} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
