defmodule McpMount.WSConnTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias McpMount.WSConn

  test "stream errors log bounded metadata without raw transport payloads" do
    state = %WSConn{conn: :invalid}
    secret = "sensitive-vfs-payload"

    log =
      capture_log(fn ->
        assert {:noreply, ^state} =
                 WSConn.handle_info({:tcp, :socket, secret}, state)
      end)

    assert log =~ "stream error exception=struct="
    assert log =~ "msg=tuple(tag=tcp,arity=3)"
    refute log =~ secret
  end
end
