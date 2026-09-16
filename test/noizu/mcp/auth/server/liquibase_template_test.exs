defmodule Noizu.MCP.Auth.Server.LiquibaseTemplateTest do
  @moduledoc """
  The shipped Liquibase templates are what hosts actually apply, and the DB-gated
  conformance suite runs against a second copy of the same DDL in
  `test/support/oauth_schema.ex`. If the two drift, the tests pass and production
  breaks — so compare them here, where it costs nothing and needs no database.

  There are two templates, applied independently: `noizu_mcp_oauth.yaml` is the
  authorization server, `noizu_mcp_agent.yaml` is the optional anonymous-agent
  block. A host may apply the first without the second. Their **union** is what
  the test schema must match.
  """
  use ExUnit.Case, async: true

  alias Noizu.MCP.Auth.Server.TestSchema

  @templates %{
    oauth: "liquibase/noizu_mcp_oauth.yaml",
    agent: "liquibase/noizu_mcp_agent.yaml"
  }

  setup_all do
    loaded =
      Map.new(@templates, fn {name, path} ->
        {name, File.read!(Path.join(:code.priv_dir(:noizu_mcp), path))}
      end)

    Map.put(loaded, :all, loaded |> Map.values() |> Enum.join("\n"))
  end

  test "both templates ship in the package", context do
    for name <- Map.keys(@templates) do
      yaml = Map.fetch!(context, name)
      assert yaml =~ "databaseChangeLog", "#{name} template is not a changelog"
      assert yaml =~ "author: noizu_mcp", "#{name} template has no noizu_mcp author"
    end
  end

  test "the same tables, in both copies", %{all: all} do
    assert tables(all) == Enum.sort(TestSchema.tables())
  end

  test "the same columns, table by table", %{all: all} do
    test_ddl = Enum.join(TestSchema.create_sql(), "\n")

    for table <- tables(all) do
      assert columns(all, table) == columns(test_ddl, table),
             "column drift in #{table} between the Liquibase templates and test/support/oauth_schema.ex"
    end
  end

  # Asserted per changeSet rather than against a total. A hard-coded count breaks
  # every time anyone adds a table and teaches the next person to bump the number
  # instead of reading what it was protecting — which was never the count.
  test "every changeSet has a rollback", context do
    for name <- Map.keys(@templates) do
      # Only the uncommented ones: the optional subject-FK changeSet ships commented.
      change_sets = context |> Map.fetch!(name) |> String.split(~r/\n  - changeSet:/) |> tl()

      assert change_sets != [], "#{name} template defines no changeSets"

      for change_set <- change_sets do
        assert change_set =~ "rollback:",
               "a changeSet in the #{name} template has no rollback and cannot be undone"
      end
    end
  end

  test "the agent template covers exactly the agent block", %{agent: yaml} do
    assert tables(yaml) == Enum.sort(~w(
             mcp_agent_account_events
             mcp_agent_account_keys
             mcp_agent_accounts
             mcp_agent_assertion_jti
             mcp_agent_credentials
             mcp_agent_sessions
           ))
  end

  # The agent block is optional, so it must not be reachable from the OAuth
  # template — a host that applies only the authorization server must not end up
  # with half an agent schema.
  test "the two templates share no tables", %{oauth: oauth, agent: agent} do
    assert tables(oauth) -- tables(agent) == tables(oauth)
  end

  test "the subject FK block is shipped commented out", %{oauth: yaml} do
    # It has to be optional: the library cannot assume the host has a `users`
    # table, and applying it would change `subject` to uuid.
    assert yaml =~ "noizu-mcp-oauth-subject-fk"

    fk_lines =
      yaml
      |> String.split("\n")
      |> Enum.filter(&String.contains?(&1, "REFERENCES users(id)"))

    assert fk_lines != []
    assert Enum.all?(fk_lines, &(String.trim_leading(&1) |> String.starts_with?("#")))
  end

  test "PKCE is pinned to S256 in the schema, not only in code", %{oauth: yaml} do
    assert yaml =~ "CHECK (code_challenge_method = 'S256')"
  end

  test "subject is text and unconstrained in the applied changeSets", %{oauth: yaml} do
    applied = yaml |> String.split("# - changeSet:") |> List.first()

    assert applied =~ "subject text NOT NULL"
    refute applied =~ "subject uuid"
  end

  # ── crude but sufficient parsing ─────────────────────────────────────────

  defp tables(sql) do
    ~r/^\s*CREATE TABLE (\w+) \(/m
    |> Regex.scan(sql)
    |> Enum.map(fn [_, table] -> table end)
    |> Enum.sort()
  end

  # Take the body between `CREATE TABLE x (` and the closing `);`, then keep the
  # first token of each line that starts one — good enough to catch a column
  # added on one side and not the other.
  defp columns(sql, table) do
    case Regex.run(~r/CREATE TABLE #{table} \((.*?)\n\s*\)[;\n]/s, sql) do
      [_, body] ->
        body
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(
          &(&1 == "" or String.starts_with?(&1, "--") or String.starts_with?(&1, "CONSTRAINT"))
        )
        |> Enum.map(fn line -> line |> String.split(~r/\s/, parts: 2) |> List.first() end)
        # A column line starts with a lowercase identifier; continuation lines of a
        # multi-line CHECK or REFERENCES clause do not.
        |> Enum.filter(&Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, &1))
        |> Enum.reject(&(&1 in ["check", "on", "references", "foreign", "unique"]))
        |> Enum.uniq()
        |> Enum.sort()

      nil ->
        flunk("could not parse the definition of #{table}")
    end
  end
end
