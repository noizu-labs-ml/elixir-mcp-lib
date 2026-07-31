defmodule Noizu.MCP.Server.RunnerDslTest do
  @moduledoc """
  DSL round-trip for spec §3: fixture tools carrying named variants +
  `verbosity_map:` + `runners:` render different text per (runner, model,
  verbosity) through `Types.Tool.to_map/2`, and on the wire via a server that
  injects runner/model into session assigns.
  """
  use ExUnit.Case, async: true

  alias Noizu.MCP.Fixtures
  alias Noizu.MCP.RenderCtx
  alias Noizu.MCP.Types.Tool

  defp rc(fields), do: struct(RenderCtx, fields)

  defp tool_desc(definition, fields),
    do: Tool.to_map(definition, rc(fields))["description"]

  defp field_desc(definition, fields),
    do: Tool.to_map(definition, rc(fields))["inputSchema"]["properties"]["query"]["description"]

  describe "classic tool: runner/model/verbosity tailoring via to_map/2" do
    setup do
      %{definition: Fixtures.RunnerTool.definition()}
    end

    test "no runner ⇒ the verbosity_map selects the variant", %{definition: d} do
      assert tool_desc(d, verbosity: 3) == "base variant"
      assert tool_desc(d, verbosity: 7) == "spark high variant"
    end

    test "grok rule with its own verbosity → tag map (and gap-fill)", %{definition: d} do
      assert tool_desc(d, runner: :grok, verbosity: 0) == "grok terse variant"
      assert tool_desc(d, runner: :grok, verbosity: 3) == "grok terse variant"
      # levels {0..3} and 9; request 7 gap-fills to the nearer 9
      assert tool_desc(d, runner: :grok, verbosity: 7) == "grok rich variant"
      assert tool_desc(d, runner: :grok, verbosity: 9) == "grok rich variant"
    end

    test "codex rule matches by model membership; falls back to its default tag", %{
      definition: d
    } do
      assert tool_desc(d, runner: :codex, model: :spark, verbosity: 3) == "codex default variant"
      # string/atom insensitivity: model "5.4" matches the :"5.4" list member
      assert tool_desc(d, runner: :codex, model: "5.4", verbosity: 8) == "codex default variant"
    end

    test "a non-matching model falls through to the verbosity_map", %{definition: d} do
      assert tool_desc(d, runner: :codex, model: :nope, verbosity: 3) == "base variant"
      assert tool_desc(d, runner: :openai, verbosity: 7) == "spark high variant"
    end

    test "field description honors its own runner rule and verbosity_map", %{definition: d} do
      assert field_desc(d, verbosity: 3) == "q base"
      assert field_desc(d, runner: :grok, verbosity: 3) == "q base"
      # field-level codex rule (any model) ⇒ q_codex
      assert field_desc(d, runner: :codex, model: :spark, verbosity: 3) == "q codex"
    end

    test "field structure is stable across runner/model/verbosity", %{definition: d} do
      for fields <- [[verbosity: 0], [runner: :codex, model: :spark], [runner: :grok, verbosity: 9]] do
        schema = Tool.to_map(d, rc(fields))["inputSchema"]
        assert schema["required"] == ["query"]
        assert schema["properties"]["query"]["type"] == "string"
      end
    end
  end

  describe "toolkit: runner tailoring via @mcp options" do
    setup do
      spec = Enum.find(Fixtures.RunnerKit.__mcp_tools__(), &(&1.definition.name == "rk.echo"))
      %{definition: spec.definition}
    end

    test "codex runner selects the codex variant, others the verbosity_map", %{definition: d} do
      assert tool_desc(d, runner: :codex, verbosity: 5) == "rk codex"
      assert tool_desc(d, runner: :grok, verbosity: 5) == "rk terse"
      assert tool_desc(d, verbosity: 5) == "rk terse"
    end
  end

  describe "end-to-end tools/list resolves runner rules from session assigns" do
    import Noizu.MCP.Test

    test "server init injects runner=codex model=spark ⇒ codex variant on the wire" do
      client = connect(Fixtures.RunnerServer)
      {:ok, tools} = list_tools(client)
      tool = Enum.find(tools, &(&1.name == "runner_tool"))

      assert tool.description == "codex default variant"
      assert tool.input_schema["properties"]["query"]["description"] == "q codex"
    end
  end

  describe "regression: runner-tagged tools with a runner-free ctx" do
    test "to_map/2 with the default context ignores runner rules entirely" do
      d = Fixtures.RunnerTool.definition()
      # default ctx ⇒ verbosity 5 ⇒ verbosity_map {5,9} ⇒ spark_hi
      assert Tool.to_map(d, RenderCtx.default())["description"] == "spark high variant"
      assert Tool.to_map(d)["description"] == "spark high variant"
      assert Tool.to_map(d) == Tool.to_map(d, RenderCtx.default())
    end
  end
end
