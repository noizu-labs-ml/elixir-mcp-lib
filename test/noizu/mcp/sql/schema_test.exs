defmodule Noizu.MCP.SQL.SchemaTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.SQL.{Schema, Types}

  @sql_server Noizu.MCP.Fixtures.SQL.Server

  defp fetch!(server, name) do
    {:ok, relation} = Schema.fetch(server, nil, name)
    relation
  end

  # PRD-7 §4.2's `tools` column list, in order. AC-9.1 asserts the derived
  # relation is byte-identical to it.
  @prd7_tools_columns [
    {"name", "text"},
    {"title", "text"},
    {"description", "text"},
    {"input_schema", "jsonb"},
    {"output_schema", "jsonb"},
    {"annotations", "jsonb"},
    {"read_only", "boolean"},
    {"destructive", "boolean"},
    {"idempotent", "boolean"},
    {"open_world", "boolean"},
    {"meta", "jsonb"}
  ]

  describe "catalog relations (FR-9.5)" do
    test "the eight derived relations are always declared" do
      names = Enum.map(Schema.catalog_relations(), & &1.name)

      assert names == [
               "tools",
               "prompts",
               "resources",
               "prompt_arguments",
               "resource_templates",
               "prompt_messages",
               "resource_contents",
               "completions"
             ]
    end

    test "tools relation columns match PRD-7 §4.2 exactly (AC-9.1)" do
      tools = Enum.find(Schema.catalog_relations(), &(&1.name == "tools"))

      assert Enum.map(tools.columns, &{&1.name, Types.to_sql(&1.type)}) == @prd7_tools_columns
      assert tools.kind == :catalog
      assert tools.primary_key == ["name"]
      assert tools.writable == false
    end

    test "required_quals match what PRD-7 hardcodes in generic mode (AC-9.13)" do
      by_name = Map.new(Schema.catalog_relations(), &{&1.name, &1})

      assert by_name["prompt_messages"].required_quals == ["prompt"]
      assert by_name["resource_contents"].required_quals == ["uri"]
      assert by_name["completions"].required_quals == ["ref", "argument_name", "argument_value"]
      assert by_name["tools"].required_quals == []
      assert by_name["resources"].required_quals == []
    end

    test "every relation declares kind, quals, sort and limit (FR-9.17)" do
      for relation <- Schema.catalog_relations() do
        assert relation.kind in [:catalog, :dataset, :tool, :resource, :prompt]
        assert is_list(relation.qual_columns)
        assert is_list(relation.required_quals)
        assert is_boolean(relation.sort)
        assert is_boolean(relation.limit)

        column_names = Enum.map(relation.columns, & &1.name)

        assert Enum.all?(relation.qual_columns, &(&1 in column_names))
      end
    end
  end

  describe "tool relations (D1/D2 — the one resolver)" do
    test "one relation per effective tool, named tool_<slug> (AP-P9)" do
      relations = Schema.relations(@sql_server, nil, [])
      tool_relations = Enum.filter(relations, &(&1.kind == :tool))

      # The fixture server registers echo, get_weather and raw_schema.
      names = Enum.map(tool_relations, & &1.name)
      assert "tool_echo" in names
      assert "tool_get_weather" in names
      assert "tool_raw_schema" in names

      for relation <- tool_relations do
        assert relation.tool
        assert is_boolean(relation.read_only)
      end

      echo = Enum.find(tool_relations, &(&1.name == "tool_echo"))
      # Echo declares readOnlyHint and a required :message argument.
      assert echo.read_only == true
      assert echo.required_quals == ["message"]
      assert "message" in echo.qual_columns
      assert {"content", :jsonb} in Enum.map(echo.columns, &{&1.name, &1.type})
      assert {"is_error", :boolean} in Enum.map(echo.columns, &{&1.name, &1.type})
    end

    test "tool relations follow the LIVE catalog, not a snapshot (AP-P9)" do
      # Two servers registering different tool sets must project different
      # tool sections, proving derivation from the Toolset protocol.
      sql_relations = Schema.relations(@sql_server, nil, [])
      readonly_relations = Schema.relations(Noizu.MCP.Fixtures.SQL.ReadOnlyServer, nil, [])

      sql_tools = sql_relations |> Enum.filter(&(&1.kind == :tool)) |> Enum.map(& &1.name)

      readonly_tools =
        readonly_relations |> Enum.filter(&(&1.kind == :tool)) |> Enum.map(& &1.name)

      assert sql_tools != readonly_tools
      assert sql_tools -- readonly_tools == ["tool_get_weather", "tool_raw_schema"]
    end

    test "ACL-denied tools are absent from the schema — same denial as tools/call" do
      relations = Schema.relations(Noizu.MCP.Fixtures.ACL.DenyAllServer, nil, [])
      tool_names = relations |> Enum.filter(&(&1.kind == :tool)) |> Enum.map(& &1.name)

      assert tool_names == [], "a deny-all provider must hide every tool relation"
    end
  end

  describe "dataset relations (FR-9.3, FR-9.6)" do
    test "registered datasets appear with their wire name" do
      names = Schema.relations(@sql_server, nil, []) |> Enum.map(& &1.name)

      assert "empty_rows" in names
      assert "paged_rows" in names
      assert "principal_rows" in names
      # :name registration option overrides info().name.
      assert "renamed_rows" in names
      refute "internal_name" in names
    end

    test "hidden datasets are excluded from build/3 but scannable by name" do
      {:ok, payload} = Schema.build(@sql_server, nil, [])
      names = Enum.map(payload["relations"], & &1["name"])
      refute "hidden_rows" in names

      # Exact-name resolution still finds it (hiding governs the listing).
      assert {:ok, relation} = Schema.fetch(@sql_server, nil, "hidden_rows")
      assert relation.name == "hidden_rows"
      assert relation.kind == :dataset
    end

    test "dataset relations declare full pushdown" do
      paged = fetch!(@sql_server, "paged_rows")

      assert paged.kind == :dataset
      assert paged.primary_key == ["id"]
      assert paged.qual_columns == ["id", "label"]
      assert paged.required_quals == []
      assert paged.sort == true
      assert paged.limit == true
    end

    test "writable reflects implemented write callbacks" do
      assert fetch!(@sql_server, "writable_rows").writable == true
      assert fetch!(@sql_server, "empty_rows").writable == false
    end

    test "reserved_names are published" do
      assert "tools" in Schema.reserved_relations()
      assert "completions" in Schema.reserved_relations()
    end
  end

  describe "wire shape" do
    test "to_wire/1 emits the §4.4 payload shape" do
      {:ok, payload} = Schema.build(@sql_server, nil, [])

      assert payload["version"] == 1
      assert is_list(payload["relations"])

      tools = Enum.find(payload["relations"], &(&1["name"] == "tools"))

      assert %{
               "name" => "tools",
               "kind" => "catalog",
               "columns" => columns,
               "primary_key" => ["name"],
               "writable" => false,
               "qual_columns" => ["name"],
               "required_quals" => [],
               "sort" => false,
               "limit" => true
             } = tools

      for column <- columns do
        assert Map.has_key?(column, "name")
        assert Map.has_key?(column, "type")
        assert Map.has_key?(column, "nullable")
      end

      echo = Enum.find(payload["relations"], &(&1["name"] == "tool_echo"))
      assert echo["tool"] == "echo"
      assert echo["read_only"] == true

      # Non-tool relations carry no tool/read_only keys.
      refute Map.has_key?(tools, "tool")
      refute Map.has_key?(tools, "read_only")
    end

    test "unknown relation fetch is invalid_params" do
      assert {:error, %{code: -32602}} = Schema.fetch(@sql_server, nil, "nope")
      assert {:error, %{code: -32602}} = Schema.fetch(@sql_server, nil, 42)
    end
  end

  # ── compile-time name collision (FR-9.6) ─────────────────────────────────

  describe "compile-time validation" do
    test "a dataset named for a derived relation is a compile error" do
      suffix = System.unique_integer([:positive])

      assert_raise CompileError, ~r/collides with a derived SQL relation/, fn ->
        Code.compile_string("""
        defmodule Noizu.MCP.SQLSchemaCollide#{suffix} do
          use Noizu.MCP.Server.Dataset

          def info, do: %{name: "tools", primary_key: ["id"]}
          def columns, do: [%{name: "id", type: :text, nullable: false}]
          def scan(_args, _ctx, _opts), do: {:ok, [], nil}
        end

        defmodule Noizu.MCP.SQLSchemaCollideServer#{suffix} do
          use Noizu.MCP.Server, name: "collide", version: "0.0.1"
          dataset Noizu.MCP.SQLSchemaCollide#{suffix}
        end
        """)
      end
    end

    test "duplicate dataset names are a compile error" do
      suffix = System.unique_integer([:positive])

      assert_raise CompileError, ~r/duplicate dataset names/, fn ->
        Code.compile_string("""
        defmodule Noizu.MCP.SQLSchemaDupA#{suffix} do
          use Noizu.MCP.Server.Dataset

          def info, do: %{name: "twice"}
          def columns, do: [%{name: "id", type: :text, nullable: false}]
          def scan(_args, _ctx, _opts), do: {:ok, [], nil}
        end

        defmodule Noizu.MCP.SQLSchemaDupB#{suffix} do
          use Noizu.MCP.Server.Dataset

          def info, do: %{name: "twice"}
          def columns, do: [%{name: "id", type: :text, nullable: false}]
          def scan(_args, _ctx, _opts), do: {:ok, [], nil}
        end

        defmodule Noizu.MCP.SQLSchemaDupServer#{suffix} do
          use Noizu.MCP.Server, name: "dup", version: "0.0.1"
          dataset Noizu.MCP.SQLSchemaDupA#{suffix}
          dataset Noizu.MCP.SQLSchemaDupB#{suffix}
        end
        """)
      end
    end

    test "the registration :name is the collision-checked name" do
      # info().name is free, but the registration renames it onto a reserved
      # relation — that must fail too.
      suffix = System.unique_integer([:positive])

      assert_raise CompileError, ~r/collides with a derived SQL relation/, fn ->
        Code.compile_string("""
        defmodule Noizu.MCP.SQLSchemaRename#{suffix} do
          use Noizu.MCP.Server.Dataset

          def info, do: %{name: "innocent", primary_key: ["id"]}
          def columns, do: [%{name: "id", type: :text, nullable: false}]
          def scan(_args, _ctx, _opts), do: {:ok, [], nil}
        end

        defmodule Noizu.MCP.SQLSchemaRenameServer#{suffix} do
          use Noizu.MCP.Server, name: "rename", version: "0.0.1"
          dataset Noizu.MCP.SQLSchemaRename#{suffix}, name: "prompts"
        end
        """)
      end
    end
  end
end
