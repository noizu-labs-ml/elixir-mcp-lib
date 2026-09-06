defmodule Noizu.MCP.Engine.SessionTest do
  @moduledoc "Session supervision, backoff and redaction (PRD-11 §7 session_test.exs)."

  use ExUnit.Case, async: false

  import Noizu.MCP.Test

  alias Noizu.MCP.Engine
  alias Noizu.MCP.Engine.{Config, Session, Supervisor}
  alias Noizu.MCP.Fixtures.Engine, as: Fixture

  setup do
    Fixture.setup_engine()
    Fixture.ensure_engine!()
    on_exit(fn -> Fixture.reset!() end)
    :ok
  end

  describe "backoff schedule" do
    test "delays are exponential, capped at max, jitter-shortening only" do
      assert Config.compute_backoff({100, 10_000, 0.0}, 0) == 100
      assert Config.compute_backoff({100, 10_000, 0.0}, 1) == 200
      assert Config.compute_backoff({100, 10_000, 0.0}, 3) == 800
      assert Config.compute_backoff({100, 10_000, 0.0}, 20) == 10_000

      # Jitter only ever shortens a delay, and never below 0.
      for _ <- 1..200 do
        delay = Config.compute_backoff({100, 10_000, 0.2}, 2)
        assert delay <= 400 and delay >= 320
      end
    end
  end

  describe "connect" do
    test "a healthy stdio fixture reaches ready with its catalog (AC-11.6 setup)" do
      assert {:ok, _} = attach_upstream(connect(Engine), Fixture.row("ses"))
      pid = await_ready("ses")

      view = Session.status(pid)
      assert view.status == "ready"
      assert view.tool_count > 0
      assert view.last_seen
      assert view.server_info["name"] == "ses"
      assert is_binary(view.protocol_version)
    end

    test "a broken upstream sets error with a redacted detail and retries forever (D5)" do
      row = %{Fixture.row("broken") | "command" => "/nonexistent/binary-xyz"}

      assert {:ok, _} = attach_upstream(connect(Engine), row)

      pid = await_status("broken", "error")
      view = Session.status(pid)
      assert view.status_detail =~ "could not be started"

      # It keeps retrying (backoff capped at 200ms in the fixture config) and
      # stays a live session — one idle process, no crash, no downed engine.
      Process.sleep(500)
      assert Process.alive?(pid)
      assert Session.status(pid).status == "error"
      assert Supervisor.pooled_pid("broken") == pid
    end

    test "an unresolvable auth_ref names the reference, never a value (FR-11.5)" do
      row = %{Fixture.row("secret") | "auth_ref" => "secret:unresolved"}

      assert {:ok, _} = attach_upstream(connect(Engine), row)

      pid = await_status("secret", "error")

      assert Session.status(pid).status_detail ==
               "auth_ref could not be resolved: secret:unresolved"
    end

    test "a resolved secret never appears in status_detail (AC-11.10)" do
      row = %{Fixture.row("secret") | "auth_ref" => "secret:engine/github"}

      assert {:ok, _} = attach_upstream(connect(Engine), row)

      pid = await_ready("secret")
      view = Session.status(pid)
      assert view.status == "ready"
      refute inspect(view) =~ Fixture.Secrets.value()
    end
  end

  describe "reconnect" do
    test "killing a ready upstream flips error then back to ready (AC-11.6)" do
      assert {:ok, _} = attach_upstream(connect(Engine), Fixture.row("die", die_after: 800))

      pid = await_ready("die")

      # The fixture SIGKILLs itself at ~800ms; the session must notice, mark
      # error, and reconnect — no operator action.
      wait_until(fn -> Session.status(pid).status == "error" end)
      assert Session.status(pid).status_detail == "connection lost"

      wait_until(fn -> Session.status(pid).status == "ready" end, 15_000)
      assert Supervisor.pooled_pid("die") == pid
    end
  end

  describe "engine.refresh" do
    test "forces a re-list and reports per-upstream status" do
      assert {:ok, _} = attach_upstream(connect(Engine), Fixture.row("rfr"))
      pid = await_ready("rfr")

      view = Session.refresh(pid)
      assert view[:name] == "rfr"
      assert view[:status] == "ready"
      assert view[:tool_count] > 0
      assert Process.alive?(pid)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp await_ready(name), do: await_status(name, "ready")

  defp await_status(name, status) do
    wait_until(fn ->
      case Supervisor.pooled_pid(name) do
        nil -> false
        pid -> Session.status(pid).status == status
      end
    end)

    Supervisor.pooled_pid(name)
  end

  defp wait_until(fun, timeout \\ 10_000) do
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
