defmodule Noizu.MCP.Toolset.CacheTest do
  @moduledoc """
  §4.6 / AC-3.6: opt-in only (zero ETS writes when off), key per spec,
  principal_hash excludes claims/metadata, invalidate/1 by toolset id, TTL
  expiry, validator/compose errors never cached. Sync: owns the table state
  checks.
  """

  use ExUnit.Case, async: false

  alias Noizu.MCP.Auth.Principal
  alias Noizu.MCP.{Ctx, Fixtures, Toolset}
  alias Noizu.MCP.Toolset.{Cache, Custom}

  @table :noizu_mcp_toolset_cache

  defp ctx(opts \\ []) do
    auth = Keyword.get(opts, :auth)

    %Ctx{server: Fixtures.Server, auth: auth, assigns: %{}}
  end

  defp principal(subject, opts \\ []) do
    %Principal{
      subject: subject,
      authenticator: :test,
      granted_scopes: MapSet.new(Keyword.get(opts, :scopes, ["mcp"])),
      claims: Keyword.get(opts, :claims, %{})
    }
  end

  defp compose_echo(slug, ctx, opts \\ []) do
    Custom.compose(
      %Custom{slug: slug, base: Fixtures.Server, include: ["echo"]},
      ctx,
      opts
    )
  end

  defp table_rows do
    case :ets.whereis(@table) do
      :undefined -> []
      ref -> :ets.tab2list(ref)
    end
  end

  describe "principal_hash/1" do
    test "stable for identical principals; differs by subject/scope" do
      a = principal("alice")
      assert Cache.principal_hash(a) == Cache.principal_hash(principal("alice"))
      assert String.length(Cache.principal_hash(a)) == 16

      refute Cache.principal_hash(a) == Cache.principal_hash(principal("bob"))
      refute Cache.principal_hash(a) == Cache.principal_hash(principal("alice", scopes: ["pm:*"]))
    end

    test "claims/metadata deliberately EXCLUDED (§4.6)" do
      with_claims = %{principal("alice") | claims: %{"sub" => "alice", "tid" => "t1"}}
      with_meta = %{principal("alice") | metadata: %{"noise" => "irrelevant"}}

      assert Cache.principal_hash(principal("alice")) == Cache.principal_hash(with_claims)
      assert Cache.principal_hash(principal("alice")) == Cache.principal_hash(with_meta)
    end

    test "nil (anonymous) hashes to a stable value" do
      assert Cache.principal_hash(nil) == Cache.principal_hash(nil)
      refute Cache.principal_hash(nil) == Cache.principal_hash(principal("alice"))
    end
  end

  describe "get/put/invalidate" do
    test "miss → put → hit; invalidate clears by toolset id" do
      key = {"t1", Cache.principal_hash(nil), "version1"}
      composed = %{entries: [:entry], version: "version1", provenance: %{}, specs: %{}}

      assert Cache.get(key) == :miss
      assert Cache.put(key, composed, ttl: 60_000) == :ok
      assert {:ok, ^composed} = Cache.get(key)

      Cache.invalidate("t1")
      assert Cache.get(key) == :miss
    end

    test "TTL expiry: an expired row is a lazy miss" do
      key = {"t2", Cache.principal_hash(nil), "v"}
      Cache.put(key, %{entries: [], version: "v", provenance: %{}, specs: %{}}, ttl: 1)
      Process.sleep(5)
      assert Cache.get(key) == :miss
    end

    test "invalidate never creates the table" do
      created_here? = :ets.whereis(@table) == :undefined
      Cache.invalidate("never-used-slug")

      if created_here? do
        assert :ets.whereis(@table) == :undefined
      end
    end
  end

  describe "compose-level memoization (AC-3.6)" do
    test "second compose of the same key hits (telemetry cached: true); invalidate forces recompose" do
      ref = make_ref()

      :telemetry.attach(
        {ref, :compose},
        [:noizu_mcp, :toolset, :compose],
        fn _e, _m, meta, _ -> send(self(), {:compose, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach({ref, :compose}) end)
      Cache.invalidate("cached-slice")

      ctx = ctx()
      assert {:ok, _, version1} = compose_echo("cached-slice", ctx, cache: true)
      assert_receive {:compose, %{cached: false, toolset: "cached-slice"}}

      assert {:ok, _, ^version1} = compose_echo("cached-slice", ctx, cache: true)
      assert_receive {:compose, %{cached: true, toolset: "cached-slice"}}

      # a different principal is a different KEY (no cross-principal leaks)
      authed = ctx(auth: principal("alice"))
      assert {:ok, _, _} = compose_echo("cached-slice", authed, cache: true)
      assert_receive {:compose, %{cached: false}}

      Cache.invalidate("cached-slice")
      assert {:ok, _, _} = compose_echo("cached-slice", ctx, cache: true)
      assert_receive {:compose, %{cached: false}}
    end

    test "metadata cache:true opts in too; results are identical either way" do
      Cache.invalidate("meta-cached")

      toolset = %Custom{
        slug: "meta-cached",
        base: Fixtures.Server,
        include: ["echo"],
        metadata: %{cache: true}
      }

      assert {:ok, entries1, v1} = Custom.compose(toolset, ctx(), [])
      assert {:ok, entries2, v2} = Custom.compose(toolset, ctx(), [])
      assert entries1 == entries2 and v1 == v2
    end

    test "cache OFF ⇒ no row is ever written for the toolset" do
      Cache.invalidate("uncached-slice")
      rows_before = length(table_rows())

      assert {:ok, _, _} = compose_echo("uncached-slice", ctx())
      assert {:ok, _, _} = compose_echo("uncached-slice", ctx())

      assert length(table_rows()) == rows_before
      refute Enum.any?(table_rows(), fn {{slug, _, _}, _, _, _} -> slug == "uncached-slice" end)
    end

    test "validator errors and D5 disables are NEVER cached (always re-checked)" do
      broken = %Custom{slug: "never-cache-me", base: :no_such_module}
      Cache.invalidate("never-cache-me")

      assert {:error, %Noizu.MCP.Error{}} = Custom.compose(broken, ctx(), cache: true)
      assert {:error, %Noizu.MCP.Error{}} = Custom.compose(broken, ctx(), cache: true)

      refute Enum.any?(table_rows(), fn {{slug, _, _}, _, _, _} -> slug == "never-cache-me" end)
    end
  end
end
