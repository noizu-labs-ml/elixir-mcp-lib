defmodule Noizu.MCP.Store.StoreTest do
  @moduledoc """
  The Store write path (PRD-4 §4.7 / FR-4.8 / AC-4.6): provider write →
  version bump → cache invalidate → notify_changed(:tools) fan-out, with
  notify failures isolated (D5 — the write already succeeded). Plus the
  AP-11 source-level assertion: no data-plane side channels — the ONLY reader
  of the lib tables is the persistence provider.
  """
  use ExUnit.Case, async: false

  import Noizu.MCP.Test

  alias Noizu.MCP.Fixtures.Persistence
  alias Noizu.MCP.Permission.Grant
  alias Noizu.MCP.Persistence.Memory
  alias Noizu.MCP.Store

  setup do
    Memory.reset()
    :ok
  end

  defp grant(overrides \\ []) do
    struct(
      %Grant{
        id: "g-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower),
        toolset_slug: "grant-slice",
        authenticator: "claims",
        subject: "user-1",
        effect: :allow,
        scopes: ["pm:read"]
      },
      overrides
    )
  end

  describe "put/get/list/delete/version" do
    test "put writes through the resolved provider; get reads it back" do
      record = grant()
      assert :ok = Store.put(:grant, record, server: Persistence.GrantServer)

      assert {:ok, %Grant{} = loaded} =
               Store.get(:grant, record.id, server: Persistence.GrantServer)

      assert loaded.toolset_slug == "grant-slice"
      assert loaded.scopes == ["pm:read"]
    end

    test "version bumps on write (observable ordering: write → bump)" do
      server = Persistence.GrantServer
      {:ok, before} = Store.version(:grant, server: server)

      record = grant()
      :ok = Store.put(:grant, record, server: server)

      {:ok, after_put} = Store.version(:grant, server: server)
      assert String.to_integer(after_put) > String.to_integer(before)

      :ok = Store.delete(:grant, record.id, server: server)
      {:ok, after_delete} = Store.version(:grant, server: server)
      assert String.to_integer(after_delete) > String.to_integer(after_put)

      assert :error = Store.get(:grant, record.id, server: server)
      # Idempotent delete.
      assert :ok = Store.delete(:grant, record.id, server: server)
    end

    test "list narrows by filter through the provider" do
      a = grant(subject: "user-1")
      b = grant(subject: "user-2")
      :ok = Store.put(:grant, a, server: Persistence.GrantServer)
      :ok = Store.put(:grant, b, server: Persistence.GrantServer)

      {:ok, found} =
        Store.list(:grant, %{subject: "user-2"}, server: Persistence.GrantServer)

      assert [%Grant{id: id}] = found
      assert id == b.id
    end

    test "unknown kinds and raw store keys behave" do
      assert {:error, {:unknown_kind, :bogus}} = Store.put(:bogus, grant(), [])
      assert {:error, {:unknown_kind, :bogus}} = Store.version(:bogus, [])
      # A raw store key works for version/2 directly.
      assert {:ok, v} = Store.version("toolset_grants", server: Persistence.GrantServer)
      assert is_binary(v)
    end

    test "a record missing its id is a put error, not a crash" do
      record = struct(grant(), id: nil)

      assert {:error, {:missing_field, :id}} =
               Store.put(:grant, record, server: Persistence.GrantServer)
    end
  end

  describe "notify fan-out (AC-4.6)" do
    test "a Store write delivers notifications/tools/list_changed to live sessions" do
      client = connect(Persistence.GrantServer)

      :ok = Store.put(:grant, grant(), server: Persistence.GrantServer)

      assert_notification(client, "notifications/tools/list_changed")
    end

    test "server: :all notifies every running server; explicit single narrows" do
      client = connect(Persistence.GrantServer)
      Noizu.MCP.Test.ensure_server_started(Persistence.BootOkServer)

      # :all (default) — every running server is notified.
      :ok = Store.put(:grant, grant())
      assert_notification(client, "notifications/tools/list_changed")

      # A single OTHER server: GrantServer's sessions hear nothing. (The
      # write rides BootOkServer's stash — MemoryPing → Memory.)
      :ok = Store.put(:grant, grant(), server: Persistence.BootOkServer)

      refute_notification(client, "notifications/tools/list_changed", timeout: 100)
    end

    test "notify failures never fail the write (D5)" do
      # A non-server module in the notify list: notify_changed/1 doesn't exist
      # — the rescue must log and move on, returning :ok from put.
      assert :ok = Store.put(:grant, grant(), server: Definitely.NotAServerModule)

      # The write DID land.
      record = grant()

      assert :ok = Store.put(:grant, record, server: Definitely.NotAServerModule)

      assert {:ok, _} = Store.get(:grant, record.id, server: Persistence.GrantServer)
    end
  end

  describe "AP-11: no data-plane side channels" do
    test "the ONLY lib source touching the lib tables is the persistence provider + migrations" do
      lib_files = Path.wildcard("lib/**/*.ex")

      allowed = MapSet.new(["ecto.ex", "v1_toolsets.ex"])

      # The TABLE names (the cache ETS table noizu_mcp_toolset_cache is not a
      # data-plane side channel).
      table_ref = ~r/noizu_mcp_toolsets|noizu_mcp_toolset_grants|noizu_mcp_toolset_negotiations/

      offenders =
        Enum.filter(lib_files, fn file ->
          allowed? = MapSet.member?(allowed, Path.basename(file))
          not allowed? and Regex.match?(table_ref, File.read!(file))
        end)

      assert offenders == [],
             "lib files other than the persistence provider and migrations reference the " <>
               "lib tables directly (AP-11 data-plane side channel): #{inspect(offenders)}"
    end
  end
end
