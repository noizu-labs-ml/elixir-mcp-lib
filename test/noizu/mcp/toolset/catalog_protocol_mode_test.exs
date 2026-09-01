defmodule Noizu.MCP.Toolset.CatalogProtocolModeTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.{Ctx, Toolset}
  alias Noizu.MCP.Fixtures
  alias Noizu.MCP.Server.Tools.Catalog

  defp ctx(server), do: %Ctx{server: server, assigns: %{}}

  # Helper returning the raw call result so both ok/error shapes are assertable.
  defp run(server, args), do: Catalog.call(args, ctx(server))

  defp tool_names(result) do
    {:ok, %{"tools" => tools}} = result
    Enum.map(tools, & &1["name"])
  end

  describe "static mode (default, unchanged)" do
    test "omitting mode uses the raw registry expansion with `hidden` flags" do
      result = run(Fixtures.HiddenServer, %{})
      assert {:ok, %{"tools" => tools}} = result

      hidden = Enum.find(tools, &(&1["name"] == "hidden_tool"))
      assert hidden["hidden"] == true
      refute Map.has_key?(hidden, "visible")
    end

    test "include_hidden: false drops hidden items in static mode" do
      names = tool_names(run(Fixtures.HiddenServer, %{"include_hidden" => false}))
      refute "hidden_tool" in names
    end
  end

  describe "protocol mode (opt-in, §4.10)" do
    test "entries carry visible/callable/reason instead of hidden" do
      {:ok, %{"tools" => tools}} = run(Fixtures.HiddenServer, %{"mode" => "protocol"})

      hidden = Enum.find(tools, &(&1["name"] == "hidden_tool"))
      assert hidden["visible"] == false
      assert hidden["callable"] == true
      assert hidden["reason"] == :hidden_by_spec
      refute Map.has_key?(hidden, "hidden")

      visible = Enum.find(tools, &(&1["name"] == "echo"))
      assert visible["visible"] == true
      assert visible["callable"] == true
    end

    test "protocol entries resolve descriptions via RenderCtx" do
      {:ok, %{"tools" => tools}} = run(Fixtures.HiddenServer, %{"mode" => "protocol"})

      echo = Enum.find(tools, &(&1["name"] == "echo"))
      assert echo["description"] == "Echo a message back"
      assert echo["inputSchema"]["required"] == ["message"]
    end

    test "include_hidden: false drops visible:false entries in protocol mode" do
      names =
        tool_names(run(Fixtures.HiddenServer, %{"mode" => "protocol", "include_hidden" => false}))

      refute "hidden_tool" in names
      assert "echo" in names
    end

    test "callable:false entries are omitted even when include_hidden is true" do
      {:ok, %{"tools" => tools}} = run(Fixtures.UncallableServer, %{"mode" => "protocol"})
      refute Enum.any?(tools, &(&1["name"] == "echo"))

      # Static mode still shows it — the mode difference is observable.
      {:ok, %{"tools" => static_tools}} = run(Fixtures.UncallableServer, %{"mode" => "static"})
      assert Enum.any?(static_tools, &(&1["name"] == "echo"))
    end

    test "non-tool sections ignore protocol mode (prompts stay static)" do
      {:ok, %{"prompts" => prompts}} =
        run(Fixtures.HiddenServer, %{"mode" => "protocol", "type" => "prompts"})

      assert Enum.any?(prompts, &(&1["name"] == "code_review"))
      assert Enum.any?(prompts, &(&1["name"] == "hidden_prompt"))
    end

    test "a broken toolset server yields a protocol error, not a crash (D5)" do
      assert {:error, %Noizu.MCP.Error{reason: :internal}} =
               run(Fixtures.NotAToolset, %{"mode" => "protocol"})
    end

    test "direct protocol enumeration agrees with the tool's protocol mode" do
      {:ok, %{"tools" => tools}} = run(Fixtures.HiddenServer, %{"mode" => "protocol"})

      {:ok, entries, _version} =
        Toolset.catalog(Fixtures.HiddenServer, ctx(Fixtures.HiddenServer), [])

      callable = entries |> Enum.reject(&(&1.callable == false)) |> Enum.map(& &1.definition.name)
      assert Enum.sort(Enum.map(tools, & &1["name"])) == Enum.sort(callable)
    end
  end
end
