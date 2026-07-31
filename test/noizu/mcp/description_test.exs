defmodule Noizu.MCP.DescriptionTest do
  use ExUnit.Case, async: true

  alias Noizu.MCP.Description
  alias Noizu.MCP.RenderCtx

  defp ctx(verbosity), do: %RenderCtx{verbosity: verbosity}

  describe "compile/2 normalization" do
    test "nil and bare strings pass through unchanged" do
      assert Description.compile(nil, "t") == nil
      assert Description.compile("just text", "t") == "just text"
    end

    test "a variant list compiles to a struct with expanded levels" do
      desc =
        Description.compile(
          [
            {{:verbosity, {2, 3}}, "mid"},
            {{:verbosity, 0}, "terse"},
            {{:verbosity, [6, 8]}, "hi"},
            default: "fallback",
            default_verbosity: 4
          ],
          "t"
        )

      assert %Description{} = desc
      assert desc.levels == %{0 => "terse", 2 => "mid", 3 => "mid", 6 => "hi", 8 => "hi"}
      assert desc.default == "fallback"
      assert desc.default_verbosity == 4
      assert desc.runners == []
    end

    test "an already-compiled struct is idempotent" do
      desc = Description.compile([{{:verbosity, 0}, "x"}], "t")
      assert Description.compile(desc, "t") == desc
    end
  end

  describe "compile/2 validation (compile-time errors)" do
    test "malformed key" do
      assert_raise ArgumentError, ~r/unrecognized description variant entry/, fn ->
        Description.compile([{{:loudness, 1}, "x"}], "t")
      end
    end

    test "out-of-domain level" do
      assert_raise ArgumentError, ~r/0\.\.9/, fn ->
        Description.compile([{{:verbosity, 10}, "x"}], "t")
      end

      assert_raise ArgumentError, ~r/0\.\.9/, fn ->
        Description.compile([{{:verbosity, -1}, "x"}], "t")
      end
    end

    test "duplicate coverage of the same level" do
      assert_raise ArgumentError, ~r/level 3 is defined by more than one/, fn ->
        Description.compile([{{:verbosity, 3}, "a"}, {{:verbosity, {2, 4}}, "b"}], "t")
      end
    end

    test "inverted range" do
      assert_raise ArgumentError, ~r/inverted/, fn ->
        Description.compile([{{:verbosity, {4, 2}}, "x"}], "t")
      end
    end

    test "non-string default and non-string variant text" do
      assert_raise ArgumentError, ~r/`default:` must be a string/, fn ->
        Description.compile([default: 5], "t")
      end

      assert_raise ArgumentError, ~r/variant text must be a string/, fn ->
        Description.compile([{{:verbosity, 3}, 5}], "t")
      end
    end

    test "bad :verbosity selector" do
      assert_raise ArgumentError, ~r/invalid :verbosity selector/, fn ->
        Description.compile([{{:verbosity, "3"}, "x"}], "t")
      end
    end
  end

  describe "resolve/2 — plain and empty forms" do
    test "a bare string covers all levels" do
      for v <- 0..9 do
        assert Description.resolve("only text", ctx(v)) == "only text"
      end
    end

    test "nil resolves to nil" do
      assert Description.resolve(nil, ctx(5)) == nil
    end

    test "only a default: entry (no verbosity levels) returns the fallback at any level" do
      desc = Description.compile([default: "fallback"], "t")
      assert Description.resolve(desc, ctx(0)) == "fallback"
      assert Description.resolve(desc, ctx(9)) == "fallback"
    end
  end

  describe "resolve/2 — exact, range, and list hits" do
    test "exact level hit" do
      desc = Description.compile([{{:verbosity, 3}, "a"}, {{:verbosity, 5}, "b"}], "t")
      assert Description.resolve(desc, ctx(3)) == "a"
      assert Description.resolve(desc, ctx(5)) == "b"
    end

    test "range hit" do
      desc = Description.compile([{{:verbosity, {3, 6}}, "mid"}], "t")
      assert Description.resolve(desc, ctx(3)) == "mid"
      assert Description.resolve(desc, ctx(6)) == "mid"
    end

    test "list hit" do
      desc = Description.compile([{{:verbosity, [1, 4, 7]}, "set"}, default: "d"], "t")
      assert Description.resolve(desc, ctx(4)) == "set"
    end
  end

  describe "resolve/2 — gap-fill (spec worked examples)" do
    test "defined {2,3} and 0, request 1 → 0 (tie prefers lower level)" do
      desc =
        Description.compile([{{:verbosity, {2, 3}}, "mid"}, {{:verbosity, 0}, "terse"}], "t")

      assert Description.resolve(desc, ctx(1)) == "terse"
    end

    test "defined 3 and 9: 8→9, 5→3, 6→3 (tie prefers lower level)" do
      desc = Description.compile([{{:verbosity, 3}, "three"}, {{:verbosity, 9}, "nine"}], "t")

      assert Description.resolve(desc, ctx(8)) == "nine"
      assert Description.resolve(desc, ctx(5)) == "three"
      assert Description.resolve(desc, ctx(6)) == "three"
      # endpoints and beyond
      assert Description.resolve(desc, ctx(0)) == "three"
      assert Description.resolve(desc, ctx(3)) == "three"
      assert Description.resolve(desc, ctx(9)) == "nine"
    end
  end

  describe "resolve/2 — out-of-domain requests are clamped to 0..9" do
    test "above and below the domain" do
      desc = Description.compile([{{:verbosity, 0}, "lo"}, {{:verbosity, 9}, "hi"}], "t")
      assert Description.resolve(desc, ctx(12)) == "hi"
      assert Description.resolve(desc, ctx(-3)) == "lo"
    end
  end

  describe "resolve/2 — effective-verbosity precedence" do
    setup do
      desc =
        Description.compile(
          [{{:verbosity, 0}, "t0"}, {{:verbosity, 9}, "t9"}, default_verbosity: 9],
          "t"
        )

      %{desc: desc}
    end

    test "explicit context verbosity wins over annotation default_verbosity", %{desc: desc} do
      assert Description.resolve(desc, %RenderCtx{verbosity: 0}) == "t0"
    end

    test "annotation default_verbosity applies when no explicit verbosity", %{desc: desc} do
      assert Description.resolve(desc, RenderCtx.default()) == "t9"
    end

    test "annotation default_verbosity wins over the defaults chain", %{desc: desc} do
      assert Description.resolve(desc, %RenderCtx{verbosity: nil, defaults: %{verbosity: 0}}) ==
               "t9"
    end

    test "with no annotation default, the defaults chain then the built-in 5 apply" do
      desc = Description.compile([{{:verbosity, 3}, "a"}, {{:verbosity, 5}, "b"}], "t")
      # built-in 5
      assert Description.resolve(desc, RenderCtx.default()) == "b"
      # server/global default chain
      assert Description.resolve(desc, %RenderCtx{defaults: %{verbosity: 3}}) == "a"
    end
  end

  describe "RenderCtx" do
    test "default/0 and effective_verbosity/1" do
      assert RenderCtx.effective_verbosity(RenderCtx.default()) == 5
      assert RenderCtx.effective_verbosity(%RenderCtx{verbosity: 8}) == 8
      assert RenderCtx.effective_verbosity(%RenderCtx{defaults: %{verbosity: 2}}) == 2
      # clamped
      assert RenderCtx.effective_verbosity(%RenderCtx{verbosity: 42}) == 9
    end

    test "server_defaults/1 falls back to the built-in default for unknown servers" do
      assert RenderCtx.server_defaults(nil) == %{verbosity: 5}
      assert RenderCtx.server_defaults(:not_a_server) == %{verbosity: 5}
    end

    test "server_defaults/1 reads the server's default_verbosity use option" do
      assert RenderCtx.server_defaults(Noizu.MCP.Fixtures.VerboseServer) == %{verbosity: 1}
    end
  end
end
