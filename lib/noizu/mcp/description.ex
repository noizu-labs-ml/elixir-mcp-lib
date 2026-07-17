defmodule Noizu.MCP.Description do
  @moduledoc """
  A tailored description: one string chosen per render context, with gap-fill
  interpolation for verbosity levels that no variant covers and — for weak
  harnesses/models — per-runner/model overrides (spec §3).

  ## Verbosity variants (spec §2)

  Anywhere a description string is accepted today — a tool's `description:`, a
  toolkit `@mcp description:`, a `field ... description:` — a **variant list** is
  also accepted:

      description: [
        {{:verbosity, {2, 3}}, "Medium description."},
        {{:verbosity, 0},      "Terse."},
        default: "Definitive fallback text"
      ]

  A bare string (`description: "just text"`) is unchanged and covers every level.

  ### Keys

    * `{:verbosity, n}` — a single level `n`
    * `{:verbosity, {lo, hi}}` — an inclusive range
    * `{:verbosity, [n, ...]}` — an explicit set of levels
    * `default: "text"` — the definitive/fallback string, used when nothing more
      specific applies
    * `default_verbosity: n` — the annotation-level default verbosity, applied
      when a render context supplies no explicit verbosity

  The verbosity domain is **0–9** (0 = tersest). Levels, range bounds, and set
  members outside that domain are a compile error, as are malformed keys and two
  entries covering the same exact level.

  > **Deliberate deviation from the design spec.** The spec sketched the
  > annotation-level default as `default: [{:verbosity, 3}]`, overloading the
  > `default:` key (fallback text vs. default-verbosity setting). This module
  > splits them: `default:` is always the fallback *text*; `default_verbosity:`
  > is the default *level*. Flagged for review.

  ## Named variants + runner/model rules (spec §3)

  Alongside `description:`, three sibling options — accepted on `use
  Noizu.MCP.Server.Tool`, `@mcp`, and `field` — build a tailored description
  without forking the tool. `from_opts/2` compiles them together:

      description:   "definitive fallback",         # the default text
      descriptions:  [foo_bar: "…", "hippo-5": "…", codex_foobar: "…"],
      verbosity_map: [{{0, 5}, :foo_bar}],          # verbosity → named variant
      runners: [
        {{:grok, :*},              [{{:verbosity, {0, 5}}, :"hippo-5"}]},
        {{:codex, [:spark, :"5.4"]}, [default: :codex_foobar]}
      ]

    * `descriptions:` — a keyword list of `tag: "text"` named variants. Tags may
      be atoms or strings; they are stored normalized to strings.
    * `verbosity_map:` — `[{verbosity_spec, tag}, ...]`, mapping a verbosity
      selector (int / `{lo, hi}` / `[levels]`) to a named variant.
    * `runners:` — `[{{provider, model_matcher}, rules}, ...]`. `provider` is an
      atom (or `:*` wildcard); `model_matcher` is `:*`, an exact atom/string, or
      a list of atoms/strings (membership). `rules` is a keyword-ish list mixing
      `{{:verbosity, spec}, tag}` entries and a `default: tag`.

  Every tag referenced by `verbosity_map:`/`runners:` must be declared in
  `descriptions:`, and matchers must be well-formed — both are validated at
  compile time (an `ArgumentError`, surfaced as a compile error at the DSL call
  site).

  ## Resolution

  `resolve/2` maps a normalized description and a `Noizu.MCP.RenderCtx` to a
  concrete string (or `nil`). Precedence (spec §0), first match wins:

    1. the most specific matching runner rule — its own verbosity → tag map
       (same gap-fill), falling back to the rule's `default:` tag;
    2. the tool/field-level `verbosity_map` (verbosity → tag, gap-filled);
    3. the inline `levels` variants (verbosity → text, gap-filled — the §2 path);
    4. the `default:` fallback text (or `nil`).

  **Runner specificity** (most specific wins; ties break toward declaration
  order): the model matcher dominates the provider matcher — exact model (2) >
  model-in-list (1) > `:*` (0); then provider exact (1) > `:*` (0). Model and
  provider comparisons are insensitive to atom-vs-string representation, so
  `"5.4"` matches `:"5.4"`.

  For an uncovered verbosity level, gap-fill picks the entry whose nearest
  covered level is the smallest absolute distance away; ties prefer the lower
  level ("left preference"). Worked examples (from the spec): defined `{2,3}` and
  `0`, request `1` → `0`; defined `3` and `9`, request `8` → `9`, `5` → `3`, `6`
  → `3`.
  """

  alias Noizu.MCP.RenderCtx

  @domain 0..9

  @type variant_key ::
          {:verbosity, integer()}
          | {:verbosity, {integer(), integer()}}
          | {:verbosity, [integer()]}
  @type variant_entry ::
          {variant_key(), String.t()}
          | {:default, String.t()}
          | {:default_verbosity, integer()}
  @type input :: nil | String.t() | [variant_entry()] | t()

  @typedoc """
  A compiled runner rule. `provider` is an atom or `:*`; `model` is `:any`,
  `{:exact, normalized}`, or `{:list, [normalized]}`; `levels` maps a verbosity
  level to a variant tag (gap-filled); `default_tag` is the rule's fallback tag.
  """
  @type runner_rule :: %{
          provider: atom() | String.t(),
          model: :any | {:exact, String.t()} | {:list, [String.t()]},
          levels: %{optional(0..9) => String.t()},
          default_tag: String.t() | nil
        }

  @type t :: %__MODULE__{
          levels: %{optional(0..9) => String.t()},
          default: String.t() | nil,
          default_verbosity: 0..9 | nil,
          variants: %{optional(String.t()) => String.t()},
          verbosity_map: %{optional(0..9) => String.t()},
          runners: [runner_rule()]
        }

  defstruct levels: %{},
            default: nil,
            default_verbosity: nil,
            variants: %{},
            verbosity_map: %{},
            runners: []

  @doc """
  Normalize a plain `description:` value into `nil`, a bare string, or a
  `%Description{}`.

  Bare strings pass through unchanged (so plain-string tools stay
  byte-identical). A verbosity variant list compiles to a struct, validating the
  domain and rejecting malformed keys or duplicate level coverage. `context`
  names the owning tool/field for error messages.

  For the named-variant / runner-rule form, use `from_opts/2`.
  """
  @spec compile(input(), String.t()) :: nil | String.t() | t()
  def compile(input, context \\ "description")

  def compile(nil, _context), do: nil
  def compile(text, _context) when is_binary(text), do: text
  def compile(%__MODULE__{} = desc, _context), do: desc

  def compile(entries, context) when is_list(entries) do
    Enum.reduce(entries, %__MODULE__{}, &apply_entry(&1, &2, context))
  end

  def compile(other, context) do
    raise ArgumentError,
          "#{context}: expected a string or a verbosity variant list, got: #{inspect(other)}"
  end

  @doc """
  Compile a DSL option set into a description, combining `description:` with the
  named-variant options `descriptions:`, `verbosity_map:`, and `runners:`.

  When none of the three sibling options are present this is exactly
  `compile(opts[:description], context)` — plain strings and §2 variant lists are
  unchanged. When any is present, the `description:` value becomes the base (a
  bare string becomes the `default:` text; a §2 variant list contributes its
  `levels`), then named variants, the verbosity map, and runner rules are layered
  on and every referenced tag is validated.
  """
  @spec from_opts(keyword(), String.t()) :: nil | String.t() | t()
  def from_opts(opts, context) when is_list(opts) do
    base = compile(opts[:description], context)

    has_named? =
      Keyword.has_key?(opts, :descriptions) or
        Keyword.has_key?(opts, :verbosity_map) or
        Keyword.has_key?(opts, :runners)

    if has_named? do
      base
      |> as_struct()
      |> put_variants(opts[:descriptions], context)
      |> put_verbosity_map(opts[:verbosity_map], context)
      |> put_runners(opts[:runners], context)
      |> validate_tags!(context)
    else
      base
    end
  end

  defp as_struct(nil), do: %__MODULE__{}
  defp as_struct(text) when is_binary(text), do: %__MODULE__{default: text}
  defp as_struct(%__MODULE__{} = desc), do: desc

  @doc """
  Resolve a description against a render context, yielding a concrete string or
  `nil`.

  Precedence for the effective level: the context's explicit `verbosity`, then
  the description's `default_verbosity`, then the context's defaults chain, then
  the built-in `5`; the result is clamped to `0..9`.

  Variant precedence (spec §0, first match wins): the most specific matching
  runner rule; then `verbosity_map` (verbosity → tag); then inline `levels`
  (verbosity → text); then the `default:` fallback text (or `nil`).
  """
  @spec resolve(nil | String.t() | t(), RenderCtx.t()) :: String.t() | nil
  def resolve(nil, _ctx), do: nil
  def resolve(text, _ctx) when is_binary(text), do: text

  def resolve(%__MODULE__{} = desc, %RenderCtx{} = ctx) do
    level = effective_level(desc, ctx)

    with nil <- resolve_runner(desc, ctx, level),
         nil <- resolve_verbosity_map(desc, level),
         nil <- resolve_levels(desc, level) do
      desc.default
    end
  end

  # ── runner rules (spec §3) ──────────────────────────────────────────────────

  defp resolve_runner(%__MODULE__{runners: []}, _ctx, _level), do: nil

  defp resolve_runner(%__MODULE__{runners: rules} = desc, ctx, level) do
    with rule when not is_nil(rule) <- best_rule(rules, ctx),
         tag when not is_nil(tag) <- rule_tag(rule, level) do
      # Tag existence is guaranteed by compile-time validation; a stray nil here
      # (e.g. an empty rule) simply falls through to the next precedence tier.
      Map.get(desc.variants, tag)
    else
      _ -> nil
    end
  end

  # Most specific matching rule; declaration order breaks ties (first wins).
  defp best_rule(rules, ctx) do
    rules
    |> Enum.filter(&rule_matches?(&1, ctx))
    |> case do
      [] -> nil
      matching -> Enum.max_by(matching, &rule_specificity/1)
    end
  end

  defp rule_matches?(rule, ctx) do
    provider_matches?(rule.provider, ctx.runner) and model_matches?(rule.model, ctx.model)
  end

  defp provider_matches?(:*, _runner), do: true
  defp provider_matches?(provider, runner), do: norm(provider) == norm(runner)

  defp model_matches?(:any, _model), do: true
  defp model_matches?({:exact, m}, model), do: m == norm(model)
  defp model_matches?({:list, ms}, model), do: norm(model) in ms

  # {model_score, provider_score}: compared lexicographically, so the model
  # matcher dominates the provider matcher (spec §0).
  defp rule_specificity(rule), do: {model_score(rule.model), provider_score(rule.provider)}

  defp model_score({:exact, _}), do: 2
  defp model_score({:list, _}), do: 1
  defp model_score(:any), do: 0

  defp provider_score(:*), do: 0
  defp provider_score(_), do: 1

  defp rule_tag(rule, level) do
    if map_size(rule.levels) > 0 do
      lookup_level(rule.levels, level)
    else
      rule.default_tag
    end
  end

  # ── verbosity_map / inline levels ───────────────────────────────────────────

  defp resolve_verbosity_map(%__MODULE__{verbosity_map: vm} = desc, level) when map_size(vm) > 0 do
    Map.get(desc.variants, lookup_level(vm, level))
  end

  defp resolve_verbosity_map(_desc, _level), do: nil

  defp resolve_levels(%__MODULE__{levels: levels}, level) when map_size(levels) > 0 do
    lookup_level(levels, level)
  end

  defp resolve_levels(_desc, _level), do: nil

  # ── effective level ─────────────────────────────────────────────────────────

  defp effective_level(desc, ctx) do
    cond do
      is_integer(ctx.verbosity) -> ctx.verbosity
      is_integer(desc.default_verbosity) -> desc.default_verbosity
      true -> RenderCtx.effective_verbosity(ctx)
    end
    |> clamp()
  end

  # ── gap-fill ─────────────────────────────────────────────────────────────────

  # Exact hit if the map covers `level`, otherwise gap-fill. Works over any
  # level-keyed map (levels/verbosity_map/rule levels) — the value is text or a
  # tag depending on the map.
  defp lookup_level(map, level) do
    if Map.has_key?(map, level), do: Map.fetch!(map, level), else: gap_fill(map, level)
  end

  defp gap_fill(map, requested) do
    # {distance, level} orders by distance first, then by level — so an exact-tie
    # on distance resolves to the lower level (left preference). The level is a
    # unique map key, so the value never participates in the comparison.
    {_key, value} = Enum.min_by(map, fn {level, _value} -> {abs(level - requested), level} end)
    value
  end

  # ── compile: §2 verbosity variant list ──────────────────────────────────────

  defp apply_entry({:default, text}, acc, _context) when is_binary(text),
    do: %{acc | default: text}

  defp apply_entry({:default, other}, _acc, context) do
    raise ArgumentError, "#{context}: `default:` must be a string, got: #{inspect(other)}"
  end

  defp apply_entry({:default_verbosity, n}, acc, context) do
    validate_level!(n, context)
    %{acc | default_verbosity: n}
  end

  defp apply_entry({{:verbosity, spec}, text}, acc, context) do
    validate_text!(text, context)
    levels = expand_levels(spec, context)
    %{acc | levels: put_levels(acc.levels, levels, text, context, "variant")}
  end

  defp apply_entry(other, _acc, context) do
    raise ArgumentError,
          "#{context}: unrecognized description variant entry: #{inspect(other)} " <>
            "(expected {{:verbosity, n | {lo, hi} | [levels]}, text}, `default:`, " <>
            "or `default_verbosity:`)"
  end

  # ── compile: named variants (§3) ─────────────────────────────────────────────

  defp put_variants(desc, nil, _context), do: desc

  defp put_variants(desc, list, context) when is_list(list) do
    variants =
      Enum.reduce(list, desc.variants, fn
        {tag, text}, acc when is_binary(text) ->
          Map.put(acc, norm_tag!(tag, context), text)

        {tag, other}, _acc ->
          raise ArgumentError,
                "#{context}: variant #{inspect(tag)} text must be a string, got: #{inspect(other)}"

        other, _acc ->
          raise ArgumentError,
                "#{context}: `descriptions:` must be a keyword list of `tag: text`, " <>
                  "bad entry: #{inspect(other)}"
      end)

    %{desc | variants: variants}
  end

  defp put_variants(_desc, other, context) do
    raise ArgumentError,
          "#{context}: `descriptions:` must be a keyword list of `tag: text`, got: #{inspect(other)}"
  end

  defp put_verbosity_map(desc, nil, _context), do: desc

  defp put_verbosity_map(desc, list, context) when is_list(list) do
    map =
      Enum.reduce(list, desc.verbosity_map, fn
        {spec, tag}, acc ->
          levels = expand_levels(spec, context)
          put_levels(acc, levels, norm_tag!(tag, context), context, "verbosity_map")

        other, _acc ->
          raise ArgumentError,
                "#{context}: `verbosity_map:` entry must be `{verbosity_spec, tag}`, " <>
                  "got: #{inspect(other)}"
      end)

    %{desc | verbosity_map: map}
  end

  defp put_verbosity_map(_desc, other, context) do
    raise ArgumentError,
          "#{context}: `verbosity_map:` must be a list of `{verbosity_spec, tag}`, " <>
            "got: #{inspect(other)}"
  end

  defp put_runners(desc, nil, _context), do: desc

  defp put_runners(desc, list, context) when is_list(list) do
    %{desc | runners: desc.runners ++ Enum.map(list, &compile_runner_rule(&1, context))}
  end

  defp put_runners(_desc, other, context) do
    raise ArgumentError,
          "#{context}: `runners:` must be a list of `{{provider, model}, rules}`, " <>
            "got: #{inspect(other)}"
  end

  defp compile_runner_rule({{provider, model_matcher}, rules}, context) when is_list(rules) do
    %{
      provider: compile_provider!(provider, context),
      model: compile_model_matcher!(model_matcher, context),
      levels: compile_rule_levels(rules, context),
      default_tag: compile_rule_default(rules, context)
    }
  end

  defp compile_runner_rule(other, context) do
    raise ArgumentError,
          "#{context}: each runner must be `{{provider, model}, rules}`, got: #{inspect(other)}"
  end

  defp compile_provider!(:*, _context), do: :*
  defp compile_provider!(p, _context) when is_atom(p), do: p
  defp compile_provider!(p, _context) when is_binary(p), do: p

  defp compile_provider!(other, context) do
    raise ArgumentError,
          "#{context}: runner provider must be an atom, a string, or `:*`, got: #{inspect(other)}"
  end

  # `:*` is an atom, so its clause must precede the general atom clause.
  defp compile_model_matcher!(:*, _context), do: :any

  defp compile_model_matcher!(m, _context) when is_atom(m) or is_binary(m), do: {:exact, norm(m)}

  defp compile_model_matcher!(list, context) when is_list(list) do
    {:list,
     Enum.map(list, fn
       m when is_atom(m) or is_binary(m) ->
         norm(m)

       other ->
         raise ArgumentError,
               "#{context}: runner model list members must be atoms or strings, " <>
                 "got: #{inspect(other)}"
     end)}
  end

  defp compile_model_matcher!(other, context) do
    raise ArgumentError,
          "#{context}: runner model matcher must be `:*`, an atom/string, or a list, " <>
            "got: #{inspect(other)}"
  end

  defp compile_rule_levels(rules, context) do
    Enum.reduce(rules, %{}, fn
      {{:verbosity, spec}, tag}, acc ->
        levels = expand_levels(spec, context)
        put_levels(acc, levels, norm_tag!(tag, context), context, "runner rule")

      {:default, _tag}, acc ->
        acc

      other, _acc ->
        raise ArgumentError,
              "#{context}: runner rule entry must be `{{:verbosity, spec}, tag}` or " <>
                "`default: tag`, got: #{inspect(other)}"
    end)
  end

  defp compile_rule_default(rules, context) do
    Enum.reduce(rules, nil, fn
      {:default, tag}, _acc -> norm_tag!(tag, context)
      _entry, acc -> acc
    end)
  end

  # ── compile: shared level machinery ──────────────────────────────────────────

  defp expand_levels(n, context) when is_integer(n) do
    validate_level!(n, context)
    [n]
  end

  defp expand_levels({lo, hi}, context) when is_integer(lo) and is_integer(hi) do
    validate_level!(lo, context)
    validate_level!(hi, context)

    if lo > hi do
      raise ArgumentError,
            "#{context}: verbosity range {#{lo}, #{hi}} is inverted (lo must be ≤ hi)"
    end

    Enum.to_list(lo..hi)
  end

  defp expand_levels(list, context) when is_list(list) do
    Enum.each(list, &validate_level!(&1, context))
    list
  end

  defp expand_levels(spec, context) do
    raise ArgumentError,
          "#{context}: invalid :verbosity selector #{inspect(spec)} " <>
            "(expected an integer, a {lo, hi} range, or a list of integers)"
  end

  defp put_levels(map, levels, value, context, kind) do
    Enum.reduce(levels, map, fn level, acc ->
      if Map.has_key?(acc, level) do
        raise ArgumentError,
              "#{context}: verbosity level #{level} is defined by more than one #{kind} entry"
      end

      Map.put(acc, level, value)
    end)
  end

  defp validate_tags!(desc, context) do
    known = MapSet.new(Map.keys(desc.variants))

    referenced =
      Map.values(desc.verbosity_map) ++
        Enum.flat_map(desc.runners, fn rule ->
          Map.values(rule.levels) ++ List.wrap(rule.default_tag)
        end)

    Enum.each(referenced, fn tag ->
      unless MapSet.member?(known, tag) do
        raise ArgumentError,
              "#{context}: references unknown variant tag #{inspect(tag)}; " <>
                "declared tags: #{inspect(Map.keys(desc.variants))}"
      end
    end)

    desc
  end

  defp validate_level!(n, _context) when is_integer(n) and n in @domain, do: :ok

  defp validate_level!(n, context) do
    raise ArgumentError,
          "#{context}: verbosity level must be an integer in 0..9, got: #{inspect(n)}"
  end

  defp validate_text!(text, _context) when is_binary(text), do: :ok

  defp validate_text!(text, context) do
    raise ArgumentError,
          "#{context}: variant text must be a string, got: #{inspect(text)}"
  end

  defp norm_tag!(tag, _context) when is_atom(tag) and not is_nil(tag), do: Atom.to_string(tag)
  defp norm_tag!(tag, _context) when is_binary(tag), do: tag

  defp norm_tag!(tag, context) do
    raise ArgumentError, "#{context}: variant tag must be an atom or string, got: #{inspect(tag)}"
  end

  defp norm(nil), do: nil
  defp norm(a) when is_atom(a), do: Atom.to_string(a)
  defp norm(s) when is_binary(s), do: s
  defp norm(other), do: to_string(other)

  defp clamp(v), do: v |> max(0) |> min(9)
end
