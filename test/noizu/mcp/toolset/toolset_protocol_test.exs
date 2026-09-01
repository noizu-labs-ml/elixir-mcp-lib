defmodule Noizu.MCP.Toolset.ProtocolTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.{Ctx, Toolset}
  alias Noizu.MCP.Fixtures
  alias Noizu.MCP.Toolset.Ref

  @raise_message "toolset entities must implement Noizu.MCP.Toolset explicitly (derive the protocol or use Noizu.MCP.Toolset.Behaviour)"

  defmodule NotDeriving do
    @moduledoc false
    defstruct [:x]
  end

  defp ctx, do: %Ctx{server: Fixtures.Server, assigns: %{}}

  describe "coerce/1" do
    test "module atoms wrap into refs (§4.1 table)" do
      assert %Ref{target: Fixtures.Server} = Toolset.coerce(Fixtures.Server)
    end

    test "refs pass through" do
      ref = %Ref{target: Fixtures.Server}
      assert Toolset.coerce(ref) == ref
    end

    test "deriving structs pass through (generated impl → identity)" do
      struct_toolset = %Fixtures.StructToolset{}
      assert Toolset.coerce(struct_toolset) == struct_toolset

      static = %Toolset.Static{specs: []}
      assert Toolset.coerce(static) == static
    end

    test "non-participants raise ArgumentError" do
      for value <- [123, "server", %{}, %{a: 1}, %NotDeriving{x: 1}] do
        assert_raise ArgumentError, @raise_message, fn -> Toolset.coerce(value) end
      end
    end
  end

  describe "fail-closed semantic calls (D4 — no semantic Any fallback)" do
    test "catalog/resolve/permissions on non-participants raise" do
      assert_raise ArgumentError, @raise_message, fn -> Toolset.catalog(123, nil, []) end
      assert_raise ArgumentError, @raise_message, fn -> Toolset.resolve("x", "echo", nil, []) end

      assert_raise ArgumentError, @raise_message, fn ->
        Toolset.permissions(%NotDeriving{}, nil, [])
      end
    end
  end

  describe "Atom impl delegation" do
    test "coerces false/nil (they are atoms) into refs — uniform path" do
      assert %Ref{target: false} = Toolset.coerce(false)
    end

    test "server atom and its ref produce identical catalogs" do
      {:ok, entries, version} = Toolset.catalog(Fixtures.Server, ctx(), [])

      assert Toolset.catalog(Fixtures.Server, ctx(), []) ==
               Toolset.catalog(%Ref{target: Fixtures.Server}, ctx(), [])

      assert is_binary(version)
      assert entries != []
    end

    test "Ref delegates unconditionally to the target module" do
      {:ok, entries, version} = Toolset.catalog(%Ref{target: Fixtures.Server}, ctx(), [])
      names = Enum.map(entries, & &1.definition.name)

      assert "echo" in names
      assert "raw_schema" in names
      assert String.length(version) == 16
    end

    test "resolve through the Atom impl lands on the target" do
      assert {:ok, %Noizu.MCP.Toolset.Effective{name: "echo"}} =
               Toolset.resolve(Fixtures.Server, "echo", ctx(), [])
    end
  end
end
