defmodule Noizu.MCP.Auth.Server.LiquibaseTemplateTest do
  @moduledoc """
  The shipped Liquibase template is what hosts actually apply, and the DB-gated
  conformance suite runs against a second copy of the same DDL in
  `test/support/oauth_schema.ex`. If the two drift, the tests pass and production
  breaks — so compare them here, where it costs nothing and needs no database.
  """
  use ExUnit.Case, async: true

  alias Noizu.MCP.Auth.Server.TestSchema

  @template Path.join(:code.priv_dir(:noizu_mcp), "liquibase/noizu_mcp_oauth.yaml")

  setup_all do
    %{yaml: File.read!(@template)}
  end

  test "the template ships in the package", %{yaml: yaml} do
    assert yaml =~ "databaseChangeLog"
    assert yaml =~ "author: noizu_mcp"
  end

  test "the same tables, in both copies", %{yaml: yaml} do
    assert tables(yaml) == Enum.sort(TestSchema.tables())
  end

  test "the same columns, table by table", %{yaml: yaml} do
    test_ddl = Enum.join(TestSchema.create_sql(), "\n")

    for table <- tables(yaml) do
      assert columns(yaml, table) == columns(test_ddl, table),
             "column drift in #{table} between the Liquibase template and test/support/oauth_schema.ex"
    end
  end

  test "every changeSet has a rollback", %{yaml: yaml} do
    # Only the uncommented ones: the optional subject-FK changeSet ships commented.
    change_sets = yaml |> String.split(~r/\n  - changeSet:/) |> tl()

    assert length(change_sets) == 6

    for change_set <- change_sets do
      assert change_set =~ "rollback:", "a changeSet with no rollback cannot be undone"
    end
  end

  test "the subject FK block is shipped commented out", %{yaml: yaml} do
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

  test "PKCE is pinned to S256 in the schema, not only in code", %{yaml: yaml} do
    assert yaml =~ "CHECK (code_challenge_method = 'S256')"
  end

  test "subject is text and unconstrained in the applied changeSets", %{yaml: yaml} do
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
