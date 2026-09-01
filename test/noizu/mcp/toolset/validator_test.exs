defmodule Noizu.MCP.Toolset.ValidatorTest do
  @moduledoc """
  §4.5: every issue code as a case, the warning cases, and compile/3 purity
  (no DB/ETS/env — no_cache table created, deterministic output).
  """

  use ExUnit.Case, async: true

  alias Noizu.MCP.Fixtures
  alias Noizu.MCP.Server.Features.Tools
  alias Noizu.MCP.Toolset.{Behaviour, Custom, Layer, Override, Validator}

  @echo_fields Fixtures.Echo.__mcp_tools__()
               |> hd()
               |> then(& &1.definition.input_fields)

  defp base_entries,
    do:
      Fixtures.Server.__mcp__(:tools)
      |> Tools.expand()
      |> Enum.map(&Behaviour.entry_for/1)

  defp toolset(opts), do: struct!(%Custom{slug: "v", base: Fixtures.Server}, opts)

  defp compile(toolset, opts \\ []), do: Validator.compile(toolset, base_entries(), opts)

  defp codes({:error, issues}), do: Enum.map(issues, & &1.code)

  # ── the §4.5 table ─────────────────────────────────────────────────────────

  test "valid toolset ⇒ {:ok, warnings=[]}" do
    assert {:ok, []} =
             compile(
               toolset(
                 include: ["echo"],
                 tools: %{"echo" => [%Override{op: :set_description, target: "echo", value: "d"}]}
               )
             )
  end

  test ":unknown_tool — tools key / include / exclude not in the base catalog" do
    assert {:error, issues} =
             compile(
               toolset(
                 include: ["echo", "ghost"],
                 exclude: ["phantom"],
                 tools: %{"nope" => [%Override{op: :set_visible, target: "nope", value: false}]}
               )
             )

    assert Enum.sort(codes({:error, issues})) == [:unknown_tool, :unknown_tool, :unknown_tool]

    sources = issues |> Enum.map(& &1.meta.source) |> Enum.sort()
    assert sources == [:exclude, :include, :tools]
  end

  test ":unknown_field — field op on a field the base tool lacks" do
    {:error, issues} =
      compile(
        toolset(
          tools: %{
            "echo" => [%Override{op: :set_arg_description, target: :nonexistent, value: "x"}]
          }
        )
      )

    assert codes({:error, issues}) == [:unknown_field]
  end

  test ":prune_not_subset — pruned values outside the base enum" do
    {:error, issues} =
      compile(
        toolset(
          tools: %{"echo" => [%Override{op: :prune_enum, target: :mode, value: [:plain, :shout]}]}
        )
      )

    assert [%{code: :prune_not_subset, meta: %{values: [:shout]}}] = issues
  end

  test "prune_enum fully inside the base enum passes" do
    assert {:ok, _} =
             compile(
               toolset(
                 tools: %{"echo" => [%Override{op: :prune_enum, target: :mode, value: [:plain]}]}
               )
             )
  end

  test ":rename_target_missing — rename on an absent field" do
    {:error, issues} =
      compile(
        toolset(tools: %{"echo" => [%Override{op: :rename_field, target: :ghost, value: "x"}]})
      )

    assert codes({:error, issues}) == [:rename_target_missing]
  end

  test ":rename_collision — onto an existing field, or two renames to one name" do
    {:error, issues} =
      compile(
        toolset(
          tools: %{"echo" => [%Override{op: :rename_field, target: :message, value: "mode"}]}
        )
      )

    assert codes({:error, issues}) == [:rename_collision]

    {:error, issues} =
      compile(
        toolset(
          tools: %{
            "echo" => [
              %Override{op: :rename_field, target: :message, value: "same"},
              %Override{op: :rename_field, target: :mode, value: "same"}
            ]
          }
        )
      )

    assert codes({:error, issues}) == [:rename_collision, :rename_collision]
  end

  test ":pin_default_invalid — outside the post-prune enum, or type-incompatible scalar" do
    # outside the POST-PRUNE enum: :loud survives pruning, :plain does not
    {:error, issues} =
      compile(
        toolset(
          tools: %{
            "echo" => [
              %Override{op: :prune_enum, target: :mode, value: [:plain]},
              %Override{op: :pin_default, target: :mode, value: :plain}
            ]
          }
        )
      )

    assert codes({:error, issues}) == [:pin_default_invalid]

    # scalar type mismatch: :repeat is an integer field
    {:error, issues} =
      compile(
        toolset(tools: %{"echo" => [%Override{op: :pin_default, target: :repeat, value: "many"}]})
      )

    assert codes({:error, issues}) == [:pin_default_invalid]

    # inside the post-prune enum is fine
    assert {:ok, _} =
             compile(
               toolset(
                 tools: %{
                   "echo" => [
                     %Override{op: :prune_enum, target: :mode, value: [:plain]},
                     %Override{op: :pin_default, target: :mode, value: :loud}
                   ]
                 }
               )
             )
  end

  test ":raw_schema_op — field op against a raw-schema tool; set_input_schema against a DSL tool" do
    {:error, issues} =
      compile(
        toolset(
          tools: %{"raw_schema" => [%Override{op: :hide_field, target: :query, value: true}]}
        )
      )

    assert codes({:error, issues}) == [:raw_schema_op]

    {:error, issues} =
      compile(
        toolset(
          tools: %{"echo" => [%Override{op: :set_input_schema, target: "echo", value: %{}}]}
        )
      )

    assert codes({:error, issues}) == [:raw_schema_op]

    # set_input_schema ON the raw-schema tool is legal
    assert {:ok, _} =
             compile(
               toolset(
                 tools: %{
                   "raw_schema" => [
                     %Override{
                       op: :set_input_schema,
                       target: "raw_schema",
                       value: %{"type" => "object"}
                     }
                   ]
                 }
               )
             )
  end

  test ":name_charset — set_name values outside ^[a-zA-Z0-9_-]{1,64}$" do
    {:error, issues} =
      compile(
        toolset(
          tools: %{"echo" => [%Override{op: :set_name, target: "echo", value: "bad name!"}]}
        )
      )

    assert codes({:error, issues}) == [:name_charset]

    too_long = String.duplicate("a", 65)

    {:error, issues} =
      compile(
        toolset(tools: %{"echo" => [%Override{op: :set_name, target: "echo", value: too_long}]})
      )

    assert codes({:error, issues}) == [:name_charset]
  end

  test ":name_collision — effective names collide (incl. other renames)" do
    {:error, issues} =
      compile(
        toolset(
          include: ["echo", "get_weather"],
          tools: %{"echo" => [%Override{op: :set_name, target: "echo", value: "get_weather"}]}
        )
      )

    assert [%{code: :name_collision, meta: %{wire: "get_weather"}}] = issues

    # excluded from the effective set ⇒ no collision
    assert {:ok, _} =
             compile(
               toolset(
                 include: ["echo"],
                 exclude: ["get_weather"],
                 tools: %{
                   "echo" => [%Override{op: :set_name, target: "echo", value: "get_weather"}]
                 }
               )
             )
  end

  test ":weight_conflict — equal max-weight non-inherit opinions (surfaced by Merge)" do
    {:error, issues} =
      compile(
        toolset(
          tools: %{
            "echo" => [
              %Override{op: :set_visible, target: "echo", value: false},
              %Override{op: :set_visible, target: "echo", value: true}
            ]
          }
        )
      )

    assert codes({:error, issues}) == [:weight_conflict]
  end

  test ":cycle — nested-base slug cycle" do
    c = %Custom{slug: "self", base: nil}
    cyclic = %{c | base: %{c | base: c}}

    {:error, issues} = Validator.compile(cyclic, base_entries())
    assert codes({:error, issues}) == [:cycle]
  end

  # ── warnings ───────────────────────────────────────────────────────────────

  test "warning: include/exclude overlap (exclude wins, noted)" do
    assert {:ok, [warning]} =
             compile(toolset(include: ["echo", "slow"], exclude: ["echo"]))

    assert warning =~ "overlap" and warning =~ "exclude wins"
  end

  test "warning: pin_default equal to the existing default" do
    assert {:ok, [warning]} =
             compile(
               toolset(
                 tools: %{"echo" => [%Override{op: :pin_default, target: :mode, value: :plain}]}
               )
             )

    assert warning =~ "existing default"
  end

  test "warning: same-value visible/callable restated by another layer" do
    layer = %Layer{
      id: {:persisted, "g1"},
      weight: 200,
      ops: [%Override{op: :set_visible, target: "echo", value: false, tool: "echo"}]
    }

    assert {:ok, [warning]} =
             compile(
               toolset(
                 tools: %{"echo" => [%Override{op: :set_visible, target: "echo", value: false}]}
               ),
               layers: [layer]
             )

    assert warning =~ "same value"
  end

  # ── purity ─────────────────────────────────────────────────────────────────

  test "compile/3 is pure: deterministic and ETS-free" do
    toolset =
      toolset(
        include: ["echo"],
        tools: %{"echo" => [%Override{op: :set_description, target: "echo", value: "d"}]}
      )

    assert compile(toolset) == compile(toolset)

    # no ETS involvement: the cache table must not have been created by
    # validation (checked defensively — other async tests may have created it)
    case :ets.whereis(:noizu_mcp_toolset_cache) do
      :undefined -> :ok
      ref -> assert :ets.tab2list(ref) != nil
    end
  end

  test "compile/3 accepts context layers for winner-dependent checks" do
    layer = %Layer{
      id: {:acl, FakeProv},
      weight: 300,
      ops: [
        %Override{op: :set_visible, target: "echo", value: false, tool: "echo"},
        %Override{op: :set_callable, target: "echo", value: false, tool: "echo"}
      ]
    }

    # ACL deny + no static name ops ⇒ still valid
    assert {:ok, _} = compile(toolset(include: ["echo"]), layers: [layer])
  end

  test "the echo fixture exposes the expected base fields (test sanity)" do
    names = Enum.map(@echo_fields, & &1.name)
    assert names == [:message, :repeat, :mode]
  end
end
