defmodule McpMount.CLI do
  require Logger

  @moduledoc """
  `mcp-mount` escript entry point.

      mcp-mount --url ws://host:port/vfs [--token TOKEN] --mount DIR [--ro] [--deletes]

  Mounts the remote VFS at DIR as real local files and keeps them live.
  `--token` is optional (empty token allowed). The connection still sends
  `vfs/auth`; an empty token is accepted when the server has `auth: nil`
  or optional auth. Token may also come from the `MCP_MOUNT_TOKEN` env var.
  `--deletes` opts in to pushing local deletions to the server (default
  off: a local `rm` is local-only). Runs in the foreground until killed.
  """

  def main(argv) do
    Application.ensure_all_started(:logger)

    {opts, _rest, invalid} =
      OptionParser.parse(argv,
        strict: [url: :string, token: :string, mount: :string, ro: :boolean, deletes: :boolean]
      )

    case {invalid, opts[:url], opts[:mount]} do
      {[], url, mount} when is_binary(url) and is_binary(mount) ->
        run(url, mount, token(opts), !!opts[:ro], !!opts[:deletes])

      _ ->
        usage()
        System.halt(64)
    end
  end

  defp run(url, mount, token, ro, deletes) do
    Logger.configure(level: :info)
    runtime_sanity!()

    # a read-only mount never pushes anything, deletes included — don't let
    # the flag look broken silently (robot review, head 80b7506)
    if ro and deletes do
      Logger.warning(
        "mcp-mount: --deletes has no effect on a --ro mount (read-only never pushes)"
      )
    end

    {:ok, _mounter} =
      McpMount.Mounter.start_link(
        url: url,
        token: token,
        mount: mount,
        ro: ro,
        deletes: deletes,
        conn_mod: McpMount.WSConn
      )

    IO.puts(
      "mcp-mount: #{url} -> #{Path.expand(mount)}#{if ro, do: " (ro)", else: ""}" <>
        if(deletes, do: " (deletes)", else: "")
    )

    Process.sleep(:infinity)
  end

  # Boot-time runtime sanity (2026-10-13 live incident): the escript embeds
  # the Elixir stdlib, so an escript built from a stale or mixed
  # MIX_BUILD_ROOT can shadow the host runtime with an incompatible beam set.
  # It boots, materializes the snapshot, then dies on the FIRST watcher event
  # with protocol/stdlib undefs (String.Chars.List, Inspect.Opts,
  # Exception.blame were the live trio). Probe the exact dispatch paths the
  # daemon leans on and refuse to mount when the embedded runtime is
  # inconsistent — failing at boot with a plain message beats dying
  # mid-mount with the tree half materialized.
  @doc false
  def runtime_sanity! do
    probes = [
      {"string_chars", fn -> String.Chars.to_string(~c"ok") == "ok" end},
      {"inspect", fn -> is_binary(inspect(%{"probe" => 1})) end},
      {"inspect_opts", fn -> Inspect.Opts.new([]) != nil end}
    ]

    Enum.each(probes, fn {label, probe} ->
      ok? =
        try do
          probe.()
        rescue
          _ -> false
        catch
          _, _ -> false
        end

      unless ok? do
        IO.puts(
          :stderr,
          "mcp-mount: embedded runtime failed the #{label} sanity probe — the escript was " <>
            "most likely built from a stale/mixed build root (an old MIX_BUILD_ROOT left " <>
            "over from a previous elixir or dependency set). Rebuild with a FRESH build " <>
            "root (rm -rf $MIX_BUILD_ROOT first, or unset MIX_BUILD_ROOT entirely) and remount."
        )

        System.halt(78)
      end
    end)

    :ok
  end

  defp token(opts) do
    cond do
      is_binary(opts[:token]) -> opts[:token]
      t = System.get_env("MCP_MOUNT_TOKEN") -> t
      true -> ""
    end
  end

  defp usage do
    IO.puts(:stderr, """
    usage: mcp-mount --url ws://host:port/vfs [--token TOKEN] --mount DIR [--ro] [--deletes]
    """)
  end
end
