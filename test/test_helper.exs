# Two batteries in this suite do not run unless you ask for them:
#
#   * the `Store.Ecto` conformance battery, gated on `MCP_OAUTH_TEST_DATABASE_URL`
#   * every `:e2e` suite (real subprocesses, a real Bandit listener), excluded by
#     default below because they are slow
#   * the `:pg_mcp` end-to-end suite (PRD-10): the extension FDW driven through
#     a real Postgres running the layered image — needs Docker plus
#     `PG_MCP_URL`; see `pg/docker/README.md` for the one-liner
#
# Both used to disappear in silence. A run that skipped the entire Ecto adapter
# reported "923 passed" in exactly the same words as a run that exercised it,
# and a `Store.Ecto` that had never performed a single INSERT shipped to two
# host applications behind that number.
#
# So an incomplete run is now a FAILING run. `mix test` exits non-zero and says
# what was not executed and how to execute it. To acknowledge a deliberately
# partial run (a fast single-file loop, a machine with no Postgres), set
# `MCP_SKIP_FULL_COVERAGE=1` — it still prints the banner, it just stops failing.
# A `--only pg_mcp` run is inherently partial (it exists to run exactly one
# battery against external infrastructure), so it is acknowledged by design.

db_url = System.get_env("MCP_OAUTH_TEST_DATABASE_URL")

e2e_included? =
  ExUnit.configuration()
  |> Keyword.get(:include, [])
  |> Enum.any?(fn
    :e2e -> true
    {:e2e, _} -> true
    _ -> false
  end)

# PRD-10: a `--only pg_mcp` run deliberately runs just the pg_mcp battery
# against external infrastructure (a Dockerized Postgres running the layered
# extension image). It is a partial run by construction, so it acknowledges
# itself instead of demanding MCP_SKIP_FULL_COVERAGE.
pg_mcp_included? =
  ExUnit.configuration()
  |> Keyword.get(:include, [])
  |> Enum.any?(fn
    :pg_mcp -> true
    {:pg_mcp, _} -> true
    _ -> false
  end)

not_run =
  []
  |> then(fn acc ->
    if db_url,
      do: acc,
      else: [
        "MCP_OAUTH_TEST_DATABASE_URL is unset — the ENTIRE Store.Ecto conformance " <>
          "battery did not run. The Ecto adapter is UNVERIFIED in this run."
        | acc
      ]
  end)
  |> then(fn acc ->
    if e2e_included?,
      do: acc,
      else: [
        "`--include e2e` was not passed — the stdio transport E2E suite " <>
          "(real subprocesses) did not run. The stdio transport is UNVERIFIED in this run."
        | acc
      ]
  end)

acknowledged? =
  System.get_env("MCP_SKIP_FULL_COVERAGE") in ~w(1 true yes) or pg_mcp_included?

full_coverage_command = """
Full coverage:

    MCP_OAUTH_TEST_DATABASE_URL="postgres://USER:PASS@127.0.0.1:5432/noizu_mcp_test" \\
      mix test --include e2e --include slow

Deliberately partial run: prefix with MCP_SKIP_FULL_COVERAGE=1.
"""

if not_run != [] do
  IO.puts(:stderr, [
    "\n\e[33m",
    String.duplicate("=", 78),
    "\nINCOMPLETE COVERAGE — this run does NOT verify the whole library:\n",
    Enum.map(not_run, &["  * ", &1, "\n"]),
    "\n",
    full_coverage_command,
    String.duplicate("=", 78),
    "\e[0m\n"
  ])
end

ExUnit.start(exclude: [:e2e, :pg_mcp])

if not_run != [] and not acknowledged? do
  defmodule Noizu.MCP.CoverageGateTest do
    @moduledoc """
    Not a test of the library — a test of the run. It fails so that an
    incomplete run cannot be mistaken for a green one.
    """
    use ExUnit.Case, async: false

    @not_run not_run
    @command full_coverage_command

    test "the full suite did not run" do
      flunk("""
      This run skipped work and would otherwise have reported success:

      #{Enum.map_join(@not_run, "\n", &("  * " <> &1))}

      #{@command}
      """)
    end
  end
end
