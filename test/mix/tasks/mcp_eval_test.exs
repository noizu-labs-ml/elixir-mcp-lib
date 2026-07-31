defmodule Mix.Tasks.Noizu.Mcp.EvalTest do
  @moduledoc """
  Spec §4: the `mix noizu.mcp.eval` task. `parse_args!/1` is pure; `run/1` is
  exercised against the eval fixture server through the default stub adapters,
  covering report emission and `--gate` exit behavior.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Noizu.Mcp.Eval, as: Task

  @server "Noizu.MCP.Fixtures.EvalServer"

  describe "parse_args!/1" do
    test "resolves --server to the module and defaults the rest" do
      opts = Task.parse_args!(["--server", @server])
      assert opts[:server] == Noizu.MCP.Fixtures.EvalServer
      assert opts[:tool] == nil
      assert opts[:verbosity] == nil
      assert opts[:runner] == nil
      assert opts[:model] == nil
      assert opts[:gate] == false
    end

    test "parses verbosity all, runner, model, tool, and gate" do
      opts =
        Task.parse_args!([
          "--server",
          @server,
          "--tool",
          "eval_tool",
          "--verbosity",
          "all",
          "--runner",
          "codex",
          "--model",
          "5.4",
          "--gate"
        ])

      assert opts[:tool] == "eval_tool"
      assert opts[:verbosity] == :all
      assert opts[:runner] == :codex
      assert opts[:model] == "5.4"
      assert opts[:gate] == true
    end

    test "parses an integer verbosity" do
      assert Task.parse_args!(["--server", @server, "--verbosity", "3"])[:verbosity] == 3
    end

    test "missing --server raises Mix.Error" do
      assert_raise Mix.Error, ~r/--server MODULE is required/, fn ->
        Task.parse_args!(["--verbosity", "all"])
      end
    end

    test "an unknown server module raises Mix.Error" do
      assert_raise Mix.Error, ~r/is not a Noizu\.MCP\.Server module/, fn ->
        Task.parse_args!(["--server", "No.Such.Module.Here"])
      end
    end

    test "an out-of-range verbosity raises Mix.Error" do
      assert_raise Mix.Error, ~r/--verbosity expects/, fn ->
        Task.parse_args!(["--server", @server, "--verbosity", "42"])
      end
    end

    test "an invalid flag raises Mix.Error" do
      assert_raise Mix.Error, ~r/Invalid options/, fn ->
        Task.parse_args!(["--server", @server, "--nope"])
      end
    end
  end

  describe "run/1" do
    test "writes a JSON report to --output and does not raise on a clean run" do
      path = Path.join(System.tmp_dir!(), "mcp_eval_#{System.unique_integer([:positive])}.json")

      capture_io(fn ->
        Task.run([
          "--server",
          @server,
          "--tool",
          "eval_tool",
          "--verbosity",
          "9",
          "--output",
          path
        ])
      end)

      assert File.exists?(path)
      report = path |> File.read!() |> Jason.decode!()
      assert report["summary"]["failed"] == 0
      assert report["summary"]["total"] == 2
      File.rm(path)
    end

    test "prints the report to stdout when no --output is given" do
      out =
        capture_io(fn ->
          Task.run(["--server", @server, "--tool", "eval_tool", "--verbosity", "9"])
        end)

      assert out =~ ~s("tool": "eval_tool")
    end

    test "--gate makes a failing run exit non-zero (Mix.Error)" do
      assert_raise Mix.Error, ~r/eval gate failed/, fn ->
        capture_io(fn ->
          Task.run(["--server", @server, "--tool", "eval_tool", "--verbosity", "0", "--gate"])
        end)
      end
    end

    test "without --gate a failing run does not raise" do
      capture_io(fn ->
        report = Task.run(["--server", @server, "--tool", "eval_tool", "--verbosity", "0"])
        assert report["summary"]["failed"] > 0
      end)
    end
  end
end
