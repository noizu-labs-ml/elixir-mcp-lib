defmodule Noizu.MCP.Transport.Test do
  @moduledoc """
  In-memory transport for tests.

  As a server sink, delivers every outbound message to a designated process
  mailbox as `{:mcp_out, tag, binary, routing}`. The sink term is either a pid
  (`tag` will be `nil`) or `{pid, tag}` so one process can own several
  sessions and tell their traffic apart — see `Noizu.MCP.Test`.
  """

  @behaviour Noizu.MCP.Transport.Server

  @impl true
  # ⟦𓈧𓈶𓃇𓍝⟧ send_message :: auto-generated pointer for public function send_message
  def send_message(sink, iodata, routing) do
    {pid, tag} = destination(sink)
    send(pid, {:mcp_out, tag, IO.iodata_to_binary(iodata), routing})
    :ok
  end

  @impl true
  # ⟦𓈈𓐕𓁚𓀾⟧ close_session :: auto-generated pointer for public function close_session
  def close_session(sink) do
    {pid, tag} = destination(sink)
    send(pid, {:mcp_closed, tag})
    :ok
  end

  defp destination({pid, tag}) when is_pid(pid), do: {pid, tag}
  defp destination(pid) when is_pid(pid), do: {pid, nil}
end
