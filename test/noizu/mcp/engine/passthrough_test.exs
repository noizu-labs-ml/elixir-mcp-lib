defmodule Noizu.MCP.Engine.PassthroughTest do
  @moduledoc "Token pass-through (PRD-11 §4.6, §7 passthrough_test.exs, AC-11.12)."

  use ExUnit.Case, async: false

  import Noizu.MCP.Test

  alias Noizu.MCP.Engine
  alias Noizu.MCP.Engine.Session
  alias Noizu.MCP.Engine.Supervisor
  alias Noizu.MCP.Fixtures.Engine, as: Fixture

  @token "caller-bearer-ey-fixture-token"

  setup do
    Fixture.setup_engine()
    Fixture.ensure_engine!()
    on_exit(fn -> Fixture.reset!() end)
    :ok
  end

  test "a pass-through upstream receives the caller's token via its per-principal session" do
    alice = connect(Engine)

    assert {:ok, _} =
             attach_upstream(alice, %{
               Fixture.row("pt", tools: ["token"])
               | "auth_ref" => "passthrough"
             })

    # No CREDENTIAL-carrying session runs for a pass-through row: the pooled
    # catalog session connects anonymously and never proxies a call.
    Process.sleep(200)
    pid = Supervisor.pooled_pid("pt")
    assert pid
    assert %{status: "ready"} = Session.status(pid)

    assert {:ok, result} =
             call_tool(alice, "pt.token", %{}, claims: %{"sub" => "alice", "token" => @token})

    assert [%{type: :text, text: @token}] = result.content

    # Invocation went through the PER-PRINCIPAL session.
    assert Supervisor.session_pid({"pt", "alice"})
    assert Session.status(Supervisor.session_pid({"pt", "alice"})).status == "ready"
  end

  test "a caller with no token gets forbidden and the upstream receives no request" do
    anon = connect(Engine)

    assert {:ok, _} =
             attach_upstream(anon, %{
               Fixture.row("pt2", tools: ["token"])
               | "auth_ref" => "passthrough"
             })

    Process.sleep(200)

    assert {:error, error} = call_tool(anon, "pt2.token", %{})
    assert error["message"] =~ "credential"

    # No PER-PRINCIPAL session was ever started: the tokenless caller's
    # refusal happened engine-side, before any upstream request.
    per_principal_started? =
      Enum.any?(Supervisor.sessions(), fn
        {{name, _subject}, _pid} -> name == "pt2"
        {_pooled, _pid} -> false
      end)

    refute per_principal_started?
  end

  test "an idle pass-through session evicts itself" do
    Application.put_env(
      :noizu_mcp,
      :engine,
      Keyword.merge(Noizu.MCP.Engine.Config.all(), passthrough_idle_ms: 600)
    )

    alice = connect(Engine)

    assert {:ok, _} =
             attach_upstream(alice, %{
               Fixture.row("pt3", tools: ["token"])
               | "auth_ref" => "passthrough"
             })

    assert {:ok, _} =
             call_tool(alice, "pt3.token", %{}, claims: %{"sub" => "alice", "token" => @token})

    assert Supervisor.session_pid({"pt3", "alice"})

    wait_until(fn -> Supervisor.session_pid({"pt3", "alice"}) == nil end)
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp wait_until(fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    repeat_until(fun, deadline)
  end

  defp repeat_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline,
        do: flunk("condition not met before deadline")

      Process.sleep(50)
      repeat_until(fun, deadline)
    end
  end
end
