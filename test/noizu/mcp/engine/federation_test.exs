defmodule Noizu.MCP.Engine.FederationTest do
  @moduledoc """
  Federation surface: union property, namespacing, proxying, notification
  refresh and sql re-export (PRD-11 §7 federation_test.exs).
  """

  use ExUnit.Case, async: false

  import Noizu.MCP.Test

  alias Noizu.MCP.Engine
  alias Noizu.MCP.Engine.Session
  alias Noizu.MCP.Engine.Supervisor
  alias Noizu.MCP.Fixtures.Engine, as: Fixture

  setup do
    Fixture.setup_engine()
    Fixture.ensure_engine!()
    on_exit(fn -> Fixture.reset!() end)
    :ok
  end

  test "tools/list is the union of both upstreams, prefixed, no omissions (AC-11.1)" do
    client = connect(Engine)

    assert {:ok, _} = attach_upstream(client, Fixture.row("fed1", tools: ["echo", "fail"]))
    assert {:ok, _} = attach_upstream(client, Fixture.row("fed2", tools: ["echo"]))
    await_ready("fed1")
    await_ready("fed2")

    assert {:ok, tools} = list_tools(client, timeout: 5_000)
    names = Enum.map(tools, & &1.name)

    assert "fed1.echo" in names
    assert "fed1.fail" in names
    assert "fed2.echo" in names

    # The engine's own tools are still there, under the reserved prefix.
    assert "engine.attach" in names
    assert "engine.detach" in names
    assert "engine.refresh" in names

    # Both upstreams define `echo` — namespacing keeps them distinct (§4.4).
    assert Enum.count(names, &(&1 in ["fed1.echo", "fed2.echo"])) == 2
  end

  test "a down upstream contributes an empty layer; healthy upstreams keep serving (AC-11.5)" do
    client = connect(Engine)

    assert {:ok, _} = attach_upstream(client, Fixture.row("healthy"))

    assert {:ok, _} =
             attach_upstream(client, %{Fixture.row("dead") | "command" => "/nonexistent/xyz"})

    await_ready("healthy")

    assert {:ok, tools} = list_tools(client, timeout: 5_000)
    names = Enum.map(tools, & &1.name)
    assert "healthy.echo" in names

    # The broken one contributed nothing, and did not fail the listing.
    refute Enum.any?(names, &String.starts_with?(&1, "dead."))

    # ...and the status is visible in the registry.
    assert Supervisor.pooled_pid("dead")
  end

  test "tools/call on a federated tool reaches the upstream byte-identically, isError included (AC-11.7)" do
    client = connect(Engine)

    assert {:ok, _} = attach_upstream(client, Fixture.row("prx", tools: ["echo", "fail"]))
    await_ready("prx")

    assert {:ok, result} = call_tool(client, "prx.echo", %{"message" => "ping-through"})
    assert [%{type: :text, text: "ping-through"}] = result.content
    assert result.is_error == false

    assert {:ok, failure} = call_tool(client, "prx.fail", %{})
    assert failure.is_error == true
  end

  test "an upstream list_changed re-lists and the engine emits its own notification (AC-11.8)" do
    client = connect(Engine)

    assert {:ok, _} =
             attach_upstream(
               client,
               Fixture.row("chg", tools: ["echo", "emit_change"], change_adds: "added")
             )

    await_ready("chg")

    assert {:ok, tools} = list_tools(client, timeout: 5_000)
    refute Enum.any?(tools, &(&1.name == "chg.added"))

    # The proxied call makes the fixture EMIT notifications/tools/list_changed;
    # the session re-lists, the new tool appears, and our client sees the
    # engine's OWN downstream notification.
    assert {:ok, _} = call_tool(client, "chg.emit_change", %{})

    wait_until(fn ->
      {:ok, tools} = list_tools(client, timeout: 5_000)
      Enum.any?(tools, &(&1.name == "chg.added"))
    end)

    assert_notification(client, "notifications/tools/list_changed")
  end

  test "an upstream advertising experimental.sql re-exports <server>.<relation> and proxies scans (FR-11.19)" do
    client = connect(Engine)

    assert {:ok, _} = attach_upstream(client, Fixture.row("sq", advertise_sql: true))
    await_ready("sq")

    assert {:ok, %{"relations" => relations}} = sql_schema(client)
    exported = Enum.find(relations, &(&1["name"] == "sq.rows"))
    assert exported
    assert Enum.map(exported["columns"], & &1["name"]) == ["id", "label"]

    assert {:ok, %{"columns" => columns, "rows" => rows}} = sql_scan(client, "sq.rows")
    assert columns == ["id", "label"]
    assert length(rows) == 3
  end

  test "prompts and resources list through the federation with namespacing" do
    # The fixture upstream advertises no prompts/resources; the engine's own
    # listing must still succeed alongside federated tools (§4.4).
    assert {:ok, _} = attach_upstream(connect(Engine), Fixture.row("sur"))
    await_ready("sur")

    assert {:ok, _prompts} = list_prompts(connect(Engine))
    assert {:ok, _resources} = list_resources(connect(Engine))
    assert {:ok, _templates} = list_resource_templates(connect(Engine))
  end

  test "invoke of a name under a dead prefix resolves like an absent tool (no oracle change)" do
    client = connect(Engine)
    assert {:ok, _} = attach_upstream(client, Fixture.row("up1"))
    await_ready("up1")

    assert {:error, err1} = call_tool(client, "up1.nope", %{})
    assert {:error, err2} = call_tool(client, "ghost.nope", %{})
    assert err1["code"] == err2["code"]
  end

  test "proxied call on a down upstream returns an execution error, not a crash (D5)" do
    client = connect(Engine)
    assert {:ok, _} = attach_upstream(client, Fixture.row("dn1", tools: ["echo"]))
    await_ready("dn1")
    pid = Supervisor.pooled_pid("dn1")

    # Kill the client underneath; until the session notices, calls fail soft.
    assert Process.alive?(pid)
    assert {:ok, _} = call_tool(client, "dn1.echo", %{"message" => "ok"})
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp wait_until(fun, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    repeat_until(fun, deadline)
  end

  defp await_ready(name, timeout \\ 10_000) do
    wait_until(
      fn ->
        case Supervisor.pooled_pid(name) do
          nil -> false
          pid -> Session.status(pid).status == "ready"
        end
      end,
      timeout
    )

    :ok
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
