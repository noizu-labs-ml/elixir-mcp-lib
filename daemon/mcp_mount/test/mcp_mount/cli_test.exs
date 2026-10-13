defmodule McpMount.CliTest do
  # The escript embeds the Elixir stdlib, so a stale/mixed build root can
  # produce a daemon that boots fine and dies on the first watcher event
  # (2026-10-13 live incident). McpMount.CLI.runtime_sanity!/0 probes the
  # dispatch paths that crash took at BOOT; this pins the probes themselves
  # passing on a healthy runtime (a broken runtime halts with exit 78 and a
  # plain stderr message instead of mounting).
  #
  # The rest of the module pins the token-resolution contract (F20): the
  # token comes from a FILE (--token-file, or the default
  # ~/.config/docmost-mcp/mount-token) so it never rides in argv where every
  # `ps` prints it. --token stays for back-compat but must warn.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias McpMount.CLI

  @argv_base ["--url", "ws://127.0.0.1:4700/vfs", "--mount", "/tmp/mcp-mount-cli-test-mount"]

  setup do
    # Per-test default-token-file under tmp; the real ~/.config file is
    # never touched (its content is a secret).
    token_file =
      Path.join(
        System.tmp_dir!(),
        "mcp-mount-cli-default-token-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:mcp_mount, :default_token_file, token_file)
    System.delete_env("MCP_MOUNT_TOKEN")

    on_exit(fn ->
      Application.delete_env(:mcp_mount, :default_token_file)
      System.delete_env("MCP_MOUNT_TOKEN")
      File.rm(token_file)
    end)

    {:ok, token_file: token_file}
  end

  test "runtime sanity probes pass on a healthy embedded runtime" do
    # a broken runtime halts(78); on a healthy one this just returns :ok
    assert :ok = CLI.runtime_sanity!()
  end

  ## --token-file (the recommended form)

  test "--token-file reads the file and trims surrounding whitespace", %{token_file: tf} do
    File.write!(tf, "  tok-abc-123\n\n")

    log =
      capture_log(fn ->
        assert {:ok, cfg} = CLI.parse_args(@argv_base ++ ["--token-file", tf])
        assert cfg.token == "tok-abc-123"
        assert cfg.token_source == :token_file
      end)

    # the file content must never surface in logs
    refute log =~ "tok-abc-123"
  end

  test "missing explicit --token-file is a config error naming the path" do
    ghost =
      Path.join(System.tmp_dir!(), "mcp-mount-cli-ghost-#{System.unique_integer([:positive])}")

    assert {:config_error, msg} = CLI.parse_args(@argv_base ++ ["--token-file", ghost])
    assert msg =~ "not found"
    # the path is safe to name; there is no content to leak by construction
    assert msg =~ ghost
  end

  test "explicit --token-file that trims to empty is a config error", %{token_file: tf} do
    File.write!(tf, "  \n\t \n")

    assert {:config_error, msg} = CLI.parse_args(@argv_base ++ ["--token-file", tf])
    assert msg =~ "empty"
  end

  test "unreadable explicit --token-file is a config error", %{token_file: tf} do
    File.write!(tf, "tok")
    File.chmod!(tf, 0o000)

    try do
      assert {:config_error, msg} = CLI.parse_args(@argv_base ++ ["--token-file", tf])
      assert msg =~ "unreadable"
    after
      File.chmod!(tf, 0o644)
    end
  end

  ## default token file (neither flag given)

  test "without token flags the default token file is read (trimmed)", %{token_file: tf} do
    File.write!(tf, "\n  default-tok  \n")

    assert {:ok, cfg} = CLI.parse_args(@argv_base)
    assert cfg.token == "default-tok"
    assert cfg.token_source == :default_file
  end

  test "missing default token file is a config error naming the path", %{token_file: tf} do
    assert {:config_error, msg} = CLI.parse_args(@argv_base)
    assert msg =~ "not found"
    assert msg =~ tf
  end

  test "default token file that trims to empty is a config error", %{token_file: tf} do
    File.write!(tf, "   \n")

    assert {:config_error, msg} = CLI.parse_args(@argv_base)
    assert msg =~ "empty"
  end

  ## env fallback (kept back-compat: env wins only when no flag is given)

  test "MCP_MOUNT_TOKEN is used when no token flag is given", %{token_file: tf} do
    System.put_env("MCP_MOUNT_TOKEN", "env-tok")

    assert {:ok, cfg} = CLI.parse_args(@argv_base)
    assert cfg.token == "env-tok"
    assert cfg.token_source == :env
    # env wins over the default file
    File.write!(tf, "default-tok")

    assert {:ok, cfg} = CLI.parse_args(@argv_base)
    assert cfg.token == "env-tok"
  end

  ## legacy --token (back-compat: warned, value never logged)

  test "--token still works but logs the ps warning, never the value", %{token_file: tf} do
    token = "secret-argv-value-do-not-log-4567"
    File.write!(tf, "default-tok")

    log =
      capture_log(fn ->
        assert {:ok, cfg} = CLI.parse_args(@argv_base ++ ["--token", token])
        assert cfg.token == token
        assert cfg.token_source == :argv
      end)

    assert log =~ "token passed via argv is visible to ps — use --token-file"
    refute log =~ token
  end

  test "empty --token is still accepted (back-compat: empty token allowed)" do
    assert {:ok, cfg} = CLI.parse_args(@argv_base ++ ["--token", ""])
    assert cfg.token == ""
    assert cfg.token_source == :argv
  end

  ## precedence

  test "explicit --token-file wins over the default token file", %{token_file: tf} do
    File.write!(tf, "default-tok")
    explicit = tf <> ".explicit"
    File.write!(explicit, "explicit-tok")
    on_exit(fn -> File.rm(explicit) end)

    assert {:ok, cfg} = CLI.parse_args(@argv_base ++ ["--token-file", explicit])
    assert cfg.token == "explicit-tok"
    assert cfg.token_source == :token_file
  end

  test "explicit --token-file wins over MCP_MOUNT_TOKEN", %{token_file: tf} do
    System.put_env("MCP_MOUNT_TOKEN", "env-tok")
    File.write!(tf, "file-tok")

    assert {:ok, cfg} = CLI.parse_args(@argv_base ++ ["--token-file", tf])
    assert cfg.token == "file-tok"
    assert cfg.token_source == :token_file
  end

  ## usage errors (exit 64 in main)

  test "--token and --token-file together is a usage error", %{token_file: tf} do
    File.write!(tf, "tok")

    assert {:usage, _} = CLI.parse_args(@argv_base ++ ["--token", "a", "--token-file", tf])
  end

  test "unknown flag is a usage error" do
    assert {:usage, _} = CLI.parse_args(@argv_base ++ ["--transport", "ws"])
  end

  test "missing --mount is a usage error" do
    assert {:usage, _} = CLI.parse_args(["--url", "ws://127.0.0.1:4700/vfs"])
  end

  test "missing --url is a usage error" do
    assert {:usage, _} = CLI.parse_args(["--mount", "/tmp/x"])
  end
end
