defmodule Noizu.MCP.Test.SQLConformanceCase do
  @moduledoc """
  The shared `sql/*` conformance battery (PRD-9 §7.5). Run against any server
  that registers datasets:

      defmodule MyApp.MCPSQLConformanceTest do
        use ExUnit.Case, async: false
        use Noizu.MCP.Test.SQLConformanceCase, server: MyApp.MCP
      end

  The host gets, for every relation the server serves:

    * schema well-formedness — kind, columns, qual/sort/limit declarations;
    * positional-row consistency — every row is one array of exactly
      `length(columns)` values;
    * cursor totality — two full cursor walks at different page sizes yield
      the identical row sequence;
    * qual honesty — every row a scan returns satisfies every qual it was
      given, whether or not the dataset applied them (the re-check contract,
      PRD-9 §4.1);
    * error shape — unknown relations are `-32602`, unsupported modify ops are
      `-32601`, missing required quals are `-32602`.

  The battery is read-only against dataset state except for the error-shape
  probe, which issues an unsupported op the server must refuse.
  """

  alias Noizu.MCP.SQL.Quals

  defmacro __using__(opts) do
    server = Keyword.fetch!(opts, :server)

    quote do
      import Noizu.MCP.Test

      @sql_conformance_server unquote(server)

      setup do
        Noizu.MCP.Test.ensure_server_started(@sql_conformance_server)
        %{client: connect(@sql_conformance_server)}
      end

      @tag :sql_conformance
      test "conformance: sql/schema is well-formed", %{client: client} do
        assert {:ok, %{"version" => 1, "relations" => relations}} = sql_schema(client)
        assert is_list(relations) and relations != []
        assert_conformance_schema_well_formed(relations)
      end

      @tag :sql_conformance
      test "conformance: rows are positional against columns", %{client: client} do
        assert {:ok, %{"relations" => relations}} = sql_schema(client)

        for %{"name" => name, "required_quals" => required} <- relations,
            required == [] do
          assert {:ok, result} = sql_scan(client, name)
          assert_conformance_positional(name, result)
        end
      end

      @tag :sql_conformance
      test "conformance: cursor totality — paged walk equals unpaginated", %{client: client} do
        assert {:ok, %{"relations" => relations}} = sql_schema(client)

        for %{"name" => name, "required_quals" => required} <- relations,
            required == [] do
          assert {:ok, walk1} = drain(client, name, 1)
          assert {:ok, walk2} = drain(client, name, nil)

          assert walk1 == walk2,
                 "relation #{name}: limit-1 walk (#{length(walk1)} rows) differs from " <>
                   "default walk (#{length(walk2)} rows)"
        end
      end

      @tag :sql_conformance
      test "conformance: qual honesty — every returned row satisfies every qual",
           %{client: client} do
        assert {:ok, %{"relations" => relations}} = sql_schema(client)

        for %{
              "name" => name,
              "qual_columns" => [qual_column | _],
              "required_quals" => required,
              "columns" => relation_columns
            } <-
              relations,
            required == [] do
          assert {:ok, %{"rows" => rows}} = sql_scan(client, name)
          column_names = Enum.map(relation_columns, & &1["name"])

          # Probe with the first non-nil row value on this qual column.
          probe_value =
            Enum.find_value(rows, fn row ->
              index = Enum.find_index(column_names, &(&1 == qual_column))
              value = Enum.at(row, index)
              value != nil && value
            end)

          if probe_value do
            quals = [%{"column" => qual_column, "op" => "eq", "value" => probe_value}]
            assert {:ok, result} = sql_scan(client, name, quals: quals)

            decoded = [%{column: qual_column, op: :eq, value: probe_value}]

            for {row, index} <- Enum.with_index(result["rows"]) do
              map_row = column_names |> Enum.zip(row) |> Map.new()

              assert Quals.satisfies?(map_row, decoded),
                     "relation #{name} row #{index} violates qual " <>
                       "#{qual_column} = #{inspect(probe_value)}"
            end
          end
        end
      end

      @tag :sql_conformance
      test "conformance: error shape", %{client: client} do
        # Unknown relation → invalid_params.
        assert {:error, %{"code" => -32602}} = sql_scan(client, "no_such_relation_ever")

        # A dataset that implements only scan refuses writes with method_not_found.
        assert {:ok, %{"relations" => relations}} = sql_schema(client)

        readonly =
          Enum.find(relations, fn %{"kind" => kind, "writable" => writable} ->
            kind == "dataset" and writable == false
          end)

        if readonly do
          assert {:error, %{"code" => -32601, "message" => message}} =
                   sql_modify(client, readonly["name"], :delete)

          assert message =~ readonly["name"]
          assert message =~ "delete"
        end

        # A relation with required quals refuses unqualified scans.
        gated = Enum.find(relations, &(&1["required_quals"] != []))

        if gated do
          assert {:error, %{"code" => -32602, "message" => message}} =
                   sql_scan(client, gated["name"])

          assert message =~ gated["name"]
        end
      end

      defp drain(client, name, limit) do
        opts = if limit, do: [limit: limit], else: []
        drain_pages(client, name, opts, nil, [])
      end

      defp drain_pages(client, name, opts, cursor, acc) do
        assert {:ok, %{"rows" => rows, "nextCursor" => next}} =
                 sql_scan(client, name, Keyword.put(opts, :cursor, cursor))

        acc = acc ++ rows

        case next do
          nil -> {:ok, acc}
          next -> drain_pages(client, name, opts, next, acc)
        end
      end

      defp assert_conformance_schema_well_formed(relations) do
        kinds = ~w(catalog dataset tool resource prompt)

        for relation <- relations do
          assert %{"name" => name, "kind" => kind, "columns" => columns} = relation
          assert is_binary(name) and name != ""
          assert kind in kinds, "relation #{name}: bad kind #{kind}"

          assert is_list(columns) and columns != [],
                 "relation #{name} must declare columns"

          column_names = Enum.map(columns, & &1["name"])
          assert Enum.uniq(column_names) == column_names, "relation #{name}: duplicate columns"

          for column <- columns do
            assert is_binary(column["name"])
            assert is_binary(column["type"])
            assert is_boolean(column["nullable"])
          end

          assert is_list(relation["primary_key"])
          assert Enum.all?(relation["primary_key"], &(&1 in column_names))

          assert is_list(relation["qual_columns"])
          assert Enum.all?(relation["qual_columns"], &(&1 in column_names))

          assert is_list(relation["required_quals"])
          assert Enum.all?(relation["required_quals"], &(&1 in relation["qual_columns"]))

          assert is_boolean(relation["sort"])
          assert is_boolean(relation["limit"])
          assert is_boolean(relation["writable"])

          if kind == "tool" do
            assert is_binary(relation["tool"])
            assert is_boolean(relation["read_only"])
          else
            refute Map.has_key?(relation, "tool")
            refute Map.has_key?(relation, "read_only")
          end
        end
      end

      defp assert_conformance_positional(name, %{"columns" => columns, "rows" => rows}) do
        width = length(columns)

        for {row, index} <- Enum.with_index(rows) do
          assert is_list(row) and length(row) == width,
                 "relation #{name} row #{index} is not positional against #{width} columns"
        end
      end
    end
  end
end
