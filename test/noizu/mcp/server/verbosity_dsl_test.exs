defmodule Noizu.MCP.Server.VerbosityDslTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.Fixtures
  alias Noizu.MCP.RenderCtx
  alias Noizu.MCP.Server.Tool.Fields
  alias Noizu.MCP.Types.Tool

  defp rc(v), do: %RenderCtx{verbosity: v}

  describe "classic tool: variant description + variant field descriptions via to_map/2" do
    setup do
      %{definition: Fixtures.VerboseTool.definition()}
    end

    test "tool description tracks the requested verbosity", %{definition: definition} do
      assert Tool.to_map(definition, rc(0))["description"] == "terse tool"
      assert Tool.to_map(definition, rc(3))["description"] == "medium tool"
      assert Tool.to_map(definition, rc(5))["description"] == "medium tool"
      assert Tool.to_map(definition, rc(9))["description"] == "verbose tool"
    end

    test "field descriptions in inputSchema track the requested verbosity", %{
      definition: definition
    } do
      query_desc = fn v ->
        Tool.to_map(definition, rc(v))["inputSchema"]["properties"]["query"]["description"]
      end

      assert query_desc.(0) == "q"
      # gap-fill: levels {0,5,9}; 3 is nearer 5 than 0
      assert query_desc.(3) == "the search query"
      assert query_desc.(5) == "the search query"
      assert query_desc.(9) == "the full-text search query string to run against the index"
    end

    test "field structure/constraints are stable across verbosity", %{definition: definition} do
      for v <- [0, 3, 5, 9] do
        schema = Tool.to_map(definition, rc(v))["inputSchema"]
        assert schema["type"] == "object"
        assert schema["required"] == ["query"]
        assert schema["properties"]["query"]["type"] == "string"
      end
    end

    test "to_json_schema/2 renders the same field strings directly", %{definition: definition} do
      fields = definition.input_fields
      assert is_list(fields)

      assert Fields.to_json_schema(fields, rc(0))["properties"]["query"]["description"] == "q"

      assert Fields.to_json_schema(fields, rc(9))["properties"]["query"]["description"] ==
               "the full-text search query string to run against the index"
    end
  end

  describe "toolkit: variant description + variant field description" do
    setup do
      spec = Enum.find(Fixtures.VerboseKit.__mcp_tools__(), &(&1.definition.name == "vk.echo"))
      %{definition: spec.definition}
    end

    test "toolkit tool description tracks verbosity with gap-fill", %{definition: definition} do
      # levels {0, 9}: 5 ties toward the lower level per left-preference
      assert Tool.to_map(definition, rc(0))["description"] == "terse kit"
      assert Tool.to_map(definition, rc(9))["description"] == "verbose kit"
      assert Tool.to_map(definition, rc(3))["description"] == "terse kit"
    end

    test "toolkit field description tracks verbosity", %{definition: definition} do
      d = fn v -> Tool.to_map(definition, rc(v))["inputSchema"]["properties"]["msg"]["description"] end
      assert d.(0) == "m"
      assert d.(9) == "the message to echo verbatim"
    end
  end

  describe "end-to-end tools/list applies the render context from session assigns" do
    import Noizu.MCP.Test

    test "server default_verbosity (1) resolves variant descriptions on the wire" do
      client = connect(Fixtures.VerboseServer)
      {:ok, tools} = list_tools(client)
      verbose = Enum.find(tools, &(&1.name == "verbose"))
      # default_verbosity: 1 on the server ⇒ the {0,2} band
      assert verbose.description == "terse tool"
      assert verbose.input_schema["properties"]["query"]["description"] == "q"
    end
  end

  # ── regression: plain-string tools render byte-identical at the default ctx ──

  describe "regression: plain-string tools are unchanged" do
    test "to_map/1 equals to_map/2 with the default context" do
      for definition <- [
            Fixtures.Echo.definition(),
            Fixtures.Weather.definition(),
            Fixtures.RawSchema.definition()
          ] do
        assert Tool.to_map(definition) == Tool.to_map(definition, RenderCtx.default())
      end
    end

    test "Echo renders its original strings and schema" do
      map = Tool.to_map(Fixtures.Echo.definition())
      assert map["description"] == "Echo a message back"
      assert map["inputSchema"]["properties"]["message"]["description"] == "Message to echo"
      assert map["inputSchema"]["required"] == ["message"]
      assert map["annotations"] == %{"readOnlyHint" => true}
    end

    test "plain-string definition fields stay plain strings (not Description structs)" do
      assert Fixtures.Echo.definition().description == "Echo a message back"
      assert Fixtures.Weather.definition().description == "Get current weather"
    end

    test "tools/list over the wire is unaffected for a plain server" do
      import Noizu.MCP.Test
      client = connect(Fixtures.Server)
      {:ok, tools} = list_tools(client)
      echo = Enum.find(tools, &(&1.name == "echo"))
      assert echo.description == "Echo a message back"
      assert echo.input_schema["properties"]["message"]["description"] == "Message to echo"
    end
  end
end
