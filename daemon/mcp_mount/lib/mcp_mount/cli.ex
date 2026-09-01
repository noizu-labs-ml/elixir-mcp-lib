defmodule McpMount.CLI do
  @moduledoc """
  `mcp-mount` escript entry point.

      mcp-mount --url ws://host:port/vfs --token TOKEN --mount DIR [--ro]

  Mounts the remote VFS at DIR as real local files and keeps them live.
  Token may also come from the `MCP_MOUNT_TOKEN` env var. Runs in the
  foreground until killed.
  """

  def main(argv) do
    Application.ensure_all_started(:logger)

    {opts, _rest, invalid} =
      OptionParser.parse(argv,
        strict: [url: :string, token: :string, mount: :string, ro: :boolean]
      )

    case {invalid, opts[:url], opts[:mount], token(opts)} do
      {[], url, mount, {:ok, token}} when is_binary(url) and is_binary(mount) ->
        run(url, mount, token, !!opts[:ro])

      _ ->
        usage()
        System.halt(64)
    end
  end

  defp run(url, mount, token, ro) do
    Logger.configure(level: :info)

    {:ok, _mounter} =
      McpMount.Mounter.start_link(
        url: url,
        token: token,
        mount: mount,
        ro: ro,
        conn_mod: McpMount.WSConn
      )

    IO.puts("mcp-mount: #{url} -> #{Path.expand(mount)}#{if ro, do: " (ro)", else: ""}")
    Process.sleep(:infinity)
  end

  defp token(opts) do
    cond do
      is_binary(opts[:token]) -> {:ok, opts[:token]}
      t = System.get_env("MCP_MOUNT_TOKEN") -> {:ok, t}
      true -> :error
    end
  end

  defp usage do
    IO.puts(:stderr, """
    usage: mcp-mount --url ws://host:port/vfs --token TOKEN --mount DIR [--ro]
    """)
  end
end
