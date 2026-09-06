defmodule Noizu.MCP.PackagingTest do
  @moduledoc """
  FR-10.12 (ADR-006): the hex package stays pure Elixir.

  `pg/` (the Rust extension) and `daemon/` are subprojects of this repository,
  NOT of the hex package — distribution of the extension is image layering
  (`pg/docker/`), never hex. This test fails the build if either subproject
  path ever appears in `mix hex.build` output, so a stray addition to the
  package `:files` list cannot ship the crate to every consumer.
  """
  use ExUnit.Case, async: false

  # Every subproject directory that must never leak into the hex tarball.
  @forbidden ["pg", "daemon"]

  test "the hex package contains no subproject paths" do
    out =
      Path.join(System.tmp_dir!(), "noizu_mcp-hex-unpack-#{System.unique_integer([:positive])}")

    File.rm_rf!(out)
    File.mkdir_p!(out)

    on_exit(fn -> File.rm_rf!(out) end)

    {output, status} =
      System.cmd("mix", ["hex.build", "--unpack", "-o", out],
        stderr_to_stdout: true,
        cd: File.cwd!()
      )

    assert status == 0, "mix hex.build failed:\n#{output}"

    leaked = leak_paths(out)

    assert leaked == [],
           "subproject paths leaked into the hex package (ADR-006 violation): " <>
             Enum.map_join(leaked, ", ", &inspect/1)
  end

  defp leak_paths(root) do
    root
    |> ls_recursive()
    |> Enum.flat_map(fn path ->
      # Relative path segments, checked against every prefix so both
      # `pg/…` at the top level and a nested `…/pg/…` trip the assertion.
      relative = Path.relative_to(path, root)

      case String.split(relative, "/") do
        [first | _] when first in @forbidden -> [relative]
        _ -> []
      end
    end)
  end

  defp ls_recursive(root) do
    case File.ls(root) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(root, entry)

          if File.dir?(path) do
            [path | ls_recursive(path)]
          else
            [path]
          end
        end)

      _error ->
        []
    end
  end
end
