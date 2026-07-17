defmodule Noizu.MCP.EvalTest do
  @moduledoc """
  Spec §4: inline @eval annotations — DSL attachment, `Eval.list/1`
  introspection, compile-time validation, and the wire-exclusion guarantee
  (evals are metadata; they never reach `tools/list` / the catalog).
  """
  use ExUnit.Case, async: true

  alias Noizu.MCP.Eval
  alias Noizu.MCP.Eval.Spec, as: EvalSpec
  alias Noizu.MCP.Fixtures
  alias Noizu.MCP.RenderCtx
  alias Noizu.MCP.Types.Tool

  describe "classic tool DSL: `evals:` option" do
    setup do
      [spec] = Fixtures.EvalTool.__mcp_tools__()
      %{spec: spec}
    end

    test "evals compile onto the tool Spec", %{spec: spec} do
      assert [%EvalSpec{name: "simple_task"} = first, %EvalSpec{name: "terse_ok"}] = spec.evals

      assert first.prompt == [%{role: "user", content: "Find documents about elixir."}]

      assert first.rubric == [
               mentions_query: "search query",
               mentions_index: "against the index"
             ]
    end

    test "a string prompt is carried verbatim", %{spec: spec} do
      terse = Enum.find(spec.evals, &(&1.name == "terse_ok"))
      assert terse.prompt == "Just search."
      assert terse.rubric == [mentions_search: "search"]
    end
  end

  describe "toolkit DSL: `@eval` attribute" do
    test "the eval drains onto the following @mcp tool" do
      echo = Enum.find(Fixtures.EvalKit.__mcp_tools__(), &(&1.definition.name == "ek.echo"))
      assert [%EvalSpec{name: "kit_eval", prompt: ["Echo hello via the kit."]}] = echo.evals
    end

    test "a sibling tool with no @eval does not inherit the eval" do
      plain = Enum.find(Fixtures.EvalKit.__mcp_tools__(), &(&1.definition.name == "ek.plain"))
      assert plain.evals == []
    end
  end

  describe "Eval.list/1" do
    test "lists only tools that carry evals, in registration order" do
      listed = Eval.list(Fixtures.EvalServer)
      assert Enum.map(listed, &elem(&1, 0)) == ["eval_tool", "ek.echo"]
    end

    test "the eval-free Echo tool is omitted" do
      names = Eval.list(Fixtures.EvalServer) |> Enum.map(&elem(&1, 0))
      refute "echo" in names
    end

    test "eval specs come through as %Eval.Spec{} structs" do
      {"eval_tool", evals} = List.keyfind(Eval.list(Fixtures.EvalServer), "eval_tool", 0)
      assert Enum.map(evals, & &1.name) == ["simple_task", "terse_ok"]
      assert Enum.all?(evals, &match?(%EvalSpec{}, &1))
    end

    test "the toolkit tool reports its single eval" do
      {"ek.echo", evals} = List.keyfind(Eval.list(Fixtures.EvalServer), "ek.echo", 0)
      assert Enum.map(evals, & &1.name) == ["kit_eval"]
    end
  end

  describe "wire exclusion: evals never appear in tools/list output" do
    setup do
      [spec] = Fixtures.EvalTool.__mcp_tools__()
      %{definition: spec.definition}
    end

    @eval_only_tokens [
      "simple_task",
      "terse_ok",
      "mentions_query",
      "mentions_index",
      "Find documents about elixir"
    ]

    test "to_map/1 (default ctx) contains no eval content, including _meta", %{
      definition: definition
    } do
      serialized = definition |> Tool.to_map() |> inspect(limit: :infinity)

      for token <- @eval_only_tokens do
        refute String.contains?(serialized, token),
               "wire output leaked eval token #{inspect(token)}"
      end
    end

    test "to_map/2 across every verbosity contains no eval content", %{definition: definition} do
      for v <- 0..9 do
        serialized =
          definition |> Tool.to_map(%RenderCtx{verbosity: v}) |> inspect(limit: :infinity)

        for token <- @eval_only_tokens do
          refute String.contains?(serialized, token),
                 "wire output at verbosity #{v} leaked eval token #{inspect(token)}"
        end
      end
    end

    test "the rendered map carries no eval key and (here) no _meta", %{definition: definition} do
      map = Tool.to_map(definition)
      refute Map.has_key?(map, "evals")
      refute Map.has_key?(map, "_meta")
    end
  end

  describe "Eval.compile_specs/2 validation" do
    test "nil compiles to []" do
      assert Eval.compile_specs(nil, "ctx") == []
    end

    test "normalizes an atom name to a string" do
      assert [%EvalSpec{name: "t"}] =
               Eval.compile_specs([[name: :t, prompt: "go", rubric: [a: "x"]]], "ctx")
    end

    test "missing name raises" do
      assert_raise ArgumentError, ~r/eval `name:` is required/, fn ->
        Eval.compile_specs([[prompt: "go", rubric: [a: "x"]]], "ctx")
      end
    end

    test "missing prompt raises" do
      assert_raise ArgumentError, ~r/`prompt:` is required/, fn ->
        Eval.compile_specs([[name: :t, rubric: [a: "x"]]], "ctx")
      end
    end

    test "empty prompt list raises" do
      assert_raise ArgumentError, ~r/`prompt:` must be a non-empty/, fn ->
        Eval.compile_specs([[name: :t, prompt: [], rubric: [a: "x"]]], "ctx")
      end
    end

    test "missing rubric raises" do
      assert_raise ArgumentError, ~r/`rubric:` is required/, fn ->
        Eval.compile_specs([[name: :t, prompt: "go"]], "ctx")
      end
    end

    test "empty rubric raises" do
      assert_raise ArgumentError, ~r/`rubric:` must be a non-empty/, fn ->
        Eval.compile_specs([[name: :t, prompt: "go", rubric: []]], "ctx")
      end
    end

    test "non-string rubric description raises" do
      assert_raise ArgumentError, ~r/description must be a string/, fn ->
        Eval.compile_specs([[name: :t, prompt: "go", rubric: [a: 123]]], "ctx")
      end
    end

    test "duplicate eval name across the list raises" do
      assert_raise ArgumentError, ~r/duplicate eval name/, fn ->
        Eval.compile_specs(
          [
            [name: :t, prompt: "go", rubric: [a: "x"]],
            [name: "t", prompt: "go", rubric: [a: "x"]]
          ],
          "ctx"
        )
      end
    end

    test "non-keyword eval entry raises" do
      assert_raise ArgumentError, ~r/each eval must be a keyword list/, fn ->
        Eval.compile_specs(["nope"], "ctx")
      end
    end
  end

  describe "compile-time DSL validation" do
    test "a bad classic-tool eval is a compile error" do
      assert_raise ArgumentError, ~r/eval `name:` is required/, fn ->
        Code.compile_string("""
        defmodule Noizu.MCP.EvalTest.BadTool do
          use Noizu.MCP.Server.Tool,
            description: "x",
            evals: [[prompt: "go", rubric: [a: "y"]]]

          @impl true
          def call(_a, _c), do: {:ok, "ok"}
        end
        """)
      end
    end

    test "a bad toolkit @eval is a CompileError" do
      assert_raise CompileError, ~r/`rubric:` is required/, fn ->
        Code.compile_string("""
        defmodule Noizu.MCP.EvalTest.BadKit do
          use Noizu.MCP.Server.Toolkit

          @eval name: :x, prompt: "go"
          @mcp description: "echo"
          def echo(_a, _c), do: {:ok, "ok"}
        end
        """)
      end
    end
  end
end
