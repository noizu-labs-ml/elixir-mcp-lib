defmodule Noizu.MCP.VFS.ControlTest.DestructiveTool do
  @moduledoc false
  use Noizu.MCP.Server.Tool,
    name: "rm_rf",
    description: "Destroys things",
    annotations: [destructive_hint: true]

  input do
    field :path, :string, required: true
  end

  @impl true
  def call(%{path: _path}, _ctx), do: {:ok, "gone"}
end

defmodule Noizu.MCP.VFS.ControlTest.Gate do
  @moduledoc false
  def allow_all(_name, _args, _ctx), do: :ok
  def deny_all(_name, _args, _ctx), do: {:error, :denied}
  def allow_all_tagged(_tag, _name, _args, _ctx), do: :ok
end

defmodule Noizu.MCP.VFS.ControlTest.Toggles do
  @moduledoc false
  def motd, do: :persistent_term.get({__MODULE__, :motd}, "off")

  def set_motd(value) do
    :persistent_term.put({__MODULE__, :motd}, value)
    :ok
  end

  def fail_set(_value), do: {:error, :nope}
end

defmodule Noizu.MCP.VFS.ControlTest.Wrapper do
  @moduledoc false
  use Noizu.MCP.VFS.Control,
    server: Noizu.MCP.VFS.ControlTest.Server,
    real: Noizu.MCP.VFS.Fixture.Memory
end

defmodule Noizu.MCP.VFS.ControlTest.StandaloneWrapper do
  @moduledoc false
  use Noizu.MCP.VFS.Control, server: Noizu.MCP.VFS.ControlTest.Server
end

defmodule Noizu.MCP.VFS.ControlTest.AllowGateWrapper do
  @moduledoc false
  use Noizu.MCP.VFS.Control,
    server: Noizu.MCP.VFS.ControlTest.Server,
    tool_gate: {Noizu.MCP.VFS.ControlTest.Gate, :allow_all}
end

defmodule Noizu.MCP.VFS.ControlTest.DenyGateWrapper do
  @moduledoc false
  use Noizu.MCP.VFS.Control,
    server: Noizu.MCP.VFS.ControlTest.Server,
    tool_gate: {Noizu.MCP.VFS.ControlTest.Gate, :deny_all}
end

defmodule Noizu.MCP.VFS.ControlTest.TaggedGateWrapper do
  @moduledoc false
  use Noizu.MCP.VFS.Control,
    server: Noizu.MCP.VFS.ControlTest.Server,
    tool_gate: {Noizu.MCP.VFS.ControlTest.Gate, :allow_all_tagged, ["tag"]}
end

defmodule Noizu.MCP.VFS.ControlTest.ToggledWrapper do
  @moduledoc false
  use Noizu.MCP.VFS.Control,
    server: Noizu.MCP.VFS.ControlTest.Server,
    toggles: [
      %{
        name: "motd",
        get: {Noizu.MCP.VFS.ControlTest.Toggles, :motd, []},
        set: {Noizu.MCP.VFS.ControlTest.Toggles, :set_motd, []}
      },
      %{
        name: "broken",
        get: {Noizu.MCP.VFS.ControlTest.Toggles, :motd, []},
        set: {Noizu.MCP.VFS.ControlTest.Toggles, :fail_set, []}
      }
    ]
end

defmodule Noizu.MCP.VFS.ControlTest.ReadonlyWrapper do
  @moduledoc false
  use Noizu.MCP.VFS.Control,
    server: Noizu.MCP.VFS.ControlTest.ReadonlyServer,
    real: Noizu.MCP.VFS.Fixture.Memory
end

defmodule Noizu.MCP.VFS.ControlTest.ReadonlyServer do
  @moduledoc false
  use Noizu.MCP.Server, name: "ctl-ro", version: "0.1.0", vfs_readonly: true

  vfs(Noizu.MCP.VFS.ControlTest.ReadonlyWrapper)
end

defmodule Noizu.MCP.VFS.ControlTest.Server do
  @moduledoc false
  use Noizu.MCP.Server, name: "ctl-test", version: "0.2.0"

  tool Noizu.MCP.Fixtures.Echo
  tool Noizu.MCP.Fixtures.Fail
  tool Noizu.MCP.VFS.ControlTest.DestructiveTool

  vfs(Noizu.MCP.VFS.ControlTest.Wrapper)
end

defmodule Noizu.MCP.VFS.Control.ConformanceTest do
  # The full battery from `Noizu.MCP.VFS.Conformance` run through the composed
  # control backend — delegation must be invisible to the dispatcher.
  use Noizu.MCP.VFS.Conformance,
    backend: Noizu.MCP.VFS.ControlTest.Wrapper,
    seed: {Noizu.MCP.VFS.Fixture.Memory, :seed}
end

defmodule Noizu.MCP.VFS.ControlTest do
  # Control-tree behaviour itself is global (persistent_term buffers, the
  # cache_enabled application env), so the suite runs exclusively.
  use ExUnit.Case, async: false

  alias Noizu.MCP.Ctx
  alias Noizu.MCP.Server.Features.VFS
  alias Noizu.MCP.VFS.Cache

  @wrapper Noizu.MCP.VFS.ControlTest.Wrapper
  @server Noizu.MCP.VFS.ControlTest.Server

  setup do
    # Control nodes are live views; a 1ms dispatcher-cache TTL keeps repeat
    # reads honest in this suite without weakening the battery's own module.
    Application.put_env(:noizu_mcp, :vfs_cache_ttl_ms, 1)

    on_exit(fn ->
      Application.put_env(:noizu_mcp, :vfs_cache_enabled, true)
      Application.delete_env(:noizu_mcp, :vfs_cache_ttl_ms)
      :persistent_term.erase({Noizu.MCP.VFS.Control, :trace, @wrapper})
      Cache.purge(@wrapper)
    end)

    # Unique session per test — buffered tool results are keyed by session and
    # must not leak between tests the way a nil session_id would.
    seed = Noizu.MCP.VFS.Fixture.Memory.seed()
    session_id = "test-#{System.unique_integer([:positive])}"
    %{ctx: %Ctx{seed | session_id: session_id}}
  end

  # ── tree shape ────────────────────────────────────────────────────────────

  test "stat: the /etc/dev tree is directories and control nodes", %{ctx: ctx} do
    assert {:ok, node} = VFS.stat(@wrapper, "/etc/dev", ctx)
    assert node.type == :dir

    for path <- [
          "/etc",
          "/etc/dev/tools",
          "/etc/dev/runtime",
          "/etc/dev/cache",
          "/etc/dev/config"
        ] do
      assert {:ok, %Noizu.MCP.VFS{type: :dir}} = VFS.stat(@wrapper, path, ctx)
    end

    assert {:ok, %Noizu.MCP.VFS{type: :control, writable: true}} =
             VFS.stat(@wrapper, "/etc/dev/tools/echo", ctx)

    assert {:ok, %Noizu.MCP.VFS{type: :control, writable: false}} =
             VFS.stat(@wrapper, "/etc/dev/runtime/status", ctx)

    assert {:ok, %Noizu.MCP.VFS{type: :control, writable: true}} =
             VFS.stat(@wrapper, "/etc/dev/cache/flush", ctx)

    assert {:ok, %Noizu.MCP.VFS{type: :control, writable: true}} =
             VFS.stat(@wrapper, "/etc/dev/config/trace", ctx)
  end

  test "stat: unknown paths and tools are :enoent", %{ctx: ctx} do
    assert {:error, :enoent} = VFS.stat(@wrapper, "/etc/dev/nope", ctx)
    assert {:error, :enoent} = VFS.stat(@wrapper, "/etc/dev/tools/unknown_tool", ctx)
    assert {:error, :enoent} = VFS.stat(@wrapper, "/etc/dev/config/nope", ctx)
    assert {:error, :enoent} = VFS.stat(@wrapper, "/etc/dev/runtime/sessions/nope", ctx)
  end

  test "list: every directory level enumerates", %{ctx: ctx} do
    assert {:ok, entries, nil} = VFS.list(@wrapper, "/", nil, ctx)
    assert Enum.any?(entries, &match?(%{name: "etc", type: :dir}, &1))
    assert {:ok, [%{name: "dev"}], nil} = VFS.list(@wrapper, "/etc", nil, ctx)

    assert {:ok, entries, nil} = VFS.list(@wrapper, "/etc/dev", nil, ctx)
    assert Enum.map(entries, & &1.name) == ["cache", "config", "runtime", "tools"]

    assert {:ok, tools, nil} = VFS.list(@wrapper, "/etc/dev/tools", nil, ctx)
    names = Enum.map(tools, & &1.name)
    assert "echo" in names and "rm_rf" in names and "fail" in names

    assert {:ok, runtime, nil} = VFS.list(@wrapper, "/etc/dev/runtime", nil, ctx)
    assert Enum.map(runtime, & &1.name) == ["sessions", "status"]

    assert {:ok, cache, nil} = VFS.list(@wrapper, "/etc/dev/cache", nil, ctx)
    assert Enum.map(cache, & &1.name) == ["flush", "stats"]

    assert {:ok, config, nil} = VFS.list(@wrapper, "/etc/dev/config", nil, ctx)
    assert Enum.map(config, & &1.name) == ["cache_enabled", "trace"]
  end

  test "list: directories are :eisdir on read/write, files are :enotdir on list", %{ctx: ctx} do
    assert {:error, :eisdir} = VFS.read(@wrapper, "/etc/dev", ctx)
    assert {:error, :eisdir} = VFS.write(@wrapper, "/etc/dev", "x", ctx)
    assert {:error, :enotdir} = VFS.list(@wrapper, "/etc/dev/tools/echo", nil, ctx)
    assert {:error, :enoent} = VFS.list(@wrapper, "/etc/dev/nope", nil, ctx)
  end

  # ── tool schema + invocation ──────────────────────────────────────────────

  test "read: tool node exposes the definition JSON schema", %{ctx: ctx} do
    assert {:ok, body, version} = VFS.read(@wrapper, "/etc/dev/tools/echo", ctx)
    assert version >= 1

    definition = Jason.decode!(body)
    assert definition["name"] == "echo"
    assert definition["inputSchema"]["properties"]["message"]
    assert definition["annotations"]["readOnlyHint"] == true
  end

  test "invoke: write args JSON → next read returns the buffered result", %{ctx: ctx} do
    assert {:ok, _node} =
             VFS.write(@wrapper, "/etc/dev/tools/echo", ~s({"args": {"message": "hi"}}), ctx)

    assert {:ok, body, _version} = VFS.read(@wrapper, "/etc/dev/tools/echo", ctx)
    result = Jason.decode!(body)
    assert result["isError"] != true
    assert [%{"text" => "hi"}] = result["content"]

    # The buffer is consumed — the next (uncached) read is the definition again.
    Process.sleep(2)
    assert {:ok, body2, _} = VFS.read(@wrapper, "/etc/dev/tools/echo", ctx)
    assert Jason.decode!(body2)["inputSchema"]
  end

  test "invoke: write without args invokes with empty arguments", %{ctx: ctx} do
    # `echo` requires :message, so the empty-args invocation comes back as an
    # SEP-1303 execution error the model can self-correct from.
    assert {:ok, _node} = VFS.write(@wrapper, "/etc/dev/tools/echo", "{}", ctx)

    assert {:ok, body, _} = VFS.read(@wrapper, "/etc/dev/tools/echo", ctx)
    assert Jason.decode!(body)["isError"] == true
  end

  test "invoke: execution errors surface as isError results", %{ctx: ctx} do
    assert {:ok, _node} = VFS.write(@wrapper, "/etc/dev/tools/fail", "{}", ctx)

    assert {:ok, body, _} = VFS.read(@wrapper, "/etc/dev/tools/fail", ctx)
    assert Jason.decode!(body)["isError"] == true
  end

  test "invoke: unknown tool is :enoent, malformed JSON is :eio", %{ctx: ctx} do
    assert {:error, :enoent} = VFS.write(@wrapper, "/etc/dev/tools/unknown_tool", "{}", ctx)
    assert {:error, :eio} = VFS.write(@wrapper, "/etc/dev/tools/echo", "not json", ctx)
    assert {:error, :eio} = VFS.write(@wrapper, "/etc/dev/tools/echo", ~s({"args": "str"}), ctx)
    assert {:error, :eio} = VFS.write(@wrapper, "/etc/dev/tools/echo", "[1,2]", ctx)
  end

  test "results are buffered per connection context", %{ctx: ctx} do
    other = %Ctx{session_id: "other-session"}

    assert {:ok, _} =
             VFS.write(@wrapper, "/etc/dev/tools/echo", ~s({"args": {"message": "x"}}), ctx)

    assert {:ok, body, _} = VFS.read(@wrapper, "/etc/dev/tools/echo", other)
    # A different context sees the definition, not the buffered result.
    assert Jason.decode!(body)["inputSchema"]
  end

  # ── destructive-tool gating ───────────────────────────────────────────────

  test "destructive tools fail closed without a gate or allowlist", %{ctx: ctx} do
    assert {:error, :eacces} =
             VFS.write(@wrapper, "/etc/dev/tools/rm_rf", ~s({"args": {"path": "/"}}), ctx)
  end

  test "a per-token allowlist claim admits destructive tools", %{ctx: ctx} do
    allowed = %Ctx{assigns: %{auth_claims: %{"vfs_tool_allowlist" => ["rm_rf"]}}}

    assert {:ok, _} =
             VFS.write(@wrapper, "/etc/dev/tools/rm_rf", ~s({"args": {"path": "/"}}), allowed)

    assert {:ok, body, _} = VFS.read(@wrapper, "/etc/dev/tools/rm_rf", allowed)
    assert [%{"text" => "gone"}] = Jason.decode!(body)["content"]

    denied = %Ctx{assigns: %{auth_claims: %{"vfs_tool_allowlist" => ["echo"]}}}
    assert {:error, :eacces} = VFS.write(@wrapper, "/etc/dev/tools/rm_rf", "{}", denied)
  end

  test "tool_gate hook verdict is final", %{ctx: ctx} do
    allow = Noizu.MCP.VFS.ControlTest.AllowGateWrapper
    deny = Noizu.MCP.VFS.ControlTest.DenyGateWrapper
    tagged = Noizu.MCP.VFS.ControlTest.TaggedGateWrapper

    # The gate admits a destructive tool without any allowlist claim.
    assert {:ok, _} = VFS.write(allow, "/etc/dev/tools/rm_rf", ~s({"args": {"path": "/"}}), ctx)

    # The gate denies everything, destructive or not.
    assert {:error, :eacces} = VFS.write(deny, "/etc/dev/tools/echo", "{}", ctx)

    # {m, f, args} form appends the extra args ahead of (name, args, ctx).
    assert {:ok, _} = VFS.write(tagged, "/etc/dev/tools/echo", "{}", ctx)
  end

  # ── runtime status + sessions ─────────────────────────────────────────────

  test "status reports server info, capabilities, transports and uptime", %{ctx: ctx} do
    assert {:ok, body, _} = VFS.read(@wrapper, "/etc/dev/runtime/status", ctx)
    status = Jason.decode!(body)

    assert status["server"] == %{"name" => "ctl-test", "version" => "0.2.0"}
    assert status["capabilities"]["vfs"] == true
    assert status["capabilities"]["vfs_write"] == true
    assert "vfs_socket" in status["transports"]
    assert is_integer(status["uptime_ms"]) and status["uptime_ms"] >= 0
    assert is_integer(status["sessions"])
  end

  test "status is read-only", %{ctx: ctx} do
    assert {:error, :eacces} = VFS.write(@wrapper, "/etc/dev/runtime/status", "{}", ctx)
    assert {:error, :eacces} = VFS.write(@wrapper, "/etc/dev/cache/stats", "{}", ctx)
  end

  test "sessions are listed when the server is running", %{ctx: ctx} do
    # Directory exists even with nothing in it (may hold a lingering session
    # from an earlier test — only the *new* session is asserted below).
    assert {:ok, before, nil} = VFS.list(@wrapper, "/etc/dev/runtime/sessions", nil, ctx)

    %Noizu.MCP.Test.Client{} = Noizu.MCP.Test.connect(@server)
    sessions = wait_for_new_sessions(before, ctx)
    assert sessions != []

    [%{name: id} | _] = sessions

    assert {:ok, %Noizu.MCP.VFS{type: :control}} =
             VFS.stat(@wrapper, "/etc/dev/runtime/sessions/#{id}", ctx)

    assert {:ok, body, _} = VFS.read(@wrapper, "/etc/dev/runtime/sessions/#{id}", ctx)
    assert Jason.decode!(body)["id"] == id
  end

  # Session registration happens as the connection handshake lands — poll
  # briefly so the listing doesn't race it.
  defp wait_for_new_sessions(before, ctx, tries \\ 50) do
    {:ok, now, nil} = VFS.list(@wrapper, "/etc/dev/runtime/sessions", nil, ctx)
    ids_before = MapSet.new(before, & &1.name)
    fresh = Enum.filter(now, &(&1.name not in ids_before))

    cond do
      fresh != [] ->
        fresh

      tries > 1 ->
        Process.sleep(20)
        wait_for_new_sessions(before, ctx, tries - 1)

      true ->
        now
    end
  end

  # ── cache stats + flush ───────────────────────────────────────────────────

  test "cache stats report generations and entry counts", %{ctx: ctx} do
    VFS.stat(@wrapper, "/etc/dev", ctx)
    assert {:ok, body, _} = VFS.read(@wrapper, "/etc/dev/cache/stats", ctx)
    stats = Jason.decode!(body)

    assert is_integer(stats["generation"]["composed"])
    assert is_integer(stats["entries"]["composed"])
    assert stats["enabled"] == true
  end

  test "flush read is a hint; any write bumps every generation", %{ctx: ctx} do
    assert {:ok, body, _} = VFS.read(@wrapper, "/etc/dev/cache/flush", ctx)
    assert Jason.decode!(body)["hint"]

    gen_before = Cache.generation(@wrapper)
    real_before = Cache.generation(Noizu.MCP.VFS.Fixture.Memory)

    assert {:ok, node} = VFS.write(@wrapper, "/etc/dev/cache/flush", "go", ctx)
    assert node.xattrs["response"] == "ok"

    assert Cache.generation(@wrapper) == gen_before + 1
    assert Cache.generation(Noizu.MCP.VFS.Fixture.Memory) == real_before + 1
  end

  # ── config toggles ────────────────────────────────────────────────────────

  test "trace toggle round-trips and validates", %{ctx: ctx} do
    assert {:ok, "false", _} = VFS.read(@wrapper, "/etc/dev/config/trace", ctx)

    assert {:ok, _} = VFS.write(@wrapper, "/etc/dev/config/trace", "true", ctx)
    assert {:ok, "true", _} = VFS.read(@wrapper, "/etc/dev/config/trace", ctx)

    # With trace on, operations still flow (and now log).
    assert {:ok, _} = VFS.stat(@wrapper, "/etc/dev", ctx)

    assert {:error, :eio} = VFS.write(@wrapper, "/etc/dev/config/trace", "not json", ctx)
    assert {:error, :eio} = VFS.write(@wrapper, "/etc/dev/config/trace", ~s({"value": 1}), ctx)
    assert {:error, :eio} = VFS.write(@wrapper, "/etc/dev/config/trace", "42", ctx)
  end

  test "cache_enabled toggle mirrors VFS.Cache", %{ctx: ctx} do
    assert {:ok, "true", _} = VFS.read(@wrapper, "/etc/dev/config/cache_enabled", ctx)

    assert {:ok, _} = VFS.write(@wrapper, "/etc/dev/config/cache_enabled", "false", ctx)
    assert Application.get_env(:noizu_mcp, :vfs_cache_enabled) == false
    assert {:ok, "false", _} = VFS.read(@wrapper, "/etc/dev/config/cache_enabled", ctx)

    # Cache actually stands down while disabled — a live, unexpired entry is
    # no longer served.
    key = {:stat, "/x"}
    live = {System.monotonic_time(:millisecond) + 60_000, :stale}
    :persistent_term.put({:noizu_mcp_vfs_cache, @wrapper}, {99, %{key => live}})
    assert nil == Cache.get(@wrapper, :stat, "/x")

    assert {:ok, _} = VFS.write(@wrapper, "/etc/dev/config/cache_enabled", "true", ctx)
  end

  test "custom toggles from the :toggles registry", %{ctx: ctx} do
    wrapper = Noizu.MCP.VFS.ControlTest.ToggledWrapper

    assert {:ok, ~s("off"), _} = VFS.read(wrapper, "/etc/dev/config/motd", ctx)
    assert {:ok, _} = VFS.write(wrapper, "/etc/dev/config/motd", ~s("hello"), ctx)
    assert {:ok, ~s("hello"), _} = VFS.read(wrapper, "/etc/dev/config/motd", ctx)

    # A set that returns {:error, _} is :eio; unknown toggles are :enoent.
    assert {:error, :eio} = VFS.write(wrapper, "/etc/dev/config/broken", "1", ctx)
    assert {:error, :enoent} = VFS.write(wrapper, "/etc/dev/config/nope", "1", ctx)
    assert {:error, :enoent} = VFS.read(wrapper, "/etc/dev/config/nope", ctx)
  end

  # ── readonly safety gate ──────────────────────────────────────────────────

  test "vfs_readonly server opt: every write is :erofs, everywhere", %{ctx: ctx} do
    wrapper = Noizu.MCP.VFS.ControlTest.ReadonlyWrapper

    assert {:error, :erofs} = VFS.write(wrapper, "/etc/dev/tools/echo", "{}", ctx)
    assert {:error, :erofs} = VFS.write(wrapper, "/etc/dev/cache/flush", "x", ctx)
    assert {:error, :erofs} = VFS.write(wrapper, "/etc/dev/config/trace", "true", ctx)
    assert {:error, :erofs} = VFS.write(wrapper, "/hello.txt", "x", ctx)
    assert {:error, :erofs} = VFS.create(wrapper, "/new.txt", "x", ctx)
    assert {:error, :erofs} = VFS.remove(wrapper, "/hello.txt", ctx)
  end

  test "create/remove inside the control tree are refused", %{ctx: ctx} do
    assert {:error, :eacces} = VFS.create(@wrapper, "/etc/dev/extra", :dir, ctx)
    assert {:error, :eacces} = VFS.remove(@wrapper, "/etc/dev/config/trace", ctx)
  end

  # ── composition ───────────────────────────────────────────────────────────

  test "real-backend paths delegate through unchanged", %{ctx: ctx} do
    assert {:ok, node} = VFS.stat(@wrapper, "/hello.txt", ctx)
    assert node.type == :file

    assert {:ok, "hello world\n", _} = VFS.read(@wrapper, "/hello.txt", ctx)
    assert {:ok, _} = VFS.write(@wrapper, "/hello.txt", "changed\n", ctx)
    assert {:ok, "changed\n", _} = VFS.read(@wrapper, "/hello.txt", ctx)

    assert {:error, :enoent} = VFS.stat(@wrapper, "/nope", ctx)
  end

  test "the root listing merges the real backend with the control branch", %{ctx: ctx} do
    assert {:ok, entries, nil} = VFS.list(@wrapper, "/", nil, ctx)
    names = Enum.map(entries, & &1.name)
    assert "etc" in names
    assert "hello.txt" in names
    assert "docs" in names
  end

  test "standalone (no :real) backend serves only the control tree", %{ctx: ctx} do
    wrapper = Noizu.MCP.VFS.ControlTest.StandaloneWrapper

    assert {:ok, %Noizu.MCP.VFS{type: :dir}} = VFS.stat(wrapper, "/", ctx)
    assert {:ok, [%{name: "etc"}], nil} = VFS.list(wrapper, "/", nil, ctx)
    assert {:ok, _} = VFS.stat(wrapper, "/etc/dev", ctx)

    assert {:error, :enoent} = VFS.stat(wrapper, "/hello.txt", ctx)
    assert {:error, :enoent} = VFS.read(wrapper, "/hello.txt", ctx)
    assert {:error, :enoent} = VFS.write(wrapper, "/hello.txt", "x", ctx)
    assert {:error, :enoent} = VFS.search(wrapper, "/", "x", ctx)
    assert {:ok, %{}} = VFS.xattr(wrapper, "/etc/dev", ctx)
  end
end
