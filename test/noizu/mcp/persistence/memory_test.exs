defmodule Noizu.MCP.Persistence.MemoryTest do
  @moduledoc """
  The `Memory` provider against the shared conformance battery (AC-4.1) — the
  executable example of "a provider claims support by passing the case module"
  (AP-8).
  """
  use ExUnit.Case, async: false

  # The single public ETS table is process-global: wipe it (records AND
  # version counters) so every conformance test starts from an empty store.
  setup do
    Noizu.MCP.Persistence.Memory.reset()
    :ok
  end

  setup do
    %{adapter: Noizu.MCP.Persistence.Memory, store_opts: []}
  end

  use Noizu.MCP.Persistence.ConformanceCase

  # ── Memory-specific behavior ──────────────────────────────────────────────

  describe "memory-specific" do
    test "rows live in the single public table :noizu_mcp_persistence", ctx do
      record = grant()
      :ok = put(ctx, "toolset_grants", record.id, record)

      refute :ets.whereis(:noizu_mcp_persistence) == :undefined

      rows = :ets.tab2list(:noizu_mcp_persistence)

      assert Enum.any?(rows, fn
               {{"toolset_grants", id}, _json, _exp, _sort} -> is_binary(id)
               _other -> false
             end)
    end

    test "version starts at \"0\" on an untouched store", ctx do
      assert {:ok, "0"} = version(ctx, "toolset_negotiations")
    end

    test "the default ping is a version roundtrip", _ctx do
      assert :ok = Noizu.MCP.Persistence.ping(Noizu.MCP.Persistence.Memory, [])
    end
  end
end
