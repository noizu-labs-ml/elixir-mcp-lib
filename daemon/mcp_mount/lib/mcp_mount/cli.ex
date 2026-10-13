defmodule McpMount.CLI do
  require Logger

  @moduledoc """
  `mcp-mount` escript entry point.

      mcp-mount --url ws://host:port/vfs [--token-file PATH | --token TOKEN] --mount DIR [--ro] [--deletes]

  Mounts the remote VFS at DIR as real local files and keeps them live.

  Token resolution (first match wins):

    1. `--token-file PATH` — read the token from PATH (trimmed) — recommended:
       keeps the token out of `ps` output
    2. `--token TOKEN` — legacy argv form; still accepted, but the token is
       visible to `ps` (one warning is logged, never the value)
    3. the `MCP_MOUNT_TOKEN` env var
    4. the default token file `~/.config/docmost-mcp/mount-token` (trimmed)

  Passing both `--token` and `--token-file` is a usage error (exit 64).
  A token file that is missing or trims to empty is a config error (exit 78).
  `--token`/env forms allow an empty token (accepted when the server has
  `auth: nil` or optional auth) — the connection still sends `vfs/auth`.
  `--deletes` opts in to pushing local deletions to the server (default
  off: a local `rm` is local-only). Runs in the foreground until killed.
  """

  @default_token_file "~/.config/docmost-mcp/mount-token"

  def main(argv) do
    Application.ensure_all_started(:logger)

    case parse_args(argv) do
      {:ok, config} ->
        run(config)

      {:usage, _} ->
        usage()
        System.halt(64)

      {:config_error, message} ->
        IO.puts(:stderr, "mcp-mount: " <> message)
        System.halt(78)
    end
  end

  @doc false
  @spec parse_args([String.t()]) ::
          {:ok, map()} | {:usage, nil} | {:config_error, String.t()}
  def parse_args(argv) do
    {opts, _rest, invalid} =
      OptionParser.parse(argv,
        strict: [
          url: :string,
          token: :string,
          token_file: :string,
          mount: :string,
          ro: :boolean,
          deletes: :boolean
        ]
      )

    cond do
      invalid != [] ->
        {:usage, nil}

      is_binary(opts[:token]) and is_binary(opts[:token_file]) ->
        {:usage, nil}

      not is_binary(opts[:url]) or not is_binary(opts[:mount]) ->
        {:usage, nil}

      true ->
        resolve_token(opts)
    end
  end

  defp resolve_token(opts) do
    cond do
      t = opts[:token] ->
        Logger.warning("mcp-mount: token passed via argv is visible to ps — use --token-file")
        {:ok, config(opts, t, :argv)}

      p = opts[:token_file] ->
        case read_token_file(p, "--token-file") do
          {:ok, token} -> {:ok, config(opts, token, :token_file)}
          {:error, message} -> {:config_error, message}
        end

      t = System.get_env("MCP_MOUNT_TOKEN") ->
        {:ok, config(opts, t, :env)}

      true ->
        case read_token_file(default_token_file(), "default token file") do
          {:ok, token} -> {:ok, config(opts, token, :default_file)}
          {:error, message} -> {:config_error, message}
        end
    end
  end

  defp config(opts, token, source) do
    %{
      url: opts[:url],
      mount: opts[:mount],
      token: token,
      ro: !!opts[:ro],
      deletes: !!opts[:deletes],
      token_source: source
    }
  end

  # Overridable via application env so tests never touch the real
  # ~/.config/docmost-mcp/mount-token.
  defp default_token_file do
    (Application.get_env(:mcp_mount, :default_token_file) || @default_token_file)
    |> Path.expand()
  end

  # Returns the trimmed token or an {:error, message}. The message may name
  # the PATH (not secret) but never the file CONTENT.
  defp read_token_file(path, label) do
    expanded = Path.expand(path)

    case File.read(expanded) do
      {:ok, content} ->
        case String.trim(content) do
          "" ->
            {:error,
             "#{label} #{path} is empty — write the mount token into it (leading/trailing " <>
               "whitespace is trimmed on read) or pass --token"}

          token ->
            {:ok, token}
        end

      {:error, :enoent} ->
        {:error,
         "#{label} #{path} not found — create it with the mount token " <>
           "(e.g. `openssl rand -hex 32 > #{path}`) or pass --token"}

      {:error, reason} ->
        {:error, "#{label} #{path} is unreadable: #{inspect(reason)}"}
    end
  end

  defp run(%{url: url, mount: mount, token: token, ro: ro, deletes: deletes}) do
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

  defp usage do
    IO.puts(:stderr, """
    usage: mcp-mount --url ws://host:port/vfs [--token-file PATH | --token TOKEN] --mount DIR [--ro] [--deletes]

    token: --token-file PATH (recommended — kept out of ps) | --token TOKEN (legacy — visible to ps)
           falls back to $MCP_MOUNT_TOKEN, then the default file ~/.config/docmost-mcp/mount-token
    """)
  end
end
