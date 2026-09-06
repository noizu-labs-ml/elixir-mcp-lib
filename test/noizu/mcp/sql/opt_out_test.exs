defmodule Noizu.MCP.SQL.OptOutTest do
  use ExUnit.Case, async: true

  import Noizu.MCP.Test

  # AC-9.2 / AP-P11: a server that registers no datasets and does not pass
  # `sql: true` must be byte-identical on the wire to a pre-PRD-9 server —
  # no experimental.sql capability and -32601 for all three methods.
  @plain_servers [Noizu.MCP.Fixtures.EmptyServer, Noizu.MCP.Fixtures.Server]

  for server <- @plain_servers do
    test "#{inspect(server)} advertises no experimental.sql" do
      client = connect(unquote(server))
      refute Map.has_key?(client.capabilities, "experimental")
    end

    test "#{inspect(server)} answers -32601 for all three sql methods" do
      client = connect(unquote(server))

      assert {:error, %{"code" => -32601}} = sql_schema(client)

      assert {:error, %{"code" => -32601}} = sql_scan(client, "anything")
      assert {:error, %{"code" => -32601}} = sql_modify(client, "anything", :delete)
    end
  end

  test "sql: true opts in with no datasets — the derived surface is the whole story" do
    client = connect(Noizu.MCP.Fixtures.SQL.ReadOnlyServer)

    assert %{"sql" => %{"version" => 1}} = client.capabilities["experimental"]

    assert {:ok, %{"relations" => relations}} = sql_schema(client)
    names = Enum.map(relations, & &1["name"])
    assert "tools" in names
    assert "tool_echo" in names
    assert Enum.all?(names, &(&1 not in ["empty_rows", "paged_rows"]))
  end

  test "a host-defined handle_sql_* alone opts in" do
    client = connect(Noizu.MCP.Fixtures.SQL.HostSQLServer)

    assert %{"sql" => %{"version" => 1}} = client.capabilities["experimental"]
    # The host's override wins over the generated default (defoverridable).
    assert {:ok, %{"custom" => true}} = sql_schema(client)
  end
end
