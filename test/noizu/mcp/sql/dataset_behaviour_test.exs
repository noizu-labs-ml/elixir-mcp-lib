defmodule Noizu.MCP.SQL.DatasetBehaviourTest do
  use ExUnit.Case, async: false

  import Noizu.MCP.Test

  alias Noizu.MCP.Fixtures.SQL

  @server SQL.Server

  setup do
    SQL.Writable.reset()
    :ok
  end

  describe "use Noizu.MCP.Server.Dataset — __mcp_dataset__/1 introspection (FR-9.2)" do
    test "write-capable datasets publish their ops" do
      assert SQL.Writable.__mcp_dataset__(:ops) == [:insert, :update, :delete]
      assert SQL.Writable.__mcp_dataset__(:writable?) == true
    end

    test "scan-only datasets publish no ops" do
      assert SQL.Empty.__mcp_dataset__(:ops) == []
      assert SQL.Empty.__mcp_dataset__(:writable?) == false
    end

    test "registration opts are stored verbatim" do
      assert SQL.Hidden.__mcp_dataset__(:opts) == []
    end
  end

  describe "compile-time column validation (FR-9.2, D5)" do
    test "an unknown column type is a compile error" do
      suffix = System.unique_integer([:positive])

      assert_raise CompileError, ~r/unknown type :int32/, fn ->
        Code.compile_string("""
        defmodule Noizu.MCP.SQLBadType#{suffix} do
          use Noizu.MCP.Server.Dataset

          def info, do: %{name: "bad", primary_key: ["id"]}
          def columns, do: [%{name: "id", type: :int32, nullable: false}]
          def scan(_args, _ctx, _opts), do: {:ok, [], nil}
        end
        """)
      end
    end

    test "a non-list columns/0 is a compile error" do
      suffix = System.unique_integer([:positive])

      assert_raise CompileError, ~r/columns\/0 must return a list/, fn ->
        Code.compile_string("""
        defmodule Noizu.MCP.SQLBadColumns#{suffix} do
          use Noizu.MCP.Server.Dataset

          def info, do: %{name: "bad", primary_key: ["id"]}
          def columns, do: :nope
          def scan(_args, _ctx, _opts), do: {:ok, [], nil}
        end
        """)
      end
    end

    test "duplicate column names are a compile error" do
      suffix = System.unique_integer([:positive])

      assert_raise CompileError, ~r/duplicate column names/, fn ->
        Code.compile_string("""
        defmodule Noizu.MCP.SQLDupColumns#{suffix} do
          use Noizu.MCP.Server.Dataset

          def info, do: %{name: "bad", primary_key: ["id"]}
          def columns do
            [
              %{name: "id", type: :text, nullable: false},
              %{name: "id", type: :text, nullable: false}
            ]
          end
          def scan(_args, _ctx, _opts), do: {:ok, [], nil}
        end
        """)
      end
    end

    test "missing columns/0 or info/0 is a compile error" do
      suffix = System.unique_integer([:positive])

      assert_raise CompileError, ~r/requires columns\/0 and info\/0/, fn ->
        Code.compile_string("""
        defmodule Noizu.MCP.SQLNoCallbacks#{suffix} do
          use Noizu.MCP.Server.Dataset
        end
        """)
      end
    end

    test "a malformed info/0 is a compile error" do
      suffix = System.unique_integer([:positive])

      assert_raise CompileError, ~r/non-empty string :name/, fn ->
        Code.compile_string("""
        defmodule Noizu.MCP.SQLBadInfo#{suffix} do
          use Noizu.MCP.Server.Dataset

          def info, do: %{primary_key: ["id"]}
          def columns, do: [%{name: "id", type: :text, nullable: false}]
          def scan(_args, _ctx, _opts), do: {:ok, [], nil}
        end
        """)
      end
    end
  end

  describe "optional callbacks absent → method_not_found (FR-9.10, AC-9.5)" do
    test "sql/modify delete on a scan-only dataset names the relation and op" do
      client = connect(@server)

      assert {:error, %{"code" => -32601, "message" => message}} =
               sql_modify(client, "empty_rows", :delete)

      assert message =~ "empty_rows"
      assert message =~ "delete"

      # The same server's sql/scan still works (AC-9.5).
      assert {:ok, %{"rows" => []}} = sql_scan(client, "empty_rows")
    end

    test "sql/modify insert and update are refused the same way" do
      client = connect(@server)

      assert {:error, %{"code" => -32601, "message" => message}} =
               sql_modify(client, "empty_rows", :insert, rows: [%{"id" => "x"}])

      assert message =~ "empty_rows"
      assert message =~ "insert"

      assert {:error, %{"code" => -32601}} =
               sql_modify(client, "empty_rows", :update, quals: [], changes: %{})
    end
  end

  describe "a raising dataset fails only its own relation (FR-9.13, AC-9.7, D5)" do
    test "scan of boom_rows errors; siblings stay healthy in the same session" do
      client = connect(@server)

      assert {:error, %{"code" => -32603}} = sql_scan(client, "boom_rows")

      assert {:ok, %{"rows" => rows}} = sql_scan(client, "paged_rows", limit: 2)
      assert length(rows) == 2

      assert {:ok, %{"relations" => relations}} = sql_schema(client)
      assert Enum.any?(relations, &(&1["name"] == "boom_rows"))
    end

    test "sql/schema still describes the raising relation — the failure is at read" do
      client = connect(@server)
      assert {:ok, _} = sql_schema(client)

      # And the error is an internal_error shaped as %Error{}, not a crash.
      assert {:error, %{"code" => -32603, "message" => message}} = sql_scan(client, "boom_rows")
      assert message =~ "boom dataset exploded"
    end

    test "a raising write fails cleanly too" do
      client = connect(@server)

      # update with an un-decodable qual shape surfaces invalid_params, not a crash.
      assert {:error, %{"code" => -32602}} =
               sql_modify(client, "writable_rows", :update, quals: "junk", changes: %{"v" => 1})
    end
  end
end
