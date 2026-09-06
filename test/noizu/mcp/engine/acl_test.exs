defmodule Noizu.MCP.Engine.ACLTest do
  @moduledoc "Per-principal ACL over federated tools and registry rows (PRD-11 §7 acl_test.exs)."

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

  test "two principals see different tools and different servers rows (AC-11.11, AP-P17)" do
    alice = connect(Engine)
    assert {:ok, _} = attach_upstream(alice, Fixture.row("github", tools: ["echo"]))
    assert {:ok, _} = attach_upstream(alice, Fixture.row("other"))
    await_ready("github")
    await_ready("other")

    # Alice sees both upstreams' tools and both registry rows.
    assert {:ok, alice_tools} = list_tools(alice)
    alice_names = Enum.map(alice_tools, & &1.name)
    assert "github.echo" in alice_names
    assert "other.echo" in alice_names

    assert upstream_row(alice, "github")
    assert upstream_row(alice, "other")

    # Bob is denied the whole github upstream: none of its tools, AND no
    # registry row for it (the registry cannot leak what one may not use).
    bob = connect(Engine)
    bob_claims = %{"sub" => "bob"}

    assert {:ok, bob_tools} = list_tools(bob, timeout: 5_000, claims: bob_claims)
    bob_names = Enum.map(bob_tools, & &1.name)
    refute Enum.any?(bob_names, &String.starts_with?(&1, "github"))
    assert "other.echo" in bob_names
    assert "engine.attach" in bob_names

    assert nil == upstream_row(bob, "github", claims: bob_claims)
    assert upstream_row(bob, "other", claims: bob_claims)
  end

  test "a denied tool returns the same error an absent tool returns (FR-11.15, AP-P16)" do
    alice = connect(Engine)
    assert {:ok, _} = attach_upstream(alice, Fixture.row("alpha", tools: ["echo", "fail"]))
    await_ready("alpha")

    bob = connect(Engine)
    bob_claims = %{"sub" => "bob"}

    # Denied and absent resolve through the SAME invalid_params shape — the
    # only textual difference is the caller's own input name (no discovery
    # oracle: neither reveals whether the upstream exists).
    assert {:error, denied} = call_tool(bob, "alpha.private", %{}, claims: bob_claims)
    assert {:error, absent} = call_tool(bob, "alpha.does_not_exist", %{}, claims: bob_claims)

    assert denied["code"] == absent["code"]
    assert String.starts_with?(denied["message"], "Unknown tool: ")

    # And the proxy never ran: the upstream got no request for the denied name.
    assert {:error, denied_alice} = call_tool(alice, "alpha.private", %{})
    assert denied_alice["code"] == absent["code"]
  end

  test "a principal denied an upstream cannot invoke through the denied prefix (AP-P16)" do
    alice = connect(Engine)
    assert {:ok, _} = attach_upstream(alice, Fixture.row("github", tools: ["echo", "fail"]))
    await_ready("github")

    bob = connect(Engine)
    bob_claims = %{"sub" => "bob"}

    # Denied upstream: its tools are out of the catalog, so the direct call
    # gets the absent-tool error, never a proxied result.
    assert {:error, denied} =
             call_tool(bob, "github.echo", %{"message" => "hi"}, claims: bob_claims)

    assert denied["code"] == -32_602

    # Alice still reaches it.
    assert {:ok, result} = call_tool(alice, "github.echo", %{"message" => "hi"})
    assert [%{type: :text, text: "hi"}] = result.content
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp await_ready(name) do
    deadline = System.monotonic_time(:millisecond) + 10_000

    repeat_until(
      fn ->
        case Supervisor.pooled_pid(name) do
          nil -> false
          pid -> Session.status(pid).status == "ready"
        end
      end,
      deadline
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
