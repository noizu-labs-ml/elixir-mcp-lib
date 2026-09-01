defmodule McpMount.IntegrationRealWSTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Mounter against a REAL VFSWS server (the lib transport hosting the demo
  server). Excluded by default; run with:

      MCP_MOUNT_E2E_URL=ws://127.0.0.1:4123/vfs mix test --include e2e_real

  Remote mutations go through a second direct WSConn connection — no
  dependency on any demo-server app, just the wire protocol. Scratch files
  are created under /notes/ with e2e- prefixed names.
  """

  import McpMount.Support

  alias McpMount.{Manifest, Mounter, WSConn}

  @moduletag :e2e_real

  @url System.get_env("MCP_MOUNT_E2E_URL")
  @token System.get_env("MCP_MOUNT_E2E_TOKEN", "demo-token")
  @scratch_rel "notes/e2e-scratch.md"
  @scratch_path "/notes/e2e-scratch.md"

  setup do
    dir = Path.join(System.tmp_dir!(), "mcp-mount-e2e-#{System.unique_integer()}")
    name = String.to_atom("mounter_e2e_#{System.unique_integer()}")

    {:ok, mutator} = WSConn.connect(url: @url, token: @token, owner: self())

    # the server persists across runs — clear any leftover scratch file
    WSConn.call(mutator, "vfs/remove", %{"path" => @scratch_path})

    mounter =
      start_supervised!(
        {Mounter, url: @url, token: @token, mount: dir, conn_mod: McpMount.WSConn, name: name}
      )

    wait_until(fn -> if elem(Mounter.state(mounter), 0) == :live, do: :ok end, 10_000)

    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir, mounter: mounter, mutator: mutator}
  end

  test "snapshot materializes the real seed tree + manifest", %{dir: dir} do
    assert File.regular?(Path.join(dir, "notes/welcome.md"))
    assert File.regular?(Path.join(dir, "personas/loom.md"))
    assert File.regular?(Path.join(dir, "etc/dev/flag"))

    entry = Manifest.read(dir)["notes/welcome.md"]
    assert %{version: v} = entry
    assert is_integer(v) and v >= 1
  end

  test "remote create/write over a second connection reaches the mount (root watch)", %{
    dir: dir,
    mutator: mutator
  } do
    path = Path.join(dir, @scratch_rel)

    assert {:ok, _} =
             WSConn.call(mutator, "vfs/create", %{"path" => @scratch_path, "data" => "one\n"})

    wait_until(fn -> if match?({:ok, "one\n"}, File.read(path)), do: :ok end)

    assert {:ok, _} =
             WSConn.call(mutator, "vfs/write", %{"path" => @scratch_path, "data" => "two\n"})

    wait_until(fn -> if match?({:ok, "two\n"}, File.read(path)), do: :ok end)

    assert %{version: v} = Manifest.read(dir)[@scratch_rel]
    assert is_integer(v) and v >= 1
  end

  test "local edit pushes back to the real server", %{dir: dir, mutator: mutator} do
    assert {:ok, _} =
             WSConn.call(mutator, "vfs/create", %{
               "path" => @scratch_path,
               "data" => "local-pending\n"
             })

    path = Path.join(dir, @scratch_rel)
    wait_until(fn -> if match?({:ok, "local-pending\n"}, File.read(path)), do: :ok end)

    write_and_wait_push(dir, @scratch_rel, "pushed from real mount\n", fn ->
      case WSConn.call(mutator, "vfs/read", %{"path" => @scratch_path}) do
        {:ok, %{"content" => "pushed from real mount\n", "version" => v}} -> is_integer(v)
        _ -> false
      end
    end)
  end

  test "remote remove deletes the mounted file", %{dir: dir, mutator: mutator} do
    assert {:ok, _} =
             WSConn.call(mutator, "vfs/create", %{"path" => @scratch_path, "data" => "bye\n"})

    path = Path.join(dir, @scratch_rel)
    wait_until(fn -> if File.regular?(path), do: :ok end)

    assert {:ok, _} = WSConn.call(mutator, "vfs/remove", %{"path" => @scratch_path})
    wait_until(fn -> if match?({:error, :enoent}, File.rm(path)), do: :ok end)
  end
end
