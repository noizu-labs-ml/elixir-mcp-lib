defmodule Noizu.MCP.SQL.ConformanceTest do
  use ExUnit.Case, async: false
  use Noizu.MCP.Test.SQLConformanceCase, server: Noizu.MCP.Fixtures.SQL.ConformanceServer

  setup do
    Noizu.MCP.Fixtures.SQL.Writable.reset()
    :ok
  end
end
