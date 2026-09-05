defmodule Noizu.MCP.Engine.ServersDatasetTest do
  @moduledoc "The `servers` dataset suite (PRD-11 §7 servers_dataset_test.exs)."

  use ExUnit.Case, async: false

  import Noizu.MCP.Test

  alias Noizu.MCP.Engine
  alias Noizu.MCP.Engine.{Servers, Supervisor}
  alias Noizu.MCP.Fixtures.Engine, as: Fixture

  setup do
    Fixture.setup_engine()
    Fixture.ensure_engine!()
    on_exit(fn -> Fixture.reset!() end)
    :ok
  end

  describe "columns/info" do
    test "declares the PRD-11 §4.2 columns" do
      names = Enum.map(Servers.columns(), & &1.name)

      assert names ==
               ~w(name transport command url auth_ref enabled status status_detail last_seen tool_count protocol_version server_info)

      derived =
        Enum.filter(
          Servers.columns(),
          &(&1.name in ~w(status status_detail last_seen tool_count protocol_version server_info))
        )

      for column <- derived, do: refute(column.name in Servers.info().primary_key)
      assert Servers.info().name == "servers"
      assert Servers.info().writable
    end
  end

  describe "insert" do
    test "persists the row through the configured provider and starts a session" do
      row = Fixture.row("ins")

      assert {:ok, [inserted]} = Servers.insert([row], nil)
      assert inserted["status"] == "connecting"

      # The store holds the operator columns only — no derived state (D3).
      {provider, popts} = Noizu.MCP.Engine.Config.persistence()
      assert {:ok, stored} = provider.get("engine_servers", "ins", popts)
      assert stored["name"] == "ins"
      refute Map.has_key?(stored, "status")

      # The session is a supervised child of the engine tree.
      assert Supervisor.pooled_pid("ins")
    end

    test "duplicate names are invalid_params" do
      assert {:ok, _} = Servers.insert([Fixture.row("dup")], nil)

      assert {:error, error} = Servers.insert([Fixture.row("dup")], nil)
      assert error.message =~ "duplicate upstream names"
    end

    test "the reserved engine prefix is rejected (FR-11.10)" do
      assert {:error, error} = Servers.insert([Fixture.row("engine")], nil)
      assert error.message =~ "reserved"
    end

    test "a malformed namespace prefix is rejected" do
      for bad <- ["GitHub", "1abc", "has space", "way_too_long_a_name_over_thirty_one_chars"] do
        assert {:error, error} = Servers.insert([Fixture.row(bad)], nil)
        assert error.code == -32_602
      end
    end

    test "a credential in auth_ref is rejected and nothing persists (AC-11.9, AP-P13)" do
      raw_token = "ghp_rawbearerAAAABBBBCCCC11112222"

      assert {:error, error} =
               Servers.insert([%{Fixture.row("leak") | "auth_ref" => raw_token}], nil)

      assert error.message =~ "reference"
      assert error.message =~ "query log"
      refute error.message =~ raw_token

      assert {:error, error} =
               Servers.insert([%{Fixture.row("leak") | "auth_ref" => "Bearer abc.def.ghi"}], nil)

      assert error.message =~ "env:VAR"

      {provider, popts} = Noizu.MCP.Engine.Config.persistence()
      assert :error = provider.get("engine_servers", "leak", popts)
      refute Supervisor.pooled_pid("leak")
    end

    test "stdio rows require command; http rows require url" do
      assert {:error, error} = Servers.insert([%{Fixture.row("nc") | "command" => nil}], nil)
      assert error.message =~ "command"

      assert {:error, error} = Servers.insert([%{Fixture.row("nu") | "transport" => "http"}], nil)
      assert error.message =~ "url"
    end
  end

  describe "update" do
    test "persists changes and restarts the session when connection fields change" do
      assert {:ok, _} = Servers.insert([Fixture.row("upd")], nil)
      wait_ready("upd")

      old_pid = Supervisor.pooled_pid("upd")

      assert {:ok, _} =
               Servers.update(
                 [%{column: "name", op: :eq, value: "upd"}],
                 %{"enabled" => false},
                 nil
               )

      stored = fetch_row("upd")
      assert stored["enabled"] == false

      # A changed row restarts the session.
      refute Supervisor.pooled_pid("upd") == old_pid
    end

    test "writing a derived column is rejected, naming it" do
      assert {:ok, _} = Servers.insert([Fixture.row("der")], nil)

      assert {:error, error} =
               Servers.update(
                 [%{column: "name", op: :eq, value: "der"}],
                 %{"status" => "ready"},
                 nil
               )

      assert error.message =~ "status"
      assert error.message =~ "derived"
    end

    test "name is insert-only" do
      assert {:ok, _} = Servers.insert([Fixture.row("io")], nil)

      assert {:error, error} =
               Servers.update(
                 [%{column: "name", op: :eq, value: "io"}],
                 %{"name" => "other"},
                 nil
               )

      assert error.message =~ "insert-only"
    end
  end

  describe "delete" do
    test "removes the row, stops the session, and counts (AC-11.4)" do
      assert {:ok, _} = Servers.insert([Fixture.row("del")], nil)
      wait_ready("del")
      assert {:ok, tools} = list_tools(connect(Engine), timeout: 5_000)
      assert Enum.any?(tools, &String.starts_with?(&1.name, "del."))

      assert {:ok, 1} = Servers.delete([%{column: "name", op: :eq, value: "del"}], nil)

      {provider, popts} = Noizu.MCP.Engine.Config.persistence()
      assert :error = provider.get("engine_servers", "del", popts)
      refute Supervisor.pooled_pid("del")

      assert {:ok, tools} = list_tools(connect(Engine), timeout: 5_000)
      refute Enum.any?(tools, &String.starts_with?(&1.name, "del."))
    end
  end

  describe "scan" do
    test "merges persisted rows with live session state; no session reads disconnected" do
      assert {:ok, _} = Servers.insert([Fixture.row("live")], nil)
      wait_ready("live")

      # A row that is present but disabled reads `disabled`, never stale-ready.
      assert {:ok, _} = Servers.insert([Fixture.row("off", enabled: false)], nil)

      assert {:ok, rows, nil} = Servers.scan(%{}, nil, %{})
      by_name = Map.new(rows, &{&1["name"], &1})

      assert by_name["live"]["status"] == "ready"
      assert by_name["live"]["tool_count"] > 0
      assert by_name["off"]["status"] == "disabled"
    end
  end

  describe "seed_static" do
    test "static config seeds rows, idempotently (D3)" do
      Application.put_env(
        :noizu_mcp,
        :engine,
        Keyword.merge(Noizu.MCP.Engine.Config.all(),
          static_servers: [%{"name" => "seed", "transport" => "stdio", "command" => "true"}]
        )
      )

      # setup_engine's on_exit restores the engine config (this test's rows are
      # cleaned by the setup on_exit reset).

      assert :ok = Servers.seed_static()
      assert %{"seed" => _} = Map.new(fetch_all(), &{&1["name"], &1})

      first_pid = Supervisor.pooled_pid("seed")
      assert :ok = Servers.seed_static()
      assert Supervisor.pooled_pid("seed") == first_pid
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp wait_ready(name) do
    deadline = System.monotonic_time(:millisecond) + 15_000

    repeat(
      fn ->
        case Supervisor.pooled_pid(name) do
          nil -> false
          pid -> Noizu.MCP.Engine.Session.status(pid).status == "ready"
        end
      end,
      deadline
    )
  end

  defp repeat(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline, do: flunk("timed out")
      Process.sleep(50)
      repeat(fun, deadline)
    end
  end

  defp fetch_row(name), do: fetch_all() |> Enum.find(&(&1["name"] == name))

  defp fetch_all do
    {provider, popts} = Noizu.MCP.Engine.Config.persistence()
    {:ok, rows} = provider.list("engine_servers", nil, popts)
    rows
  end
end
