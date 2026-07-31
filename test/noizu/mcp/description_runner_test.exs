defmodule Noizu.MCP.DescriptionRunnerTest do
  @moduledoc """
  Unit coverage for the spec §3 named-variant / runner-rule layer of
  `Noizu.MCP.Description`: `from_opts/2` compilation and the runner/verbosity_map
  precedence in `resolve/2`.
  """
  use ExUnit.Case, async: true

  alias Noizu.MCP.Description
  alias Noizu.MCP.RenderCtx

  defp compile(opts), do: Description.from_opts(opts, "t")

  describe "from_opts/2 — compilation" do
    test "no named options ⇒ identical to compile(description)" do
      assert Description.from_opts([description: "plain"], "t") == "plain"
      assert Description.from_opts([description: nil], "t") == nil
      assert Description.from_opts([], "t") == nil

      variant = [description: [{{:verbosity, 0}, "terse"}, default: "def"]]
      assert Description.from_opts(variant, "t") == Description.compile(variant[:description], "t")
    end

    test "named variants + verbosity_map + runners compile into the struct" do
      desc =
        compile(
          description: "definitive",
          descriptions: [base: "B", codex: "C", "hippo-5": "H"],
          verbosity_map: [{{0, 5}, :base}],
          runners: [
            {{:grok, :*}, [{{:verbosity, {0, 5}}, :"hippo-5"}]},
            {{:codex, [:spark, :"5.4"]}, [default: :codex]}
          ]
        )

      assert %Description{} = desc
      assert desc.default == "definitive"
      assert desc.variants == %{"base" => "B", "codex" => "C", "hippo-5" => "H"}
      assert desc.verbosity_map == %{0 => "base", 1 => "base", 2 => "base", 3 => "base", 4 => "base", 5 => "base"}

      assert [grok_rule, codex_rule] = desc.runners
      assert grok_rule.provider == :grok
      assert grok_rule.model == :any
      assert grok_rule.levels == Map.new(0..5, &{&1, "hippo-5"})
      assert grok_rule.default_tag == nil

      assert codex_rule.provider == :codex
      assert codex_rule.model == {:list, ["spark", "5.4"]}
      assert codex_rule.levels == %{}
      assert codex_rule.default_tag == "codex"
    end

    test "a bare description: string becomes the default text" do
      desc = compile(description: "fallback", descriptions: [a: "A"], verbosity_map: [{9, :a}])
      assert desc.default == "fallback"
    end
  end

  describe "from_opts/2 — compile-time validation" do
    test "unknown tag referenced by a runner rule" do
      assert_raise ArgumentError, ~r/unknown variant tag/, fn ->
        compile(descriptions: [a: "A"], runners: [{{:codex, :*}, [default: :missing]}])
      end
    end

    test "unknown tag referenced by the verbosity_map" do
      assert_raise ArgumentError, ~r/unknown variant tag/, fn ->
        compile(descriptions: [a: "A"], verbosity_map: [{{0, 9}, :nope}])
      end
    end

    test "malformed model matcher" do
      assert_raise ArgumentError, ~r/model matcher/, fn ->
        compile(descriptions: [a: "A"], runners: [{{:codex, 5}, [default: :a]}])
      end
    end

    test "malformed runner shape" do
      assert_raise ArgumentError, ~r/each runner must be/, fn ->
        compile(descriptions: [a: "A"], runners: [{:codex, [default: :a]}])
      end
    end

    test "non-string variant text" do
      assert_raise ArgumentError, ~r/text must be a string/, fn ->
        compile(descriptions: [a: 5])
      end
    end

    test "out-of-domain verbosity_map level" do
      assert_raise ArgumentError, ~r/0\.\.9/, fn ->
        compile(descriptions: [a: "A"], verbosity_map: [{{0, 12}, :a}])
      end
    end
  end

  describe "resolve/2 — runner-rule matching and specificity" do
    setup do
      desc =
        compile(
          descriptions: [a: "A", b: "B", c: "C", d: "D"],
          runners: [
            {{:*, :*}, [default: :a]},
            {{:codex, :*}, [default: :b]},
            {{:*, :"5.4"}, [default: :c]},
            {{:codex, :"5.4"}, [default: :d]}
          ]
        )

      %{desc: desc}
    end

    test "both exact wins over every less specific rule", %{desc: desc} do
      assert Description.resolve(desc, %RenderCtx{runner: :codex, model: :"5.4"}) == "D"
    end

    test "provider-exact beats all-wildcard when the model does not match", %{desc: desc} do
      assert Description.resolve(desc, %RenderCtx{runner: :codex, model: :other}) == "B"
    end

    test "model-exact beats all-wildcard when the provider does not match", %{desc: desc} do
      assert Description.resolve(desc, %RenderCtx{runner: :grok, model: :"5.4"}) == "C"
    end

    test "the all-wildcard rule is the last resort", %{desc: desc} do
      assert Description.resolve(desc, %RenderCtx{runner: :grok, model: :other}) == "A"
    end

    test "an exact model matcher dominates an exact provider matcher" do
      desc =
        compile(
          descriptions: [by_model: "model", by_provider: "provider"],
          runners: [
            {{:codex, :*}, [default: :by_provider]},
            {{:*, :"5.4"}, [default: :by_model]}
          ]
        )

      assert Description.resolve(desc, %RenderCtx{runner: :codex, model: :"5.4"}) == "model"
    end
  end

  describe "resolve/2 — atom/string representation insensitivity" do
    setup do
      desc = compile(descriptions: [x: "X"], runners: [{{:codex, :"5.4"}, [default: :x]}])
      %{desc: desc}
    end

    test "string model matches an atom matcher", %{desc: desc} do
      assert Description.resolve(desc, %RenderCtx{runner: :codex, model: "5.4"}) == "X"
    end

    test "string runner and atom model both match", %{desc: desc} do
      assert Description.resolve(desc, %RenderCtx{runner: "codex", model: :"5.4"}) == "X"
    end

    test "a differing model does not match", %{desc: desc} do
      # No rule matches ⇒ no verbosity_map/levels/default ⇒ nil
      assert Description.resolve(desc, %RenderCtx{runner: :codex, model: "5.5"}) == nil
    end
  end

  describe "resolve/2 — gap-fill inside a runner rule" do
    setup do
      desc =
        compile(
          descriptions: [lo: "LO", hi: "HI"],
          runners: [{{:grok, :*}, [{{:verbosity, 0}, :lo}, {{:verbosity, 9}, :hi}]}]
        )

      %{desc: desc}
    end

    test "uncovered level inside the rule gap-fills to the nearest tag", %{desc: desc} do
      assert Description.resolve(desc, %RenderCtx{runner: :grok, verbosity: 0}) == "LO"
      assert Description.resolve(desc, %RenderCtx{runner: :grok, verbosity: 3}) == "LO"
      assert Description.resolve(desc, %RenderCtx{runner: :grok, verbosity: 8}) == "HI"
      assert Description.resolve(desc, %RenderCtx{runner: :grok, verbosity: 9}) == "HI"
    end
  end

  describe "resolve/2 — precedence chain (§0)" do
    setup do
      desc =
        compile(
          description: "definitive",
          descriptions: [rk: "runner-tag", vm: "vmap-tag"],
          verbosity_map: [{{0, 9}, :vm}],
          runners: [{{:codex, :*}, [default: :rk]}]
        )

      %{desc: desc}
    end

    test "a matching runner rule wins over the verbosity_map", %{desc: desc} do
      assert Description.resolve(desc, %RenderCtx{runner: :codex, verbosity: 5}) == "runner-tag"
    end

    test "with no runner match the verbosity_map applies", %{desc: desc} do
      assert Description.resolve(desc, %RenderCtx{runner: :grok, verbosity: 5}) == "vmap-tag"
      assert Description.resolve(desc, %RenderCtx{verbosity: 5}) == "vmap-tag"
    end

    test "inline §2 levels sit between the verbosity_map and the default" do
      desc =
        compile(
          description: "definitive",
          descriptions: [vm: "vmap-tag"],
          runners: [{{:codex, :*}, [default: :vm]}]
        )

      # No verbosity_map, no levels ⇒ default text when nothing matches.
      assert Description.resolve(desc, %RenderCtx{runner: :grok, verbosity: 5}) == "definitive"
      assert Description.resolve(desc, %RenderCtx{runner: :codex, verbosity: 5}) == "vmap-tag"
    end

    test "a description mixing §2 levels with a runner rule prefers the rule, else levels" do
      desc =
        Description.from_opts(
          [
            description: [
              {{:verbosity, 0}, "lvl-terse"},
              {{:verbosity, 9}, "lvl-rich"},
              default: "def"
            ],
            descriptions: [rk: "runner-tag"],
            runners: [{{:codex, :*}, [default: :rk]}]
          ],
          "t"
        )

      assert Description.resolve(desc, %RenderCtx{runner: :codex, verbosity: 0}) == "runner-tag"
      assert Description.resolve(desc, %RenderCtx{runner: :grok, verbosity: 0}) == "lvl-terse"
      assert Description.resolve(desc, %RenderCtx{runner: :grok, verbosity: 9}) == "lvl-rich"
    end
  end

  describe "resolve/2 — regression: no runner in ctx" do
    test "a runner-free ctx never consults runner rules" do
      desc =
        compile(
          descriptions: [base: "base", codex: "codex"],
          verbosity_map: [{{0, 9}, :base}],
          runners: [{{:codex, :*}, [default: :codex]}]
        )

      for v <- 0..9 do
        assert Description.resolve(desc, %RenderCtx{verbosity: v}) == "base"
      end
    end
  end
end
