defmodule Noizu.MCP.VFS.Database.LiquibaseTemplateTest do
  @moduledoc """
  The shipped Liquibase template is what hosts actually apply, and the
  DB-gated conformance suite builds its scratch tables from
  `Noizu.MCP.VFS.Database.create_table_ddl/1`. If the two drift, the tests
  pass and production breaks — so compare them here, where it costs nothing
  and needs no database.
  """

  use ExUnit.Case, async: true

  @template "liquibase/noizu_mcp_vfs.yaml"
  @table "noizu_mcp_vfs_nodes"

  setup_all do
    yaml = read_template()
    %{yaml: yaml, ddl: Noizu.MCP.VFS.Database.create_table_ddl(@table)}
  end

  # Read the template from the source tree first, the packaged
  # `:code.priv_dir` copy as fallback. Worktree checkouts share the parent
  # `_build`, whose `priv` symlink resolves to the canonical checkout — the
  # packaged copy can lag the source there.
  defp read_template do
    source = Path.expand("../../../priv/#{@template}", __DIR__)

    if File.exists?(source) do
      File.read!(source)
    else
      File.read!(Path.join(:code.priv_dir(:noizu_mcp), @template))
    end
  end

  test "the template ships in the package", %{yaml: yaml} do
    assert yaml =~ "databaseChangeLog", "template is not a changelog"
    assert yaml =~ "author: noizu_mcp", "template has no noizu_mcp author"
  end

  test "every changeSet has a rollback", %{yaml: yaml} do
    change_sets = String.split(yaml, ~r/\n  - changeSet:/) |> tl()

    assert change_sets != [], "template defines no changeSets"

    for change_set <- change_sets do
      assert change_set =~ "rollback:",
             "a changeSet in the template has no rollback and cannot be undone"
    end
  end

  test "the same columns, in both copies", %{yaml: yaml, ddl: ddl} do
    assert columns(yaml, @table) == columns(ddl, @table)
  end

  test "the template matches the backend's column list", %{yaml: yaml} do
    # Drift guard against the code that speaks the table: every column
    # Noizu.MCP.VFS.Database references must exist in what hosts apply.
    for column <- Noizu.MCP.VFS.Database.columns() do
      assert column in columns(yaml, @table),
             "column #{column} is referenced by the backend but missing from the template"
    end
  end

  test "the type check constraint is pinned at the schema level", %{yaml: yaml} do
    assert yaml =~ "CHECK (type IN ('file','dir'))"
  end

  test "parent_path is indexed", %{yaml: yaml} do
    assert yaml =~ ~r/CREATE INDEX IF NOT EXISTS \w+\s*\n?\s*ON #{@table} \(parent_path\)/
  end

  test "timestamps follow the lib convention", %{ddl: ddl} do
    assert ddl =~ "created_at"
    assert ddl =~ "updated_at"
    refute ddl =~ "modified_at"
  end

  # ── crude but sufficient parsing ─────────────────────────────────────────
  # Same approach as the auth-server template test: take the body between
  # `CREATE TABLE x (` and the closing `);`, keep the first token of each
  # column line.

  defp columns(sql, table) do
    case Regex.run(~r/CREATE TABLE(?: IF NOT EXISTS)? #{table} \((.*?)\n\s*\)/s, sql) do
      [_, body] ->
        body
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "--")))
        |> Enum.map(fn line -> line |> String.split(~r/\s/, parts: 2) |> List.first() end)
        |> Enum.filter(&Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, &1))
        |> Enum.uniq()

      nil ->
        flunk("could not parse the definition of #{table}")
    end
  end
end
