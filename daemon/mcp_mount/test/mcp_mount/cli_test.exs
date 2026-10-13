defmodule McpMount.CliTest do
  # The escript embeds the Elixir stdlib, so a stale/mixed build root can
  # produce a daemon that boots fine and dies on the first watcher event
  # (2026-10-13 live incident). McpMount.CLI.runtime_sanity!/0 probes the
  # dispatch paths that crash took at BOOT; this pins the probes themselves
  # passing on a healthy runtime (a broken runtime halts with exit 78 and a
  # plain stderr message instead of mounting).
  use ExUnit.Case, async: true

  alias McpMount.CLI

  test "runtime sanity probes pass on a healthy embedded runtime" do
    # a broken runtime halts(78); on a healthy one this just returns :ok
    assert :ok = CLI.runtime_sanity!()
  end
end
