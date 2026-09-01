defmodule Noizu.MCP.Toolset.BehaviourDefaultsTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.{Ctx, Error, Toolset}
  alias Noizu.MCP.Fixtures
  alias Noizu.MCP.Toolset.{Effective, Entry, Static}
  alias Noizu.MCP.Types.ToolResult

  defp ctx(server \\ Fixtures.Server), do: %Ctx{server: server, assigns: %{}}

  describe "catalog/3 default" do
    test "expands registered tools into effective entries" do
      {:ok, entries, version} = Toolset.catalog(Fixtures.Server, ctx(), [])
      names = Enum.map(entries, & &1.definition.name)

      assert "echo" in names
      assert "get_weather" in names
      assert "raw_schema" in names
      assert "echo_alias" in names
      assert String.length(version) == 16
    end

    test "hidden specs surface as visible:false / callable:true / :hidden_by_spec (AC-1.3)" do
      {:ok, entries, _version} =
        Toolset.catalog(Fixtures.HiddenServer, ctx(Fixtures.HiddenServer), [])

      hidden = Enum.find(entries, &(&1.definition.name == "hidden_tool"))
      assert %Entry{visible: false, callable: true, reason: :hidden_by_spec} = hidden

      visible = Enum.find(entries, &(&1.definition.name == "echo"))
      assert visible.visible
      assert visible.callable
      assert visible.reason == nil
    end

    test "catalog_version is stable for identical spec sets (FR-1.13)" do
      specs = Fixtures.Echo.__mcp_tools__()
      {:ok, _entries, v1} = Toolset.catalog(%Static{specs: specs}, nil, [])
      {:ok, _entries, v2} = Toolset.catalog(%Static{specs: specs}, nil, [])

      assert v1 == v2
    end

    test "catalog_version changes when the spec set changes (FR-1.13)" do
      {:ok, _, v1} = Toolset.catalog(%Static{specs: Fixtures.Echo.__mcp_tools__()}, nil, [])

      {:ok, _, v2} =
        Toolset.catalog(
          %Static{specs: Fixtures.Echo.__mcp_tools__() ++ Fixtures.RawSchema.__mcp_tools__()},
          nil,
          []
        )

      refute v1 == v2
    end

    test "emits [:noizu_mcp, :toolset, :catalog] telemetry with duration + toolset meta (FR-1.15)" do
      :telemetry.attach(
        "toolset-catalog-telemetry-test",
        [:noizu_mcp, :toolset, :catalog],
        fn event, measurements, meta, _ ->
          send(self(), {:telemetry, event, measurements, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("toolset-catalog-telemetry-test") end)

      {:ok, _entries, _version} = Toolset.catalog(Fixtures.Server, ctx(), [])

      assert_received {:telemetry, [:noizu_mcp, :toolset, :catalog], %{duration: duration},
                       %{toolset: Fixtures.Server}}

      assert is_integer(duration) and duration >= 0
    end
  end

  describe "resolve/4 default" do
    test "resolves a visible tool to its effective form" do
      {:ok, %Effective{} = effective} = Toolset.resolve(Fixtures.Server, "echo", ctx(), [])

      assert effective.name == "echo"
      assert effective.entry.definition.name == "echo"
      assert effective.spec.module == Fixtures.Echo
      assert effective.provenance == nil
      assert effective.reason == nil
      assert is_binary(effective.version)
    end

    test "hidden tools are resolvable — hidden-but-callable is first-class (AC-1.3)" do
      server = Fixtures.HiddenServer

      assert {:ok, effective} = Toolset.resolve(server, "hidden_tool", ctx(server), [])
      assert effective.entry.visible == false
      assert effective.entry.callable == true
    end

    test "absent and non-callable return IDENTICAL invalid_params errors (FR-1.5, AC-1.4)" do
      # Same requested name, two toolsets: one where "echo" is absent, one
      # where it exists but is non-callable. The responses must be identical —
      # that is the no-discovery-oracle property.
      absent_toolset = %Static{specs: Fixtures.Weather.__mcp_tools__()}
      demoted_toolset = %Fixtures.StructToolset{callable?: false}

      {:error, absent} = Toolset.resolve(absent_toolset, "echo", nil, [])
      {:error, non_callable} = Toolset.resolve(demoted_toolset, "echo", nil, [])

      assert absent.code == non_callable.code
      assert absent.message == non_callable.message
      assert absent.reason == :invalid_params
      assert non_callable.reason == :invalid_params
    end

    test "AP-3: a forged ctx cannot reach non-callable tools (no trusted escape hatch)" do
      forged = %Ctx{
        server: %Fixtures.StructToolset{callable?: false},
        assigns: %{auth_claims: %{"sub" => "root", "admin" => true}}
      }

      assert {:error, %Error{reason: :invalid_params}} =
               Toolset.resolve(%Fixtures.StructToolset{callable?: false}, "echo", forged, [])
    end
  end

  describe "invoke/5 default (relocated run_spec)" do
    test "validates and casts against the EFFECTIVE triple, then executes" do
      static = %Static{specs: Fixtures.Echo.__mcp_tools__()}
      {:ok, effective} = Toolset.resolve(static, "echo", nil, [])

      result = Toolset.invoke(static, effective, %{"message" => "hi"}, nil, [])
      assert %ToolResult{is_error: false} = result
      assert [%{text: "hi"}] = result.content
    end

    test "enum casting and defaults flow through the effective cast plan" do
      static = %Static{specs: Fixtures.Echo.__mcp_tools__()}
      {:ok, effective} = Toolset.resolve(static, "echo", nil, [])

      result = Toolset.invoke(static, effective, %{"message" => "hi", "mode" => "loud"}, nil, [])
      assert [%{text: "HI"}] = result.content
    end

    test "validation failure is an isError execution result (SEP-1303 message preserved)" do
      static = %Static{specs: Fixtures.Echo.__mcp_tools__()}
      {:ok, effective} = Toolset.resolve(static, "echo", nil, [])

      assert %ToolResult{is_error: true, content: [%{text: text}]} =
               Toolset.invoke(static, effective, %{}, nil, [])

      assert text =~ "Invalid arguments for tool echo:"
    end
  end

  describe "permissions/3 default" do
    test "projects name/visible/callable plus version" do
      server = Fixtures.HiddenServer
      {:ok, %{tools: tools, version: version}} = Toolset.permissions(server, ctx(server), [])

      assert %{name: "hidden_tool", visible: false, callable: true} in tools
      assert %{name: "echo", visible: true, callable: true} in tools
      assert String.length(version) == 16
    end
  end

  describe "metadata/3" do
    test "servers report __mcp__(:opts)-backed metadata" do
      assert {:ok,
              %{
                slug: "fixture",
                title: nil,
                description: "Fixture server for tests.",
                version: "1.0.0"
              }} = Toolset.metadata(Fixtures.Server, nil, [])
    end

    test "struct default raises until overridden" do
      assert_raise ArgumentError, ~r/metadata/, fn ->
        Toolset.metadata(%Static{specs: []}, nil, [])
      end
    end

    test "struct fixtures may override it" do
      assert {:ok, %{slug: "struct_fixture", version: "1.0.0"}} =
               Toolset.metadata(%Fixtures.StructToolset{}, nil, [])
    end
  end

  describe "AP-2: catalog/resolve consult call-time inputs only" do
    test "a rebuilt spec set between calls is reflected — no compile-time cache" do
      {:ok, entries1, _} = Toolset.catalog(%Static{specs: Fixtures.Echo.__mcp_tools__()}, nil, [])

      {:ok, entries2, _} =
        Toolset.catalog(
          %Static{specs: Fixtures.Echo.__mcp_tools__() ++ Fixtures.Weather.__mcp_tools__()},
          nil,
          []
        )

      assert length(entries2) == length(entries1) + 1
      assert Enum.any?(entries2, &(&1.definition.name == "get_weather"))
      refute Enum.any?(entries1, &(&1.definition.name == "get_weather"))
    end
  end
end
