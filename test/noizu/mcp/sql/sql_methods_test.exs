defmodule Noizu.MCP.SQL.MethodsTest do
  use ExUnit.Case, async: false

  import Noizu.MCP.Test

  alias Noizu.MCP.Fixtures.SQL

  @server SQL.Server

  setup do
    SQL.Writable.reset()
    %{client: connect(@server)}
  end

  # Drain every cursor page — what the FDW (Postgres re-check) actually does.
  defp scan_all(client, relation, opts \\ []) do
    case sql_scan(client, relation, opts) do
      {:ok, result} -> {:ok, collect(client, relation, opts, result)}
      {:error, _} = error -> error
    end
  end

  defp collect(client, relation, opts, %{"rows" => rows, "nextCursor" => next} = result) do
    case next do
      nil ->
        rows

      _cursor ->
        {:ok, page} = sql_scan(client, relation, Keyword.put(opts, :cursor, next))
        rows ++ collect(client, relation, opts, page)
    end
  end

  describe "capabilities (FR-9.11)" do
    test "the server advertises experimental.sql version 1", %{client: client} do
      assert %{"version" => 1} = client.capabilities["experimental"]["sql"]
    end

    test "the sql capability merges non-destructively with other experimental keys" do
      flags = %{
        tools?: true,
        resources?: false,
        prompts?: false,
        completions?: false,
        vfs?: false,
        sql?: true,
        user_subscribe?: false
      }

      caps = Noizu.MCP.Server.build_capabilities(@server, flags)
      assert %{"sql" => %{"version" => 1}} = caps["experimental"]

      # A host folding its own key into `experimental` must not lose it to sql.
      caps = %{caps | "experimental" => Map.put(caps["experimental"], "host_key", %{"x" => 1})}
      caps = Noizu.MCP.Server.build_capabilities(@server, flags) |> Map.merge(caps)

      assert caps["experimental"]["sql"] == %{"version" => 1}
    end
  end

  describe "sql/schema (FR-9.5, AC-9.1)" do
    test "answers with the fixture dataset plus the catalog relations", %{client: client} do
      assert {:ok, %{"version" => 1, "relations" => relations}} = sql_schema(client)
      names = Enum.map(relations, & &1["name"])

      for name <- ["tools", "prompts", "resources", "empty_rows", "paged_rows", "principal_rows"] do
        assert name in names
      end

      refute "hidden_rows" in names
    end

    test "hidden datasets remain scannable by exact name", %{client: client} do
      assert {:ok, %{"rows" => [["hidden"]], "nextCursor" => nil}} =
               sql_scan(client, "hidden_rows")
    end
  end

  describe "sql/scan over datasets (FR-9.9)" do
    test "rows are positional against the returned columns", %{client: client} do
      assert {:ok, %{"columns" => columns, "rows" => rows}} = sql_scan(client, "paged_rows")

      assert columns == [%{"name" => "id"}, %{"name" => "label"}] |> Enum.map(& &1["name"])
      assert [first | _] = rows
      assert length(first) == 2
      assert Enum.at(first, 1) == "row-1"
    end

    test "pagination: limit + nextCursor, union equals unpaginated (AC-9.3)", %{client: client} do
      assert {:ok, all} = scan_all(client, "paged_rows")
      assert length(all) == 7

      assert {:ok, page1} = sql_scan(client, "paged_rows", limit: 2)
      assert length(page1["rows"]) == 2
      refute is_nil(page1["nextCursor"])

      assert {:ok, page2} = sql_scan(client, "paged_rows", limit: 2, cursor: page1["nextCursor"])
      assert {:ok, page3} = sql_scan(client, "paged_rows", limit: 2, cursor: page2["nextCursor"])
      assert {:ok, page4} = sql_scan(client, "paged_rows", limit: 2, cursor: page3["nextCursor"])

      assert is_nil(page4["nextCursor"])
      assert page1["rows"] ++ page2["rows"] ++ page3["rows"] ++ page4["rows"] == all
    end

    test "a dataset that ignores quals still yields correct results — the lib re-checks (AC-9.4)",
         %{client: client} do
      # Paged ignores quals entirely and pages at 3 rows; the library's
      # reference filter plus a full walk must still deliver only the
      # matching rows — the Postgres re-check model.
      quals = [%{"column" => "label", "op" => "eq", "value" => "row-4"}]

      assert {:ok, [[4, "row-4"]]} = scan_all(client, "paged_rows", quals: quals)
    end

    test "column projection subsets the output columns", %{client: client} do
      assert {:ok, %{"columns" => ["label"], "rows" => rows}} =
               sql_scan(client, "paged_rows", columns: ["label"])

      assert Enum.at(rows, 0) == ["row-1"]
    end

    test "unknown column in projection is dropped, not an error", %{client: client} do
      assert {:ok, %{"columns" => ["id"]}} =
               sql_scan(client, "paged_rows", columns: ["id", "not_a_column"])
    end

    test "an invalid cursor is invalid_params on a lib-paged relation", %{client: client} do
      assert {:error, %{"code" => -32602}} = sql_scan(client, "tools", cursor: "garbage!")
    end

    test "an unknown relation is invalid_params", %{client: client} do
      assert {:error, %{"code" => -32602, "message" => message}} = sql_scan(client, "nope")
      assert message =~ "nope"
    end

    test "missing relation param is invalid_params", %{client: client} do
      assert {:error, %{"code" => -32602}} = request(client, "sql/scan", %{})
    end

    test "a malformed qual is invalid_params", %{client: client} do
      assert {:error, %{"code" => -32602}} =
               sql_scan(client, "paged_rows", quals: [%{"column" => "id", "op" => "regex"}])
    end
  end

  describe "sql/scan over catalog relations (D1)" do
    test "the tools relation agrees with tools/list", %{client: client} do
      assert {:ok, tools} = list_tools(client)
      assert {:ok, %{"columns" => columns, "rows" => rows}} = sql_scan(client, "tools")

      name_index = Enum.find_index(columns, &(&1 == "name"))
      sql_names = rows |> Enum.map(&Enum.at(&1, name_index)) |> Enum.sort()
      assert sql_names == tools |> Enum.map(& &1.name) |> Enum.sort()
    end

    test "the prompts relation scans prompt catalog rows", %{client: client} do
      assert {:ok, %{"rows" => rows}} = sql_scan(client, "prompts")
      assert rows != []
    end

    test "the resources relation scans resource catalog rows", %{client: client} do
      assert {:ok, %{"rows" => rows}} = sql_scan(client, "resources")
      assert rows != []
    end
  end

  describe "sql/scan over read-through relations (AC-9.13)" do
    test "prompt_messages requires the prompt qual", %{client: client} do
      assert {:error, %{"code" => -32602, "message" => message}} =
               sql_scan(client, "prompt_messages")

      assert message =~ "prompt"
    end

    test "prompt_messages renders the rendered prompt", %{client: client} do
      quals = [
        %{"column" => "prompt", "op" => "eq", "value" => "code_review"},
        %{"column" => "arguments", "op" => "eq", "value" => %{"code" => "let it be"}}
      ]

      assert {:ok, %{"columns" => columns, "rows" => rows}} =
               sql_scan(client, "prompt_messages", quals: quals)

      role_index = Enum.find_index(columns, &(&1 == "role"))
      assert Enum.all?(rows, &(Enum.at(&1, role_index) == "user"))
    end

    test "resource_contents requires the uri qual", %{client: client} do
      assert {:error, %{"code" => -32602}} = sql_scan(client, "resource_contents")

      quals = [%{"column" => "uri", "op" => "eq", "value" => "config://app"}]
      assert {:ok, %{"rows" => rows}} = sql_scan(client, "resource_contents", quals: quals)
      assert rows != []
    end

    test "completions requires ref + argument quals", %{client: client} do
      assert {:error, %{"code" => -32602}} = sql_scan(client, "completions")

      quals = [
        %{
          "column" => "ref",
          "op" => "eq",
          "value" => %{"type" => "ref/prompt", "name" => "code_review"}
        },
        %{"column" => "argument_name", "op" => "eq", "value" => "style"},
        %{"column" => "argument_value", "op" => "eq", "value" => "s"}
      ]

      assert {:ok, %{"rows" => rows}} = sql_scan(client, "completions", quals: quals)
      assert rows != []
    end
  end

  describe "sql/scan over tool relations (FR-9.17)" do
    test "a read-only tool relation selects through tools/call" do
      client = connect(@server)
      quals = [%{"column" => "message", "op" => "eq", "value" => "hi"}]

      assert {:ok, %{"rows" => rows}} = sql_scan(client, "tool_echo", quals: quals)
      assert [row] = rows
      # content is a jsonb array of content blocks; is_error false.
      assert row |> Enum.at(0) == "hi"
    end

    test "a required tool argument behaves as a required qual" do
      client = connect(@server)
      assert {:error, %{"code" => -32602, "message" => message}} = sql_scan(client, "tool_echo")
      assert message =~ "message"
    end

    test "a denied tool is denied identically on both paths (AC-9.12)" do
      client = connect(SQL.ACLServer)
      claims = %{"sub" => "alice"}

      # tools/call → existence-hiding invalid_params (PRD-2 AP-5).
      assert {:error, %{"code" => -32602}} =
               request(client, "tools/call", %{"name" => "echo", "arguments" => %{}})

      # sql/scan over its relation → the identical denial class.
      assert {:error, %{"code" => -32602}} = sql_scan(client, "tool_echo", claims: claims)
    end

    test "an allowed tool scans and calls normally for the same principal" do
      client = connect(SQL.ACLServer)
      claims = %{"sub" => "alice"}

      quals = [%{"column" => "location", "op" => "eq", "value" => "NYC"}]

      assert {:ok, %{"rows" => rows}} =
               sql_scan(client, "tool_get_weather", quals: quals, claims: claims)

      assert rows != []
    end
  end

  describe "principal filtering (FR-9.12, AC-9.6, AP-P10)" do
    test "two principals over the same transport see different rows" do
      client = connect(@server)

      alice = sql_scan(client, "principal_rows", claims: %{"sub" => "alice"})
      bob = sql_scan(client, "principal_rows", claims: %{"sub" => "bob"})

      assert {:ok,
              %{"rows" => [["a1", "alice", "alice-private"], ["a2", "alice", "alice-second"]]}} =
               alice

      assert {:ok, %{"rows" => [["b1", "bob", "bob-private"]]}} = bob
    end

    test "claim-less and anonymous sessions see only public rows — no synthetic principal (AP-P10)" do
      client = connect(@server)

      assert {:ok, %{"rows" => [["public", "anonymous", "public-data"]]}} =
               sql_scan(client, "principal_rows")

      # Claims WITHOUT a "sub" never synthesize a principal (PRD-2 §4.5).
      assert {:ok, %{"rows" => [["public", "anonymous", "public-data"]]}} =
               sql_scan(client, "principal_rows", claims: %{"scope" => "everything"})
    end
  end

  describe "sql/modify (FR-9.10)" do
    test "insert returns the written rows; scan sees them", %{client: client} do
      assert {:ok, %{"rows" => [%{"id" => id, "value" => "v1"}]}} =
               sql_modify(client, "writable_rows", :insert, rows: [%{"value" => "v1"}])

      assert is_binary(id)

      assert {:ok, %{"rows" => rows}} = sql_scan(client, "writable_rows")
      values = Enum.map(rows, &Enum.at(&1, 1))
      assert "v1" in values
    end

    test "update applies changes to matching rows only", %{client: client} do
      {:ok, _} =
        sql_modify(client, "writable_rows", :insert, rows: [%{"value" => "a"}, %{"value" => "b"}])

      quals = [%{"column" => "value", "op" => "eq", "value" => "a"}]

      assert {:ok, %{"rows" => changed}} =
               sql_modify(client, "writable_rows", :update,
                 quals: quals,
                 changes: %{"value" => "a2"}
               )

      assert [%{"value" => "a2"}] = changed

      assert {:ok, %{"rows" => rows}} = sql_scan(client, "writable_rows")
      values = Enum.map(rows, &Enum.at(&1, 1))
      refute "a" in values
      assert "b" in values
    end

    test "delete returns the removed count", %{client: client} do
      {:ok, _} = sql_modify(client, "writable_rows", :insert, rows: [%{"value" => "gone"}])

      quals = [%{"column" => "value", "op" => "eq", "value" => "gone"}]
      assert {:ok, %{"count" => 1}} = sql_modify(client, "writable_rows", :delete, quals: quals)
      assert {:ok, %{"count" => 0}} = sql_modify(client, "writable_rows", :delete, quals: quals)
    end

    test "insert into a tool relation invokes the tool (§4.5 invocation)", %{client: client} do
      rows = [%{"message" => "via-insert", "repeat" => 2}]
      assert {:ok, %{"rows" => [row]}} = sql_modify(client, "tool_echo", :insert, rows: rows)

      # The returned row merges arguments and the tool result: content blocks
      # with the upcased echo, is_error false.
      assert %{"message" => "via-insert", "is_error" => false, "content" => content} = row
      assert [%{"type" => "text", "text" => "via-insertvia-insert"}] = content
    end

    test "writes to catalog relations are refused", %{client: client} do
      assert {:error, %{"code" => -32600, "message" => message}} =
               sql_modify(client, "tools", :delete)

      assert message =~ "read-only"
    end

    test "an invalid op is invalid_params", %{client: client} do
      assert {:error, %{"code" => -32602}} =
               request(client, "sql/modify", %{"relation" => "writable_rows", "op" => "truncate"})
    end

    test "delete quals are required input and decoded safely", %{client: client} do
      assert {:error, %{"code" => -32602}} =
               sql_modify(client, "writable_rows", :delete, quals: "junk")
    end
  end

  describe "dataset ACL subject (FR-9.18)" do
    test "a provider governing datasets consults check with {:dataset, name}" do
      client = connect(SQL.ACLServer)
      # EchoDenyProvider allows datasets: scan works.
      assert {:ok, %{"rows" => rows}} = sql_scan(client, "principal_rows")
      assert rows != []
    end

    test "a provider that does not recognize the dataset subject denies" do
      client = connect(SQL.NoDatasetKindServer)

      assert {:error, %{"code" => -32000, "message" => message}} =
               sql_scan(client, "empty_rows")

      assert message =~ "Forbidden"
      assert message =~ "empty_rows"
    end
  end
end
