defmodule McpMount.MounterStatusTest do
  # Crash reports render the terminating GenServer's state, and the Mounter
  # state holds the mount token (live leak 2026-10-13: a crash while logging
  # a dead-watcher reason echoed the token into the console transcript).
  # format_status/1 redacts it — pinned here through the same code path
  # (:sys.get_status) the report renderer uses.
  use ExUnit.Case, async: false

  import McpMount.Support

  alias McpMount.{FakeConn, Mounter}
  alias McpMount.Test.FakeVfs

  @token "super-secret-mount-token-do-not-leak"

  setup do
    dir = Path.join(System.tmp_dir!(), "mcp-mount-st-#{System.unique_integer()}")
    name = String.to_atom("mounter_st_#{System.unique_integer()}")

    _fake = start_supervised!({FakeVfs, tree()})

    mounter =
      start_supervised!(
        Supervisor.child_spec(
          {
            Mounter,
            url: "ws://fake/vfs",
            token: @token,
            mount: dir,
            conn_mod: FakeConn,
            conn_opts: [handler: FakeVfs.handler()],
            name: name
          },
          id: name
        )
      )

    wait_until(fn -> if elem(Mounter.state(mounter), 0) == :live, do: :ok end)

    on_exit(fn ->
      File.rm_rf!(dir)
      FakeVfs.stop()
    end)

    %{dir: dir, mounter: mounter}
  end

  defp tree do
    [
      {"/docs", %{type: :dir, version: 1}},
      {"/docs/hello.txt", %{type: :file, version: 1, content: "hello world\n"}}
    ]
  end

  test "status reports redact the mount token", %{mounter: mounter} do
    rendered = inspect(:sys.get_status(mounter))

    refute rendered =~ @token
    assert rendered =~ "<redacted>"
  end

  test "format_status passes through non-mounter status maps unchanged" do
    assert :other = Mounter.format_status(:other)
  end
end
