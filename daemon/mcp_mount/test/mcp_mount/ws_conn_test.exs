defmodule McpMount.WSConnTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import McpMount.Support

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

  # Conn contract: a deadline fires as the `{:error, :timeout}` VALUE, never
  # as an exit out of call/4.
  test "deadline is returned as {:error, :timeout}, not raised" do
    # accepts the call envelope but never replies
    pid =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, _msg} -> Process.sleep(:infinity)
        end
      end)

    assert {:error, :timeout} = WSConn.call(pid, "vfs/ping", nil, 10)
  end

  test "a conn that died mid-call surfaces as {:error, :closed}, not raised" do
    pid = spawn(fn -> :ok end)

    wait_until(fn -> if Process.alive?(pid), do: nil, else: :ok end)

    assert {:error, :closed} = WSConn.call(pid, "vfs/ping", nil, 10)
  end
end
