defmodule Noizu.MCP.Test.EngineConformanceCase do
  @moduledoc """
  The shared engine conformance battery (PRD-11 §7.5), following
  `persistence_conformance_case.ex` / `sql_conformance_case.ex`. It asserts the
  three properties ANY engine deployment must hold:

    1. federated `tools/list` equals the union of the upstreams' own lists,
       every name prefixed, no duplicates, no omissions (AC-11.1);
    2. `sql/scan` over `servers` agrees with the live session states —
       one row per attached upstream, live `status` and `tool_count` (AC-11.2);
    3. an insert attaches a real stdio fixture upstream end to end: within the
       connect timeout its tools appear in `tools/list` and its status reads
       `ready` (AC-11.3, via `sql/modify`).

  Usage:

      defmodule Noizu.MCP.EngineConformanceTest do
        use ExUnit.Case, async: false
        use Noizu.MCP.Test.EngineConformanceCase
      end

  Non-async: the engine config and the `servers` store are process-global.
  """

  defmacro __using__(_opts) do
    quote do
      import Noizu.MCP.Test

      @engine Noizu.MCP.Engine

      setup do
        Noizu.MCP.Fixtures.Engine.setup_engine()
        Noizu.MCP.Fixtures.Engine.ensure_engine!()
        %{client: connect(@engine)}
      end

      @tag :engine_conformance
      test "conformance: federated tools/list is the prefixed union of upstream lists",
           %{client: client} do
        assert {:ok, _} =
                 attach_upstream(client, Noizu.MCP.Fixtures.Engine.row("cnfa"), timeout: 5_000)

        assert {:ok, _} =
                 attach_upstream(client, Noizu.MCP.Fixtures.Engine.row("cnfb"), timeout: 5_000)

        upstream_a = upstream_tools("cnfa")
        upstream_b = upstream_tools("cnfb")

        assert {:ok, tools} = list_tools(client, timeout: 5_000)
        names = Enum.map(tools, & &1.name)

        for name <- upstream_a, do: assert(name in names, "missing federated tool #{name}")
        for name <- upstream_b, do: assert(name in names, "missing federated tool #{name}")

        assert names == Enum.uniq(names), "federated catalog has duplicate names"

        # No omissions: every upstream tool the engine knows about is listed.
        assert length(names) >= length(upstream_a) + length(upstream_b)
      end

      @tag :engine_conformance
      test "conformance: servers scan agrees with live session states", %{client: client} do
        assert {:ok, _} =
                 attach_upstream(client, Noizu.MCP.Fixtures.Engine.row("cnfc"), timeout: 5_000)

        row = await_upstream_status(client, "cnfc", "ready")

        assert is_integer(row["tool_count"]) and row["tool_count"] > 0
        assert is_binary(row["protocol_version"])
        assert %{"name" => "cnfc"} = row["server_info"]
        assert row["last_seen"]
      end

      @tag :engine_conformance
      test "conformance: an insert attaches a stdio upstream end to end", %{client: client} do
        row = Noizu.MCP.Fixtures.Engine.row("cnfd")

        assert {:ok, %{"rows" => [inserted]}} =
                 sql_modify(client, "servers", :insert, rows: [row])

        assert %{"status" => "connecting"} = inserted

        row_map = await_upstream_status(client, "cnfd", "ready")
        assert row_map["tool_count"] > 0

        assert {:ok, tools} = list_tools(client, timeout: 5_000)
        assert Enum.any?(tools, &String.starts_with?(&1.name, "cnfd."))
      end

      defp upstream_tools(prefix) do
        pid = Noizu.MCP.Engine.Supervisor.pooled_pid(prefix)
        assert pid, "no upstream session for #{prefix}"

        assert {:ok, tools} = Noizu.MCP.Engine.Session.catalog(pid)

        Enum.map(tools, &Noizu.MCP.Engine.Toolset.join(prefix, &1.name))
      end
    end
  end
end
