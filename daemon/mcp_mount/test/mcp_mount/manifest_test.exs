defmodule McpMount.ManifestTest do
  use ExUnit.Case, async: true

  alias McpMount.Manifest

  setup do
    dir = Path.join(System.tmp_dir!(), "mcp-mount-manifest-#{System.unique_integer()}")
    Manifest.prepare(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "prepare creates .mcp-mount with 0700" do
    dir = Path.join(System.tmp_dir!(), "mcp-mount-prep-#{System.unique_integer()}")
    Manifest.prepare(dir)

    assert File.dir?(dir)
    assert %File.Stat{mode: mode} = File.stat!(Manifest.dir(dir))
    assert Bitwise.band(mode, 0o777) == 0o700
    File.rm_rf!(dir)
  end

  test "read of missing manifest is empty map", %{dir: dir} do
    assert %{} == Manifest.read(dir)
  end

  test "write is atomic and read round-trips", %{dir: dir} do
    entries = %{
      "a.txt" => %{version: 3, mode: 0o644, size: 12},
      "d/b.txt" => %{version: 1, mode: 0o755, size: 4}
    }

    :ok = Manifest.write(dir, entries)

    # no temp file left behind
    refute File.exists?(Path.join(Manifest.dir(dir), "manifest.json.tmp"))

    assert entries == Manifest.read(dir)
  end

  test "ignored? covers .mcp-mount, dotfiles and conflict files" do
    assert Manifest.ignored?(".mcp-mount")
    assert Manifest.ignored?(".mcp-mount/manifest.json")
    assert Manifest.ignored?(".hidden")
    assert Manifest.ignored?("docs/note.md.conflict-2026-09-01T10-00-00Z")
    refute Manifest.ignored?("docs/note.md")
  end
end
