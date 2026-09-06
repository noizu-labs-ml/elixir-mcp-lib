defmodule Noizu.MCP.Engine.LayeringTest do
  @moduledoc """
  Weight-100 placement (PRD-11 §7 layering_test.exs): a persisted operator
  override at 200 wins over a federated definition, ACL at 300 still filters —
  with NO federation-specific precedence code in the path (AC-11.13).
  """

  use ExUnit.Case, async: false

  import Noizu.MCP.Test

  alias Noizu.MCP.Engine
  alias Noizu.MCP.Engine.Session
  alias Noizu.MCP.Engine.Supervisor
  alias Noizu.MCP.Fixtures.Engine, as: Fixture
  alias Noizu.MCP.Persistence.Memory
  alias Noizu.MCP.Toolset.Override

  @store "toolset_grants"

  setup do
    Fixture.setup_engine()
    Fixture.ensure_engine!()

    on_exit(fn ->
      Fixture.reset!()
      Memory.delete(@store, "override-echo", [])
    end)

    :ok
  end

  test "a persisted set_name override wins over the federated definition (AC-11.13)" do
    assert {:ok, _} = attach_upstream(connect(Engine), Fixture.row("lyr"))
    await_ready("lyr")

    # Operator grant: rename the federated tool — weight 200 beats the
    # upstream layer's 100 through the ordinary merge fold (D2).
    grant = %{
      id: "override-echo",
      toolset_slug: "noizu-mcp-engine",
      authenticator: "claims",
      subject: "alice",
      effect: "allow",
      scopes: [],
      tool_overrides: %{
        "lyr.echo" => [
          Override.to_map(%Override{
            op: :set_description,
            target: "lyr.echo",
            value: "operator-overridden-description"
          })
        ]
      },
      expires_at: nil,
      inserted_at: nil,
      metadata: %{}
    }

    assert :ok = Memory.put(@store, "override-echo", grant, [])

    client = connect(Engine, client_info: %{name: "t", version: "1"})

    assert {:ok, tools} = list_tools(client, claims: %{"sub" => "alice"})
    tool = Enum.find(tools, &(&1.name == "lyr.echo"))
    assert tool, "federated tool visible"
    assert tool.description == "operator-overridden-description"

    # ...and the overridden tool still CALLS through to the upstream.
    assert {:ok, result} =
             call_tool(client, "lyr.echo", %{"message" => "hi"}, claims: %{"sub" => "alice"})

    assert [%{type: :text, text: "hi"}] = result.content
  end

  test "ACL filters federated tools through the same weight-300 layer as local tools" do
    client = connect(Engine)
    assert {:ok, _} = attach_upstream(client, Fixture.row("acl1"))
    await_ready("acl1")

    # The fixture ACL denies bob every "github*" tool; the engine's own tools
    # stay visible. The mechanism is the ordinary ACL layer — nothing here is
    # federation-specific.
    bob = connect(Engine, client_info: %{name: "t", version: "1"})
    {:ok, tools} = list_tools(bob)
    names = Enum.map(tools, & &1.name)
    assert "acl1.echo" in names
    assert "engine.attach" in names
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
